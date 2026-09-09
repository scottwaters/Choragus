import Foundation

/// A speaker's physical audio input, playable through any group.
///
/// Sonos exposes physical inputs as a "Line-In" source in its own apps.
/// The speaker that owns the input streams it; the group that plays it
/// points its transport at the owner's stream URI:
///   - Analog (Connect, Amp, Five, Play:5, Move) → `x-rincon-stream:<id>`
///   - TV inputs (Arc, Beam, Playbar, Playbase, Ray) → `x-sonos-htastream:<id>:spdif`
///
/// Shared by the Browse "Line-In" list and the Select Input Shortcuts
/// intent, so both list the same speakers and send the same URI.
public struct PhysicalInput: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case analog
        case tv
    }

    /// Bare ZonePlayer id (`RINCON_xxx`, no `_MR` suffix). This is
    /// what the stream URI embeds.
    public let deviceID: String
    public let roomName: String
    public let modelName: String
    public let kind: Kind

    public var id: String { deviceID }

    public init(deviceID: String, roomName: String, modelName: String, kind: Kind) {
        self.deviceID = deviceID
        self.roomName = roomName
        self.modelName = modelName
        self.kind = kind
    }

    // MARK: - Discovery

    /// Every input-capable speaker in `devices`. Walks every
    /// SSDP-discovered entry — ZonePlayers and their MediaRenderer `_MR`
    /// shadows both — because model names typically live on the `_MR`
    /// entries while the stream URI needs the bare ZonePlayer id. The
    /// two are merged by base id. Sorted by room name.
    public static func inputs(in devices: [String: SonosDevice]) -> [PhysicalInput] {
        var byBaseID: [String: PhysicalInput] = [:]
        for device in devices.values {
            let baseID = device.id.hasSuffix("_MR")
                ? String(device.id.dropLast("_MR".count))
                : device.id
            let existing = byBaseID[baseID]
            let bestModel = !device.modelName.isEmpty ? device.modelName : (existing?.modelName ?? "")
            guard let kind = kind(forModelName: bestModel) else { continue }
            byBaseID[baseID] = PhysicalInput(
                deviceID: baseID,
                roomName: device.roomName.isEmpty ? (existing?.roomName ?? L10n.unnamedSpeaker) : device.roomName,
                modelName: bestModel.isEmpty ? L10n.sonosPlayerFallback : bestModel,
                kind: kind
            )
        }
        return byBaseID.values.sorted {
            $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
        }
    }

    /// Maps a Sonos model name to its input capability, or nil when the
    /// model has no physical input. Substring-matched because model
    /// name strings vary across firmware versions ("Sonos Connect:Amp"
    /// vs "Sonos ZP120"). TV-input models are checked first: they carry
    /// HDMI / optical, not analog.
    public static func kind(forModelName modelName: String) -> Kind? {
        let m = modelName.lowercased()
        if m.contains("arc") || m.contains("beam") || m.contains("playbar")
            || m.contains("playbase") || m.contains("ray") {
            return .tv
        }
        if m.contains("connect") || m.contains("amp")
            || m.contains("five") || m.contains("play:5") || m.contains("move") {
            return .analog
        }
        return nil
    }

    public static func isInputCapable(modelName: String) -> Bool {
        kind(forModelName: modelName) != nil
    }

    // MARK: - Playback

    /// Stream URI the playing group's transport is pointed at.
    public var playURI: String {
        switch kind {
        case .analog: return "x-rincon-stream:\(deviceID)"
        case .tv: return "x-sonos-htastream:\(deviceID):spdif"
        }
    }

    /// Now Playing title. Deliberately not localised: `SonosManager`
    /// maps the stream URIs to these same literals and
    /// `PlayHistoryManager` matches on them to skip TV / Line-In plays.
    public var title: String {
        switch kind {
        case .analog: return "Line-In"
        case .tv: return "TV"
        }
    }

    /// Localised album line shown under the title ("Analog input from Kitchen").
    public var albumLabel: String {
        switch kind {
        case .analog: return L10n.analogInputFromFormat(roomName)
        case .tv: return L10n.tvInputFromFormat(roomName)
        }
    }

    /// Browse item carrying the stream URI and DIDL, ready for
    /// `SonosManager.playBrowseItem`.
    public var browseItem: BrowseItem {
        BrowseItem(
            id: "linein:\(deviceID)",
            title: title,
            artist: roomName,
            album: albumLabel,
            albumArtURI: nil,
            itemClass: .musicTrack,
            resourceURI: playURI,
            resourceMetadata: didl
        )
    }

    /// DIDL-Lite the speaker accepts for a physical-input stream.
    public var didl: String {
        let escTitle = XMLResponseParser.xmlEscape(title)
        let escAlbum = XMLResponseParser.xmlEscape(albumLabel)
        let escStream = XMLResponseParser.xmlEscape(playURI)
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="linein" parentID="-1" restricted="1">\
        <dc:title>\(escTitle)</dc:title>\
        <upnp:album>\(escAlbum)</upnp:album>\
        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
        <res protocolInfo="x-rincon-stream:*:*:*">\(escStream)</res>\
        </item></DIDL-Lite>
        """
    }
}
