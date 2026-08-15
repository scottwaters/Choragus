/// EventListener.swift — Lightweight HTTP server for receiving UPnP NOTIFY callbacks.
///
/// Listens on a local port for incoming event notifications from Sonos speakers.
/// Uses NWListener (Network.framework) for modern, efficient networking.
/// Speakers POST XML event payloads to this server when subscribed state changes.
import Foundation
import Network

public final class EventListener: @unchecked Sendable {
    /// Thrown by `start()` when the listener cannot reach a usable
    /// `.ready` state. Callers (`HybridEventFirstTransport.start`)
    /// treat any thrown error as "run in poll-only mode".
    public enum StartError: Error {
        /// NWListener entered `.failed` before becoming ready.
        case bindFailed(underlying: Error)
        /// Listener did not become ready within the startup deadline.
        case startTimeout
        /// Listener reported ready but no bound port was available.
        case portUnavailable
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sonos.eventListener", qos: .userInitiated)

    // Request-framing limits. NOTIFY payloads from Sonos are small
    // (LastChange XML, a few KB); anything beyond these caps is not a
    // legitimate speaker event and is rejected to bound memory growth
    // on a socket any LAN peer can open.
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 256 * 1024
    private static let idleTimeout: TimeInterval = 10
    private static let maxConcurrentConnections = 16
    private static let startTimeout: TimeInterval = 3

    /// Open-connection count. Mutated only on `queue` (accept handler,
    /// per-connection state handlers, and receive callbacks all run
    /// there), so no separate lock is needed.
    private var activeConnectionCount = 0

    /// Callback: (subscriptionID, sequenceNumber, xmlBody)
    public var onEvent: ((String, UInt32, String) -> Void)?

    /// The port the listener is bound to (available after start)
    public private(set) var port: UInt16 = 0

    /// The local IP address to use in CALLBACK URLs
    public private(set) var localAddress: String = ""

    public init() {}

    /// Preferred fixed callback port. A STABLE port lets users on segmented
    /// networks (speakers in an IoT VLAN) write a tight firewall rule —
    /// `Sonos devices → <Mac IP>:3401 TCP` — instead of having to allow any
    /// port because the OS picked a fresh ephemeral one each launch. Falls
    /// back to an ephemeral port if the port is taken (second app instance,
    /// another process); the SUBSCRIBE callback URL always carries the
    /// actual bound port, so eventing works either way.
    public static let defaultPort: UInt16 = 3401

    /// User-configurable via Settings → System → Network (applied at next
    /// launch — live rebinding would invalidate every active subscription's
    /// callback). Values outside the unprivileged range fall back to default.
    public static var preferredPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: UDKey.eventListenerPort)
        guard stored >= 1024, stored <= 65535 else { return defaultPort }
        return UInt16(stored)
    }

    public func start() throws {
        // Resolve local IP first, before starting the listener
        localAddress = Self.getLocalIPAddress() ?? "127.0.0.1"

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let nwListener: NWListener
        if let fixed = NWEndpoint.Port(rawValue: Self.preferredPort),
           let bound = try? NWListener(using: params, on: fixed) {
            nwListener = bound
        } else {
            sonosDebugLog("[EVENTS] Port \(Self.preferredPort) unavailable — falling back to an ephemeral port (firewall rules scoped to \(Self.preferredPort) will not see this session's events)")
            nwListener = try NWListener(using: params)
        }

        let readySemaphore = DispatchSemaphore(value: 0)
        // Written on `queue` by the state handler, read on the caller
        // thread after the semaphore wait — hence the lock.
        let failureLock = NSLock()
        var failure: Error?

        nwListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = nwListener.port?.rawValue {
                    self?.port = port
                }
                readySemaphore.signal()
            case .failed(let error):
                failureLock.lock()
                failure = error
                failureLock.unlock()
                nwListener.cancel()
                readySemaphore.signal()
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        nwListener.start(queue: queue)
        self.listener = nwListener

        // A dead listener must be reported as thrown error, not as a
        // normal return with port == 0 — callers use the throw to fall
        // back to poll-only mode.
        let result = readySemaphore.wait(timeout: .now() + Self.startTimeout)
        if result == .timedOut {
            nwListener.cancel()
            self.listener = nil
            throw StartError.startTimeout
        }
        failureLock.lock()
        let capturedFailure = failure
        failureLock.unlock()
        if let capturedFailure {
            self.listener = nil
            throw StartError.bindFailed(underlying: capturedFailure)
        }
        guard port != 0 else {
            nwListener.cancel()
            self.listener = nil
            throw StartError.portUnavailable
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The URL that Sonos speakers should send NOTIFY requests to
    public var callbackURL: URL? {
        guard port > 0, !localAddress.isEmpty, localAddress != "127.0.0.1" else {
            // If we only have localhost, try resolving again
            if localAddress == "127.0.0.1" || localAddress.isEmpty {
                if let ip = Self.getLocalIPAddress() {
                    return URL(string: "http://\(ip):\(port)/notify")
                }
            }
            guard port > 0 else { return nil }
            return nil
        }
        return URL(string: "http://\(localAddress):\(port)/notify")
    }

    // MARK: - Connection Handling

    /// Per-connection idle timer. All access happens on `queue`.
    private final class ConnectionContext {
        var idleTimer: DispatchWorkItem?
    }

    private func handleConnection(_ connection: NWConnection) {
        // Concurrent-connection cap: refuse anything beyond the cap
        // outright (no response — the socket never enters service).
        guard activeConnectionCount < Self.maxConcurrentConnections else {
            connection.cancel()
            return
        }
        activeConnectionCount += 1

        let context = ConnectionContext()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                context.idleTimer?.cancel()
                context.idleTimer = nil
                if let self, self.activeConnectionCount > 0 {
                    self.activeConnectionCount -= 1
                }
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        rescheduleIdleTimer(context, connection: connection)
        receiveFullRequest(connection: connection, accumulated: Data(), context: context)
    }

    /// Idle deadline: a peer that stops sending mid-request is cut off
    /// rather than holding a connection slot open indefinitely.
    private func rescheduleIdleTimer(_ context: ConnectionContext, connection: NWConnection) {
        context.idleTimer?.cancel()
        let timer = DispatchWorkItem { connection.cancel() }
        context.idleTimer = timer
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timer)
    }

    /// Sends a bodyless HTTP response and closes the connection.
    private func respondAndClose(_ connection: NWConnection, status: String, context: ConnectionContext) {
        context.idleTimer?.cancel()
        context.idleTimer = nil
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    /// Accumulates data from the connection until we have a complete,
    /// validated NOTIFY request. Rejects: oversized headers/bodies
    /// (413), missing/invalid Content-Length (400), non-NOTIFY methods
    /// (405). This socket is reachable by any LAN peer, so framing is
    /// enforced defensively at this boundary.
    private func receiveFullRequest(connection: NWConnection, accumulated: Data, context: ConnectionContext) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            var allData = accumulated
            if let data = data {
                allData.append(data)
                self.rescheduleIdleTimer(context, connection: connection)
            }

            let headerTerminator = Data("\r\n\r\n".utf8)
            guard let terminatorRange = allData.range(of: headerTerminator) else {
                // Headers incomplete. Cap their size before buffering more.
                if allData.count > Self.maxHeaderBytes {
                    self.respondAndClose(connection, status: "413 Content Too Large", context: context)
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receiveFullRequest(connection: connection, accumulated: allData, context: context)
                return
            }

            if terminatorRange.lowerBound > Self.maxHeaderBytes {
                self.respondAndClose(connection, status: "413 Content Too Large", context: context)
                return
            }

            guard let headerText = String(data: allData[..<terminatorRange.lowerBound], encoding: .utf8),
                  let (requestLine, headers) = Self.parseHTTPHeader(headerText) else {
                self.respondAndClose(connection, status: "400 Bad Request", context: context)
                return
            }

            // Only UPnP NOTIFY is served here.
            guard requestLine.hasPrefix("NOTIFY ") else {
                self.respondAndClose(connection, status: "405 Method Not Allowed", context: context)
                return
            }

            // Content-Length is mandatory; missing/invalid/negative
            // values would otherwise accept arbitrary bodies.
            guard let lengthField = headers["CONTENT-LENGTH"],
                  let contentLength = Int(lengthField), contentLength >= 0 else {
                self.respondAndClose(connection, status: "400 Bad Request", context: context)
                return
            }
            guard contentLength <= Self.maxBodyBytes else {
                self.respondAndClose(connection, status: "413 Content Too Large", context: context)
                return
            }

            let bodyData = allData[terminatorRange.upperBound...]
            if bodyData.count < contentLength {
                if isComplete || error != nil {
                    // Peer closed before delivering the declared body.
                    connection.cancel()
                    return
                }
                self.receiveFullRequest(connection: connection, accumulated: allData, context: context)
                return
            }

            let sid = headers["SID"] ?? ""
            let seq = UInt32(headers["SEQ"] ?? "0") ?? 0
            let body = String(data: bodyData.prefix(contentLength), encoding: .utf8) ?? ""

            self.respondAndClose(connection, status: "200 OK", context: context)

            if !body.isEmpty {
                self.onEvent?(sid, seq, body)
            }
        }
    }

    /// Parses an HTTP header section (request line + header fields).
    /// Returns nil when there is no request line.
    static func parseHTTPHeader(_ headerSection: String) -> (requestLine: String, headers: [String: String])? {
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex])
                    .trimmingCharacters(in: .whitespaces)
                    .uppercased()
                let value = String(line[line.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return (requestLine, headers)
    }

    /// Discovers the local IP address on the LAN interface.
    /// Tries en* interfaces first, then falls back to any non-loopback interface.
    static func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var bestAddress: String?
        var fallbackAddress: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: addr.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                       &hostname, socklen_t(hostname.count),
                       nil, 0, NI_NUMERICHOST)

            let ip = String(cString: hostname)
            guard !ip.isEmpty, ip != "0.0.0.0", ip != "127.0.0.1" else { continue }

            if name.hasPrefix("en") {
                bestAddress = ip
                if name == "en0" { return ip } // Prefer en0 (Wi-Fi)
            } else if name != "lo0" {
                fallbackAddress = ip
            }
        }

        return bestAddress ?? fallbackAddress
    }
}
