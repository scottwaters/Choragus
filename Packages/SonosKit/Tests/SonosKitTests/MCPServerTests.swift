import XCTest
@testable import SonosKit

final class LocalHTTPParserTests: XCTestCase {
    func testParsesRequestWithBody() {
        let raw = "POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nAuthorization: Bearer abc\r\n\r\n{}"
        guard case .complete(let request)? = LocalHTTPServer.parse(Data(raw.utf8)) else { return XCTFail("no request") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.headers["authorization"], "Bearer abc")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{}")
    }

    func testWaitsForFullBody() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        XCTAssertNil(LocalHTTPServer.parse(Data(raw.utf8)))
    }

    func testRejectsOversizedBody() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: \(LocalHTTPServer.maxBodyBytes + 1)\r\n\r\n"
        guard case .tooLarge? = LocalHTTPServer.parse(Data(raw.utf8)) else { return XCTFail("expected tooLarge") }
    }

    func testMalformedRequestLine() {
        guard case .malformed? = LocalHTTPServer.parse(Data("GARBAGE\r\n\r\n".utf8)) else { return XCTFail("expected malformed") }
    }
}

@MainActor
final class MCPDispatchTests: XCTestCase {
    private func call(_ message: [String: Any]) async -> [String: Any]? {
        await ChoragusMCPServer.shared.dispatch(message)
    }

    func testInitializeAdvertisesToolsAndResources() async {
        let reply = await call(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, ChoragusMCPServer.protocolVersion)
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
    }

    func testNotificationsProduceNoReply() async {
        let reply = await call(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(reply)
    }

    func testToolsListNamesEveryToolWithSchema() async {
        let reply = await call(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, MCPTool.all.count)
        XCTAssertTrue(tools.contains { $0["name"] as? String == "build_playlist" })
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, tools.count)
    }

    func testUnknownMethodIsMethodNotFound() async {
        let reply = await call(["jsonrpc": "2.0", "id": 3, "method": "nope"])
        XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testToolCallWithoutManagerIsAToolError() async {
        let reply = await call(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                "params": ["name": "list_rooms", "arguments": [:]]])
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
    }

    func testUnauthorisedRequestIsRefused() async {
        ChoragusMCPServer.shared.tokenOverride = "secret"
        defer { ChoragusMCPServer.shared.tokenOverride = nil }
        let bare = HTTPRequest(method: "POST", path: "/mcp", headers: [:], body: Data("{}".utf8))
        let bareStatus = await ChoragusMCPServer.shared.handle(bare).status
        XCTAssertEqual(bareStatus, 401)
        let wrong = HTTPRequest(method: "POST", path: "/mcp", headers: ["authorization": "Bearer nope"], body: Data("{}".utf8))
        let wrongStatus = await ChoragusMCPServer.shared.handle(wrong).status
        XCTAssertEqual(wrongStatus, 401)
        let elsewhere = HTTPRequest(method: "POST", path: "/other", headers: ["authorization": "Bearer secret"], body: Data())
        let elsewhereStatus = await ChoragusMCPServer.shared.handle(elsewhere).status
        XCTAssertEqual(elsewhereStatus, 404)
        let ping = HTTPRequest(method: "POST", path: "/mcp", headers: ["authorization": "Bearer secret"],
                               body: Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8))
        let response = await ChoragusMCPServer.shared.handle(ping)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("\"id\":9"))
    }
}
