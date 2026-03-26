/// AVTransportService.swift — UPnP AVTransport:1 service wrapper.
///
/// Controls playback (play/pause/stop/seek/next/previous), transport state queries,
/// play mode (shuffle/repeat), sleep timer, and speaker grouping. All actions
/// require InstanceID=0 (Sonos only uses a single instance).
import Foundation

public final class AVTransportService {
    private let soap: SOAPClient
    private static let path = "/MediaRenderer/AVTransport/Control"
    private static let service = "AVTransport"

    public init(soap: SOAPClient = SOAPClient()) {
        self.soap = soap
    }

    public func play(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Play",
            arguments: [("InstanceID", "0"), ("Speed", "1")]
        )
    }

    public func pause(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Pause",
            arguments: [("InstanceID", "0")]
        )
    }

    public func stop(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Stop",
            arguments: [("InstanceID", "0")]
        )
    }

    public func next(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Next",
            arguments: [("InstanceID", "0")]
        )
    }

    public func previous(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Previous",
            arguments: [("InstanceID", "0")]
        )
    }

    public func seek(device: SonosDevice, to time: String) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "Seek",
            arguments: [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", time)]
        )
    }

    public func getTransportInfo(device: SonosDevice) async throws -> TransportState {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetTransportInfo",
            arguments: [("InstanceID", "0")]
        )
        let stateStr = result["CurrentTransportState"] ?? "STOPPED"
        return TransportState(rawValue: stateStr) ?? .stopped
    }

    /// Fetches current track, position, duration, and DIDL metadata in a single call
    public func getPositionInfo(device: SonosDevice) async throws -> TrackMetadata {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetPositionInfo",
            arguments: [("InstanceID", "0")]
        )

        var metadata = TrackMetadata()

        if let didl = result["TrackMetaData"], !didl.isEmpty,
           didl != "NOT_IMPLEMENTED" {
            if let parsed = XMLResponseParser.parseDIDLMetadata(didl) {
                metadata.title = parsed.title
                metadata.artist = parsed.creator
                metadata.album = parsed.album

                // Detect radio/streaming from the track URI or content type
                let trackURI = result["TrackURI"] ?? ""
                let isRadioStream = trackURI.contains("x-sonosapi-stream:") ||
                                    trackURI.contains("x-sonosapi-radio:") ||
                                    trackURI.contains("x-rincon-mp3radio:") ||
                                    trackURI.hasSuffix(".m3u8") ||
                                    trackURI.hasSuffix(".pls") ||
                                    trackURI.contains("tunein.com") ||
                                    parsed.title.lowercased().hasSuffix(".m3u8") ||
                                    parsed.title.lowercased().hasSuffix(".pls") ||
                                    parsed.title.lowercased().hasSuffix(".mp3")

                // r:streamContent has the currently playing track for radio/streams.
                if !parsed.streamContent.isEmpty {
                    let parts = parsed.streamContent.components(separatedBy: " - ")
                    if parts.count >= 2 {
                        metadata.artist = Self.smartCase(parts[0].trimmingCharacters(in: .whitespaces))
                        metadata.title = Self.smartCase(parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces))
                    } else {
                        metadata.title = Self.smartCase(parsed.streamContent)
                    }
                } else if isRadioStream {
                    // No track info from stream — clear title so station name shows alone
                    metadata.title = ""
                    metadata.artist = ""
                }

                // Final safety: clear title if it looks like a technical name
                if Self.looksLikeTechnicalTitle(metadata.title) {
                    metadata.title = ""
                }
                if Self.looksLikeTechnicalTitle(metadata.artist) {
                    metadata.artist = ""
                }

                // Relative art URIs need the device's base URL prepended
                var artURI = parsed.albumArtURI
                if artURI.hasPrefix("/") {
                    artURI = "http://\(device.ip):\(device.port)\(artURI)"
                }
                if artURI.isEmpty, !parsed.resourceURI.isEmpty {
                    let encoded = parsed.resourceURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? parsed.resourceURI
                    artURI = "http://\(device.ip):\(device.port)/getaa?s=1&u=\(encoded)"
                }
                metadata.albumArtURI = artURI.isEmpty ? nil : artURI
            }
        }

        // Detect TV/HDMI and Line-In sources from the track URI.
        // Must run AFTER DIDL parsing — overrides any RINCON ID that appears as title.
        if let trackURI = result["TrackURI"] {
            if trackURI.contains("x-sonos-htastream:") {
                metadata.title = "TV"
                let uriParts = trackURI.components(separatedBy: ":")
                if uriParts.count >= 2 {
                    metadata.artist = uriParts[1]  // RINCON_xxx — resolved to room name by the view
                }
                metadata.album = trackURI.contains(":spdif") ? "HDMI / Optical" : "HDMI"
            } else if trackURI.contains("x-rincon-stream:") {
                metadata.title = "Line-In"
                let uriParts = trackURI.components(separatedBy: ":")
                if uriParts.count >= 2 {
                    metadata.artist = uriParts[1]
                }
                metadata.album = "Analog Input"
            }
        }

        if let relTime = result["RelTime"] {
            metadata.position = TrackMetadata.parseTimeString(relTime)
        }
        if let duration = result["TrackDuration"] {
            metadata.duration = TrackMetadata.parseTimeString(duration)
        }
        if let trackStr = result["Track"], let track = Int(trackStr) {
            metadata.trackNumber = track
        }
        metadata.trackURI = result["TrackURI"]

        return metadata
    }

    public func getMediaInfo(device: SonosDevice) async throws -> [String: String] {
        return try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetMediaInfo",
            arguments: [("InstanceID", "0")]
        )
    }

    // MARK: - Play Mode (Shuffle/Repeat)

    public func getTransportSettings(device: SonosDevice) async throws -> PlayMode {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetTransportSettings",
            arguments: [("InstanceID", "0")]
        )
        let modeStr = result["PlayMode"] ?? "NORMAL"
        return PlayMode(rawValue: modeStr) ?? .normal
    }

    public func setPlayMode(device: SonosDevice, mode: PlayMode) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetPlayMode",
            arguments: [("InstanceID", "0"), ("NewPlayMode", mode.rawValue)]
        )
    }

    // MARK: - Crossfade

    public func getCrossfadeMode(device: SonosDevice) async throws -> Bool {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetCrossfadeMode",
            arguments: [("InstanceID", "0")]
        )
        return result["CrossfadeMode"] == "1"
    }

    public func setCrossfadeMode(device: SonosDevice, enabled: Bool) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetCrossfadeMode",
            arguments: [("InstanceID", "0"), ("CrossfadeMode", enabled ? "1" : "0")]
        )
    }

    // MARK: - Sleep Timer

    public func configureSleepTimer(device: SonosDevice, duration: String) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "ConfigureSleepTimer",
            arguments: [("InstanceID", "0"), ("NewSleepTimerDuration", duration)]
        )
    }

    public func getSleepTimerRemaining(device: SonosDevice) async throws -> String {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetRemainingSleepTimerDuration",
            arguments: [("InstanceID", "0")]
        )
        return result["RemainingSleepTimerDuration"] ?? ""
    }

    // MARK: - Grouping

    /// Sets the transport URI. Used for both playing content (with metadata) and
    /// grouping speakers (x-rincon:{coordinatorID} with no metadata).
    public func setAVTransportURI(device: SonosDevice, uri: String, metadata: String = "") async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetAVTransportURI",
            arguments: [
                ("InstanceID", "0"),
                ("CurrentURI", uri),
                ("CurrentURIMetaData", metadata)
            ]
        )
    }

    /// Detects technical stream/file names that shouldn't be shown as track titles.
    private static func looksLikeTechnicalTitle(_ name: String) -> Bool {
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
        // URL-like
        if name.contains("://") || name.contains("?") || name.contains("&") { return true }
        if name.hasPrefix("http") || name.hasPrefix("x-") { return true }
        return false
    }

    /// Cleans up stream metadata text casing.
    /// - ALL CAPS text (>70% uppercase) is converted to Title Case, preserving Roman numerals.
    /// - All text gets first-letter-after-bracket capitalisation (fixes stream metadata like "(os Caça" → "(Os Caça").
    private static let romanNumerals: Set<String> = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV", "XV", "XVI", "XX"]

    private static func smartCase(_ text: String) -> String {
        var result = text

        // Convert ALL CAPS to title case
        let letters = text.filter { $0.isLetter }
        if !letters.isEmpty {
            let upperCount = letters.filter { $0.isUppercase }.count
            if Double(upperCount) / Double(letters.count) > 0.7 {
                result = text.lowercased().split(separator: " ").map { word in
                    let str = String(word)
                    // Preserve Roman numerals
                    let stripped = str.trimmingCharacters(in: .punctuationCharacters)
                    let original = String(text[word.startIndex..<word.endIndex]).trimmingCharacters(in: .punctuationCharacters)
                    if romanNumerals.contains(original.uppercased()) {
                        // Reattach any leading punctuation
                        let prefix = str.prefix(while: { !$0.isLetter })
                        return prefix + original.uppercased()
                    }
                    // Capitalise first letter (including after punctuation)
                    return capitaliseFirstLetter(str)
                }.joined(separator: " ")
            }
        }

        // Always fix first letter after ( [ / — regardless of overall case
        result = fixBracketCapitalisation(result)
        return result
    }

    /// Capitalises the first letter in a string, even after leading punctuation
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

    /// Capitalises the first letter after ( [ /
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

    public func becomeCoordinatorOfStandaloneGroup(device: SonosDevice) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "BecomeCoordinatorOfStandaloneGroup",
            arguments: [("InstanceID", "0")]
        )
    }
}
