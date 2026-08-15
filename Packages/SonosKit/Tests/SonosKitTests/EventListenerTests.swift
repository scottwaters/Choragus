/// EventListenerTests.swift — Startup contract and NOTIFY request
/// validation for the UPnP callback listener.
import XCTest
@testable import SonosKit

final class EventListenerTests: XCTestCase {

    /// The listener binds `EventListener.preferredPort` (default 3401),
    /// which a concurrently running Choragus instance may hold — with
    /// the reuse option that surfaces as `.failed` at start, not at
    /// init, so no ephemeral fallback occurs. Point the preference at
    /// a per-run high port (test runner's defaults domain, not the
    /// app's) and retry on the rare collision.
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UDKey.eventListenerPort)
        super.tearDown()
    }

    private func startedListener() throws -> EventListener {
        for _ in 0..<5 {
            UserDefaults.standard.set(Int.random(in: 20000...60000), forKey: UDKey.eventListenerPort)
            let listener = EventListener()
            do {
                try listener.start()
                return listener
            } catch EventListener.StartError.bindFailed {
                continue // port collision — retry with another
            }
        }
        throw XCTSkip("No free test port after 5 attempts")
    }

    // MARK: - Header parsing

    func testParseHTTPHeaderExtractsRequestLineAndFields() {
        let raw = "NOTIFY /notify HTTP/1.1\r\nHOST: 192.168.1.10:3401\r\nSID: uuid:RINCON_123\r\nSEQ: 7\r\nContent-Length: 5"
        let parsed = EventListener.parseHTTPHeader(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.requestLine, "NOTIFY /notify HTTP/1.1")
        XCTAssertEqual(parsed?.headers["SID"], "uuid:RINCON_123")
        XCTAssertEqual(parsed?.headers["SEQ"], "7")
        XCTAssertEqual(parsed?.headers["CONTENT-LENGTH"], "5")
    }

    func testParseHTTPHeaderLowercaseFieldNamesAreUppercased() {
        let raw = "NOTIFY / HTTP/1.1\r\ncontent-length: 12"
        let parsed = EventListener.parseHTTPHeader(raw)
        XCTAssertEqual(parsed?.headers["CONTENT-LENGTH"], "12")
    }

    func testParseHTTPHeaderEmptyInputReturnsNil() {
        XCTAssertNil(EventListener.parseHTTPHeader(""))
    }

    // MARK: - Startup contract

    func testStartYieldsReadyListenerWithNonzeroPort() throws {
        let listener = try startedListener()
        defer { listener.stop() }
        XCTAssertNotEqual(listener.port, 0)
    }

    // MARK: - Request validation (live socket)

    /// Raw-socket round trip against a started listener. Returns the
    /// HTTP status line of the response, or nil when the server closed
    /// without responding.
    private func send(_ request: Data, to port: UInt16, timeout: TimeInterval = 5) -> String? {
        var task: URLSessionStreamTask!
        let session = URLSession(configuration: .ephemeral)
        task = session.streamTask(withHostName: "127.0.0.1", port: Int(port))
        task.resume()

        let writeDone = expectation(description: "write")
        task.write(request, timeout: timeout) { _ in writeDone.fulfill() }
        wait(for: [writeDone], timeout: timeout)

        let readDone = expectation(description: "read")
        var statusLine: String?
        task.readData(ofMinLength: 1, maxLength: 4096, timeout: timeout) { data, _, _ in
            if let data, let text = String(data: data, encoding: .utf8) {
                statusLine = text.components(separatedBy: "\r\n").first
            }
            readDone.fulfill()
        }
        wait(for: [readDone], timeout: timeout)
        task.closeWrite()
        task.closeRead()
        return statusLine
    }

    func testValidNotifyReturns200AndDeliversEvent() throws {
        let listener = try startedListener()
        defer { listener.stop() }

        let delivered = expectation(description: "event")
        var received: (sid: String, seq: UInt32, body: String)?
        listener.onEvent = { sid, seq, body in
            received = (sid, seq, body)
            delivered.fulfill()
        }

        let body = "<e:propertyset>ok</e:propertyset>"
        let request = "NOTIFY /notify HTTP/1.1\r\nHOST: 127.0.0.1\r\nSID: uuid:sub-1\r\nSEQ: 3\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let status = send(Data(request.utf8), to: listener.port)
        XCTAssertEqual(status, "HTTP/1.1 200 OK")

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(received?.sid, "uuid:sub-1")
        XCTAssertEqual(received?.seq, 3)
        XCTAssertEqual(received?.body, body)
    }

    func testNonNotifyMethodReturns405() throws {
        let listener = try startedListener()
        defer { listener.stop() }
        let request = "POST /notify HTTP/1.1\r\nHOST: 127.0.0.1\r\nContent-Length: 2\r\n\r\nhi"
        let status = send(Data(request.utf8), to: listener.port)
        XCTAssertEqual(status, "HTTP/1.1 405 Method Not Allowed")
    }

    func testMissingContentLengthReturns400() throws {
        let listener = try startedListener()
        defer { listener.stop() }
        let request = "NOTIFY /notify HTTP/1.1\r\nHOST: 127.0.0.1\r\n\r\n"
        let status = send(Data(request.utf8), to: listener.port)
        XCTAssertEqual(status, "HTTP/1.1 400 Bad Request")
    }

    func testInvalidContentLengthReturns400() throws {
        let listener = try startedListener()
        defer { listener.stop() }
        let request = "NOTIFY /notify HTTP/1.1\r\nHOST: 127.0.0.1\r\nContent-Length: banana\r\n\r\n"
        let status = send(Data(request.utf8), to: listener.port)
        XCTAssertEqual(status, "HTTP/1.1 400 Bad Request")
    }

    func testOversizedDeclaredBodyReturns413() throws {
        let listener = try startedListener()
        defer { listener.stop() }
        // Declared length over the 256 KB cap — rejected from the
        // header alone, no body bytes required.
        let request = "NOTIFY /notify HTTP/1.1\r\nHOST: 127.0.0.1\r\nContent-Length: 300000\r\n\r\n"
        let status = send(Data(request.utf8), to: listener.port)
        XCTAssertEqual(status, "HTTP/1.1 413 Content Too Large")
    }

    func testOversizedHeadersReturns413() throws {
        let listener = try startedListener()
        defer { listener.stop() }
        // 20 KB of header data with no terminator exceeds the 16 KB cap.
        let filler = String(repeating: "x", count: 20 * 1024)
        let request = "NOTIFY /notify HTTP/1.1\r\nX-FILL: \(filler)"
        let status = send(Data(request.utf8), to: listener.port)
        XCTAssertEqual(status, "HTTP/1.1 413 Content Too Large")
    }
}
