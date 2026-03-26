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
                Text("No recently played tracks")
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
                                        let item = BrowseItem(id: "history", title: entry.title, resourceURI: uri)
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
                playError = "Could not play \"\(entry.stationName.isEmpty ? entry.title : entry.stationName)\": \(error.localizedDescription)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { playError = nil }
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
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ServiceColor.color(for: serviceName), in: Capsule())
                }
            }

            Spacer()

            Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
