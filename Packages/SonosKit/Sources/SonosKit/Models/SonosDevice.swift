import Foundation

public struct SonosDevice: Identifiable, Hashable {
    public let id: String // UUID like RINCON_xxxx
    public let ip: String
    public let port: Int
    public var roomName: String
    public var modelName: String
    public var modelNumber: String
    public var softwareVersion: String
    public var swGen: String // "1" for S1, "2" for S2, empty when unknown
    public var householdID: String?
    public var isCoordinator: Bool
    public var groupID: String?

    public init(id: String, ip: String, port: Int = SonosProtocol.defaultPort, roomName: String = "",
                modelName: String = "", modelNumber: String = "", softwareVersion: String = "",
                swGen: String = "", householdID: String? = nil,
                isCoordinator: Bool = false, groupID: String? = nil) {
        self.id = id
        self.ip = ip
        self.port = port
        self.roomName = roomName
        self.modelName = modelName
        self.modelNumber = modelNumber
        self.softwareVersion = softwareVersion
        self.swGen = swGen
        self.householdID = householdID
        self.isCoordinator = isCoordinator
        self.groupID = groupID
    }

    /// Sonos S1 vs S2 classification. Prefers the canonical `<swGen>` tag
    /// ("1" = S1, "2" = S2); falls back to parsing the firmware major version.
    /// Returns .unknown only when both signals are missing.
    public var systemVersion: SonosSystemVersion {
        SonosSystemVersion.classify(swGen: swGen, softwareVersion: softwareVersion)
    }

    // swiftlint:disable:next force_unwrapping
    private static let fallbackURL = URL(string: "http://127.0.0.1:1400")!

    public var baseURL: URL {
        URL(string: "http://\(ip):\(port)") ?? Self.fallbackURL
    }

    /// Converts a relative path (e.g. "/getaa?...") to an absolute URL using this device's address.
    /// Returns the original string unchanged if it's already absolute.
    public func makeAbsoluteURL(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return "http://\(ip):\(port)\(path)"
    }

    /// True if this speaker model can decode and render Dolby Atmos.
    /// Used to gate the "Dolby Atmos" badge in Now Playing — the badge
    /// only appears when the content carries the Dolby flag AND the
    /// coordinator is capable of actually rendering it (otherwise the
    /// content is downmixed to stereo). Conservatively whitelisted to
    /// the models documented by Sonos as Atmos-capable.
    /// True when the device is a portable Sonos speaker (Move, Move 2,
    /// Roam, Roam 2). These models have two independent input sources
    /// — WiFi (responds to SMAPI/UPnP control) and Bluetooth (local
    /// pairing, isolated audio pipeline). When a portable is on
    /// Bluetooth, the WiFi-side `RenderingControl` service still
    /// answers SOAP calls but `GetVolume` returns 0 and `SetVolume`
    /// no-ops at the audio pipeline. Use this flag to surface
    /// portable-specific diagnostics so issues like #37 don't
    /// require the maintainer to own a Move to reproduce.
    public var isPortable: Bool {
        let name = modelName.lowercased()
        return name.contains("move") || name.contains("roam")
    }

    public var isAtmosCapable: Bool {
        let name = modelName
        if name.localizedCaseInsensitiveContains("Arc") { return true }
        if name.localizedCaseInsensitiveContains("Era 300") { return true }
        if name.localizedCaseInsensitiveContains("Beam") {
            // Beam Gen 2 is Atmos-capable; original Beam is not. The
            // model number is `S40` for Gen 2, `S14` for Gen 1.
            return modelNumber.uppercased().contains("S40")
                || name.localizedCaseInsensitiveContains("Gen 2")
        }
        return false
    }
}

extension SonosGroup {
    /// True if the group's coordinator can decode Dolby Atmos. Resolves
    /// the model name via an explicit lookup dictionary because Sonos
    /// publishes two device records per speaker — the bare ZonePlayer
    /// (used as the coordinator) often carries an empty modelName,
    /// while the sibling MediaRenderer sub-device (UUID suffixed
    /// `_MR`) holds the descriptive metadata. The lookup walks both
    /// so the gate doesn't fail purely because the bare record is
    /// blank. Pass `SonosManager.devices` from the call site.
    public func isAtmosCapable(devices: [String: SonosDevice]) -> Bool {
        let bareID = coordinatorID
        if let bare = devices[bareID], bare.isAtmosCapable { return true }
        if let mr = devices["\(bareID)_MR"], mr.isAtmosCapable { return true }
        // Fallback: scan all records whose ID shares the bare prefix.
        // Catches stray ID-suffix variants Sonos may emit on future
        // firmware without breaking the existing two-record split.
        for (id, dev) in devices where id.hasPrefix(bareID) {
            if dev.isAtmosCapable { return true }
        }
        return false
    }
}
