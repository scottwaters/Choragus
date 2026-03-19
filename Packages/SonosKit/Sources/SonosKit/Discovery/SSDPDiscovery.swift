/// SSDPDiscovery.swift — Discovers Sonos speakers on the local network via SSDP/UPnP.
///
/// Sends M-SEARCH multicast datagrams to 239.255.255.250:1900 and parses
/// HTTP-style responses to extract device LOCATION URLs. Uses raw BSD sockets
/// (not NWConnection) for multicast support. Marked @unchecked Sendable because
/// socket state is confined to receiveQueue.
import Foundation

public final class SSDPDiscovery: @unchecked Sendable {
    // Standard SSDP multicast address and port (UPnP spec)
    private let multicastGroup = "239.255.255.250"
    private let multicastPort: UInt16 = 1900
    // Only discover Sonos ZonePlayers, not other UPnP devices
    private let searchTarget = "urn:schemas-upnp-org:device:ZonePlayer:1"

    private var socket: Int32 = -1
    private var isSearching = false
    private var receiveQueue = DispatchQueue(label: "ssdp.receive", qos: .userInitiated)

    /// Callback: (locationURL, ipAddress, port)
    public typealias DeviceFoundHandler = (String, String, Int) -> Void
    public var onDeviceFound: DeviceFoundHandler?

    public init() {}

    public func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true
        createSocket()
        sendSearch()
        startReceiving()
    }

    public func stopDiscovery() {
        isSearching = false
        if socket >= 0 {
            close(socket)
            socket = -1
        }
    }

    public func rescan() {
        if socket < 0 {
            createSocket()
            startReceiving()
        }
        sendSearch()
    }

    private func createSocket() {
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else {
            print("SSDP: Failed to create socket")
            return
        }

        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Set receive timeout to 1 second so the receive loop can check isSearching
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends an SSDP M-SEARCH request. MX:3 tells devices to reply within 3 seconds
    /// to avoid flooding the network.
    private func sendSearch() {
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
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(socket, data, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func startReceiving() {
        receiveQueue.async { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            while self.isSearching && self.socket >= 0 {
                let n = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(self.socket, &buffer, buffer.count, 0, sockPtr, &senderLen)
                    }
                }

                if n > 0 {
                    let data = Data(buffer[0..<n])
                    if let response = String(data: data, encoding: .utf8) {
                        self.parseResponse(response, from: senderAddr)
                    }
                }
                // n <= 0 means timeout or error, just loop and retry
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

        let port = url.port ?? 1400
        onDeviceFound?(location, host, port)
    }
}
