/// PlayHistoryManager.swift — Play history business logic and stats.
///
/// Owns the in-memory entries list and delegates all persistence to
/// PlayHistoryRepository. Provides dedup logic, stats computation,
/// and export functionality.
import Foundation

@MainActor
public final class PlayHistoryManager: ObservableObject {
    @Published public var entries: [PlayHistoryEntry] = []

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UDKey.playHistoryEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.playHistoryEnabled); objectWillChange.send() }
    }

    private let repo: PlayHistoryRepository
    private var lastLoggedTrack: [String: String] = [:]
    private var reloadTask: Task<Void, Never>?

    // Legacy JSON path for migration
    private let legacyJSONURL: URL

    public init() {
        let dbPath = AppPaths.appSupportDirectory.appendingPathComponent("play_history.sqlite").path
        self.repo = PlayHistoryRepository(dbPath: dbPath)
        self.legacyJSONURL = AppPaths.appSupportDirectory.appendingPathComponent("play_history.json")

        // Default to enabled
        if !UserDefaults.standard.bool(forKey: UDKey.playHistoryEnabledSet) {
            UserDefaults.standard.set(true, forKey: UDKey.playHistoryEnabled)
            UserDefaults.standard.set(true, forKey: UDKey.playHistoryEnabledSet)
        }

        migrateFromJSONIfNeeded()
        loadEntries()
    }

    // MARK: - Loading

    private func loadEntries() {
        entries = repo.loadAll()
        pruneIfNeeded()
    }

    private func pruneIfNeeded() {
        let max = PlayHistoryRepository.maxEntries
        guard entries.count > max else { return }
        let toRemove = entries.count - max
        let idsToDelete = entries.prefix(toRemove).map(\.id)
        repo.delete(ids: idsToDelete)
        entries.removeFirst(toRemove)
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Timing.reloadDebounce)
            guard !Task.isCancelled, let self else { return }
            self.loadEntries()
        }
    }

    private func migrateFromJSONIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyJSONURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyJSONURL),
              let jsonEntries = try? JSONDecoder().decode([PlayHistoryEntry].self, from: data),
              !jsonEntries.isEmpty else { return }

        sonosDebugLog("[HISTORY] Migrating \(jsonEntries.count) entries from JSON to SQLite")
        repo.insertBatch(jsonEntries)
        try? FileManager.default.removeItem(at: legacyJSONURL)
        sonosDebugLog("[HISTORY] Migration complete, removed JSON file")
    }

    // MARK: - Track Logging

    /// Called by SonosManager when track metadata changes
    public func trackMetadataChanged(groupID: String, metadata: TrackMetadata,
                                     groupName: String, transportState: TransportState) {
        guard isEnabled else { return }
        guard transportState == .playing else { return }
        // For radio with no track data, log the station name
        var metadata = metadata
        if metadata.title.isEmpty && !metadata.stationName.isEmpty {
            metadata.title = metadata.stationName
        }
        guard !metadata.title.isEmpty else { return }
        // Don't log radio ad breaks (no real track info)
        guard !metadata.isAdBreak else { return }

        // Normalize whitespace for dedup (radio streams often vary trailing spaces)
        let normTitle = metadata.title.trimmingCharacters(in: .whitespaces)
        let normArtist = metadata.artist.trimmingCharacters(in: .whitespaces)
        let dedupKey = "\(normTitle)|\(normArtist)|\(groupID)"
        guard lastLoggedTrack[groupID] != dedupKey else { return }

        // Dedup window: use track duration + buffer, minimum 60s for radio, 10min for others
        let trackDuration = metadata.duration > 0 ? metadata.duration : 300
        let dedupWindow: TimeInterval = metadata.isRadioStream ? max(60, trackDuration + 30) : max(600, trackDuration + 60)
        let cutoff = Date().timeIntervalSince1970 - dedupWindow
        if repo.hasRecentEntry(title: normTitle, artist: normArtist, groupName: groupName, since: cutoff) {
            lastLoggedTrack[groupID] = dedupKey
            return
        }

        lastLoggedTrack[groupID] = dedupKey

        // Only persist internet art URLs — speaker-local /getaa URLs are ephemeral
        // and break after IP changes or restarts. updateArtwork() will backfill
        // from iTunes search when it completes.
        let artURI: String?
        if let art = metadata.albumArtURI, !art.isEmpty, !art.contains("/getaa?") {
            artURI = art
        } else {
            artURI = nil
        }

        let entry = PlayHistoryEntry(
            title: TrackMetadata.filterDeviceID(metadata.title),
            artist: TrackMetadata.filterDeviceID(metadata.artist),
            album: metadata.album,
            stationName: metadata.stationName,
            sourceURI: metadata.trackURI,
            groupName: groupName,
            duration: metadata.duration,
            albumArtURI: artURI
        )
        repo.insert(entry)
        entries.append(entry)

        // Search for track-specific art if missing or only has a generic station logo
        let needsArt = artURI == nil || (metadata.isRadioStream && !metadata.stationName.isEmpty)
        if needsArt && !entry.title.isEmpty && entry.title != metadata.stationName {
            let title = entry.title
            let artist = entry.artist
            let isRadio = metadata.isRadioStream
            Task {
                let artURL: String?
                if isRadio {
                    artURL = await AlbumArtSearchService.shared.searchRadioTrackArt(
                        artist: artist, title: AlbumArtSearchService.cleanTrackTitle(title)
                    )
                } else {
                    artURL = await AlbumArtSearchService.shared.searchArtwork(
                        artist: artist, album: entry.album.isEmpty ? title : entry.album
                    )
                }
                if let artURL {
                    updateArtwork(forTitle: title, artist: artist, artURL: artURL)
                }
            }
        }
    }

    /// Updates the album art URI for entries matching title+artist.
    /// Also matches entries with empty artist (radio tracks logged before artist parsing was fixed).
    public func updateArtwork(forTitle title: String, artist: String, artURL: String) {
        var didUpdate = false
        for i in entries.indices.reversed() {
            let titleMatch = entries[i].title == title
            let artistMatch = entries[i].artist == artist ||
                              entries[i].artist.isEmpty || artist.isEmpty
            if titleMatch && artistMatch {
                if entries[i].albumArtURI != artURL {
                    entries[i].albumArtURI = artURL
                    repo.updateArtwork(id: entries[i].id, artURL: artURL)
                    didUpdate = true
                }
            }
        }
        // Trigger @Published notification so history view refreshes
        if didUpdate {
            entries = entries
        }
    }

    /// Query filtered entries via SQLite — efficient for large datasets.
    /// Source filtering still done in-memory after the SQL query.
    public func queryFiltered(since: Date? = nil, until: Date? = nil,
                              room: String? = nil, source: String? = nil,
                              searchText: String? = nil,
                              sortNewestFirst: Bool = true) -> [PlayHistoryEntry] {
        var result = repo.loadFiltered(since: since, until: until, room: room,
                                        searchText: searchText, sortNewestFirst: sortNewestFirst)
        // Source filtering requires URI pattern matching — done in-memory
        if let source {
            result = result.filter { sourceServiceName(for: $0) == source }
        }
        return result
    }

    /// Count filtered entries via SQLite (fast, no data loading)
    public func countFiltered(since: Date? = nil, until: Date? = nil,
                              room: String? = nil, searchText: String? = nil) -> Int {
        repo.countFiltered(since: since, until: until, room: room, searchText: searchText)
    }

    /// Toggle starred status on an entry
    public func toggleStar(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].starred.toggle()
        repo.setStarred(id: id, starred: entries[idx].starred)
    }

    /// Star the most recent entry matching this title+artist (for starring the currently playing track)
    public func starCurrentTrack(title: String, artist: String) {
        for i in entries.indices.reversed() {
            if entries[i].title == title && entries[i].artist == artist {
                if !entries[i].starred {
                    entries[i].starred = true
                    repo.setStarred(id: entries[i].id, starred: true)
                }
                return
            }
        }
    }

    /// All starred entries
    public var starredEntries: [PlayHistoryEntry] {
        entries.filter(\.starred).sorted { $0.timestamp > $1.timestamp }
    }

    public func clearHistory() {
        entries.removeAll()
        lastLoggedTrack.removeAll()
        repo.deleteAll()
    }

    // MARK: - Stats

    public var totalEntries: Int { entries.count }

    public var totalListeningHours: Double {
        entries.reduce(0) { $0 + $1.duration } / 3600.0
    }

    public var uniqueArtists: [String] {
        Array(Set(entries.compactMap { $0.artist.isEmpty ? nil : $0.artist })).sorted()
    }

    public var uniqueRooms: [String] {
        Array(Set(entries.compactMap { $0.groupName.isEmpty ? nil : $0.groupName })).sorted()
    }

    /// Returns the most recent unique tracks/stations, deduplicated.
    public func recentlyPlayed(limit: Int = 20) -> [PlayHistoryEntry] {
        var seen = Set<String>()
        var seenStations = Set<String>()
        var result: [PlayHistoryEntry] = []
        for entry in entries.reversed() {
            guard !entry.title.isEmpty else { continue }

            if !entry.stationName.isEmpty {
                let key = "station:\(entry.stationName)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                seenStations.insert(entry.stationName)
                var stationEntry = entry
                stationEntry.title = entry.stationName
                result.append(stationEntry)
            } else if let uri = entry.sourceURI, URIPrefix.isRadio(uri) {
                continue
            } else {
                let key = "track:\(entry.title)|\(entry.artist)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(entry)
            }

            if result.count >= limit { break }
        }
        return result
    }

    /// Determines service name from a history entry's source URI.
    /// Returns the streaming service (e.g. "Sonos Radio", "TuneIn", "Spotify"),
    /// not the station name — station name is shown separately in metadata.
    public func sourceServiceName(for entry: PlayHistoryEntry) -> String {
        guard let uri = entry.sourceURI else { return ServiceName.local }
        let decoded = (uri.removingPercentEncoding ?? uri).replacingOccurrences(of: "&amp;", with: "&")

        // Check sid= first — identifies the specific service (Sonos Radio, TuneIn, Calm Radio, etc.)
        if let range = decoded.range(of: "sid=") {
            let numStr = String(decoded[range.upperBound...].prefix(while: { $0.isNumber }))
            if let sid = Int(numStr), let name = ServiceID.knownNames[sid] { return name }
        }

        if URIPrefix.isLocal(uri) { return ServiceName.musicLibrary }
        if URIPrefix.isRadio(uri) { return ServiceName.radio }
        if decoded.contains("spotify") { return ServiceName.spotify }
        if decoded.contains("apple") { return ServiceName.appleMusic }
        if decoded.contains("amazon") || decoded.contains("amzn") { return ServiceName.amazonMusic }
        return ServiceName.streaming
    }

    /// Plays per day for the last N days (fills in zeros for days with no plays)
    public func dailyActivity(days: Int = 30) -> [(Date, Int)] {
        let calendar = Calendar.current
        let now = Date()
        var counts: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            counts[day, default: 0] += 1
        }
        return (0..<days).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!)
            return (day, counts[day] ?? 0)
        }
    }

    /// Plays per hour of day (0-23) across all history
    public var hourlyDistribution: [(Int, Int)] {
        let calendar = Calendar.current
        var counts = [Int](repeating: 0, count: 24)
        for entry in entries {
            let hour = calendar.component(.hour, from: entry.timestamp)
            counts[hour] += 1
        }
        return counts.enumerated().map { ($0.offset, $0.element) }
    }

    /// Peak listening hour
    public var peakHour: Int {
        hourlyDistribution.max(by: { $0.1 < $1.1 })?.0 ?? 12
    }

    /// Source distribution for pie chart
    public var sourceDistribution: [(String, Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            let source = sourceServiceName(for: entry)
            counts[source, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    public var mostPlayedArtists: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty {
            counts[e.artist, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    public var mostPlayedTracks: [(String, String, Int)] {
        var counts: [String: Int] = [:]
        var trackArtist: [String: String] = [:]
        for e in entries where !e.title.isEmpty {
            let key = "\(e.title)|\(e.artist)"
            counts[key, default: 0] += 1
            trackArtist[key] = e.artist
        }
        return counts.sorted { $0.value > $1.value }.map { (key, count) in
            let parts = key.components(separatedBy: "|")
            return (parts[0], parts.count > 1 ? parts[1] : "", count)
        }
    }

    public var mostPlayedStations: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !e.stationName.isEmpty {
            counts[e.stationName, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    // MARK: - Extended Stats

    public var mostPlayedAlbums: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !e.album.isEmpty {
            counts[e.album, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    public var uniqueAlbumCount: Int {
        Set(entries.compactMap { $0.album.isEmpty ? nil : $0.album }).count
    }

    public var uniqueStationCount: Int {
        Set(entries.compactMap { $0.stationName.isEmpty ? nil : $0.stationName }).count
    }

    /// Plays grouped by day of week (0=Sunday, 1=Monday, ..., 6=Saturday)
    public var dayOfWeekDistribution: [(String, Int)] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols // ["Sun", "Mon", ...]
        var counts = [Int](repeating: 0, count: 7)
        for entry in entries {
            let weekday = calendar.component(.weekday, from: entry.timestamp) - 1 // 0-based
            counts[weekday] += 1
        }
        return counts.enumerated().map { (symbols[$0.offset], $0.element) }
    }

    /// Longest consecutive-day listening streak
    public var listeningStreak: Int {
        guard !entries.isEmpty else { return 0 }
        let calendar = Calendar.current
        let days = Set(entries.map { calendar.startOfDay(for: $0.timestamp) }).sorted()
        guard !days.isEmpty else { return 0 }
        var maxStreak = 1
        var current = 1
        for i in 1..<days.count {
            if calendar.dateComponents([.day], from: days[i-1], to: days[i]).day == 1 {
                current += 1
                maxStreak = max(maxStreak, current)
            } else {
                current = 1
            }
        }
        return maxStreak
    }

    /// Current active streak (consecutive days ending today or yesterday)
    public var currentStreak: Int {
        guard !entries.isEmpty else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = Set(entries.map { calendar.startOfDay(for: $0.timestamp) }).sorted().reversed()
        guard let latest = days.first else { return 0 }
        // Must include today or yesterday to be "active"
        let diff = calendar.dateComponents([.day], from: latest, to: today).day ?? 99
        guard diff <= 1 else { return 0 }
        var streak = 1
        var prev = latest
        for day in days.dropFirst() {
            if calendar.dateComponents([.day], from: day, to: prev).day == 1 {
                streak += 1
                prev = day
            } else {
                break
            }
        }
        return streak
    }

    /// Average plays per day (over days that had at least one play)
    public var averagePlaysPerDay: Double {
        let calendar = Calendar.current
        let uniqueDays = Set(entries.map { calendar.startOfDay(for: $0.timestamp) }).count
        guard uniqueDays > 0 else { return 0 }
        return Double(entries.count) / Double(uniqueDays)
    }

    /// Per-room play counts
    public var roomDistribution: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !e.groupName.isEmpty {
            counts[e.groupName, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    // MARK: - Export

    public func exportCSV() -> String {
        let formatter = ISO8601DateFormatter()
        var csv = "Date,Title,Artist,Album,Station,Room,Duration\n"
        for e in entries {
            let date = formatter.string(from: e.timestamp)
            let dur = String(format: "%.0f", e.duration)
            csv += "\(csvEscape(date)),\(csvEscape(e.title)),\(csvEscape(e.artist)),\(csvEscape(e.album)),\(csvEscape(e.stationName)),\(csvEscape(e.groupName)),\(dur)\n"
        }
        return csv
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
