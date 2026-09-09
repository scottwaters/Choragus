/// MediaServerDiscovery.swift — Finds UPnP/DLNA media servers on the network.
///
/// Same SSDP mechanics as speaker discovery, different search target. Kept
/// separate from `SSDPDiscovery` because the two answer different questions
/// and have different lifetimes: speakers are discovered continuously and
/// drive the whole app, media servers are looked for occasionally and are
/// optional.
///
/// Devices that are not media servers answer this search too (Hue bridges,
/// television tuners), so a responder is only accepted once its description
/// proves it offers ContentDirectory.
///
/// The address that ANSWERED is kept alongside the address the device
/// advertises. A NAS bound to a VLAN interface can answer from one subnet
/// while advertising URLs on another; the speaker is handed the advertised
/// host, so such a server browses but does not play.
import Foundation

public final class MediaServerDiscovery: @unchecked Sendable {

    private static let searchTarget = "urn:schemas-upnp-org:device:MediaServer:1"
    private static let multicastGroup = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900
    /// Time to collect responses. SSDP replies are unicast and arrive within
    /// the MX window; 4 s covers a slow NAS.
    public static let collectWindow: TimeInterval = 4

    public init() {}

    /// Bounded description fetch: 256 KB covers every real DLNA
    /// description document; the cap bounds a hostile responder.
    static func cappedFetch(_ url: URL, maxBytes: Int = 256 * 1024) async throws -> (data: Data, response: URLResponse) {
        try await cappedFetch(URLRequest(url: url), maxBytes: maxBytes)
    }

    static func cappedFetch(_ request: URLRequest, maxBytes: Int = 256 * 1024) async throws -> (data: Data, response: URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (data, response)
    }

    /// One search pass. Returns servers that answered AND proved themselves by
    /// exposing ContentDirectory.
    public func discover(timeout: TimeInterval = MediaServerDiscovery.collectWindow) async -> [MediaServer] {
        let responses = await withCheckedContinuation { (continuation: CheckedContinuation<[(location: String, host: String)], Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.search(timeout: timeout))
            }
        }

        var servers: [MediaServer] = []
        var seen = Set<String>()
        for response in responses {
            // LOCATION arrives in an unauthenticated UDP reply.
            // Dual-interface servers legitimately advertise an address
            // they did not answer from, so the host is bounded rather
            // than sender-matched: web scheme only, and a private (LAN)
            // address — a LOCATION naming an internet host is an
            // exfiltration beacon, never a media server.
            guard let url = URL(string: response.location),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, IPAddress.isLAN(host),
                  let fetched = try? await Self.cappedFetch(url),
                  let xml = String(data: fetched.data, encoding: .utf8),
                  let server = MediaServerService.makeServer(descriptionXML: xml,
                                                             locationURL: url,
                                                             answeringHost: response.host),
                  seen.insert(server.id).inserted
            else { continue }
            MediaServerService.Remembered.remember(server, descriptionURL: url)

            if let advertised = server.advertisedHostMismatch {
                sonosDiagLog(.warning, tag: "MEDIASERVER",
                             "Server advertises an address it did not answer from",
                             context: ["server": server.name,
                                       "advertised": server.baseURL.host ?? "?",
                                       "answeredFrom": advertised])
            }
            sonosDiagLog(.info, tag: "MEDIASERVER", "Media server found",
                         context: ["server": server.name, "model": server.modelName,
                                   "control": server.baseURL.absoluteString + server.controlPath])
            servers.append(server)
        }
        // Re-probe servers seen before. A serving server can still ignore an
        // M-SEARCH (Synology DMS does), and a library that vanishes for that
        // reason is worse than one that takes a moment to confirm.
        for known in MediaServerService.Remembered.descriptionURLs() where !seen.contains(known.id) {
            guard let server = await MediaServerService.probe(address: known.url.absoluteString),
                  seen.insert(server.id).inserted
            else { continue }
            sonosDiagLog(.info, tag: "MEDIASERVER", "Known server confirmed without SSDP",
                         context: ["server": server.name, "url": known.url.absoluteString])
            servers.append(server)
        }

        if servers.isEmpty {
            sonosDiagLog(.info, tag: "MEDIASERVER", "No media servers answered",
                         context: ["responders": String(responses.count)])
        }
        return servers
    }

    /// Blocking SSDP exchange, run off the main actor by `discover`.
    private static func search(timeout: TimeInterval) -> [(location: String, host: String)] {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        // Same hop limit as speaker discovery: a server one router away is
        // reachable where the network forwards multicast.
        var ttl = Timing.ssdpDefaultMulticastTTL
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
        // Mirrors the speaker search. Without the reuse flags a second socket
        // on the same port is refused, and the replies — which are unicast
        // back to this socket — never arrive.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let message = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastGroup):\(multicastPort)",
            "MAN: \"ssdp:discover\"",
            "MX: 3",
            "ST: \(searchTarget)",
            "", ""
        ].joined(separator: "\r\n")

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = multicastPort.bigEndian
        inet_pton(AF_INET, multicastGroup, &addr.sin_addr)
        let payload = Array(message.utf8)
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(fd, payload, payload.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            sonosDiagLog(.warning, tag: "MEDIASERVER", "Search datagram could not be sent",
                         context: ["errno": String(errno)])
            return []
        }

        var found: [(String, String)] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buffer, buffer.count, 0, sockPtr, &fromLen)
                }
            }
            if n <= 0 {
                // A timeout here is the normal end of the collection window;
                // anything else is worth recording, because "no servers" and
                // "the socket failed" look identical from the outside.
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    sonosDiagLog(.warning, tag: "MEDIASERVER", "Search receive failed",
                                 context: ["errno": String(errno)])
                }
                break
            }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            guard let location = headerValue("LOCATION", in: text) else { continue }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
            found.append((location, String(cString: host)))
        }
        return found
    }

    private static func headerValue(_ name: String, in response: String) -> String? {
        for line in response.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].uppercased().trimmingCharacters(in: .whitespaces) == name
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
