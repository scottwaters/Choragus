import Foundation

/// Identifies whether a device/household belongs to the Sonos S1 (legacy) or S2 platform.
/// The two systems cannot be merged; they coexist on a LAN as independent topologies.
public enum SonosSystemVersion: String, CaseIterable, Hashable {
    case s1 = "S1"
    case s2 = "S2"
    case unknown = "Unknown"

    public var displayLabel: String { rawValue }

    /// Canonical Sonos S1/S2 indicator from the UPnP device description `<swGen>` tag.
    /// Sonos publishes "1" for S1 and "2" for S2. Preferred over softwareVersion parsing.
    public static func fromSwGen(_ swGen: String) -> SonosSystemVersion {
        switch swGen.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .s1
        case "2": return .s2
        default: return .unknown
        }
    }

    /// Fallback classification when `<swGen>` is absent. Uses the firmware major version:
    /// S2 shipped with firmware 12.x in 2020; S1 peaks at 11.x.
    public static func fromSoftwareVersion(_ version: String) -> SonosSystemVersion {
        guard !version.isEmpty else { return .unknown }
        let head = version.split(whereSeparator: { !$0.isNumber }).first ?? ""
        guard let major = Int(head) else { return .unknown }
        return major < 12 ? .s1 : .s2
    }

    /// Combined classifier: swGen wins when present; softwareVersion is the fallback.
    public static func classify(swGen: String, softwareVersion: String) -> SonosSystemVersion {
        let fromGen = fromSwGen(swGen)
        if fromGen != .unknown { return fromGen }
        return fromSoftwareVersion(softwareVersion)
    }
}
