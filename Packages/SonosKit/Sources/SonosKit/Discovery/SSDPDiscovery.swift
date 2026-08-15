/// SSDPDiscovery.swift — Discovers Sonos speakers on the local network via SSDP/UPnP.
///
/// Sends M-SEARCH multicast datagrams to 239.255.255.250:1900 and parses
/// HTTP-style responses to extract device LOCATION URLs. Uses raw BSD sockets
/// (not NWConnection) for multicast support.
///
/// Concurrency: ALL socket state (fd, read source, isSearching) is confined
/// to `queue`; the public API only enqueues. The previous implementation
/// closed the fd from the caller's thread while a blocking `recvfrom` loop
/// used it — after `close`, the kernel can recycle the descriptor number for
/// an unrelated file, and the still-running `recvfrom` then reads someone
/// else's descriptor (2026-08-06 concurrency audit, worst finding). The
/// blocking loop is replaced with a `DispatchSourceRead`: reads are
/// event-driven on `queue`, and the fd is closed exclusively in the source's
/// cancel handler, which libdispatch guarantees runs after the last event
/// handler — no thread ever touches a closed fd.
import Foundation

public final class SSDPDiscovery: SpeakerDiscovery, @unchecked Sendable {
    // Standard SSDP multicast address and port (UPnP spec)
    private let multicastGroup = "239.255.255.250"
    private let multicastPort: UInt16 = 1900
    // Only discover Sonos ZonePlayers, not other UPnP devices
    private let searchTarget = "urn:schemas-upnp-org:device:ZonePlayer:1"

    // Confined to `queue`.
    private var socket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var isSearching = false
    private let queue = DispatchQueue(label: "ssdp.receive", qos: .userInitiated)

    public var onDeviceFound: SpeakerDiscovery.DeviceFoundHandler?

    public init() {}

    /// Hop limit to use for the next search. Reads the user override and
    /// clamps it: below 1 is unusable, and an unbounded value would push
    /// discovery traffic past the local network for no gain.
    private static var configuredMulticastTTL: Int32 {
        let stored = Int32(UserDefaults.standard.integer(forKey: UDKey.ssdpMulticastTTL))
        guard stored > 0 else { return Timing.ssdpDefaultMulticastTTL }
        return min(stored, Timing.ssdpMaxMulticastTTL)
    }

    public func startDiscovery() {
        queue.async { [weak self] in
            guard let self, !self.isSearching else { return }
            self.openSocketAndListen()
            self.sendSearchOnQueue()
        }
    }

    public func stopDiscovery() {
        queue.async { [weak self] in
            self?.teardownOnQueue()
        }
    }

    public func rescan() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.socket < 0 {
                self.openSocketAndListen()
            }
            self.sendSearchOnQueue()
        }
    }

    // MARK: - Queue-confined socket lifecycle

    private func openSocketAndListen() {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Multicast hop limit. The socket default of 1 confines the search
        // to the local subnet, so a speaker behind a router — a separate
        // VLAN, a second subnet — never receives the M-SEARCH and reads as
        // absent. Only affects how far the search travels; a network that
        // does not forward multicast still blocks it.
        var ttl = Self.configuredMulticastTTL
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking: the read source only fires when data is ready, and
        // the drain loop must stop at EWOULDBLOCK rather than stall the queue.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        socket = fd
        isSearching = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainSocketOnQueue()
        }
        // The ONLY place the fd is closed — runs after the final event
        // handler, so no read can race the close.
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        readSource = source
    }

    private func teardownOnQueue() {
        isSearching = false
        readSource?.cancel()
        readSource = nil
        socket = -1
    }

    /// Sends an SSDP M-SEARCH request. MX:3 tells devices to reply within 3 seconds
    /// to avoid flooding the network.
    private func sendSearchOnQueue() {
        guard socket >= 0 else { return }

        let message = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastGroup):\(multicastPort)",
            "MAN: \"ssdp:discover\"",
            "MX: 3",
            "ST: \(searchTarget)",
            "",
            ""
        ].joined(separator: "\r\n")

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = multicastPort.bigEndian
        inet_pton(AF_INET, multicastGroup, &addr.sin_addr)

        let data = Array(message.utf8)
        let fd = socket
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                _ = sendto(fd, data, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Reads every datagram currently queued on the socket, then returns
    /// (non-blocking; EWOULDBLOCK ends the drain).
    private func drainSocketOnQueue() {
        guard socket >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var senderAddr = sockaddr_in()

        while true {
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = socket
            let n = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, sockPtr, &senderLen)
                }
            }
            guard n > 0 else { return }
            let data = Data(buffer[0..<n])
            if let response = String(data: data, encoding: .utf8) {
                parseResponse(response, from: senderAddr)
            }
        }
    }

    /// Parses an HTTP-formatted SSDP response to extract the LOCATION header,
    /// which points to the device's XML description endpoint (e.g. http://192.168.1.5:1400/xml/device_description.xml).
    private func parseResponse(_ response: String, from addr: sockaddr_in) {
        guard response.contains("ZonePlayer") || response.contains("Sonos") else { return }

        var headers: [String: String] = [:]
        let lines = response.components(separatedBy: "\r\n")

        for line in lines {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces).uppercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        guard let location = headers["LOCATION"],
              let url = URL(string: location),
              let host = url.host else {
            return
        }

        let port = url.port ?? SonosProtocol.defaultPort
        onDeviceFound?(location, host, port, nil)
    }
}
