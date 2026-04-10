/// BrowseXMLParser.swift — SAX parser for DIDL-Lite XML returned by ContentDirectory Browse.
///
/// DIDL-Lite is the UPnP content format: items and containers with Dublin Core metadata.
/// The tricky part is `r:resMD` — Sonos embeds escaped DIDL metadata *inside* DIDL items.
/// The SAX parser would descend into and mangle this nested XML, so we pre-extract resMD
/// content via regex before SAX parsing, then stitch it back in during didEndElement.
import Foundation

public class BrowseXMLParser: NSObject, XMLParserDelegate {
    private var items: [BrowseItem] = []

    // Current item/container being assembled during SAX traversal
    private var inEntry = false
    private var entryID = ""
    private var currentLocalName = ""
    private var currentValue = ""
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentAlbum = ""
    private var currentArtURI = ""
    private var currentClass = ""
    private var currentResURI = ""
    private var currentResMD = ""
    private var currentDesc = ""
    private var isContainerEntry = false

    // resMD handling: track depth so we skip nested elements inside resMD
    private var resMDDepth = 0
    private var inResMD = false

    private let deviceIP: String
    private let devicePort: Int

    // Pre-extracted resMD map: item id -> raw escaped metadata string
    private var resMDMap: [String: String] = [:]

    init(deviceIP: String, devicePort: Int) {
        self.deviceIP = deviceIP
        self.devicePort = devicePort
    }

    public static func parse(_ xml: String, deviceIP: String, devicePort: Int) -> [BrowseItem] {
        // Do NOT call xmlUnescape — the SOAP SAX parser already unescaped
        // the outer layer. The DIDL XML is valid XML with its own &amp; entities.
        guard let data = xml.data(using: .utf8) else { return [] }
        let handler = BrowseXMLParser(deviceIP: deviceIP, devicePort: devicePort)

        // Pre-extract resMD content before SAX parsing, because the SAX parser
        // will unescape and descend into the nested DIDL elements
        handler.extractResMDMap(from: xml)

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = handler
        parser.parse()
        return handler.items
    }

    /// Extract r:resMD content for each item before SAX parsing.
    /// The resMD contains escaped DIDL-Lite XML that we need to preserve as-is.
    private func extractResMDMap(from xml: String) {
        // Match item id and its resMD content
        // Pattern: item with id="X" ... <r:resMD>CONTENT</r:resMD>
        let itemPattern = #"<item[^>]*id="([^"]+)"[^>]*>(.*?)</item>"#
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern, options: .dotMatchesLineSeparators) else { return }

        let nsXML = xml as NSString
        let matches = itemRegex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let itemID = nsXML.substring(with: match.range(at: 1))
            let itemBody = nsXML.substring(with: match.range(at: 2))

            // Extract resMD content from within this item
            if let mdRange = itemBody.range(of: "<r:resMD>"),
               let mdEndRange = itemBody.range(of: "</r:resMD>", range: mdRange.upperBound..<itemBody.endIndex) {
                let mdContent = String(itemBody[mdRange.upperBound..<mdEndRange.lowerBound])
                resMDMap[itemID] = mdContent
            }
        }
    }

    private func localName(_ elementName: String) -> String {
        if let idx = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: idx)...])
        }
        return elementName
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String,
                       namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String] = [:]) {
        let name = localName(elementName)

        if inResMD {
            resMDDepth += 1
            return
        }

        currentLocalName = name
        currentValue = ""

        if name == "item" || name == "container" {
            inEntry = true
            isContainerEntry = (name == "container")
            entryID = attributes["id"] ?? ""
            currentTitle = ""
            currentArtist = ""
            currentAlbum = ""
            currentArtURI = ""
            currentClass = ""
            currentResURI = ""
            currentResMD = ""
            currentDesc = ""
        }

        if inEntry && name == "resMD" {
            inResMD = true
            resMDDepth = 0
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !inResMD {
            currentValue += string
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String,
                       namespaceURI: String?, qualifiedName: String?) {
        let name = localName(elementName)

        if inResMD {
            if name == "resMD" && resMDDepth == 0 {
                inResMD = false
                // Use pre-extracted metadata
                currentResMD = resMDMap[entryID] ?? ""
            } else {
                resMDDepth -= 1
            }
            return
        }

        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if inEntry {
            switch name {
            case "title":
                currentTitle = trimmed
            case "creator", "artist":
                if currentArtist.isEmpty { currentArtist = trimmed }
            case "album":
                currentAlbum = trimmed
            case "albumArtURI":
                // Sonos returns relative art URIs (e.g. /getaa?s=1&u=...) — resolve against device
                if trimmed.hasPrefix("/") {
                    currentArtURI = "http://\(deviceIP):\(devicePort)\(trimmed)"
                } else if !trimmed.isEmpty {
                    // Upgrade external HTTP to HTTPS — only keep HTTP for local speaker URLs
                    if trimmed.hasPrefix("http://"),
                       let parsed = URL(string: trimmed),
                       parsed.host != deviceIP {
                        currentArtURI = trimmed.replacingOccurrences(of: "http://", with: "https://", options: [], range: trimmed.startIndex..<trimmed.index(trimmed.startIndex, offsetBy: 7))
                    } else {
                        currentArtURI = trimmed
                    }
                }
            case "class":
                currentClass = trimmed
            case "res":
                if currentResURI.isEmpty { currentResURI = trimmed }
            case "desc", "description":
                if currentDesc.isEmpty { currentDesc = trimmed }

            case "item", "container":
                let itemClass: BrowseItemClass
                if isContainerEntry {
                    itemClass = currentClass.isEmpty ? .container : BrowseItemClass.from(upnpClass: currentClass)
                } else {
                    itemClass = BrowseItemClass.from(upnpClass: currentClass)
                }

                let item = BrowseItem(
                    id: entryID,
                    title: currentTitle,
                    artist: currentArtist,
                    album: currentAlbum,
                    albumArtURI: currentArtURI.isEmpty ? nil : currentArtURI,
                    itemClass: itemClass,
                    resourceURI: currentResURI.isEmpty ? nil : currentResURI,
                    resourceMetadata: currentResMD.isEmpty ? nil : currentResMD,
                    serviceDescriptor: currentDesc.isEmpty ? nil : currentDesc
                )
                items.append(item)
                inEntry = false

            default:
                break
            }
        }
    }
}
