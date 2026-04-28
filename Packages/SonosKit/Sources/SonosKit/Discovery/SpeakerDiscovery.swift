/// SpeakerDiscovery.swift — Common interface for Sonos speaker discovery transports.
///
/// SSDP and mDNS both end up calling `handleDiscoveredDevice(location:ip:port:hh:)`
/// in `SonosManager`. The transports differ in how they obtain that tuple:
///
/// - SSDP multicast probe → parse LOCATION + IP from datagram.
/// - mDNS browse → read `location` (and bonus `uuid`/`hhid`) from TXT record.
///
/// `householdID` is non-nil only when the transport learned it cheaply
/// (mDNS TXT). It's a hint that lets `SonosManager` skip a `GetHouseholdID`
/// SOAP round-trip per speaker — significant on S1 hardware which is
/// sensitive to request pressure.
import Foundation

public protocol SpeakerDiscovery: AnyObject, Sendable {
    typealias DeviceFoundHandler = @Sendable (
        _ location: String,
        _ ip: String,
        _ port: Int,
        _ householdID: String?
    ) -> Void

    var onDeviceFound: DeviceFoundHandler? { get set }

    func startDiscovery()
    func stopDiscovery()
    func rescan()
}
