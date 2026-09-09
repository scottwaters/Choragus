import XCTest
@testable import SonosKit

@MainActor
final class MCPAccessGuardTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private lazy var guardUnderTest = MCPAccessGuard(now: { self.clock })

    private func request(headers: [String: String] = [:], from remote: String = "127.0.0.1") -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(), remoteAddress: remote)
    }

    func testLoopbackOriginAndHostPass() {
        XCTAssertEqual(guardUnderTest.check(request(headers: ["origin": "http://localhost:52080", "host": "127.0.0.1:52080"]), allowLAN: false), .allow)
        XCTAssertEqual(guardUnderTest.check(request(headers: ["host": "[::1]:52080"]), allowLAN: false), .allow)
        XCTAssertEqual(guardUnderTest.check(request(), allowLAN: false), .allow)
    }

    func testForeignOriginIsRefused() {
        XCTAssertEqual(guardUnderTest.check(request(headers: ["origin": "https://evil.example"]), allowLAN: false), .badOrigin("https://evil.example"))
        XCTAssertEqual(guardUnderTest.check(request(headers: ["origin": "null"]), allowLAN: false), .badOrigin("null"))
    }

    func testPublicHostNameIsRefusedEvenOnLAN() {
        XCTAssertEqual(guardUnderTest.check(request(headers: ["host": "attacker.example:52080"]), allowLAN: true), .badHost("attacker.example:52080"))
        XCTAssertEqual(guardUnderTest.check(request(headers: ["host": "192.168.1.20:52080"]), allowLAN: false), .badHost("192.168.1.20:52080"))
    }

    func testPrivateAddressesPassOnLAN() {
        for host in ["192.168.1.20:52080", "10.0.0.5", "172.16.4.4", "studio-mac.local:52080", "studio-mac", "[fe80::1]"] {
            XCTAssertEqual(guardUnderTest.check(request(headers: ["host": host]), allowLAN: true), .allow, host)
        }
        XCTAssertEqual(guardUnderTest.check(request(headers: ["host": "8.8.8.8"]), allowLAN: true), .badHost("8.8.8.8"))
    }

    func testRepeatedAuthFailuresLockTheAddressOut() {
        for _ in 0..<(MCPAccessGuard.maxFailures - 1) {
            XCTAssertEqual(guardUnderTest.recordAuthFailure(from: "10.0.0.9"), 0)
        }
        XCTAssertEqual(guardUnderTest.recordAuthFailure(from: "10.0.0.9"), Int(MCPAccessGuard.lockoutDuration))
        guard case .lockedOut(let left) = guardUnderTest.check(request(from: "10.0.0.9"), allowLAN: true) else {
            return XCTFail("expected lockout")
        }
        XCTAssertEqual(left, Int(MCPAccessGuard.lockoutDuration))
        XCTAssertEqual(guardUnderTest.check(request(from: "10.0.0.10"), allowLAN: true), .allow)
        clock = clock.addingTimeInterval(MCPAccessGuard.lockoutDuration + 1)
        XCTAssertEqual(guardUnderTest.check(request(from: "10.0.0.9"), allowLAN: true), .allow)
    }

    func testFailuresOutsideTheWindowDoNotCount() {
        for _ in 0..<(MCPAccessGuard.maxFailures - 1) { guardUnderTest.recordAuthFailure(from: "a") }
        clock = clock.addingTimeInterval(MCPAccessGuard.failureWindow + 1)
        XCTAssertEqual(guardUnderTest.recordAuthFailure(from: "a"), 0)
    }

    func testSuccessClearsFailures() {
        for _ in 0..<(MCPAccessGuard.maxFailures - 1) { guardUnderTest.recordAuthFailure(from: "a") }
        guardUnderTest.recordAuthSuccess(from: "a")
        XCTAssertEqual(guardUnderTest.recordAuthFailure(from: "a"), 0)
    }

    func testRateLimitPerToken() {
        for _ in 0..<MCPAccessGuard.rateLimit { XCTAssertTrue(guardUnderTest.allowCall(token: "t")) }
        XCTAssertFalse(guardUnderTest.allowCall(token: "t"))
        XCTAssertTrue(guardUnderTest.allowCall(token: "other"))
        clock = clock.addingTimeInterval(MCPAccessGuard.rateWindow + 1)
        XCTAssertTrue(guardUnderTest.allowCall(token: "t"))
    }
}

@MainActor
final class MCPScopeTests: XCTestCase {
    func testScopeOrdering() {
        XCTAssertTrue(MCPScope.manage.covers(.readOnly))
        XCTAssertTrue(MCPScope.control.covers(.control))
        XCTAssertFalse(MCPScope.readOnly.covers(.control))
        XCTAssertFalse(MCPScope.control.covers(.manage))
    }

    func testTokensWithoutAScopeDecodeAsManage() throws {
        let json = #"[{"id":"6B2D8B7A-6D2C-4C9B-9E5E-1B2C3D4E5F60","name":"Old","createdAt":700000000}]"#
        let tokens = try JSONDecoder().decode([MCPClientToken].self, from: Data(json.utf8))
        XCTAssertEqual(tokens.first?.scope, .manage)
    }

    func testEveryToolDeclaresAScopeAndReadToolsAreAnnotated() {
        for tool in MCPTool.all {
            let annotations = tool.descriptor["annotations"] as? [String: Any]
            XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, tool.scope == .readOnly, tool.name)
            let hasConfirm = ((tool.inputSchema["properties"] as? [String: Any])?["confirm"]) != nil
            XCTAssertEqual(annotations?["destructiveHint"] as? Bool, tool.destructive, tool.name)
            if hasConfirm { XCTAssertTrue(tool.destructive, "\(tool.name) takes confirm so it is destructive") }
        }
        for name in ["remove_from_queue", "remove_from_playlist", "dedupe_queue", "clear_queue", "delete_playlist", "delete_alarm", "ungroup_all"] {
            XCTAssertTrue(MCPTool.all.first { $0.name == name }?.destructive == true, name)
        }
        XCTAssertNotNil(MCPTool.all.first { $0.name == "list_rooms" }?.outputSchema)
        XCTAssertTrue(MCPTool.all.contains { $0.name == "delete_playlist" && $0.scope == .manage })
        XCTAssertTrue(MCPTool.all.contains { $0.name == "list_rooms" && $0.scope == .readOnly })
    }

    func testReadOnlyTokenCannotCallControlTools() async {
        let context = MCPCallContext(client: "reader", scope: .readOnly, remote: "127.0.0.1")
        let reply = await ChoragusMCPServer.shared.dispatch(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "pause_all", "arguments": [:]]],
            context: context)
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("read only"), text)
        XCTAssertEqual(ChoragusMCPServer.shared.activity.entries.first?.outcome, .denied)
    }

    func testLockedOutAddressGets429() async {
        let server = ChoragusMCPServer.shared
        server.tokenOverride = "secret"
        defer { server.tokenOverride = nil }
        let remote = "10.9.9.\(Int.random(in: 1...254))"
        var status = 0
        for _ in 0..<MCPAccessGuard.maxFailures {
            let wrong = HTTPRequest(method: "POST", path: "/mcp", headers: ["authorization": "Bearer nope"],
                                    body: Data("{}".utf8), remoteAddress: remote)
            status = await server.handle(wrong).status
        }
        XCTAssertEqual(status, 401)
        let right = HTTPRequest(method: "POST", path: "/mcp", headers: ["authorization": "Bearer secret"],
                                body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8), remoteAddress: remote)
        let locked = await server.handle(right)
        XCTAssertEqual(locked.status, 429)
        XCTAssertNotNil(locked.headers["Retry-After"])
    }

    func testForeignOriginGets403() async {
        let server = ChoragusMCPServer.shared
        server.tokenOverride = "secret"
        defer { server.tokenOverride = nil }
        let request = HTTPRequest(method: "POST", path: "/mcp",
                                  headers: ["authorization": "Bearer secret", "origin": "https://evil.example"],
                                  body: Data("{}".utf8), remoteAddress: "127.0.0.1")
        let status = await server.handle(request).status
        XCTAssertEqual(status, 403)
    }

    func testPromptsListAndGet() async {
        let list = await ChoragusMCPServer.shared.dispatch(["jsonrpc": "2.0", "id": 1, "method": "prompts/list"])
        let prompts = (list?["result"] as? [String: Any])?["prompts"] as? [[String: Any]] ?? []
        XCTAssertEqual(prompts.count, MCPPrompt.all.count)
        let get = await ChoragusMCPServer.shared.dispatch(
            ["jsonrpc": "2.0", "id": 2, "method": "prompts/get",
             "params": ["name": "play_for_me", "arguments": ["request": "Kind of Blue", "room": "Office"]]])
        let messages = (get?["result"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        let text = (messages.first?["content"] as? [String: Any])?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Kind of Blue") && text.contains("Office"))
        let missing = await ChoragusMCPServer.shared.dispatch(
            ["jsonrpc": "2.0", "id": 3, "method": "prompts/get", "params": ["name": "play_for_me", "arguments": [:]]])
        XCTAssertEqual((missing?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testActivitySummaryIsShortAndStable() {
        let summary = MCPActivityLog.summarise(["room": "Office", "item_ids": ["a", "b"], "level": 40,
                                                "query": String(repeating: "x", count: 100)])
        XCTAssertEqual(summary, "item_ids=[2] level=40 query=\(String(repeating: "x", count: 40)) room=Office")
    }
}
