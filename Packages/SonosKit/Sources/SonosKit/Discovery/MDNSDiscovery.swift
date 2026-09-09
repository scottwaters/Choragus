/// MDNSDiscovery.swift — Discovers Sonos speakers via Bonjour/_sonos._tcp.
///
/// `NWBrowser` (Network.framework) browses for `_sonos._tcp.local.` and reads
/// the TXT record advertised by every modern (S2 1.51+) Sonos player. The TXT
/// carries the same `location` URL that SSDP would surface in its M-SEARCH
/// response, so the existing post-discovery pipeline (device-description fetch
/// → topology → browse) is unchanged.
///
/// Useful on segmented networks where mDNS reflectors (UniFi, OPNsense) bridge
/// Bonjour across VLANs but not SSDP multicast.
///
/// **TXT priming:** when the speaker advertises `hhid`, `MDNSDiscovery` passes
/// it through `onDeviceFound` so `SonosManager` can skip the per-speaker
/// `GetHouseholdID` SOAP call. Saves one round-trip per speaker on every
/// discovery cycle — meaningful on S1 hardware which is request-sensitive.
import Foundation
import Network

public final class MDNSDiscovery: SpeakerDiscovery, @unchecked Sendable {
    private let serviceType = "_sonos._tcp"
    private let queue = DispatchQueue(label: "mdns.discovery", qos: .userInitiated)

    private var browser: NWBrowser?
    private var resolveConnections: [NWEndpoint: NWConnection] = [:]
    private var seenLocations: Set<String> = []  // de-dup repeats from the same browse

    public var onDeviceFound: DeviceFoundHandler?

    public init() {}

    public func startDiscovery() {
        queue.async { [weak self] in self?.startBrowserLocked() }
    }

    public func stopDiscovery() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel()
            self.browser = nil
            for c in self.resolveConnections.values { c.cancel() }
            self.resolveConnections.removeAll()
            self.seenLocations.removeAll()
        }
    }

    /// mDNS is push-driven; rescan tears down and rebuilds the browser to
    /// trigger a fresh announce/query cycle. Also clears the dedup cache so
    /// the host pipeline re-receives existing speakers (matches SSDP rescan
    /// semantics).
    public func rescan() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel()
            self.browser = nil
            self.seenLocations.removeAll()
            self.startBrowserLocked()
        }
    }

    // MARK: - Private

    private func startBrowserLocked() {
        let params = NWParameters()
        params.includePeerToPeer = false

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let err) = state {
                sonosDebugLog("[MDNS] Browser failed: \(err). Restarting in 5s.")
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.browser?.cancel()
                    self?.browser = nil
                    self?.startBrowserLocked()
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                self.handleResult(result)
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleResult(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

        // Any process that can register a Bonjour service writes arbitrary
        // TXT records, and the host a TXT `location` names would become a
        // minted device IP and an event-listener allowed peer. Every
        // discovery therefore resolves the host from the actual endpoint,
        // at one TCP connection per service per discovery pass.

        // Spec-compliant fallback: resolve the service via NWConnection to
        // obtain host/port, then synthesise the standard device-description
        // URL. Rare in practice — Sonos always advertises `location` — but
        // protects against firmware that strips TXT or reflectors that mangle it.
        resolveService(name: name, type: type, domain: domain)
    }

    /// IPv4 first: the rest of the pipeline keys speakers by IPv4 address.
    /// A service reachable only over IPv6 is retried without the
    /// restriction and its literal is bracketed for the URL.
    private func resolveService(name: String, type: String, domain: String, ipv4Only: Bool = true) {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        guard resolveConnections[endpoint] == nil else { return }

        let parameters = NWParameters.tcp
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if let (host, port) = self.extractHostPort(from: connection) {
                    let location = "http://\(Self.urlHost(host)):\(port)/xml/device_description.xml"
                    if !self.seenLocations.contains(location) {
                        self.seenLocations.insert(location)
                        self.onDeviceFound?(location, host, port, nil)
                    }
                }
                connection.cancel()
                self.resolveConnections.removeValue(forKey: endpoint)
            case .failed:
                self.resolveConnections.removeValue(forKey: endpoint)
                if ipv4Only {
                    self.resolveService(name: name, type: type, domain: domain, ipv4Only: false)
                }
            case .cancelled:
                self.resolveConnections.removeValue(forKey: endpoint)
            default:
                break
            }
        }
        resolveConnections[endpoint] = connection
        connection.start(queue: queue)
    }

    private func extractHostPort(from connection: NWConnection) -> (String, Int)? {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, let port) = endpoint else { return nil }
        let hostString: String
        switch host {
        case .ipv4(let v4): hostString = "\(v4)"
        case .ipv6(let v6):
            if let v4 = v6.asIPv4 {
                hostString = "\(v4)"
            } else {
                // Drop the `%scope` suffix: it is not URL syntax.
                hostString = "\(v6)".split(separator: "%", maxSplits: 1).first.map(String.init) ?? "\(v6)"
            }
        case .name(let n, _): hostString = n
        @unknown default: return nil
        }
        return (hostString, Int(port.rawValue))
    }

    /// Host as it appears in a URL authority: an IPv6 literal is bracketed.
    static func urlHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// TXT keys on Sonos are lowercase, but tolerate case variation.
    private func txtValue(_ txt: NWTXTRecord, _ key: String) -> String? {
        if let v = txt[key] { return v }
        if let v = txt[key.lowercased()] { return v }
        if let v = txt[key.uppercased()] { return v }
        return nil
    }
}
