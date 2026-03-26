import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct QueueView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup

    @State private var queueItems: [QueueItem] = []
    @State private var currentTrack: Int = 0
    @State private var totalTracks: Int = 0
    @State private var isLoading = true
    @State private var dropTargetIndex: Int?
    @State private var showSavePlaylist = false
    @State private var newPlaylistName = ""
    @State private var saveMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.queue)
                    .font(.headline)
                Spacer()
                Text("\(totalTracks) \(L10n.tracks)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showSavePlaylist = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip("Save as Playlist")
                .disabled(queueItems.isEmpty)

                Button {
                    Task { await clearQueue() }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip(L10n.clearQueue)
                .disabled(queueItems.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxHeight: .infinity)
            } else if queueItems.isEmpty {
                VStack(spacing: 8) {
                    Text(L10n.queueIsEmpty)
                        .foregroundStyle(.secondary)
                    Text("Drag tracks here to add")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    guard let item = sonosManager.draggedBrowseItem else { return false }
                    sonosManager.draggedBrowseItem = nil
                    Task {
                        try? await sonosManager.addBrowseItemToQueue(item, in: group)
                        await loadQueue()
                    }
                    return true
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(queueItems.enumerated()), id: \.element.id) { index, item in
                            VStack(spacing: 0) {
                                // Drop indicator above this item
                                if dropTargetIndex == index {
                                    Rectangle()
                                        .fill(Color.accentColor)
                                        .frame(height: 2)
                                        .padding(.horizontal, 12)
                                }

                                QueueItemRow(item: item, isCurrentTrack: item.id == currentTrack)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        Task { await playTrack(item.id) }
                                    }
                                    .contextMenu {
                                        Button(L10n.play) { Task { await playTrack(item.id) } }
                                        Divider()
                                        Button(L10n.removeFromQueue) { Task { await removeTrack(item.id) } }
                                    }
                                    .onDrag {
                                        NSItemProvider(object: "\(item.id)" as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: QueueDropDelegate(
                                        targetIndex: index,
                                        queueItems: queueItems,
                                        dropTargetIndex: $dropTargetIndex,
                                        sonosManager: sonosManager,
                                        group: group,
                                        reloadQueue: { await loadQueue() }
                                    ))

                                Divider().padding(.leading, 60)
                            }
                        }

                        // Drop zone at bottom of queue
                        Rectangle()
                            .fill(dropTargetIndex == queueItems.count ? Color.accentColor.opacity(0.3) : Color.clear)
                            .frame(height: 30)
                            .onDrop(of: [.text], delegate: QueueDropDelegate(
                                targetIndex: queueItems.count,
                                queueItems: queueItems,
                                dropTargetIndex: $dropTargetIndex,
                                sonosManager: sonosManager,
                                group: group,
                                reloadQueue: { await loadQueue() }
                            ))
                    }
                }
            }
        }
        .onAppear { Task { await loadQueue() } }
        .onChange(of: group.id) { Task { await loadQueue() } }
        .alert("Save as Playlist", isPresented: $showSavePlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Save") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                newPlaylistName = ""
                Task {
                    do {
                        _ = try await sonosManager.saveQueueAsPlaylist(group: group, title: name)
                        saveMessage = "Saved as \"\(name)\""
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveMessage = nil }
                    } catch {
                        sonosDebugLog("[QUEUE] Save as playlist failed: \(error)")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = saveMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.8), in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
            sonosDebugLog("[QUEUE] Load queue failed: \(error)")
        }
        isLoading = false
    }

    private func playTrack(_ trackNumber: Int) async {
        do {
            try await sonosManager.playTrackFromQueue(group: group, trackNumber: trackNumber)
            currentTrack = trackNumber
        } catch {
            sonosDebugLog("[QUEUE] Play track failed: \(error)")
        }
    }

    private func removeTrack(_ trackIndex: Int) async {
        do {
            try await sonosManager.removeFromQueue(group: group, trackIndex: trackIndex)
            await loadQueue()
        } catch {
            sonosDebugLog("[QUEUE] Remove track failed: \(error)")
        }
    }

    private func clearQueue() async {
        do {
            try await sonosManager.clearQueue(group: group)
            queueItems = []
            totalTracks = 0
        } catch {
            sonosDebugLog("[QUEUE] Clear queue failed: \(error)")
        }
    }
}

// MARK: - Drop Delegate

struct QueueDropDelegate: DropDelegate {
    let targetIndex: Int
    let queueItems: [QueueItem]
    @Binding var dropTargetIndex: Int?
    let sonosManager: SonosManager
    let group: SonosGroup
    let reloadQueue: () async -> Void

    func dropEntered(info: DropInfo) {
        dropTargetIndex = targetIndex
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetIndex = nil

        // Check for browse item drag (cross-view)
        if let browseItem = sonosManager.draggedBrowseItem {
            sonosManager.draggedBrowseItem = nil
            // 1-based insert position, 0 = append to end
            let insertAt = targetIndex < queueItems.count ? queueItems[targetIndex].id : 0
            Task { @MainActor in
                try? await sonosManager.addBrowseItemToQueue(browseItem, in: group, atPosition: insertAt)
                await reloadQueue()
            }
            return true
        }

        // Queue internal reorder
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let str = object as? String, let fromTrack = Int(str) else { return }
            let insertBefore: Int
            if targetIndex < queueItems.count {
                insertBefore = queueItems[targetIndex].id
            } else {
                insertBefore = (queueItems.last?.id ?? 0) + 1
            }
            guard fromTrack != insertBefore else { return }
            Task { @MainActor in
                try? await sonosManager.moveTrackInQueue(group: group, from: fromTrack, to: insertBefore)
                await reloadQueue()
            }
        }
        return true
    }
}

// MARK: - Queue Item Row

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
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(isCurrentTrack ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}
