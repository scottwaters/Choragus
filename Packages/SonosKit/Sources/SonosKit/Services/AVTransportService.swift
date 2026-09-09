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

    /// Asks the speaker which transport commands it currently accepts.
    /// Only meaningful on a group coordinator — members report an empty
    /// list. Returns nil when the speaker reports nothing, so callers can
    /// distinguish "not allowed" from "unknown".
    public func getCurrentTransportActions(device: SonosDevice) async throws -> TransportActions? {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetCurrentTransportActions",
            arguments: [("InstanceID", "0")]
        )
        return TransportActions.parse(result["Actions"] ?? "")
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

        if let didl = result["TrackMetaData"], !didl.isEmpty,
           didl != "NOT_IMPLEMENTED" {
            // DIDL parsing + enrichment moved off the caller's actor.
            // The two parses below run `NSXMLParser` synchronously on
            // strings that can be several KB; on the @MainActor caller
            // this added 3–6 ms per position-info poll to the main
            // thread. `Task.detached` hops the work to the cooperative
            // pool. Inputs are value types; result is returned as a
            // Sendable tuple.
            let didlInput = didl
            let baseMetadata = metadata
            let device = device
            let (enriched, parsedDIDL, streamContent) =
                await Task.detached(priority: .userInitiated) {
                    var m = baseMetadata
                    m.enrichFromDIDL(didlInput, device: device)
                    let parsed = XMLResponseParser.parseDIDLMetadata(didlInput)
                    let extracted: String?
                    if let sc = parsed?.streamContent, !sc.isEmpty {
                        extracted = sc
                    } else {
                        extracted = XMLResponseParser.extractStreamContent(didlInput)
                    }
                    return (m, parsed, extracted)
                }.value
            metadata = enriched
            let parsed = parsedDIDL
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
