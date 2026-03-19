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
}
