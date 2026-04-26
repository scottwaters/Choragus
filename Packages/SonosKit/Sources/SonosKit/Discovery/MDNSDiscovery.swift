/// MDNSDiscovery.swift — Discovers Sonos speakers via mDNS/Bonjour (_sonos._tcp).
///
/// Uses NWBrowser (Network.framework) to browse the _sonos._tcp service type.
/// Each result's TXT record contains a "location" key whose value is identical
/// in format to the LOCATION header returned by SSDP, so the existing
/// handleDiscoveredDevice pipeline in SonosManager works without modification.
///
/// This is useful in VLAN-segmented networks where mDNS reflectors (e.g. UniFi)
/// forward Bonjour traffic across subnets but do not forward SSDP multicast.
import Foundation
import Network

public final class MDNSDiscovery: SpeakerDiscovery, @unchecked Sendable {
    private let serviceType = "_sonos._tcp"

    private var browser: NWBrowser?
    private var activeConnections: [NWEndpoint: NWConnection] = [:]
    private let queue = DispatchQueue(label: "mdns.discovery", qos: .userInitiated)

    public var onDeviceFound: DeviceFoundHandler?

    public init() {}

    public func startDiscovery() {
        queue.async { [weak self] in
            self?.startBrowser()
        }
    }

    public func stopDiscovery() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel()
            self.browser = nil
            for conn in self.activeConnections.values { conn.cancel() }
            self.activeConnections.removeAll()
        }
    }

    /// mDNS is passive (the network pushes updates); rescan re-creates the browser
    /// to force a fresh browse cycle.
    public func rescan() {
        queue.async { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
            self?.startBrowser()
        }
    }

    // MARK: - Private

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = false

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                sonosDebugLog("[MDNS] Browser failed: \(error). Restarting.")
                self?.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.browser?.cancel()
                    self?.browser = nil
                    self?.startBrowser()
                }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                self?.queue.async { [weak self] in
                    self?.handleResult(result)
                }
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleResult(_ result: NWBrowser.Result) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

        // Extract location from TXT record if present — this avoids needing to
        // resolve the service and open a TCP connection just to get the URL.
        if case .bonjour(let txt) = result.metadata {
            if let location = txtValue(txt, key: "location"), !location.isEmpty,
               let url = URL(string: location), let host = url.host {
                let port = url.port ?? SonosProtocol.defaultPort
                sonosDebugLog("[MDNS] Found via TXT: \(name) location=\(location)")
                onDeviceFound?(location, host, port)
                return
            }
        }

        // Fallback: resolve the service to get IP + port, then build the
        // standard device description URL. This path fires when the TXT record
        // doesn't include a "location" key (rare, but spec-compliant speakers
        // should always include it).
        resolveService(name: name, type: type, domain: domain)
    }

    /// Resolves a Bonjour service name to an IP address and port, then synthesises
    /// the device description URL used by the SSDP pipeline.
    private func resolveService(name: String, type: String, domain: String) {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        guard activeConnections[endpoint] == nil else { return }

        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if let (host, port) = self.extractHostPort(from: connection) {
                    let location = "http://\(host):\(port)/xml/device_description.xml"
                    sonosDebugLog("[MDNS] Resolved \(name): \(location)")
                    self.onDeviceFound?(location, host, port)
                }
                connection.cancel()
                self.activeConnections.removeValue(forKey: endpoint)
            case .failed, .cancelled:
                self.activeConnections.removeValue(forKey: endpoint)
            default:
                break
            }
        }

        activeConnections[endpoint] = connection
        connection.start(queue: queue)
    }

    private func extractHostPort(from connection: NWConnection) -> (String, Int)? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, let port):
            let hostString: String
            switch host {
            case .ipv4(let v4): hostString = "\(v4)"
            case .ipv6(let v6): hostString = "\(v6)"
            case .name(let n, _): hostString = n
            @unknown default: return nil
            }
            return (hostString, Int(port.rawValue))
        default:
            return nil
        }
    }

    /// Reads a key from an NWTXTRecord. Sonos advertises keys in lowercase.
    private func txtValue(_ txt: NWTXTRecord, key: String) -> String? {
        txt[key] ?? txt[key.lowercased()] ?? txt[key.uppercased()]
    }
}
