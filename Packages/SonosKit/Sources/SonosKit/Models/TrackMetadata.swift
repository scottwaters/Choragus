import Foundation

public struct TrackMetadata: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtURI: String?
    public var duration: TimeInterval
    public var position: TimeInterval
    public var trackNumber: Int
    public var queueSize: Int
    public var stationName: String
    public var trackURI: String?
    public var isQueueSource: Bool  // true when CurrentURI is x-rincon-queue (playing from queue)

    public init(title: String = "", artist: String = "", album: String = "",
                albumArtURI: String? = nil, duration: TimeInterval = 0,
                position: TimeInterval = 0, trackNumber: Int = 0, queueSize: Int = 0,
                stationName: String = "", isQueueSource: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURI = albumArtURI
        self.duration = duration
        self.position = position
        self.trackNumber = trackNumber
        self.queueSize = queueSize
        self.stationName = stationName
        self.isQueueSource = isQueueSource
    }

    // MARK: - Computed State

    /// True when a radio station is playing but track details are absent (ad break, buffer, etc.)
    public var isAdBreak: Bool {
        guard isRadioStream || !stationName.isEmpty else { return false }
        if title.isEmpty { return true }
        if title == stationName && artist.isEmpty { return true }
        return false
    }

    /// True if the track URI indicates a radio/internet stream
    public var isRadioStream: Bool {
        trackURI.map(URIPrefix.isRadio) ?? false
    }

    // MARK: - Formatting

    public var durationString: String { formatTime(duration) }
    public var positionString: String { formatTime(position) }

    private func formatTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Extracts the Sonos service ID (sid=NNN) from the track URI, if present.
    public var serviceID: Int? {
        guard let uri = trackURI, let range = uri.range(of: "sid=") else { return nil }
        let after = uri[range.upperBound...]
        let numStr = after.prefix(while: { $0.isNumber })
        return Int(numStr)
    }

    // MARK: - RINCON Device ID Filtering

    public static func isDeviceID(_ value: String) -> Bool {
        value.hasPrefix("RINCON_")
    }

    public static func filterDeviceID(_ value: String) -> String {
        isDeviceID(value) ? "" : value
    }

    // MARK: - DIDL Enrichment (single source of truth for all DIDL parsing)

    /// Enriches metadata from a raw DIDL-Lite XML string.
    /// Handles XML-escaped input, extracts title, artist, album, art URI.
    /// Art URIs are made absolute using the provided device address.
    /// Used by: AVTransportService, TransportStrategy, BrowseItemArtLoader, enrichFromMediaInfo.
    public mutating func enrichFromDIDL(_ rawDIDL: String, device: SonosDevice) {
        guard !rawDIDL.isEmpty, rawDIDL != "NOT_IMPLEMENTED" else { return }
        let didl = rawDIDL.contains("&lt;") ? XMLResponseParser.xmlUnescape(rawDIDL) : rawDIDL
        guard let parsed = XMLResponseParser.parseDIDLMetadata(didl) else { return }

        if title.isEmpty { title = parsed.title }
        if artist.isEmpty { artist = parsed.creator }
        if album.isEmpty { album = parsed.album }

        let artURI = device.makeAbsoluteURL(parsed.albumArtURI)
        if !artURI.isEmpty {
            albumArtURI = artURI
        }
    }

    /// Enriches metadata from GetMediaInfo's CurrentURIMetaData DIDL.
    /// Extracts station name for radio streams in addition to standard DIDL fields.
    public mutating func enrichFromMediaInfo(_ mediaInfo: [String: String], device: SonosDevice) {
        guard let rawDIDL = mediaInfo["CurrentURIMetaData"] else { return }
        let currentURI = mediaInfo["CurrentURI"] ?? ""

        // Detect if playing from queue vs direct stream/favorite
        isQueueSource = currentURI.hasPrefix(URIPrefix.rinconQueue)

        // Set queue size from NrTracks
        if let nrTracks = mediaInfo["NrTracks"], let n = Int(nrTracks) {
            queueSize = n
        }

        // Save current title/artist — enrichFromDIDL only fills empty fields
        let hadTitle = !title.isEmpty
        enrichFromDIDL(rawDIDL, device: device)

        // For radio streams, DIDL title is the station name
        if let parsed = Self.quickParseDIDLTitle(rawDIDL),
           URIPrefix.isRadio(currentURI), !parsed.isEmpty {
            stationName = parsed
            // If title was set from DIDL but it's just the station name, keep it
            if !hadTitle && title == parsed {
                // title is the station name — that's fine for now, track info may come later
            }
        }
    }

    /// Quick parse to get just the title from DIDL without full parsing.
    private static func quickParseDIDLTitle(_ rawDIDL: String) -> String? {
        guard !rawDIDL.isEmpty, rawDIDL != "NOT_IMPLEMENTED" else { return nil }
        let didl = rawDIDL.contains("&lt;") ? XMLResponseParser.xmlUnescape(rawDIDL) : rawDIDL
        return XMLResponseParser.parseDIDLMetadata(didl)?.title
    }

    // MARK: - Stream Content Parsing

    /// Parses "Artist - Title" from radio stream content, applying smartCase cleanup.
    /// Single source of truth — called by AVTransportService and TransportStrategy.
    public static func parseStreamContent(_ content: String) -> (artist: String, title: String)? {
        guard !content.isEmpty else { return nil }
        let parts = content.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = smartCase(parts[0].trimmingCharacters(in: .whitespaces))
            let title = smartCase(parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces))
            return (artist, title)
        }
        return (artist: "", title: smartCase(content))
    }

    // MARK: - Technical Name Detection

    /// Detects technical stream/file names that should not be shown as track titles or artist names.
    /// Single source of truth — replaces looksLikeTechnicalTitle and looksLikeTechnicalName.
    public static func isTechnicalName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let lower = name.lowercased()
        // File extensions
        if lower.hasSuffix(".mp3") || lower.hasSuffix(".mp4") || lower.hasSuffix(".m3u8") ||
           lower.hasSuffix(".m3u") || lower.hasSuffix(".pls") || lower.hasSuffix(".aac") ||
           lower.hasSuffix(".ogg") || lower.hasSuffix(".flac") || lower.hasSuffix(".wav") { return true }
        // No spaces + has dot = filename
        if name.contains(".") && !name.contains(" ") { return true }
        // No spaces + has underscores = technical ID
        if name.contains("_") && !name.contains(" ") { return true }
        // URL-like (only flag & and ? when no spaces — real artist names like "Hall & Oates" have spaces)
        if name.contains("://") { return true }
        if (name.contains("?") || name.contains("&")) && !name.contains(" ") { return true }
        if name.hasPrefix("http") || name.hasPrefix("x-") { return true }
        // Single-character alphanumeric codes with digits (e.g. not real names)
        if name.count == 1 && name.first?.isNumber == true { return true }
        return false
    }

    // MARK: - Smart Case (Stream Metadata Cleanup)

    private static let romanNumerals: Set<String> = [
        "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
        "XI", "XII", "XIII", "XIV", "XV", "XVI", "XX"
    ]

    /// Cleans up stream metadata text casing.
    /// ALL CAPS text (>70% uppercase) is converted to Title Case, preserving Roman numerals.
    /// First letter after brackets is capitalised.
    public static func smartCase(_ text: String) -> String {
        var result = text
        let letters = text.filter { $0.isLetter }
        if !letters.isEmpty {
            let upperCount = letters.filter { $0.isUppercase }.count
            if Double(upperCount) / Double(letters.count) > 0.7 {
                result = text.lowercased().split(separator: " ").map { word in
                    let str = String(word)
                    let original = String(text[word.startIndex..<word.endIndex]).trimmingCharacters(in: .punctuationCharacters)
                    if romanNumerals.contains(original.uppercased()) {
                        let prefix = str.prefix(while: { !$0.isLetter })
                        return prefix + original.uppercased()
                    }
                    return capitaliseFirstLetter(str)
                }.joined(separator: " ")
            }
        }
        result = fixBracketCapitalisation(result)
        return result
    }

    private static func capitaliseFirstLetter(_ str: String) -> String {
        var result = ""
        var done = false
        for char in str {
            if !done && char.isLetter {
                result.append(contentsOf: char.uppercased())
                done = true
            } else {
                result.append(char)
            }
        }
        return result
    }

    private static func fixBracketCapitalisation(_ text: String) -> String {
        var result = ""
        var capitaliseNext = false
        for char in text {
            if capitaliseNext && char.isLetter {
                result.append(contentsOf: char.uppercased())
                capitaliseNext = false
            } else {
                result.append(char)
                if char == "(" || char == "[" || char == "/" {
                    capitaliseNext = true
                } else if char != " " {
                    capitaliseNext = false
                }
            }
        }
        return result
    }

    // MARK: - Time Parsing

    public static func parseTimeString(_ time: String) -> TimeInterval {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}
