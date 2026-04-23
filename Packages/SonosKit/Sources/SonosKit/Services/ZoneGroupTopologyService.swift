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
}
