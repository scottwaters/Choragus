import Foundation

public final class RenderingControlService {
    private let soap: SOAPClient
    private static let path = "/MediaRenderer/RenderingControl/Control"
    private static let service = "RenderingControl"

    public init(soap: SOAPClient = SOAPClient()) {
        self.soap = soap
    }

    public func getVolume(device: SonosDevice) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetVolume",
            arguments: [("InstanceID", "0"), ("Channel", "Master")]
        )
        return Int(result["CurrentVolume"] ?? "0") ?? 0
    }

    public func setVolume(device: SonosDevice, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetVolume",
            arguments: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", "\(clamped)")]
        )
    }

    public func getMute(device: SonosDevice) async throws -> Bool {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetMute",
            arguments: [("InstanceID", "0"), ("Channel", "Master")]
        )
        return result["CurrentMute"] == "1"
    }

    public func setMute(device: SonosDevice, muted: Bool) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetMute",
            arguments: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")]
        )
    }

    public func getBass(device: SonosDevice) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetBass",
            arguments: [("InstanceID", "0")]
        )
        return Int(result["CurrentBass"] ?? "0") ?? 0
    }

    public func setBass(device: SonosDevice, bass: Int) async throws {
        let clamped = max(-10, min(10, bass))
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetBass",
            arguments: [("InstanceID", "0"), ("DesiredBass", "\(clamped)")]
        )
    }

    public func getTreble(device: SonosDevice) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetTreble",
            arguments: [("InstanceID", "0")]
        )
        return Int(result["CurrentTreble"] ?? "0") ?? 0
    }

    public func setTreble(device: SonosDevice, treble: Int) async throws {
        let clamped = max(-10, min(10, treble))
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetTreble",
            arguments: [("InstanceID", "0"), ("DesiredTreble", "\(clamped)")]
        )
    }

    public func getLoudness(device: SonosDevice) async throws -> Bool {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetLoudness",
            arguments: [("InstanceID", "0"), ("Channel", "Master")]
        )
        return result["CurrentLoudness"] == "1"
    }

    public func setLoudness(device: SonosDevice, enabled: Bool) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetLoudness",
            arguments: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredLoudness", enabled ? "1" : "0")]
        )
    }
}
