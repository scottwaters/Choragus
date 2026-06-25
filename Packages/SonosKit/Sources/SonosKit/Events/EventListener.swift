/// EventListener.swift — Lightweight HTTP server for receiving UPnP NOTIFY callbacks.
///
/// Listens on a local port for incoming event notifications from Sonos speakers.
/// Uses NWListener (Network.framework) for modern, efficient networking.
/// Speakers POST XML event payloads to this server when subscribed state changes.
import Foundation
import Network

public final class EventListener: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sonos.eventListener", qos: .userInitiated)

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

        nwListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = nwListener.port?.rawValue {
                    self?.port = port
                }
                readySemaphore.signal()
            case .failed(let error):
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

        // Wait for the listener to become ready (up to 3 seconds)
        let result = readySemaphore.wait(timeout: .now() + 3)
        if result == .timedOut {
            // Listener did not become ready in time
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

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFullRequest(connection: connection, accumulated: Data())
    }

    /// Accumulates data from the connection until we have a complete HTTP request
    private func receiveFullRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            var allData = accumulated
            if let data = data {
                allData.append(data)
            }

            // Try to parse as complete HTTP request
            if let raw = String(data: allData, encoding: .utf8),
               let (headers, body) = Self.parseHTTPRequest(raw) {

                let contentLength = Int(headers["CONTENT-LENGTH"] ?? "0") ?? 0
                let bodyData = body.data(using: .utf8) ?? Data()

                if bodyData.count >= contentLength || isComplete {
                    let sid = headers["SID"] ?? ""
                    let seq = UInt32(headers["SEQ"] ?? "0") ?? 0

                    // Send 200 OK response
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                        connection.cancel()
                    }))

                    if !body.isEmpty {
                        self.onEvent?(sid, seq, body)
                    }
                    return
                }
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveFullRequest(connection: connection, accumulated: allData)
        }
    }

    /// Parses a raw HTTP request into headers and body
    private static func parseHTTPRequest(_ raw: String) -> (headers: [String: String], body: String)? {
        guard let separatorRange = raw.range(of: "\r\n\r\n") else { return nil }

        let headerSection = String(raw[raw.startIndex..<separatorRange.lowerBound])
        let body = String(raw[separatorRange.upperBound...])

        var headers: [String: String] = [:]
        let lines = headerSection.components(separatedBy: "\r\n")

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

        return (headers, body)
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
