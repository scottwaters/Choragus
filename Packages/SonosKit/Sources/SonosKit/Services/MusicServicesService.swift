import Foundation

public struct MusicService: Identifiable, Equatable {
    public let id: Int
    public var name: String
    public var uri: String
    public var secureURI: String
    public var containerType: String
    public var capabilities: String

    public init(id: Int, name: String = "", uri: String = "", secureURI: String = "",
                containerType: String = "", capabilities: String = "") {
        self.id = id
        self.name = name
        self.uri = uri
        self.secureURI = secureURI
        self.containerType = containerType
        self.capabilities = capabilities
    }
}

public final class MusicServicesService {
    private let soap: SOAPClient
    private static let path = "/MusicServices/Control"
    private static let service = "MusicServices"

    public init(soap: SOAPClient = SOAPClient()) {
        self.soap = soap
    }

    public func listAvailableServices(device: SonosDevice) async throws -> [MusicService] {
        let result = try await soap.send(
            to: device.baseURL,
            path: Self.path,
            service: Self.service,
            action: "ListAvailableServices",
            arguments: []
        )

        guard let descriptor = result["AvailableServiceDescriptorList"] else { return [] }
        return MusicServiceXMLParser.parse(descriptor)
    }
}

// MARK: - Parser

private class MusicServiceXMLParser: NSObject, XMLParserDelegate {
    private var services: [MusicService] = []

    static func parse(_ xml: String) -> [MusicService] {
        // The descriptor list arrives from the SOAP layer already
        // unescaped exactly once — valid XML. A second unescape turned
        // `&amp;` inside Uri/SecureUri attributes into bare `&`, aborting
        // the parse and silently dropping every service after that point
        // (same defect class as issue #81).
        guard let data = xml.data(using: .utf8) else { return [] }
        let handler = MusicServiceXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        guard parser.parse() else {
            sonosDiagLog(.error, tag: "SERVICES",
                         "Service descriptor parse aborted — discarding partial list",
                         context: ["parserError": String(describing: parser.parserError),
                                   "servicesBeforeAbort": String(handler.services.count)])
            return []
        }
        return handler.services
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "Service" {
            let service = MusicService(
                id: Int(attributes["Id"] ?? "0") ?? 0,
                name: attributes["Name"] ?? "",
                uri: attributes["Uri"] ?? "",
                secureURI: attributes["SecureUri"] ?? "",
                containerType: attributes["ContainerType"] ?? "",
                capabilities: attributes["Capabilities"] ?? ""
            )
            if !service.name.isEmpty {
                services.append(service)
            }
        }
    }
}
