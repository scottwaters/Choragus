/// LocalHTTPServer.swift — Minimal HTTP/1.1 listener for the MCP endpoint.
///
/// One request per connection, body bounded by `maxBodyBytes`, handler
/// answers with a status, headers and body. Bound to loopback unless LAN
/// access is requested; a Bonjour advert lets a sleeping Mac be woken by
/// the first request when "Wake for network access" is on.
import Foundation
import Network

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]   // lower-cased names
    public let body: Data
    /// The peer's address, for logging and lockouts; empty when unknown.
    public let remoteAddress: String

    public init(method: String, path: String, headers: [String: String], body: Data, remoteAddress: String = "") {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    func withRemote(_ address: String) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: body, remoteAddress: address)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
}

public final class LocalHTTPServer: @unchecked Sendable {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.choragus.mcp.http")
    public private(set) var port: UInt16
    /// Bonjour advert, published on its own so a registration failure
    /// (Local Network permission, mDNS trouble) cannot take the socket
    /// down with it — with `NWListener.service` the two share a fate.
    private var bonjour: NetService?
    private let bonjourName: String?
    /// Called on every state change after the listener is up.
    public var onStateChange: (@Sendable (String) -> Void)?

    public init(port: UInt16, loopbackOnly: Bool, bonjourName: String?, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        if loopbackOnly {
            // Bind the socket to 127.0.0.1 itself, not just the loopback
            // interface: a wildcard listener shows as *:port and depends on
            // the firewall to stay private. The port rides on the endpoint;
            // passing it again with `on:` makes NWListener refuse to start.
            params.requiredInterfaceType = .loopback
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: nwPort)
        }
        self.bonjourName = loopbackOnly ? nil : bonjourName
        self.handler = handler
        self.port = port
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let actual = self?.listener.port?.rawValue { self?.port = actual }
                    if !resumed { resumed = true; continuation.resume(); self?.publishBonjour() }
                    else { self?.onStateChange?("ready") }
                case .failed(let error):
                    if !resumed { resumed = true; continuation.resume(throwing: error) }
                    else { self?.onStateChange?("failed: \(error)") }
                case .cancelled:
                    if resumed { self?.onStateChange?("cancelled") }
                case .waiting(let error):
                    self?.onStateChange?("waiting: \(error)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        bonjour?.stop()
        bonjour = nil
        listener.cancel()
    }

    private func publishBonjour() {
        guard let bonjourName else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let service = NetService(domain: "local.", type: "_mcp._tcp.", name: bonjourName, port: Int32(self.port))
            service.publish()
            self.bonjour = service
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        let remote: String
        if case .hostPort(let host, _) = connection.endpoint { remote = Self.address(of: host) } else { remote = "" }
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }
                if let request = Self.parse(buffer) {
                    switch request {
                    case .complete(let req):
                        Task {
                            let response = await self.handler(req.withRemote(remote))
                            self.send(response, on: connection)
                        }
                    case .tooLarge:
                        self.send(HTTPResponse(status: 413), on: connection)
                    case .malformed:
                        self.send(HTTPResponse(status: 400), on: connection)
                    }
                    return
                }
                if buffer.count > Self.maxHeaderBytes + Self.maxBodyBytes || isComplete {
                    self.send(HTTPResponse(status: isComplete ? 400 : 413), on: connection)
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    enum Parse { case complete(HTTPRequest), tooLarge, malformed }

    /// "127.0.0.1", "::1" or a name; the interface suffix is dropped.
    static func address(of host: NWEndpoint.Host) -> String {
        let text = "\(host)"
        if let percent = text.firstIndex(of: "%") { return String(text[..<percent]) }
        return text
    }

    /// Nil while more bytes are needed.
    static func parse(_ data: Data) -> Parse? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .tooLarge : nil
        }
        guard headerEnd.lowerBound <= maxHeaderBytes else { return .tooLarge }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .malformed }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0 else { return .malformed }
        guard length <= maxBodyBytes else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(),
                                     path: String(requestLine[1]),
                                     headers: headers,
                                     body: Data(body)))
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
