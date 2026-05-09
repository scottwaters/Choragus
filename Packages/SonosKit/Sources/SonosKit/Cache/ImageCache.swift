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

    /// Append-only index of every URL ever stored. The on-disk files
    /// are keyed by DJB2 hash so the URL itself isn't recoverable
    /// from a cache file alone; this index lets callers (e.g.
    /// Club Vis) enumerate cached URLs as a fallback artwork source.
    /// Entries pointing at evicted files are filtered out at read
    /// time. The index can grow unbounded but the file is small
    /// (~100 bytes per URL) and rebuilt lazily.
    private static let urlIndexFileName = "urls.txt"
    private let urlIndexQueue = DispatchQueue(label: "com.choragus.imagecache.urlindex")
    private var pendingURLAppends: [String] = []

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

        // Append to the URL index — debounced via the serial queue so
        // bursts of stores coalesce into a single file write.
        appendToURLIndex(url.absoluteString)

        // Periodically evict (roughly every 50 stores)
        if Int.random(in: 0..<CacheDefaults.imageEvictionFrequency) == 0 {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                self.evictExpiredAndOversized()
            }
        }
    }

    /// Buffers a URL string for the index file and writes batched
    /// appends. Avoids one file write per store on rapid bursts.
    private func appendToURLIndex(_ urlString: String) {
        urlIndexQueue.async { [weak self] in
            guard let self else { return }
            self.pendingURLAppends.append(urlString)
            if self.pendingURLAppends.count >= 25 { self.flushURLIndexLocked() }
        }
        // Schedule a flush in 2 s in case we don't hit the threshold.
        urlIndexQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.flushURLIndexLocked()
        }
    }

    /// MUST be called on `urlIndexQueue`. Appends pending URLs to the
    /// on-disk index file in one write.
    private func flushURLIndexLocked() {
        guard !pendingURLAppends.isEmpty else { return }
        let payload = pendingURLAppends.joined(separator: "\n") + "\n"
        pendingURLAppends.removeAll(keepingCapacity: true)
        guard let data = payload.data(using: .utf8) else { return }
        let path = diskCacheURL.appendingPathComponent(Self.urlIndexFileName)
        if fileManager.fileExists(atPath: path.path) {
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: path, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    /// Returns every URL the index has seen whose cache file still
    /// exists on disk, sampled uniformly across the file's
    /// modification-date timeline. `count` upper-bounds the result.
    /// "Evenly across time" is implemented by sorting surviving URLs
    /// by their cache file's mtime and taking equally-spaced indices.
    public func sampledCachedURLs(count: Int) -> [URL] {
        guard count > 0 else { return [] }
        let path = diskCacheURL.appendingPathComponent(Self.urlIndexFileName)
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        // Dedupe — index can have duplicates because store() doesn't
        // check for existing entries.
        let seenLines = Array(Set(raw.split(separator: "\n").map { String($0) }))
        let withDates: [(url: URL, date: Date)] = seenLines.compactMap { line -> (URL, Date)? in
            guard let url = URL(string: line) else { return nil }
            let key = cacheKey(for: url)
            let filePath = diskCacheURL.appendingPathComponent(key)
            guard let attrs = try? fileManager.attributesOfItem(atPath: filePath.path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (url, date)
        }
        guard !withDates.isEmpty else { return [] }
        let sorted = withDates.sorted { $0.date < $1.date }
        if sorted.count <= count { return sorted.map(\.url) }
        // Equally-spaced sampling for "evenly across time".
        let step = Double(sorted.count) / Double(count)
        var result: [URL] = []
        for i in 0..<count {
            let idx = min(sorted.count - 1, Int(Double(i) * step))
            result.append(sorted[idx].url)
        }
        return result
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
