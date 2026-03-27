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

    public init(id: String, ip: String, port: Int = SonosProtocol.defaultPort, roomName: String = "",
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

    // swiftlint:disable:next force_unwrapping
    private static let fallbackURL = URL(string: "http://127.0.0.1:1400")!

    public var baseURL: URL {
        URL(string: "http://\(ip):\(port)") ?? Self.fallbackURL
    }

    /// Converts a relative path (e.g. "/getaa?...") to an absolute URL using this device's address.
    /// Returns the original string unchanged if it's already absolute.
    public func makeAbsoluteURL(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return "http://\(ip):\(port)\(path)"
    }
}
