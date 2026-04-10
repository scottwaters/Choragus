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

    /// Seeks to a position. Time must be in HH:MM:SS format.
    public func seek(device: SonosDevice, to time: String) async throws {
        let parts = time.split(separator: ":")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else {
            sonosDebugLog("[AVTransport] Invalid seek time format: \(time)")
            return
        }
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
        metadata.trackURI = result["TrackURI"]

        // Debug: log what the speaker returns for service tracks
        if let uri = result["TrackURI"], uri.contains("x-sonos-http") {
            let didlFull = result["TrackMetaData"] ?? "nil"
            sonosDebugLog("[POSITION] Apple Music track — URI: \(uri.prefix(80)), Track#: \(result["Track"] ?? "nil"), DIDL: \(didlFull)")
        }

        if let didl = result["TrackMetaData"], !didl.isEmpty,
           didl != "NOT_IMPLEMENTED" {
            // Base DIDL extraction (title, artist, album, art)
            metadata.enrichFromDIDL(didl, device: device)

            // Radio/stream-specific: parse r:streamContent for current track info
            let parsed = XMLResponseParser.parseDIDLMetadata(didl)
            // Fallback: if streamContent is empty (bare & breaks XML parser), extract with string matching
            let streamContent: String? = {
                if let sc = parsed?.streamContent, !sc.isEmpty { return sc }
                return XMLResponseParser.extractStreamContent(didl)
            }()
            let trackURI = result["TrackURI"] ?? ""
            let isRadio = URIPrefix.isRadio(trackURI) ||
                          trackURI.hasSuffix(".m3u8") || trackURI.hasSuffix(".pls")

            if let content = streamContent, !content.isEmpty {
                if let stream = TrackMetadata.parseStreamContent(content) {
                    metadata.artist = stream.artist
                    metadata.title = stream.title
                }
            } else if isRadio {
                metadata.title = ""
                metadata.artist = ""
            }

            if let parsed {

                // Clear technical-looking names
                if TrackMetadata.isTechnicalName(metadata.title) {
                    sonosDebugLog("[POSITION] Cleared technical title: '\(metadata.title)'")
                    metadata.title = ""
                }
                if TrackMetadata.isTechnicalName(metadata.artist) { metadata.artist = "" }

                // Fallback art via /getaa if DIDL had no art
                if metadata.albumArtURI == nil, !parsed.resourceURI.isEmpty {
                    metadata.albumArtURI = AlbumArtSearchService.getaaURL(
                        speakerIP: device.ip, port: device.port, trackURI: parsed.resourceURI)
                }
            }
        }

        // Detect TV/HDMI and Line-In sources from the track URI.
        // Must run AFTER DIDL parsing — overrides any RINCON ID that appears as title.
        if let trackURI = result["TrackURI"] {
            if trackURI.contains("x-sonos-htastream:") {
                metadata.title = "TV"
                metadata.artist = ""
                metadata.album = trackURI.contains(":spdif") ? "HDMI / Optical" : "HDMI"
            } else if trackURI.contains("x-rincon-stream:") {
                metadata.title = "Line-In"
                metadata.artist = ""
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

        if let uri = result["TrackURI"], uri.contains("x-sonos-http") {
            sonosDebugLog("[POSITION] Result — title: '\(metadata.title)', artist: '\(metadata.artist)', album: '\(metadata.album)', art: '\(metadata.albumArtURI ?? "nil")', track#: \(metadata.trackNumber)")
        }

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
