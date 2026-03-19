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

        if let didl = result["TrackMetaData"], !didl.isEmpty {
            if let parsed = XMLResponseParser.parseDIDLMetadata(didl) {
                metadata.title = parsed.title
                metadata.artist = parsed.creator
                metadata.album = parsed.album

                // Relative art URIs need the device's base URL prepended
                var artURI = parsed.albumArtURI
                if artURI.hasPrefix("/") {
                    artURI = "http://\(device.ip):\(device.port)\(artURI)"
                }
                metadata.albumArtURI = artURI.isEmpty ? nil : artURI
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
