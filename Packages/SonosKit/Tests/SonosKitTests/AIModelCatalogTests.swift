import XCTest
@testable import SonosKit

final class AIModelCatalogTests: XCTestCase {

    func testClaudePageParsesIDsAndCursor() throws {
        let json = """
        {"data":[{"type":"model","id":"claude-opus-5","display_name":"Claude Opus 5","created_at":"2026-04-01T00:00:00Z"},
                 {"type":"model","id":"claude-sonnet-5","display_name":"Claude Sonnet 5","created_at":"2026-03-01T00:00:00Z"}],
         "has_more":true,"first_id":"claude-opus-5","last_id":"claude-sonnet-5"}
        """
        let page = try AIModelCatalog.parseClaudePage(Data(json.utf8))
        XCTAssertEqual(page.ids, ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.lastID, "claude-sonnet-5")
    }

    func testClaudePageWithoutDataIsBadResponse() {
        XCTAssertThrowsError(try AIModelCatalog.parseClaudePage(Data("{\"error\":{}}".utf8)))
    }

    func testOpenAIListKeepsChatFamiliesNewestFirst() throws {
        let json = """
        {"object":"list","data":[
          {"id":"gpt-4o","object":"model","created":1715367049,"owned_by":"system"},
          {"id":"gpt-5","object":"model","created":1754000000,"owned_by":"system"},
          {"id":"gpt-4o-2024-08-06","object":"model","created":1722814719,"owned_by":"system"},
          {"id":"gpt-4-0613","object":"model","created":1686588896,"owned_by":"openai"},
          {"id":"whisper-1","object":"model","created":1677532384,"owned_by":"openai-internal"},
          {"id":"gpt-4o-audio-preview","object":"model","created":1727389042,"owned_by":"system"},
          {"id":"text-embedding-3-small","object":"model","created":1705948997,"owned_by":"system"},
          {"id":"o3-mini","object":"model","created":1737146383,"owned_by":"system"},
          {"id":"gpt-5-codex","object":"model","created":1757000000,"owned_by":"system"}
        ]}
        """
        XCTAssertEqual(try AIModelCatalog.parseOpenAIModels(Data(json.utf8)), ["gpt-5", "o3-mini", "gpt-4o"])
    }

    func testIDSanitising() {
        XCTAssertNil(AIModelCatalog.sanitisedID(nil))
        XCTAssertNil(AIModelCatalog.sanitisedID(""))
        XCTAssertNil(AIModelCatalog.sanitisedID("bad\u{0007}id"))
        XCTAssertNil(AIModelCatalog.sanitisedID(String(repeating: "x", count: AIModelCatalog.maxIDLength + 1)))
        XCTAssertEqual(AIModelCatalog.sanitisedID("claude-opus-5"), "claude-opus-5")
    }
}

final class IPAddressLANTests: XCTestCase {
    func testHostnamesStartingWithHexAreNotULA() {
        XCTAssertFalse(IPAddress.isPrivate("fdcdn.example.com"))
        XCTAssertFalse(IPAddress.isPrivate("fc.evil.net"))
        XCTAssertTrue(IPAddress.isPrivate("fd12:3456::1"))
        XCTAssertTrue(IPAddress.isPrivate("[fc00::1]"))
    }

    func testSingleLabelNamesCountAsLAN() {
        XCTAssertTrue(IPAddress.isLAN("diskstation"))
        XCTAssertTrue(IPAddress.isLAN("192.168.1.5"))
        XCTAssertFalse(IPAddress.isLAN("cdn.example.com"))
        XCTAssertFalse(IPAddress.isLAN(""))
    }
}

final class MediaServerControlURLTests: XCTestCase {
    private func description(control: String) -> String {
        """
        <root><device><friendlyName>NAS</friendlyName><UDN>uuid:1</UDN>
        <serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <controlURL>\(control)</controlURL></service></serviceList></device></root>
        """
    }

    func testAbsoluteControlURLOnAnotherHostIsRejected() {
        let location = URL(string: "http://192.168.1.10:50001/desc.xml")!
        XCTAssertNil(MediaServerService.makeServer(descriptionXML: description(control: "http://203.0.113.9/x"),
                                                   locationURL: location, answeringHost: "192.168.1.10"))
        XCTAssertNil(MediaServerService.makeServer(descriptionXML: description(control: "//203.0.113.9/x"),
                                                   locationURL: location, answeringHost: "192.168.1.10"))
    }

    func testRelativeAndSameHostControlURLsAreKept() {
        let location = URL(string: "http://192.168.1.10:50001/desc.xml")!
        XCTAssertNotNil(MediaServerService.makeServer(descriptionXML: description(control: "/ctl/ContentDir"),
                                                      locationURL: location, answeringHost: "192.168.1.10"))
        XCTAssertNotNil(MediaServerService.makeServer(descriptionXML: description(control: "http://192.168.1.10:50001/ctl"),
                                                      locationURL: location, answeringHost: "192.168.1.10"))
    }
}
