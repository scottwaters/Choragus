/// ImageCache.swift — Two-tier (memory + disk) album art cache with LRU eviction.
///
/// Memory tier: NSCache with 200 items / 50 MB cost limit (auto-evicted by OS).
/// Disk tier: JPEG files keyed by a DJB2 hash of the URL, stored in Application Support.
/// Eviction runs on startup and probabilistically (~1 in 50 stores) to avoid overhead.
/// The modification date is used as "last accessed" for LRU ordering.
import Foundation
import AppKit

public final class ImageCache: ImageCacheProtocol {
    public static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskCacheURL: URL
    private let fileManager = FileManager.default
    private var cachedDiskUsage: Int?
    private var cachedFileCount: Int?

    private static let maxSizeMBKey = "imageCacheMaxSizeMB"
    private static let maxAgeDaysKey = "imageCacheMaxAgeDays"
    private static let defaultMaxSizeMB = CacheDefaults.imageDiskMaxSizeMB
    private static let defaultMaxAgeDays = CacheDefaults.imageDiskMaxAgeDays

    public var maxSizeMB: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: UDKey.imageCacheMaxSizeMB)
            return val > 0 ? val : Self.defaultMaxSizeMB
        }
        set {
            UserDefaults.standard.set(newValue, forKey: UDKey.imageCacheMaxSizeMB)
        }
    }

    public var maxAgeDays: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: UDKey.imageCacheMaxAgeDays)
            return val > 0 ? val : Self.defaultMaxAgeDays
        }
        set {
            UserDefaults.standard.set(newValue, forKey: UDKey.imageCacheMaxAgeDays)
        }
    }

    private var maxDiskBytes: Int { maxSizeMB * 1024 * 1024 }
    private var maxAgeSeconds: TimeInterval { TimeInterval(maxAgeDays) * 86400 }

    private init() {
        diskCacheURL = AppPaths.appSupportDirectory.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        memoryCache.countLimit = CacheDefaults.imageMemoryCountLimit
        memoryCache.totalCostLimit = CacheDefaults.imageMemoryBytesLimit

        // Run eviction on startup in background
        DispatchQueue.global(qos: .utility).async { [weak self] in guard let self else { return };
            evictExpiredAndOversized()
        }
    }

    /// DJB2 hash of the URL string — fast, good distribution, no crypto overhead
    private func cacheKey(for url: URL) -> String {
        let str = url.absoluteString
        var hash: UInt64 = 5381
        for byte in str.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    public func image(for url: URL) -> NSImage? {
        let key = cacheKey(for: url)

        if let img = memoryCache.object(forKey: key as NSString) {
            return img
        }

        let filePath = diskCacheURL.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: filePath),
              let img = NSImage(data: data) else {
            return nil
        }

        // Check if this file has expired
        if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > maxAgeSeconds {
            // Expired — remove from disk, don't return
            try? fileManager.removeItem(at: filePath)
            return nil
        }

        let cost = data.count
        memoryCache.setObject(img, forKey: key as NSString, cost: cost)
        // Touch file to update access time for LRU
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: filePath.path)
        return img
    }

    public func store(_ image: NSImage, for url: URL) {
        let key = cacheKey(for: url)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return
        }

        memoryCache.setObject(image, forKey: key as NSString, cost: data.count)

        let filePath = diskCacheURL.appendingPathComponent(key)
        try? data.write(to: filePath, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)

        invalidateDiskStats()

        // Periodically evict (roughly every 50 stores)
        if Int.random(in: 0..<CacheDefaults.imageEvictionFrequency) == 0 {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                self.evictExpiredAndOversized()
            }
        }
    }

    public func clearDisk() {
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        invalidateDiskStats()
    }

    public func clearMemory() {
        memoryCache.removeAllObjects()
    }

    public var diskUsage: Int {
        if let cached = cachedDiskUsage { return cached }
        let value = computeDiskUsage()
        cachedDiskUsage = value
        return value
    }

    private func computeDiskUsage() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }

    public var diskUsageString: String {
        let bytes = diskUsage
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    public var fileCount: Int {
        if let cached = cachedFileCount { return cached }
        let value = (try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil))?.count ?? 0
        cachedFileCount = value
        return value
    }

    /// Invalidates cached disk stats (call after store/clear/evict)
    private func invalidateDiskStats() {
        cachedDiskUsage = nil
        cachedFileCount = nil
    }

    /// Two-pass eviction: (1) remove files older than maxAge, (2) if still over
    /// maxDiskBytes, sort remaining by modification date (LRU) and delete oldest first.
    private func evictExpiredAndOversized() {
        guard let files = try? fileManager.contentsOfDirectory(at: diskCacheURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }

        let now = Date()
        var totalSize = 0
        var fileInfos: [(url: URL, size: Int, date: Date)] = []

        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { continue }

            // Remove expired files immediately
            if now.timeIntervalSince(date) > maxAgeSeconds {
                try? fileManager.removeItem(at: file)
                continue
            }

            totalSize += size
            fileInfos.append((file, size, date))
        }

        // Evict oldest files if over size limit
        guard totalSize > maxDiskBytes else { return }

        fileInfos.sort { $0.date < $1.date }

        for info in fileInfos {
            guard totalSize > maxDiskBytes else { break }
            try? fileManager.removeItem(at: info.url)
            totalSize -= info.size
        }
    }
}
