import Foundation

public final class ZoneGroupTopologyService {
    private let soap: SOAPClient
    private static let path = "/ZoneGroupTopology/Control"
    private static let service = "ZoneGroupTopology"

    public init(soap: SOAPClient = SOAPClient()) {
        self.soap = soap
    }

    public func getZoneGroupState(device: SonosDevice) async throws -> [ZoneGroupData] {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "GetZoneGroupState",
            arguments: []
        )

        guard let state = result["ZoneGroupState"] else {
            return []
        }

        return XMLResponseParser.parseZoneGroupState(state)
    }

    /// Queries DeviceProperties for the device's household ID (stable per Sonos system).
    /// S1 and S2 systems on the same LAN return different household IDs,
    /// which is the discriminator used to merge topology refreshes correctly.
    public func getHouseholdID(device: SonosDevice) async throws -> String {
        let result = try await soap.send(
            to: device.baseURL,
            path: "/DeviceProperties/Control",
            service: "DeviceProperties",
            action: "GetHouseholdID",
            arguments: []
        )
        return result["CurrentHouseholdID"] ?? ""
    }

    /// Queries DeviceProperties for the speaker's current home-theater
    /// audio input format. Returns Sonos's undocumented `HTAudioIn`
    /// integer bitfield, which encodes stereo PCM / multichannel PCM /
    /// Dolby Digital / Dolby Atmos for whatever is on the HDMI ARC /
    /// eARC / optical / TOSLink input. Caller should only invoke this
    /// when the coordinator's `trackURI` begins with `x-sonos-htastream:`
    /// or `x-rincon-stream:`; the field is meaningless otherwise.
    public func getHTAudioIn(device: SonosDevice) async throws -> Int {
        let result = try await soap.send(
            to: device.baseURL,
            path: "/DeviceProperties/Control",
            service: "DeviceProperties",
            action: "GetZoneInfo",
            arguments: []
        )
        guard let raw = result["HTAudioIn"], let value = Int(raw) else { return 0 }
        return value
    }
}
