/// SpeakerDiscovery.swift — Protocol for Sonos speaker discovery mechanisms.
///
/// Abstracts over different discovery transports (SSDP, mDNS) so SonosManager
/// can use either without knowing the underlying implementation.
import Foundation

/// Common interface for all Sonos speaker discovery implementations.
public protocol SpeakerDiscovery: AnyObject, Sendable {
    /// Callback type: (locationURL, ipAddress, port)
    typealias DeviceFoundHandler = (String, String, Int) -> Void

    var onDeviceFound: DeviceFoundHandler? { get set }

    /// Begin listening for speakers.
    func startDiscovery()

    /// Stop listening and release resources.
    func stopDiscovery()

    /// Re-send a discovery probe without tearing down the underlying transport.
    func rescan()
}
