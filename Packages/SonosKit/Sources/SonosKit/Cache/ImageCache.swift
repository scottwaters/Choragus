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
    // Guarded by `statsLock`: written from art-fetch threads (every
    // `store` invalidates) while the Settings UI reads on main — an
    // unsynchronized Optional<Int> is a two-word torn-read hazard.
    private let statsLock = NSLock()
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
    /// Single serial queue for EVERY disk + index operation (read,
    /// store, sample, clear, eviction, stat computation). image files,
    /// the URL index, and the pending-append buffer were previously
    /// touched from unrelated threads (art fetches, Settings UI,
    /// eviction on a global queue) with only index writes serialized.
    /// `pendingURLAppends` is accessed exclusively on this queue.
    /// CONCURRENT queue: reads (`image`, sampling, stats) run in
    /// parallel via plain `.sync`; every mutation (store, remove,
    /// eviction, clear, index flush) takes a `.barrier`. The previous
    /// serial queue meant a long read (Club Vis's 1200-URL sample
    /// enumeration + pool resolution reads) parked every other
    /// caller — observed as ~1.3 s main stalls whenever a main-side
    /// art resolver missed memory cache during a pool build.
    private let diskQueue = DispatchQueue(label: "com.choragus.imagecache.disk",
                                          qos: .utility, attributes: .concurrent)
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

        // Run eviction on startup in background (on the disk queue so it
        // can't race concurrent reads/stores)
        diskQueue.async(flags: .barrier) { [weak self] in
            self?.evictExpiredAndOversized()
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

        return diskQueue.sync {
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
    }

    /// Evicts one URL from memory and disk. For entries whose source
    /// has become permanently unfetchable (dead speaker `getaa`,
    /// removed CDN object) — a stale cached image would otherwise
    /// resurface after the caller's failure bookkeeping resets. The
    /// URL-index line is left in place; a sampled URL with no backing
    /// file resolves to a miss.
    public func remove(for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.removeObject(forKey: key as NSString)
        diskQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            try? self.fileManager.removeItem(at: self.diskCacheURL.appendingPathComponent(key))
            self.invalidateDiskStats()
        }
    }

    public func store(_ image: NSImage, for url: URL) {
        let key = cacheKey(for: url)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return
        }

        memoryCache.setObject(image, forKey: key as NSString, cost: data.count)

        // Disk write, index append, and (occasionally) eviction all run
        // on the disk queue so stores can't interleave with reads,
        // sampling, clears, or eviction.
        diskQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let filePath = self.diskCacheURL.appendingPathComponent(key)
            try? data.write(to: filePath, options: .atomic)
            try? self.fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)

            self.invalidateDiskStats()

            self.appendToURLIndex(url.absoluteString)

            // Periodically evict (roughly every 50 stores)
            if Int.random(in: 0..<CacheDefaults.imageEvictionFrequency) == 0 {
                self.evictExpiredAndOversized()
            }
        }
    }

    /// MUST be called on `diskQueue`. Buffers a URL string for the
    /// index file and writes batched appends — avoids one file write
    /// per store on rapid bursts.
    private func appendToURLIndex(_ urlString: String) {
        pendingURLAppends.append(urlString)
        if pendingURLAppends.count >= 25 { flushURLIndexLocked() }
        // Schedule a flush in 2 s in case we don't hit the threshold.
        diskQueue.asyncAfter(deadline: .now() + 2.0, flags: .barrier) { [weak self] in
            self?.flushURLIndexLocked()
        }
    }

    /// MUST be called on `diskQueue`. Appends pending URLs to the
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
        return diskQueue.sync { sampledCachedURLsLocked(count: count) }
    }

    /// MUST be called on `diskQueue`.
    private func sampledCachedURLsLocked(count: Int) -> [URL] {
        // Fold any buffered appends in first so just-stored art is
        // visible to the sample.
        flushURLIndexLocked()
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
        diskQueue.sync(flags: .barrier) {
            // Discard buffered index appends atomically with the wipe —
            // flushing them afterwards would resurrect index entries for
            // files that no longer exist.
            pendingURLAppends.removeAll()
            try? fileManager.removeItem(at: diskCacheURL)
            try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
            invalidateDiskStats()
        }
    }

    public func clearMemory() {
        memoryCache.removeAllObjects()
    }

    public var diskUsage: Int {
        statsLock.lock()
        if let cached = cachedDiskUsage {
            statsLock.unlock()
            return cached
        }
        statsLock.unlock()
        let value = diskQueue.sync { computeDiskUsage() }
        statsLock.lock()
        cachedDiskUsage = value
        statsLock.unlock()
        return value
    }

    /// MUST be called on `diskQueue`.
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
        statsLock.lock()
        if let cached = cachedFileCount {
            statsLock.unlock()
            return cached
        }
        statsLock.unlock()
        let value = diskQueue.sync {
            (try? fileManager.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil))?.count ?? 0
        }
        statsLock.lock()
        cachedFileCount = value
        statsLock.unlock()
        return value
    }

    /// Invalidates cached disk stats (call after store/clear/evict)
    private func invalidateDiskStats() {
        statsLock.lock()
        defer { statsLock.unlock() }
        cachedDiskUsage = nil
        cachedFileCount = nil
    }

    /// MUST be called on `diskQueue`.
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
