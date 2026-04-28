/// RecentlyPlayedView.swift — Shows recently played tracks from play history.
import SwiftUI
import SonosKit

struct RecentlyPlayedView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    let group: SonosGroup?

    private var recentItems: [PlayHistoryEntry] {
        playHistoryManager.recentlyPlayed(limit: 30)
    }

    var body: some View {
        if recentItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(L10n.noRecentlyPlayed)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(recentItems) { entry in
                        Button {
                            playEntry(entry)
                        } label: {
                            RecentItemRow(entry: entry, serviceName: playHistoryManager.sourceServiceName(for: entry))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let group = group {
                                Button(L10n.playNow) { playEntry(entry) }
                                Button(L10n.addToQueue) {
                                    guard let uri = entry.sourceURI, !uri.isEmpty else { return }
                                    Task {
                                        // Pass full metadata + a constructed DIDL so the
                                        // queue row actually shows title/artist/album and
                                        // doesn't render as a blank entry. Without DIDL,
                                        // Sonos accepts the URI (the track plays) but
                                        // Browse(Q:0) returns an empty title for the row.
                                        let item = BrowseItem(
                                            id: "history",
                                            title: entry.title,
                                            artist: entry.artist,
                                            album: entry.album,
                                            albumArtURI: entry.albumArtURI,
                                            itemClass: .musicTrack,
                                            resourceURI: uri,
                                            resourceMetadata: Self.buildHistoryDIDL(
                                                uri: uri,
                                                title: entry.title,
                                                artist: entry.artist,
                                                album: entry.album,
                                                albumArtURI: entry.albumArtURI
                                            )
                                        )
                                        try? await sonosManager.addBrowseItemToQueue(item, in: group)
                                    }
                                }
                                .disabled(entry.sourceURI == nil || entry.sourceURI?.isEmpty == true)
                            }
                        }
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let error = playError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    @State private var playError: String?

    /// Builds a minimal but display-correct DIDL-Lite envelope for a
    /// history entry being re-added to the queue. The leading `1` in
    /// the item ID is the Sonos container-hint flag (matches what
    /// `buildSMAPIDIDL` uses for service tracks); the cdudn token uses
    /// the inferred service serial number from the URI's `sid=` query
    /// param so the speaker can authenticate the track on advance.
    /// Without this, Sonos accepts the URI but stores blank metadata
    /// against the queue position → row renders empty.
    private static func buildHistoryDIDL(uri: String,
                                         title: String,
                                         artist: String,
                                         album: String,
                                         albumArtURI: String?) -> String {
        let serviceType = inferServiceType(from: uri)
        var artElement = ""
        if let art = albumArtURI, !art.isEmpty {
            artElement = "<upnp:albumArtURI>\(xmlEscape(art))</upnp:albumArtURI>"
        }
        let cdudn = "SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token"
        // Use a generic ID — Sonos doesn't validate it against any
        // catalogue when the URI alone resolves, but it must be present.
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="10032020history" parentID="" restricted="true"><dc:title>\(xmlEscape(title))</dc:title><dc:creator>\(xmlEscape(artist))</dc:creator><upnp:album>\(xmlEscape(album))</upnp:album>\(artElement)<upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(cdudn)</desc></item></DIDL-Lite>
        """
    }

    /// Pulls `sid=<n>` out of the URI's query string and converts to the
    /// Sonos RINCON service-type integer (`(sid << 8) + 7`). Falls back
    /// to a generic value when the URI doesn't look like a service URI.
    private static func inferServiceType(from uri: String) -> Int {
        guard let sidRange = uri.range(of: "sid=") else { return 65031 } // default
        let after = uri[sidRange.upperBound...]
        let digits = after.prefix { $0.isNumber }
        guard !digits.isEmpty, let sid = Int(digits) else { return 65031 }
        return (sid << 8) + 7
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func playEntry(_ entry: PlayHistoryEntry) {
        guard let group = group,
              let uri = entry.sourceURI, !uri.isEmpty else { return }
        playError = nil
        Task {
            do {
                try await sonosManager.playURI(
                    group: group,
                    uri: uri,
                    title: entry.stationName.isEmpty ? entry.title : entry.stationName,
                    artist: entry.stationName.isEmpty ? entry.artist : "",
                    stationName: entry.stationName,
                    albumArtURI: entry.albumArtURI
                )
            } catch {
                sonosDebugLog("[RECENT] Play failed: \(error.localizedDescription) uri=\(uri.prefix(80))")
                let appErr = (error as? SOAPError).map(AppError.from) ?? .unknown(error); playError = appErr.errorDescription
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.defaultGracePeriod) { playError = nil }
            }
        }
    }
}

private struct RecentItemRow: View {
    let entry: PlayHistoryEntry
    let serviceName: String

    private var isStation: Bool { !entry.stationName.isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: entry.albumArtURI.flatMap { URL(string: $0) })
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isStation ? entry.stationName : entry.title)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !isStation && !entry.artist.isEmpty {
                        Text(entry.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(serviceName)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ServiceColor.color(for: serviceName), in: Capsule())
                }
            }

            Spacer()

            Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
