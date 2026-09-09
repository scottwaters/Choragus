/// IPAddress.swift — Classifies a host string as LAN-local or public.
///
/// Two decisions depend on this and both fail silently when it is wrong:
/// upgrading an art URL to HTTPS (a LAN device has no TLS listener, so the
/// upgraded URL never connects) and deciding whether a media server is
/// reachable at all.
import Foundation

public enum IPAddress {
    /// True for addresses that only exist on a local network: RFC 1918
    /// private ranges, loopback, link-local, RFC 6598 carrier-grade NAT, and
    /// `.local` mDNS names. False for anything routable on the internet and
    /// for hostnames, which cannot be classified without resolving them.
    /// `isPrivate`, plus single-label names (`nas`, `diskstation`) that
    /// only a local resolver can answer.
    public static func isLAN(_ host: String) -> Bool {
        isPrivate(host) || (!host.isEmpty && !host.contains(".") && !host.contains(":"))
    }

    public static func isPrivate(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("fe80:") || host == "::1" { return true }
        // Unique local IPv6 (fc00::/7); only an IPv6 literal carries colons.
        if host.contains(":"), let first = host.split(separator: ":").first, first.count >= 2,
           let leading = UInt16(first.prefix(2), radix: 16), (leading & 0xFE) == 0xFC {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168):
            return true
        case (172, 16...31), (169, 254), (100, 64...127):
            return true
        default:
            return false
        }
    }
}
