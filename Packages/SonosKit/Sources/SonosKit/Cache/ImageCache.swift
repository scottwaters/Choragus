/// ImageCache.swift — Two-tier (memory + disk) album art cache with LRU eviction.
///
/// Memory tier: NSCache with 200 items / 50 MB cost limit (auto-evicted by OS).
/// Disk tier: JPEG files keyed by a DJB2 hash of the URL, stored in Application Support.
/// Eviction runs on startup and probabilistically (~1 in 50 stores) to avoid overhead.
/// The modification date is used as "last accessed" for LRU ordering.
import Foundation
import AppKit
import ImageIO

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
    /// Single concurrent queue for EVERY disk + index operation.
    /// Reads (`image`, sampling, stats) run in parallel via plain
    /// `.sync`; every mutation (store, remove, eviction, clear, index
    /// flush) takes a `.barrier`. `pendingURLAppends` is accessed
    /// exclusively on this queue. A serial queue would let one long read
    /// (a 1200-URL sample enumeration) park every other caller.
    private let diskQueue = DispatchQueue(label: "com.choragus.imagecache.disk",
                                          qos: .utility, attributes: .concurrent)
    private var pendingURLAppends: [String] = []

    /// Bumped when a defect made STORED images wrong, so a fixed build
    /// discards what the broken one wrote instead of serving it forever.
    /// The stored file gives no clue that it is damaged, so the whole
    /// disk tier goes; art re-fetches lazily as it is shown.
    ///
    /// 2 — non-square art was cropped with a rectangle measured in
    /// `NSImage` points against the pixel-space `CGImage`. For art
    /// tagged above 72 DPI that stored a magnified corner of the cover
    /// (a 639x640 cover at 300 DPI kept its top-left 154x154 pixels).
    /// 3 — art fetched over the network was centre-cropped to a square
    /// before storage. Harmless for album art, which is already square;
    /// an artist photo is a tall portrait, so the square kept its middle
    /// and cut the head off. Images are now stored as fetched.
    private static let purgeGeneration = 3

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

        // A generation bump discards everything a broken build stored.
        // The flag is written before the wipe runs: a crash mid-wipe
        // leaves a partly-emptied cache, which is self-healing, while
        // re-running the wipe on every launch would not be.
        let ranGeneration = UserDefaults.standard.integer(forKey: UDKey.imageCachePurgeGeneration)
        let needsPurge = ranGeneration < Self.purgeGeneration
        if needsPurge {
            UserDefaults.standard.set(Self.purgeGeneration, forKey: UDKey.imageCachePurgeGeneration)
        }

        // Run eviction on startup in background (on the disk queue so it
        // can't race concurrent reads/stores)
        diskQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            if needsPurge {
                self.wipeDiskContents()
                sonosDiagLog(.info, tag: "CACHE",
                             "Art cache purged — stored images predate a decoding fix",
                             context: ["generation": String(Self.purgeGeneration)])
            }
            self.evictExpiredAndOversized()
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
        return diskQueue.sync { readFromDisk(key: key) }
    }

    public func memoryImage(for url: URL, maxPixelSize: Int? = nil) -> NSImage? {
        memoryCache.object(forKey: Self.memoryKey(cacheKey(for: url), maxPixelSize: maxPixelSize))
    }

    /// The disk read runs on the disk queue and the caller suspends, so
    /// no view pays a file read on the main thread.
    ///
    /// `maxPixelSize` asks for a decoded thumbnail. A full-size
    /// `NSImage(data:)` keeps the JPEG and decodes it again whenever it
    /// is drawn at a new size (a 300-cell cover grid re-decodes 300 JPEGs
    /// per relayout). The thumbnail is a bitmap already decoded at
    /// ≤ `maxPixelSize`, cached under its own key, and draws as a plain scale.
    public func diskImage(for url: URL, maxPixelSize: Int? = nil) async -> NSImage? {
        let key = cacheKey(for: url)
        if let img = memoryCache.object(forKey: Self.memoryKey(key, maxPixelSize: maxPixelSize)) {
            return img
        }
        return await withCheckedContinuation { continuation in
            diskQueue.async { [weak self] in
                continuation.resume(returning: self?.readFromDisk(key: key, maxPixelSize: maxPixelSize))
            }
        }
    }

    private static func memoryKey(_ key: String, maxPixelSize: Int?) -> NSString {
        (maxPixelSize.map { "\(key)@\($0)" } ?? key) as NSString
    }

    /// Disk tier read. Must run on `diskQueue`. Expired files are
    /// removed and read as a miss; a hit fills the memory tier and
    /// touches the file for LRU.
    private func readFromDisk(key: String, maxPixelSize: Int? = nil) -> NSImage? {
        let filePath = diskCacheURL.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: filePath) else { return nil }
        if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > maxAgeSeconds {
            try? fileManager.removeItem(at: filePath)
            return nil
        }
        let img: NSImage?
        let cost: Int
        if let maxPixelSize {
            img = Self.decodedThumbnail(from: data, maxPixelSize: maxPixelSize)
            cost = maxPixelSize * maxPixelSize * 4
        } else {
            img = NSImage(data: data)
            cost = data.count
        }
        guard let img else { return nil }
        memoryCache.setObject(img, forKey: Self.memoryKey(key, maxPixelSize: maxPixelSize), cost: cost)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: filePath.path)
        return img
    }

    /// ImageIO thumbnail: decoded once, at most `maxPixelSize` on the
    /// longer side, backed by a bitmap rather than the encoded bytes.
    private static func decodedThumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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
        // Schedule a flush in 2 s in case the threshold is not reached.
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
        diskQueue.sync(flags: .barrier) { wipeDiskContents() }
    }

    /// Empties the disk tier. Callers hold the `diskQueue` barrier.
    /// Buffered index appends are discarded as part of the same wipe —
    /// flushing them afterwards would resurrect index entries for files
    /// that no longer exist.
    private func wipeDiskContents() {
        pendingURLAppends.removeAll()
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        invalidateDiskStats()
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
