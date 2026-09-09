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

    /// Largest accepted description document. A real Sonos description
    /// is ~30 KB; the cap bounds what a hostile LAN host can make this
    /// process buffer.
    static let maxDescriptionBytes = 256 * 1024

    public static func fetch(from locationURL: String) async throws -> DeviceDescription? {
        guard let url = URL(string: locationURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let (bytes, _) = try await session.bytes(from: url)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxDescriptionBytes { return nil }
        }
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        return XMLResponseParser.parseDeviceDescription(xml)
    }
}
