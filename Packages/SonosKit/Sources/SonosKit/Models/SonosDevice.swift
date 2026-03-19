import Foundation

public struct SonosDevice: Identifiable, Hashable {
    public let id: String // UUID like RINCON_xxxx
    public let ip: String
    public let port: Int
    public var roomName: String
    public var modelName: String
    public var modelNumber: String
    public var isCoordinator: Bool
    public var groupID: String?

    public init(id: String, ip: String, port: Int = 1400, roomName: String = "",
                modelName: String = "", modelNumber: String = "",
                isCoordinator: Bool = false, groupID: String? = nil) {
        self.id = id
        self.ip = ip
        self.port = port
        self.roomName = roomName
        self.modelName = modelName
        self.modelNumber = modelNumber
        self.isCoordinator = isCoordinator
        self.groupID = groupID
    }

    public var baseURL: URL {
        URL(string: "http://\(ip):\(port)")!
    }
}
