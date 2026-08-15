/// Per-speaker network diagnostics pulled from the speaker's own
/// `:1400` diagnostic endpoints. Read-only, best-effort: every field
/// is optional and an unreachable speaker yields a row with
/// `httpRTTMillis == nil` rather than an error, so one dead device
/// never blocks the sweep.
///
/// Sources per speaker:
/// - `/status/zp` — zone name (with stereo-pair role suffix), serial,
///   hardware version, software build date. The request is also the
///   RTT probe: its wall-clock time is the latency figure.
/// - `/status/proc/ath_rincon/status` — operating frequency/channel
///   (band derivation), noise floor, PHY error counter.
/// - `/status/wireless` — connection type string, SonosNet state.
/// - `/xml/device_description.xml` — marketing firmware version
///   (`displayVersion`, e.g. "18.5") to pair with the internal build id.
import Foundation

public struct SpeakerNetworkDiagnostics: Identifiable, Sendable {
    public enum Band: Sendable {
        case ghz24
        case ghz5
        case wired
        /// Bonded home-theater satellite (surround/Sub) on the
        /// soundbar's dedicated wireless link — reported by the
        /// speaker as `ConnectionTypeString: Home Theater`.
        case homeTheater
        case sonosNet
        case unknown
    }

    public let deviceID: String
    public let roomName: String
    public let modelName: String
    /// Zone name as the speaker reports it — includes bonded-role
    /// suffixes the topology hides, e.g. "Office Front (L)".
    public let zoneName: String?
    public let ip: String
    public let band: Band
    public let ieeeChannel: Int?
    public let noiseFloorDBm: Int?
    public let phyErrors: Int?
    public let sonosNetDisabled: Bool?
    public let serialNumber: String?
    public let hardwareVersion: String?
    public let softwareDate: String?
    public let softwareVersion: String
    public let displayVersion: String?
    /// Round-trip time of the `/status/zp` request. `nil` = unreachable.
    public let httpRTTMillis: Double?
    public let fetchedAt: Date

    public var id: String { deviceID }
    public var reachable: Bool { httpRTTMillis != nil }
}

public struct SpeakerNetworkDiagnosticsService: Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        session = URLSession(configuration: config)
    }

    /// Sweeps every device concurrently; order of the result matches
    /// no particular order (callers sort for display).
    public func fetchAll(devices: [SonosDevice]) async -> [SpeakerNetworkDiagnostics] {
        await withTaskGroup(of: SpeakerNetworkDiagnostics.self) { taskGroup in
            for device in devices {
                taskGroup.addTask { await fetch(device: device) }
            }
            var out: [SpeakerNetworkDiagnostics] = []
            for await row in taskGroup { out.append(row) }
            return out
        }
    }

    public func fetch(device: SonosDevice) async -> SpeakerNetworkDiagnostics {
        let base = "http://\(device.ip):\(device.port)"

        // RTT probe + zp fields.
        let started = Date()
        let zp = await get("\(base)/status/zp")
        let rtt: Double? = zp == nil ? nil : Date().timeIntervalSince(started) * 1000

        // Remaining endpoints only when the speaker answered the probe —
        // a dead device shouldn't burn three more timeouts.
        var ath: String?
        var wireless: String?
        var description: String?
        if zp != nil {
            async let athFetch = get("\(base)/status/proc/ath_rincon/status")
            async let wirelessFetch = get("\(base)/status/wireless")
            async let descriptionFetch = get("\(base)/xml/device_description.xml")
            (ath, wireless, description) = await (athFetch, wirelessFetch, descriptionFetch)
        }

        let connectionType = firstMatch(#"<ConnectionTypeString>([^<\n]+)"#, in: wireless)
        let frequency = firstMatch(#"Operating on channel (\d+)"#, in: ath).flatMap(Int.init)
        // Observed ConnectionTypeString values: "WiFi" (infrastructure
        // station), "Home Theater" (bonded satellite on the soundbar's
        // dedicated link), "Ethernet"/"Wired". Only an explicit
        // wired value maps to `.wired` — an unrecognized value must
        // not (satellites were previously shown as Ethernet).
        let band: SpeakerNetworkDiagnostics.Band
        let type = connectionType?.lowercased() ?? ""
        if type.contains("ethernet") || type.contains("wired") {
            band = .wired
        } else if type.contains("home theater") {
            band = .homeTheater
        } else if type.contains("sonosnet") {
            band = .sonosNet
        } else if let frequency {
            band = frequency >= 4900 ? .ghz5 : .ghz24
        } else {
            band = .unknown
        }

        // Model falls back to the device description — discovery records
        // hold an empty modelName for devices whose description fetch
        // hasn't completed this session.
        let descriptionModel = firstMatch(#"<modelName>([^<\n]+)"#, in: description)

        return SpeakerNetworkDiagnostics(
            deviceID: device.id,
            roomName: device.roomName,
            modelName: device.modelName.isEmpty ? (descriptionModel ?? "") : device.modelName,
            zoneName: firstMatch(#"<ZoneName>([^<\n]+)"#, in: zp),
            ip: device.ip,
            band: band,
            ieeeChannel: firstMatch(#"IEEE channel: (\d+)"#, in: ath).flatMap(Int.init),
            noiseFloorDBm: firstMatch(#"Noise Floor:\s+(-\d+) dBm \(chain 0"#, in: ath).flatMap(Int.init),
            phyErrors: firstMatch(#"PHY errors since last reading/reset: (\d+)"#, in: ath).flatMap(Int.init),
            sonosNetDisabled: firstMatch(#"<SonosNetDisabled>(\d)"#, in: wireless).map { $0 == "1" },
            serialNumber: firstMatch(#"<SerialNumber>([^<\n]+)"#, in: zp),
            hardwareVersion: firstMatch(#"<HardwareVersion>([^<\n]+)"#, in: zp),
            softwareDate: firstMatch(#"<SoftwareDate>([^<\n ]+)"#, in: zp),
            softwareVersion: device.softwareVersion,
            displayVersion: firstMatch(#"<displayVersion>([^<\n]+)"#, in: description),
            httpRTTMillis: rtt,
            fetchedAt: Date()
        )
    }

    private func get(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func firstMatch(_ pattern: String, in text: String?) -> String? {
        guard let text,
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        // Values come straight out of XML — decode entities so names
        // like "Kid&apos;s Bedroom" display as written.
        return XMLResponseParser.xmlUnescape(String(text[range]))
            .trimmingCharacters(in: .whitespaces)
    }
}
