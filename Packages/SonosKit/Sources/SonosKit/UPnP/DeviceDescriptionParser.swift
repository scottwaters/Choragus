import Foundation

public enum DeviceDescriptionParser {
    /// Shared session (one connection pool for all description fetches).
    /// 3 s timeout: a live speaker answers /xml/device_description.xml in
    /// tens of milliseconds on LAN; anything slower is a dead or stale
    /// address, and long timeouts gate fresh discoveries behind dead ones
    /// (post-VLAN-move cache/mDNS staleness made live speakers appear
    /// minutes late).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    public static func fetch(from locationURL: String) async throws -> DeviceDescription? {
        guard let url = URL(string: locationURL) else { return nil }
        let (data, _) = try await session.data(from: url)
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        return XMLResponseParser.parseDeviceDescription(xml)
    }
}
