/// PlayHistoryManager.swift — Tracks play history with JSON persistence and stats.
import Foundation

@MainActor
public final class PlayHistoryManager: ObservableObject {
    @Published public var entries: [PlayHistoryEntry] = []

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "playHistoryEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "playHistoryEnabled"); objectWillChange.send() }
    }

    private let fileURL: URL
    private var lastLoggedTrack: [String: String] = [:]
    private var saveTask: Task<Void, Never>?
    private static let maxEntries = 10_000

    public init() {
        self.fileURL = AppPaths.appSupportDirectory.appendingPathComponent("play_history.json")

        // Default to enabled
        if !UserDefaults.standard.bool(forKey: "playHistoryEnabledSet") {
            UserDefaults.standard.set(true, forKey: "playHistoryEnabled")
            UserDefaults.standard.set(true, forKey: "playHistoryEnabledSet")
        }

        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder().decode([PlayHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // Prune to max entries
            if self.entries.count > Self.maxEntries {
                self.entries = Array(self.entries.suffix(Self.maxEntries))
            }
            guard let data = try? JSONEncoder().encode(self.entries) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }

    /// Called by SonosManager when track metadata changes
    public func trackMetadataChanged(groupID: String, metadata: TrackMetadata,
                                     groupName: String, transportState: TransportState) {
        guard isEnabled else { return }
        guard transportState == .playing else { return }
        guard !metadata.title.isEmpty else { return }

        let dedupKey = "\(metadata.title)|\(metadata.artist)|\(groupID)"
        guard lastLoggedTrack[groupID] != dedupKey else { return }
        lastLoggedTrack[groupID] = dedupKey

        let entry = PlayHistoryEntry(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            stationName: metadata.stationName,
            sourceURI: metadata.trackURI,
            groupName: groupName,
            duration: metadata.duration,
            albumArtURI: metadata.albumArtURI
        )
        entries.append(entry)
        save()
    }

    public func clearHistory() {
        entries.removeAll()
        lastLoggedTrack.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
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
    /// Radio stations: show once per station name (not per song).
    /// Tracks: show once per title+artist combination.
    public func recentlyPlayed(limit: Int = 20) -> [PlayHistoryEntry] {
        var seen = Set<String>()
        var seenStations = Set<String>() // Track which stations we've seen to skip their individual songs
        var result: [PlayHistoryEntry] = []
        for entry in entries.reversed() {
            guard !entry.title.isEmpty else { continue }

            if !entry.stationName.isEmpty {
                // Radio: dedup by station name, skip individual songs
                let key = "station:\(entry.stationName)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                seenStations.insert(entry.stationName)
                // Use station name as title for display
                var stationEntry = entry
                stationEntry.title = entry.stationName
                result.append(stationEntry)
            } else if let uri = entry.sourceURI, URIPrefix.isRadio(uri) {
                // Radio track without station name — skip if we already have the station
                continue
            } else {
                // Track: dedup by title + artist
                let key = "track:\(entry.title)|\(entry.artist)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(entry)
            }

            if result.count >= limit { break }
        }
        return result
    }

    /// Determines service name from a history entry's source URI
    public func sourceServiceName(for entry: PlayHistoryEntry) -> String {
        if !entry.stationName.isEmpty { return entry.stationName }
        guard let uri = entry.sourceURI else { return "Local" }
        if URIPrefix.isLocal(uri) { return "Music Library" }
        if URIPrefix.isRadio(uri) { return "Radio" }
        let decoded = (uri.removingPercentEncoding ?? uri).replacingOccurrences(of: "&amp;", with: "&")
        if let range = decoded.range(of: "sid=") {
            let numStr = String(decoded[range.upperBound...].prefix(while: { $0.isNumber }))
            if let sid = Int(numStr), let name = ServiceID.knownNames[sid] { return name }
        }
        if decoded.contains("spotify") { return "Spotify" }
        return "Streaming"
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
