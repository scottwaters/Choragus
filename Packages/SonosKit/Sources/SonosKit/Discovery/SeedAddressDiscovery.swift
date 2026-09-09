/// SeedAddressDiscovery.swift — Finds speakers at addresses the user supplied.
///
/// Multicast discovery fails on networks that refuse to carry it: IGMP
/// snooping without a querier, an access point that drops multicast to save
/// airtime, a VLAN boundary with no relay. Raising the SSDP hop limit helps
/// where multicast is *routed*; it does nothing where multicast is *blocked*.
///
/// A direct HTTP GET to a speaker's description endpoint is ordinary unicast
/// traffic and crosses those boundaries. The escape hatch is a user-named
/// address.
///
/// **One address is usually enough for a whole household.** This transport
/// only has to get a single speaker into the device list; `GetZoneGroupState`
/// on that speaker then returns every other member with its own IP, and the
/// normal topology path takes over. The setting is a seed list, not a table
/// the user has to maintain per speaker.
///
/// What this does NOT bypass is UPnP itself — every transport command is a
/// SOAP call to the speaker. It replaces the multicast *search* step only.
import Foundation

public final class SeedAddressDiscovery: SpeakerDiscovery, @unchecked Sendable {

    /// Outcome of probing one address, surfaced per entry in Settings.
    public enum ProbeResult: Equatable, Sendable {
        case reachable(roomName: String)
        /// Answered, but not with a Sonos device description.
        case notASpeaker
        /// No answer inside the timeout.
        case unreachable
        case malformedAddress
    }

    /// Probe timeout. Short: a seed address that is switched off or has moved
    /// must not hold up discovery.
    private static let probeTimeout: TimeInterval = 3

    public var onDeviceFound: SpeakerDiscovery.DeviceFoundHandler?

    /// Called after each probe so the settings UI can show per-entry state.
    public var onProbeResult: (@Sendable (String, ProbeResult) -> Void)?

    private let addressProvider: @Sendable () -> [String]
    private let queue = DispatchQueue(label: "sonos.seedDiscovery", qos: .utility)
    private var task: Task<Void, Never>?

    /// - Parameter addresses: read at each scan rather than captured once, so
    ///   edits in Settings take effect on the next refresh without a relaunch.
    public init(addresses: @escaping @Sendable () -> [String]) {
        self.addressProvider = addresses
    }

    public func startDiscovery() { rescan() }

    public func stopDiscovery() {
        task?.cancel()
        task = nil
    }

    public func rescan() {
        task?.cancel()
        let addresses = addressProvider()
        guard !addresses.isEmpty else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Sequential: seed lists are a handful of entries, and probing them
            // in parallel would put an unnecessary burst on S1 hardware, which
            // is sensitive to request pressure.
            for address in addresses {
                if Task.isCancelled { return }
                await self.probe(address)
            }
        }
    }

    /// Normalises what a user typed into an address this can probe.
    /// Accepts a bare address, one with a port, or a full URL.
    public static func normalise(_ input: String) -> (host: String, port: Int)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        var port = SonosProtocol.defaultPort
        // Split on the LAST colon so an IPv6 literal is not mangled; a bare
        // IPv6 address has several and none of them is a port.
        if let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1 {
            let candidate = String(text[text.index(after: colon)...])
            if let parsed = Int(candidate), (1...65535).contains(parsed) {
                port = parsed
                text = String(text[..<colon])
            }
        }
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespaces) == nil else { return nil }
        return (text, port)
    }

    private func probe(_ address: String) async {
        guard let (host, port) = Self.normalise(address) else {
            onProbeResult?(address, .malformedAddress)
            return
        }
        let location = "http://\(host):\(port)/xml/device_description.xml"
        do {
            let description = try await withTimeout(seconds: Self.probeTimeout) {
                try await DeviceDescriptionParser.fetch(from: location)
            }
            guard let description else {
                onProbeResult?(address, .notASpeaker)
                return
            }
            onProbeResult?(address, .reachable(roomName: description.roomName))
            // The household is not known cheaply here — unlike mDNS, which
            // carries it in a TXT record — so it is left for the normal path
            // to resolve with GetHouseholdID.
            onDeviceFound?(location, host, port, nil)
        } catch {
            onProbeResult?(address, .unreachable)
        }
    }

    /// `URLSession` timeouts apply per request, not to the whole await, and a
    /// host that accepts a connection then stalls would otherwise hang the
    /// scan for the session's full timeout.
    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}
