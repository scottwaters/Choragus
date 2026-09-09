/// MCPAccessGuard.swift — Request checks that run around authentication.
///
/// Three defences a bearer token alone does not give:
/// - **Origin and Host validation.** A browser page on any site can
///   POST to `127.0.0.1`; a DNS-rebinding page can reach a LAN listener
///   under a public host name. Requests that carry an `Origin` or `Host`
///   naming anything but this machine (or, on the LAN, a private
///   address) are refused before the token is even read.
/// - **Auth-failure lockout.** Wrong tokens from one address are counted;
///   past the limit the address waits out a lockout, which turns a
///   brute-force attempt into a few guesses per five minutes.
/// - **Per-token rate limit.** A runaway agent cannot flood the speakers.
import Foundation

@MainActor
final class MCPAccessGuard {
    static let maxFailures = 5
    static let failureWindow: TimeInterval = 60
    static let lockoutDuration: TimeInterval = 300
    static let rateLimit = 60
    static let rateWindow: TimeInterval = 10

    enum Verdict: Equatable {
        case allow
        case badOrigin(String)
        case badHost(String)
        case lockedOut(secondsLeft: Int)
    }

    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]
    private var calls: [String: [Date]] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Addresses currently locked out and when the lock lifts.
    var lockouts: [(address: String, until: Date)] {
        let current = now()
        return lockedUntil.filter { $0.value > current }.map { ($0.key, $0.value) }.sorted { $0.until < $1.until }
    }

    func check(_ request: HTTPRequest, allowLAN: Bool) -> Verdict {
        let current = now()
        if let until = lockedUntil[request.remoteAddress], until > current {
            return .lockedOut(secondsLeft: Int(until.timeIntervalSince(current).rounded(.up)))
        }
        if let origin = request.headers["origin"] {
            guard let host = Self.host(fromOrigin: origin), Self.isLocalName(host, allowLAN: allowLAN) else {
                return .badOrigin(origin)
            }
        }
        if let hostHeader = request.headers["host"], !hostHeader.isEmpty {
            let host = Self.stripPort(hostHeader)
            guard Self.isLocalName(host, allowLAN: allowLAN) else { return .badHost(hostHeader) }
        }
        return .allow
    }

    /// Counts a failed authentication; returns the lockout length in
    /// seconds when this failure tripped it, else 0.
    @discardableResult
    func recordAuthFailure(from address: String) -> Int {
        let current = now()
        var recent = (failures[address] ?? []).filter { current.timeIntervalSince($0) < Self.failureWindow }
        recent.append(current)
        failures[address] = recent
        guard recent.count >= Self.maxFailures else { return 0 }
        lockedUntil[address] = current.addingTimeInterval(Self.lockoutDuration)
        failures[address] = nil
        return Int(Self.lockoutDuration)
    }

    func recordAuthSuccess(from address: String) {
        failures[address] = nil
    }

    /// True when the token may make another call inside the window.
    func allowCall(token: String) -> Bool {
        let current = now()
        var recent = (calls[token] ?? []).filter { current.timeIntervalSince($0) < Self.rateWindow }
        guard recent.count < Self.rateLimit else { calls[token] = recent; return false }
        recent.append(current)
        calls[token] = recent
        return true
    }

    // MARK: - Names

    static func host(fromOrigin origin: String) -> String? {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    static func stripPort(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            // Bracketed IPv6, with or without a port.
            guard let close = trimmed.firstIndex(of: "]") else { return trimmed }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        if trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.firstIndex(of: ":") {
            return String(trimmed[..<colon])
        }
        return trimmed
    }

    /// Loopback names always pass. On the LAN, private-network addresses
    /// and local-only suffixes pass too; public DNS names never do.
    static func isLocalName(_ rawHost: String, allowLAN: Bool) -> Bool {
        let host = rawHost.lowercased()
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") { return true }
        guard allowLAN else { return false }
        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if host.contains(":") {
            // Link-local or unique-local IPv6.
            return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let localSuffixes = [".local", ".lan", ".home", ".internal", ".home.arpa"]
        if localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
        // A bare machine name (no dots) as Bonjour and mDNS resolvers hand it out.
        return !host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}
