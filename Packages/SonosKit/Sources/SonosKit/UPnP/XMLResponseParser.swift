/// XMLResponseParser.swift — Umbrella for all XML/SAX parsing in the Sonos UPnP stack.
///
/// Contains specialized parsers for: SOAP responses, device descriptions, zone group
/// topology, and DIDL-Lite metadata. Each uses Foundation's XMLParser (SAX) rather than
/// DOM parsing, since Sonos XML can be deeply nested with escaped inner XML (e.g.
/// ZoneGroupState contains XML-escaped XML inside a SOAP response — two layers deep).
import Foundation

public enum XMLResponseParser {

    // MARK: - SOAP Response Parsing

    public static func parseActionResponse(_ xml: String, action: String) -> [String: String] {
        let parser = SimpleXMLParser()
        parser.parse(xml)
        return parser.elements
    }

    public static func parseFault(_ xml: String) -> (code: String, string: String) {
        let parser = SimpleXMLParser()
        parser.parse(xml)
        let code = parser.elements["errorCode"] ?? parser.elements["faultcode"] ?? "Unknown"
        let string = parser.elements["faultstring"] ?? "Unknown error"
        return (code, string)
    }

    // MARK: - Device Description Parsing

    public static func parseDeviceDescription(_ xml: String) -> DeviceDescription? {
        let parser = SimpleXMLParser()
        parser.parse(xml)
        guard let udn = parser.elements["UDN"] else { return nil }

        let uuid = udn.replacingOccurrences(of: "uuid:", with: "")
        return DeviceDescription(
            uuid: uuid,
            roomName: parser.elements["roomName"] ?? parser.elements["friendlyName"] ?? "Unknown",
            modelName: parser.elements["modelName"] ?? "",
            modelNumber: parser.elements["modelNumber"] ?? "",
            displayName: parser.elements["displayName"] ?? ""
        )
    }

    // MARK: - Zone Group Topology Parsing

    /// The ZoneGroupState is double-encoded: XML-escaped content inside a SOAP XML element.
    /// We must unescape the outer layer to get valid inner XML for the SAX parser.
    public static func parseZoneGroupState(_ xml: String) -> [ZoneGroupData] {
        let unescaped = xmlUnescape(xml)
        let parser = ZoneGroupParser()
        return parser.parse(unescaped)
    }

    // MARK: - DIDL-Lite Metadata Parsing

    public static func parseDIDLMetadata(_ didl: String) -> DIDLItem? {
        guard !didl.isEmpty else { return nil }
        // Do NOT xmlUnescape — the SOAP SAX parser already unescaped the outer layer.
        // The DIDL XML still has valid &amp; entities in URLs that must stay escaped.
        let parser = DIDLParser()
        return parser.parse(didl)
    }

    // MARK: - Helpers

    static func xmlUnescape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

// MARK: - Data Types

public struct DeviceDescription {
    public let uuid: String
    public let roomName: String
    public let modelName: String
    public let modelNumber: String
    public let displayName: String
}

public struct ZoneGroupData {
    public let id: String
    public let coordinatorUUID: String
    public var members: [ZoneMemberData]
}

public struct ZoneMemberData {
    public let uuid: String
    public let location: String
    public let zoneName: String
    public let ip: String
    public let port: Int
    public let isInvisible: Bool
}

public struct DIDLItem {
    public var title: String = ""
    public var creator: String = ""
    public var album: String = ""
    public var albumArtURI: String = ""
}

// MARK: - Simple XML Parser (SAX-based)

/// Flattens any XML into a [localName: textContent] dictionary.
/// Last-write-wins for duplicate element names — fine for SOAP responses
/// where each field appears once.
private class SimpleXMLParser: NSObject, XMLParserDelegate {
    var elements: [String: String] = [:]
    private var currentElement = ""
    private var currentValue = ""

    func parse(_ xml: String) {
        guard let data = xml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // Strip namespace prefix (e.g. "s:Body" -> "Body")
        currentElement = elementName.components(separatedBy: ":").last ?? elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            elements[name] = trimmed
        }
    }
}

// MARK: - Zone Group Parser

/// Parses Sonos ZoneGroupState XML into group/member structures.
/// The XML uses attributes (not child elements) for member data.
private class ZoneGroupParser: NSObject, XMLParserDelegate {
    private var groups: [ZoneGroupData] = []
    private var currentGroup: ZoneGroupData?

    func parse(_ xml: String) -> [ZoneGroupData] {
        // Try to find the ZoneGroupState content
        var xmlToParse = xml

        // If wrapped in a SOAP response, extract the ZoneGroupState value
        if let range = xml.range(of: "<ZoneGroupState>") {
            let start = range.upperBound
            if let endRange = xml.range(of: "</ZoneGroupState>", range: start..<xml.endIndex) {
                let content = String(xml[start..<endRange.lowerBound])
                xmlToParse = XMLResponseParser.xmlUnescape(content)
            }
        }

        guard let data = xmlToParse.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return groups
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch elementName {
        case "ZoneGroup":
            let coordinator = attributes["Coordinator"] ?? ""
            let id = attributes["ID"] ?? UUID().uuidString
            currentGroup = ZoneGroupData(id: id, coordinatorUUID: coordinator, members: [])

        case "ZoneGroupMember":
            guard currentGroup != nil else { return }
            let uuid = attributes["UUID"] ?? ""
            let location = attributes["Location"] ?? ""
            let zoneName = attributes["ZoneName"] ?? ""
            let invisible = attributes["Invisible"] == "1"

            var ip = ""
            var port = 1400
            if let url = URL(string: location) {
                ip = url.host ?? ""
                port = url.port ?? 1400
            }

            let member = ZoneMemberData(uuid: uuid, location: location, zoneName: zoneName, ip: ip, port: port, isInvisible: invisible)
            currentGroup?.members.append(member)

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "ZoneGroup", let group = currentGroup {
            if !group.members.isEmpty {
                groups.append(group)
            }
            currentGroup = nil
        }
    }
}

// MARK: - DIDL-Lite Parser

private class DIDLParser: NSObject, XMLParserDelegate {
    private var item = DIDLItem()
    private var currentElement = ""
    private var currentValue = ""

    func parse(_ xml: String) -> DIDLItem? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return item
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = name
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "title": item.title = trimmed
        case "creator": item.creator = trimmed
        case "album": item.album = trimmed
        case "albumArtURI": item.albumArtURI = trimmed
        default: break
        }
    }
}
