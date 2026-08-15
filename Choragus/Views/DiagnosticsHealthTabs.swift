/// Shared display vocabulary for speaker link diagnostics — band /
/// latency / interference / status text and tints derived from
/// `SpeakerNetworkDiagnostics`. Used by the Diagnostics → Network tab.
import SwiftUI
import SonosKit

extension SpeakerNetworkDiagnostics {
    var displayName: String {
        if let zoneName, !zoneName.isEmpty { return zoneName }
        return roomName.isEmpty ? deviceID : roomName
    }

    var bandText: String {
        switch band {
        case .wired: return "Ethernet"
        case .homeTheater:
            return ieeeChannel.map { "\(L10n.diagConnHomeTheater) · ch \($0)" } ?? L10n.diagConnHomeTheater
        case .sonosNet: return "SonosNet"
        case .ghz5: return ieeeChannel.map { "5 GHz · ch \($0)" } ?? "5 GHz"
        case .ghz24: return ieeeChannel.map { "2.4 GHz · ch \($0)" } ?? "2.4 GHz"
        case .unknown: return "—"
        }
    }

    /// Band is identity, not judgment: 2.4 GHz is the only Wi-Fi band
    /// home-theater-class products (Arc/Beam/Amp) can join, so it
    /// renders neutral. Status colors are reserved for measured
    /// problems (latency, interference, reachability).
    var bandTint: Color {
        switch band {
        case .ghz5, .wired, .homeTheater, .sonosNet: return .green
        case .ghz24, .unknown: return .secondary
        }
    }

    var latencyText: String {
        httpRTTMillis.map { String(format: "%.0f ms", $0) } ?? L10n.diagNetworkUnreachable
    }

    var latencyTint: Color {
        guard let rtt = httpRTTMillis else { return .red }
        if rtt < 50 { return .green }
        if rtt < 150 { return .orange }
        return .red
    }

    var firmwareText: String {
        if let displayVersion, !displayVersion.isEmpty {
            return "\(displayVersion) (\(softwareVersion))"
        }
        return softwareVersion
    }

    /// Interference proxy: the PHY error counter. Thresholds chosen from
    /// observed fleet behaviour — healthy 5 GHz units sit in the
    /// hundreds; congested 2.4 GHz units reach tens of thousands.
    var interferenceTint: Color {
        guard let phyErrors else { return .secondary }
        if phyErrors < 5_000 { return .green }
        if phyErrors < 20_000 { return .orange }
        return .red
    }

    var interferenceText: String {
        phyErrors.map { $0.formatted() } ?? "—"
    }

    /// One plain-language status word per speaker.
    /// 0 = OK, 1 = check, 2 = offline — also the sort rank.
    /// Being on 2.4 GHz is deliberately NOT a flag: home-theater-class
    /// products (Arc/Beam/Amp) can only join 2.4 GHz, so band alone is
    /// not a problem — only measured symptoms are (latency,
    /// interference, reachability).
    var statusRank: Int {
        if !reachable { return 2 }
        let slowLink = (httpRTTMillis ?? 0) >= 150
        let noisyLink = (phyErrors ?? 0) >= 20_000
        return (slowLink || noisyLink) ? 1 : 0
    }

    var sortBand: Int {
        switch band {
        case .wired: return 0
        case .ghz5: return 1
        case .homeTheater: return 2
        case .sonosNet: return 3
        case .ghz24: return 4
        case .unknown: return 5
        }
    }
}

enum SpeakerStatusDisplay {
    static func text(forRank rank: Int) -> String {
        switch rank {
        case 2: return L10n.diagStatusOffline
        case 1: return L10n.diagStatusCheckWifi
        default: return L10n.diagStatusOK
        }
    }

    static func tint(forRank rank: Int) -> Color {
        switch rank {
        case 2: return .red
        case 1: return .orange
        default: return .green
        }
    }
}
