import SwiftUI
import SonosKit

struct QueueView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup

    @State private var queueItems: [QueueItem] = []
    @State private var currentTrack: Int = 0
    @State private var totalTracks: Int = 0
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                Text("\(totalTracks) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await clearQueue() }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Clear queue")
                .disabled(queueItems.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxHeight: .infinity)
            } else if queueItems.isEmpty {
                Text("Queue is empty")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(queueItems) { item in
                        QueueItemRow(item: item, isCurrentTrack: item.id == currentTrack)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await playTrack(item.id) }
                            }
                            .contextMenu {
                                Button("Play") { Task { await playTrack(item.id) } }
                                Divider()
                                Button("Remove from Queue") { Task { await removeTrack(item.id) } }
                            }
                    }
                    .onMove { from, to in
                        Task { await moveTrack(from: from, to: to) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { Task { await loadQueue() } }
        .onChange(of: group.id) { Task { await loadQueue() } }
    }

    private func loadQueue() async {
        isLoading = true
        do {
            let (items, total) = try await sonosManager.getQueue(group: group)
            queueItems = items
            totalTracks = total
            let posInfo = try await sonosManager.getPositionInfo(group: group)
            currentTrack = posInfo.trackNumber
        } catch {
            print("Failed to load queue: \(error)")
        }
        isLoading = false
    }

    private func playTrack(_ trackNumber: Int) async {
        do {
            try await sonosManager.playTrackFromQueue(group: group, trackNumber: trackNumber)
            currentTrack = trackNumber
        } catch {
            print("Failed to play track: \(error)")
        }
    }

    private func removeTrack(_ trackIndex: Int) async {
        do {
            try await sonosManager.removeFromQueue(group: group, trackIndex: trackIndex)
            await loadQueue()
        } catch {
            print("Failed to remove track: \(error)")
        }
    }

    private func clearQueue() async {
        do {
            try await sonosManager.clearQueue(group: group)
            queueItems = []
            totalTracks = 0
        } catch {
            print("Failed to clear queue: \(error)")
        }
    }

    private func moveTrack(from source: IndexSet, to destination: Int) async {
        guard let sourceIndex = source.first else { return }
        let fromTrack = queueItems[sourceIndex].id
        let toTrack = destination < sourceIndex ? queueItems[destination].id : queueItems[min(destination, queueItems.count - 1)].id
        do {
            try await sonosManager.moveTrackInQueue(group: group, from: fromTrack, to: toTrack)
            await loadQueue()
        } catch {
            print("Failed to move track: \(error)")
        }
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let isCurrentTrack: Bool

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: item.albumArtURI.flatMap { URL(string: $0) })
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .fontWeight(isCurrentTrack ? .semibold : .regular)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.duration)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrentTrack ? Color.accentColor.opacity(0.1) : Color.clear)
    }

}
