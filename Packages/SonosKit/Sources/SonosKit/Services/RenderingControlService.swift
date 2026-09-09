import Foundation

/// The RenderingControl capabilities `VolumeController` needs. Narrow on
/// purpose: the controller depends on reading and writing volume and mute,
/// not on the whole SOAP service, and a stub satisfies it in tests.
public protocol RenderingControlling: Sendable {
    func getVolume(device: SonosDevice) async throws -> Int
    func setVolume(device: SonosDevice, volume: Int) async throws
    func getMute(device: SonosDevice) async throws -> Bool
    func setMute(device: SonosDevice, muted: Bool) async throws
    func getOutputFixed(device: SonosDevice) async -> Bool
}

public final class RenderingControlService: RenderingControlling, EQServiceProtocol {
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

    /// Whether the device's line-out volume is set to Fixed. Connect / Port /
    /// Amp line-outs can be locked to a fixed level in the Sonos app; when
    /// fixed, `SetVolume` faults UPnP 501. Returns false on any
    /// error so a transient failure doesn't disable the slider.
    public func getOutputFixed(device: SonosDevice) async -> Bool {
        guard let result = try? await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetOutputFixed",
            arguments: [("InstanceID", "0")]
        ) else { return false }
        return result["CurrentFixed"] == "1"
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

    // MARK: - Home Theater EQ (Sub / Surrounds / Night Mode)

    public func getEQ(device: SonosDevice, eqType: String) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetEQ",
            arguments: [("InstanceID", "0"), ("EQType", eqType)]
        )
        return Int(result["CurrentValue"] ?? "0") ?? 0
    }

    public func setEQ(device: SonosDevice, eqType: String, value: Int) async throws {
        _ = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "SetEQ",
            arguments: [("InstanceID", "0"), ("EQType", eqType), ("DesiredValue", "\(value)")]
        )
    }
}
