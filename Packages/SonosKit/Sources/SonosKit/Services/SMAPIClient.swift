/// SMAPIClient.swift — SOAP client for Sonos SMAPI (music service) endpoints.
/// Handles authenticated requests with token refresh.
import Foundation

public struct SMAPIServiceDescriptor {
    public let id: Int
    public let name: String
    public let secureUri: String
    public let authType: String // "AppLink", "DeviceLink", "Anonymous", "UserId"
    public let capabilities: Int
}

public struct SMAPIMediaItem {
    public let id: String
    public let title: String
    public let itemType: String // "track", "album", "artist", "playlist", "container", "stream"
    public let artist: String
    public let album: String
    public let albumArtURI: String
    public let canPlay: Bool
    public let canBrowse: Bool
    public let uri: String // for playback
    public let metadata: String // DIDL for playback
}

public final class SMAPIClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    // MARK: - Device Identity

    public func getHouseholdID(speakerIP: String) async throws -> String {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
         s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:GetHouseholdID xmlns:u="urn:schemas-upnp-org:service:DeviceProperties:1"/>
        </s:Body></s:Envelope>
        """
        let result = try await soapCall(
            url: "http://\(speakerIP):\(SonosProtocol.defaultPort)/DeviceProperties/Control",
            action: "urn:schemas-upnp-org:service:DeviceProperties:1#GetHouseholdID",
            body: body
        )
        return extractValue(from: result, tag: "CurrentHouseholdID") ?? ""
    }

    public func getDeviceID(speakerIP: String) async throws -> String {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
         s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:GetString xmlns:u="urn:schemas-upnp-org:service:SystemProperties:1">
        <VariableName>R_TrialZPSerial</VariableName>
        </u:GetString></s:Body></s:Envelope>
        """
        let result = try await soapCall(
            url: "http://\(speakerIP):\(SonosProtocol.defaultPort)/SystemProperties/Control",
            action: "urn:schemas-upnp-org:service:SystemProperties:1#GetString",
            body: body
        )
        return extractValue(from: result, tag: "StringValue") ?? ""
    }

    // MARK: - AppLink Authentication

    public func getAppLink(serviceURI: String, householdID: String, deviceID: String) async throws -> (regUrl: String, linkCode: String) {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
         xmlns:s="http://www.sonos.com/Services/1.1">
        <soap:Header>
        <s:credentials>
        <s:deviceId>\(deviceID)</s:deviceId>
        <s:deviceProvider>Sonos</s:deviceProvider>
        </s:credentials>
        </soap:Header>
        <soap:Body>
        <s:getAppLink>
        <s:householdId>\(householdID)</s:householdId>
        </s:getAppLink>
        </soap:Body></soap:Envelope>
        """
        let result = try await soapCall(
            url: serviceURI,
            action: "http://www.sonos.com/Services/1.1#getAppLink",
            body: body
        )
        let regUrl = extractValue(from: result, tag: "regUrl") ?? ""
        let linkCode = extractValue(from: result, tag: "linkCode") ?? ""
        return (regUrl, linkCode)
    }

    public func getDeviceAuthToken(serviceURI: String, householdID: String, deviceID: String, linkCode: String) async throws -> (authToken: String, privateKey: String)? {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
         xmlns:s="http://www.sonos.com/Services/1.1">
        <soap:Header>
        <s:credentials>
        <s:deviceId>\(deviceID)</s:deviceId>
        <s:deviceProvider>Sonos</s:deviceProvider>
        </s:credentials>
        </soap:Header>
        <soap:Body>
        <s:getDeviceAuthToken>
        <s:householdId>\(householdID)</s:householdId>
        <s:linkCode>\(linkCode)</s:linkCode>
        <s:linkDeviceId>\(deviceID)</s:linkDeviceId>
        </s:getDeviceAuthToken>
        </soap:Body></soap:Envelope>
        """
        let result = try await soapCall(
            url: serviceURI,
            action: "http://www.sonos.com/Services/1.1#getDeviceAuthToken",
            body: body
        )
        // Check for "not linked yet" fault
        if result.contains("NOT_LINKED_RETRY") { return nil }
        let token = extractValue(from: result, tag: "authToken") ?? ""
        let key = extractValue(from: result, tag: "privateKey") ?? ""
        if token.isEmpty { return nil }
        return (token, key)
    }

    // MARK: - Authenticated SMAPI Calls

    public func search(serviceURI: String, token: SMAPIToken, searchID: String = "artist",
                       term: String, index: Int = 0, count: Int = 20) async throws -> (items: [SMAPIMediaItem], total: Int) {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return ([], 0) }
        let clampedCount = min(max(count, 1), 500)
        let body = buildAuthenticatedEnvelope(token: token, bodyContent: """
        <s:search>
        <s:id>\(searchID)</s:id>
        <s:term>\(xmlEscape(term))</s:term>
        <s:index>\(index)</s:index>
        <s:count>\(clampedCount)</s:count>
        </s:search>
        """)
        let result = try await soapCallWithRefresh(
            url: serviceURI,
            action: "http://www.sonos.com/Services/1.1#search",
            body: body,
            token: token
        )
        return parseMediaList(result)
    }

    public func getMetadata(serviceURI: String, token: SMAPIToken, id: String = BrowseID.smapiRoot,
                            index: Int = 0, count: Int = 20) async throws -> (items: [SMAPIMediaItem], total: Int) {
        let body = buildAuthenticatedEnvelope(token: token, bodyContent: """
        <s:getMetadata>
        <s:id>\(xmlEscape(id))</s:id>
        <s:index>\(index)</s:index>
        <s:count>\(count)</s:count>
        </s:getMetadata>
        """)
        let result = try await soapCallWithRefresh(
            url: serviceURI,
            action: "http://www.sonos.com/Services/1.1#getMetadata",
            body: body,
            token: token
        )
        return parseMediaList(result)
    }

    /// Discovers available search categories for a service by browsing the "search" container.
    /// Returns category IDs like ["tracks", "artists", "albums", "playlists"].
    public func getSearchCategories(serviceURI: String, token: SMAPIToken) async throws -> [(id: String, title: String)] {
        let result = try await getMetadata(serviceURI: serviceURI, token: token, id: "search", index: 0, count: 50)
        return result.items.map { ($0.id, $0.title) }
    }

    // MARK: - Internal

    private func buildAuthenticatedEnvelope(token: SMAPIToken, bodyContent: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
         xmlns:s="http://www.sonos.com/Services/1.1">
        <soap:Header>
        <s:credentials>
        <s:deviceId>\(token.deviceID)</s:deviceId>
        <s:deviceProvider>Sonos</s:deviceProvider>
        <s:context/>
        <s:loginToken>
        <s:token>\(token.authToken)</s:token>
        <s:key>\(token.privateKey)</s:key>
        <s:householdId>\(token.householdID)</s:householdId>
        </s:loginToken>
        </s:credentials>
        </soap:Header>
        <soap:Body>
        \(bodyContent)
        </soap:Body></soap:Envelope>
        """
    }

    /// Anonymous SMAPI envelope — for services that don't require auth (e.g. TuneIn)
    public func getMetadataAnonymous(serviceURI: String, deviceID: String, householdID: String = "",
                                     id: String = BrowseID.smapiRoot,
                                     index: Int = 0, count: Int = 20) async throws -> (items: [SMAPIMediaItem], total: Int) {
        let householdElement = householdID.isEmpty ? "" : "<s:householdId>\(householdID)</s:householdId>"
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
         xmlns:s="http://www.sonos.com/Services/1.1">
        <soap:Header>
        <s:credentials>
        <s:deviceId>\(deviceID)</s:deviceId>
        <s:deviceProvider>Sonos</s:deviceProvider>
        \(householdElement)
        </s:credentials>
        </soap:Header>
        <soap:Body>
        <s:getMetadata>
        <s:id>\(xmlEscape(id))</s:id>
        <s:index>\(index)</s:index>
        <s:count>\(count)</s:count>
        </s:getMetadata>
        </soap:Body></soap:Envelope>
        """
        let result = try await soapCall(url: serviceURI, action: "http://www.sonos.com/Services/1.1#getMetadata", body: body)
        return parseMediaList(result)
    }

    public func searchAnonymous(serviceURI: String, deviceID: String, householdID: String = "",
                                searchID: String = "artist",
                                term: String, index: Int = 0, count: Int = 20) async throws -> (items: [SMAPIMediaItem], total: Int) {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return ([], 0) }
        let householdElement = householdID.isEmpty ? "" : "<s:householdId>\(householdID)</s:householdId>"
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
         xmlns:s="http://www.sonos.com/Services/1.1">
        <soap:Header>
        <s:credentials>
        <s:deviceId>\(deviceID)</s:deviceId>
        <s:deviceProvider>Sonos</s:deviceProvider>
        \(householdElement)
        </s:credentials>
        </soap:Header>
        <soap:Body>
        <s:search>
        <s:id>\(searchID)</s:id>
        <s:term>\(xmlEscape(term))</s:term>
        <s:index>\(index)</s:index>
        <s:count>\(count)</s:count>
        </s:search>
        </soap:Body></soap:Envelope>
        """
        let result = try await soapCall(url: serviceURI, action: "http://www.sonos.com/Services/1.1#search", body: body)
        return parseMediaList(result)
    }

    private func soapCallWithRefresh(url: String, action: String, body: String, token: SMAPIToken) async throws -> String {
        let result = try await soapCall(url: url, action: action, body: body)
        // Check for token refresh required
        if result.contains("TokenRefreshRequired") || result.contains("tokenRefreshRequired") {
            if let newToken = extractValue(from: result, tag: "authToken"),
               let newKey = extractValue(from: result, tag: "privateKey") {
                // Notify caller about token refresh (via notification)
                NotificationCenter.default.post(
                    name: .smapiTokenRefreshed,
                    object: nil,
                    userInfo: ["serviceID": token.serviceID, "authToken": newToken, "privateKey": newKey]
                )
                // Retry with new token
                var updated = token
                updated.authToken = newToken
                updated.privateKey = newKey
                let retryBody = buildAuthenticatedEnvelope(token: updated, bodyContent: extractBodyContent(from: body))
                return try await soapCall(url: url, action: action, body: retryBody)
            }
        }
        return result
    }

    private static let sonosUserAgent = "Linux UPnP/1.0 Sonos/79.1-53202 (ACR_SonosController)"

    private func soapCall(url urlStr: String, action: String, body: String) async throws -> String {
        guard let url = URL(string: urlStr) else { throw SMAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(action, forHTTPHeaderField: "SOAPAction")
        request.setValue(Self.sonosUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let responseStr = String(data: data, encoding: .utf8) ?? ""
        if httpResponse?.statusCode == 500 && !responseStr.contains("TokenRefreshRequired") && !responseStr.contains("NOT_LINKED_RETRY") {
            throw SMAPIError.soapFault(responseStr)
        }
        return responseStr
    }

    private func parseMediaList(_ xml: String) -> (items: [SMAPIMediaItem], total: Int) {
        var items: [SMAPIMediaItem] = []
        let total = Int(extractValue(from: xml, tag: "total") ?? "0") ?? 0
        // Parse mediaCollection and mediaMetadata elements
        let collections = extractElements(from: xml, tag: "mediaCollection") + extractElements(from: xml, tag: "mediaMetadata")
        for element in collections {
            let item = SMAPIMediaItem(
                id: extractValue(from: element, tag: "id") ?? "",
                title: extractValue(from: element, tag: "title") ?? "",
                itemType: extractValue(from: element, tag: "itemType") ?? extractAttribute(from: element, tag: "mediaCollection", attr: "itemType") ?? "container",
                artist: extractValue(from: element, tag: "artist") ?? extractValue(from: element, tag: "artistId") ?? "",
                album: extractValue(from: element, tag: "album") ?? "",
                albumArtURI: extractValue(from: element, tag: "albumArtURI") ?? extractValue(from: element, tag: "logo") ?? "",
                canPlay: element.contains("canPlay") ? extractValue(from: element, tag: "canPlay") == "true" : true,
                canBrowse: element.contains("canEnumerate") ? extractValue(from: element, tag: "canEnumerate") == "true" : element.contains("mediaCollection"),
                uri: extractValue(from: element, tag: "uri") ?? "",
                metadata: ""
            )
            if !item.id.isEmpty { items.append(item) }
        }
        return (items, total > 0 ? total : items.count)
    }

    // MARK: - XML Helpers

    /// Extracts a value from XML, handling namespace prefixes (e.g. <ns1:regUrl>)
    private func extractValue(from xml: String, tag: String) -> String? {
        // Try without namespace first, then with any namespace prefix
        let patterns = [
            ("<\(tag)>", "</\(tag)>"),           // <regUrl>...</regUrl>
            ("<\(tag) ", "</\(tag)>"),            // <regUrl attr>...</regUrl>
        ]
        for (openPattern, closePattern) in patterns {
            if let start = xml.range(of: openPattern),
               let end = xml.range(of: closePattern, range: start.upperBound..<xml.endIndex) {
                if let gtRange = xml[start.upperBound..<end.lowerBound].range(of: ">") {
                    return unescape(String(xml[gtRange.upperBound..<end.lowerBound]))
                }
                return unescape(String(xml[start.upperBound..<end.lowerBound]))
            }
        }
        // Try with namespace prefix (ns1:tag, ns2:tag, etc.)
        let nsPattern = ":\(tag)>"
        if let nsStart = xml.range(of: nsPattern) {
            // Walk back to find the < before the namespace
            let beforeNs = xml[xml.startIndex..<nsStart.lowerBound]
            if let openBracket = beforeNs.lastIndex(of: "<") {
                let fullOpenEnd = nsStart.upperBound
                // Find closing tag with same namespace
                let prefix = String(xml[xml.index(after: openBracket)..<nsStart.lowerBound]) // e.g. "ns1"
                let closeTag = "</\(prefix):\(tag)>"
                if let end = xml.range(of: closeTag, range: fullOpenEnd..<xml.endIndex) {
                    return unescape(String(xml[fullOpenEnd..<end.lowerBound]))
                }
            }
        }
        return nil
    }

    private func unescape(_ str: String) -> String {
        XMLResponseParser.xmlUnescape(str)
    }

    private func extractElements(from xml: String, tag: String) -> [String] {
        var elements: [String] = []
        // Try both plain and namespaced tags
        for pattern in ["<\(tag)", ":\(tag)"] {
            var searchRange = xml.startIndex..<xml.endIndex
            while let start = xml.range(of: pattern, range: searchRange) {
                // For namespaced, walk back to find <
                let openStart: String.Index
                if pattern.hasPrefix(":") {
                    guard let bracket = xml[xml.startIndex..<start.lowerBound].lastIndex(of: "<") else {
                        searchRange = start.upperBound..<xml.endIndex
                        continue
                    }
                    openStart = bracket
                } else {
                    openStart = start.lowerBound
                }
                // Find closing tag
                let closePatterns = ["</\(tag)>", ":\(tag)>"]
                var found = false
                for close in closePatterns {
                    if let end = xml.range(of: close, range: start.upperBound..<xml.endIndex) {
                        // Include the full closing tag
                        let endIdx = xml.index(end.upperBound, offsetBy: 0, limitedBy: xml.endIndex) ?? end.upperBound
                        elements.append(String(xml[openStart..<endIdx]))
                        searchRange = endIdx..<xml.endIndex
                        found = true
                        break
                    }
                }
                if !found { break }
            }
            if !elements.isEmpty { break } // Found with this pattern, don't try the other
        }
        return elements
    }

    private func extractAttribute(from xml: String, tag: String, attr: String) -> String? {
        guard let tagRange = xml.range(of: "<\(tag)"),
              let attrRange = xml.range(of: "\(attr)=\"", range: tagRange.upperBound..<xml.endIndex),
              let endQuote = xml.range(of: "\"", range: attrRange.upperBound..<xml.endIndex) else { return nil }
        return String(xml[attrRange.upperBound..<endQuote.lowerBound])
    }

    private func extractBodyContent(from envelope: String) -> String {
        guard let bodyStart = envelope.range(of: "<soap:Body>"),
              let bodyEnd = envelope.range(of: "</soap:Body>") else { return "" }
        return String(envelope[bodyStart.upperBound..<bodyEnd.lowerBound])
    }

    private func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Error Types

public enum SMAPIError: Error, LocalizedError {
    case invalidURL
    case soapFault(String)
    case notAuthenticated
    case authFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid service URL"
        case .soapFault(let detail): return "Service error: \(detail.prefix(200))"
        case .notAuthenticated: return "Not signed in to this service"
        case .authFailed(let reason): return "Authentication failed: \(reason)"
        }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let smapiTokenRefreshed = Notification.Name("smapiTokenRefreshed")
}
