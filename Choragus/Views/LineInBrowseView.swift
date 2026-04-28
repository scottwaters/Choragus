/// LineInBrowseView.swift — Lists speakers that have analog or TV inputs.
///
/// Sonos exposes physical inputs as a "Line-In" source in its own
/// apps. Tapping a speaker plays its input through the
/// currently-selected group:
///   - Analog (Connect, Amp, Five, Play:5, Move) → `x-rincon-stream:<id>`
///   - TV inputs (Arc, Beam, Playbar, Playbase, Ray) → `x-sonos-htastream:<id>:spdif`
/// Speakers without any input capability aren't listed.
import SwiftUI
import SonosKit
import AppKit

struct LineInBrowseView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup?

    @State private var playError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Line-In sources").font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let err = playError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.85))
            }

            let entries = inputCapableSpeakers()
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector").font(.title2).foregroundStyle(.tertiary)
                    Text("No speakers with line-in or TV inputs found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    ForEach(entries, id: \.deviceID) { entry in
                        Button { play(entry: entry) } label: {
                            row(for: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Row

    private func row(for entry: LineInEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == .tv ? "tv.fill" : "cable.connector.horizontal")
                .frame(width: 30, height: 30)
                .foregroundStyle(entry.kind == .tv ? .blue : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.roomName).font(.body).lineLimit(1)
                Text("\(entry.modelName)  •  \(entry.kind == .tv ? "TV (HDMI / Optical)" : "Analog input")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Discovery

    private enum LineInKind { case analog, tv }

    private struct LineInEntry {
        let deviceID: String   // RINCON_xxx (no _MR suffix)
        let roomName: String
        let modelName: String
        let kind: LineInKind
    }

    /// Filter speakers by model. Walks `sonosManager.devices` (every
    /// SSDP-discovered device, includes both ZonePlayers and their
    /// MediaRenderer `_MR` shadows) — model names typically live on
    /// the `_MR` entries while line-in playback URIs need the bare
    /// ZonePlayer ID, so we have to look across both and dedupe by
    /// the base ID.
    private func inputCapableSpeakers() -> [LineInEntry] {
        var byBaseID: [String: LineInEntry] = [:]
        for member in sonosManager.devices.values {
            let baseID = member.id.hasSuffix("_MR")
                ? String(member.id.dropLast("_MR".count))
                : member.id
            let modelName = member.modelName
            let roomName = member.roomName
            let existing = byBaseID[baseID]
            let bestModel = !modelName.isEmpty ? modelName : (existing?.modelName ?? "")
            guard let kind = inputKind(for: bestModel) else { continue }
            byBaseID[baseID] = LineInEntry(
                deviceID: baseID,
                roomName: roomName.isEmpty ? (existing?.roomName ?? "Speaker") : roomName,
                modelName: bestModel.isEmpty ? "Sonos Player" : bestModel,
                kind: kind
            )
        }
        return byBaseID.values.sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }

    /// Maps Sonos model names to input capability. Substring-matched
    /// because Sonos's `modelName` strings vary across firmware
    /// versions (e.g. "Sonos Connect:Amp" vs "Sonos ZP120").
    private func inputKind(for modelName: String) -> LineInKind? {
        let m = modelName.lowercased()
        // TV-input devices first — they DO have HDMI/Optical, not analog.
        if m.contains("arc") || m.contains("beam") || m.contains("playbar")
            || m.contains("playbase") || m.contains("ray") {
            return .tv
        }
        // Analog line-in devices.
        if m.contains("connect") || m.contains("amp")
            || m.contains("five") || m.contains("play:5") || m.contains("move") {
            return .analog
        }
        return nil
    }

    /// Static so the sidebar can probe without instantiating the view.
    static func isInputCapable(modelName: String) -> Bool {
        let m = modelName.lowercased()
        return m.contains("arc") || m.contains("beam") || m.contains("playbar")
            || m.contains("playbase") || m.contains("ray")
            || m.contains("connect") || m.contains("amp")
            || m.contains("five") || m.contains("play:5") || m.contains("move")
    }

    // MARK: - Playback

    private func play(entry: LineInEntry) {
        guard let group = group else {
            playError = "No speaker group selected to play to."
            return
        }
        playError = nil
        let uri: String
        let title: String
        let albumLabel: String
        switch entry.kind {
        case .analog:
            uri = "x-rincon-stream:\(entry.deviceID)"
            title = "Line-In"
            albumLabel = "Analog input from \(entry.roomName)"
        case .tv:
            uri = "x-sonos-htastream:\(entry.deviceID):spdif"
            title = "TV"
            albumLabel = "HDMI / Optical input from \(entry.roomName)"
        }
        let didl = Self.buildDIDL(title: title, album: albumLabel, streamURI: uri)
        let item = BrowseItem(
            id: "linein:\(entry.deviceID)",
            title: title,
            artist: entry.roomName,
            album: albumLabel,
            albumArtURI: nil,
            itemClass: .musicTrack,
            resourceURI: uri,
            resourceMetadata: didl
        )
        Task {
            do {
                try await sonosManager.playBrowseItem(item, in: group)
            } catch {
                playError = "Couldn't start \(title): \(error.localizedDescription)"
                sonosDebugLog("[LINEIN] play failed for \(entry.deviceID): \(error)")
            }
        }
    }

    private static func buildDIDL(title: String, album: String, streamURI: String) -> String {
        let id = "linein"
        let escTitle = xmlEscape(title)
        let escAlbum = xmlEscape(album)
        let escStream = xmlEscape(streamURI)
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="\(id)" parentID="-1" restricted="1">\
        <dc:title>\(escTitle)</dc:title>\
        <upnp:album>\(escAlbum)</upnp:album>\
        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
        <res protocolInfo="x-rincon-stream:*:*:*">\(escStream)</res>\
        </item></DIDL-Lite>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }
}
