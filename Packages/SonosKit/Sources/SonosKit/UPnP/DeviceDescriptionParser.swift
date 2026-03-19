import Foundation

public enum DeviceDescriptionParser {
    public static func fetch(from locationURL: String) async throws -> DeviceDescription? {
        guard let url = URL(string: locationURL) else { return nil }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)

        let (data, _) = try await session.data(from: url)
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        return XMLResponseParser.parseDeviceDescription(xml)
    }
}
