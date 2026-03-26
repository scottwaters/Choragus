/// QueueView.swift — Queue panel displaying the current play queue.
///
/// Thin view layer — all business logic lives in QueueViewModel.
/// Supports drag-drop reordering and cross-view drag from browse panel.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct QueueView: View {
    @StateObject private var vm: QueueViewModel
    @State private var dropTargetIndex: Int?
    @State private var showSavePlaylist = false
    @State private var newPlaylistName = ""

    @EnvironmentObject private var sonosManager: SonosManager

    init(group: SonosGroup, sonosManager: SonosManager) {
        _vm = StateObject(wrappedValue: QueueViewModel(sonosManager: sonosManager, group: group))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .onAppear { Task { await vm.loadQueue() } }
        .onChange(of: vm.group.id) { Task { await vm.loadQueue() } }
        .onReceive(sonosManager.$groupTrackMetadata) { _ in
            vm.updateCurrentTrack()
        }
        .alert("Save as Playlist", isPresented: $showSavePlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Save") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                newPlaylistName = ""
                Task { await vm.saveAsPlaylist(name: name) }
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = vm.saveMessage {
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

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            Text(L10n.queue)
                .font(.headline)
            Spacer()
            Text("\(vm.totalTracks) \(L10n.tracks)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { Task { await vm.shuffleQueue() } } label: {
                Image(systemName: "shuffle").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip("Shuffle Queue")
            .disabled(vm.queueItems.count < 2)

            Button { showSavePlaylist = true } label: {
                Image(systemName: "square.and.arrow.down").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip("Save as Playlist")
            .disabled(vm.queueItems.isEmpty)

            Button { Task { await vm.clearQueue() } } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip(L10n.clearQueue)
            .disabled(vm.queueItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            ProgressView()
                .frame(maxHeight: .infinity)
        } else if vm.queueItems.isEmpty {
            emptyState
        } else {
            queueList
        }
    }

    private var emptyState: some View {
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
            handleBrowseDrop(atPosition: 0)
        }
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(vm.queueItems.enumerated()), id: \.element.id) { index, item in
                    VStack(spacing: 0) {
                        if dropTargetIndex == index {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .padding(.horizontal, 12)
                        }

                        QueueItemRow(item: item, isCurrentTrack: item.id == vm.currentTrack && !vm.isPlayingStation,
                                     isPlaying: item.id == vm.currentTrack && !vm.isPlayingStation && vm.sonosManager.groupTransportStates[vm.group.coordinatorID]?.isPlaying == true)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await vm.playTrack(item.id) } }
                            .contextMenu {
                                Button(L10n.play) { Task { await vm.playTrack(item.id) } }
                                Divider()
                                Button(L10n.removeFromQueue) { Task { await vm.removeTrack(item.id) } }
                            }
                            .onDrag { NSItemProvider(object: "\(item.id)" as NSString) }
                            .onDrop(of: [.text], delegate: QueueDropDelegate(
                                targetIndex: index, vm: vm,
                                dropTargetIndex: $dropTargetIndex
                            ))

                        Divider().padding(.leading, 60)
                    }
                }

                Rectangle()
                    .fill(dropTargetIndex == vm.queueItems.count ? Color.accentColor.opacity(0.3) : Color.clear)
                    .frame(height: 30)
                    .onDrop(of: [.text], delegate: QueueDropDelegate(
                        targetIndex: vm.queueItems.count, vm: vm,
                        dropTargetIndex: $dropTargetIndex
                    ))
            }
        }
        .onChange(of: vm.currentTrack) {
            guard vm.currentTrack > 0, !vm.isPlayingStation else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(vm.currentTrack, anchor: .center)
            }
        }
        }
    }

    private func handleBrowseDrop(atPosition: Int) -> Bool {
        guard let item = vm.sonosManager.draggedBrowseItem else { return false }
        vm.sonosManager.draggedBrowseItem = nil
        Task { await vm.addBrowseItem(item, atPosition: atPosition) }
        return true
    }
}

// MARK: - Drop Delegate

struct QueueDropDelegate: DropDelegate {
    let targetIndex: Int
    let vm: QueueViewModel
    @Binding var dropTargetIndex: Int?

    func dropEntered(info: DropInfo) { dropTargetIndex = targetIndex }
    func dropExited(info: DropInfo) { if dropTargetIndex == targetIndex { dropTargetIndex = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetIndex = nil

        // Browse item drag (cross-view)
        if let browseItem = vm.sonosManager.draggedBrowseItem {
            vm.sonosManager.draggedBrowseItem = nil
            let insertAt = targetIndex < vm.queueItems.count ? vm.queueItems[targetIndex].id : 0
            Task { @MainActor in await vm.addBrowseItem(browseItem, atPosition: insertAt) }
            return true
        }

        // Queue internal reorder
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let str = object as? String, let fromTrack = Int(str) else { return }
            let insertBefore: Int
            if targetIndex < vm.queueItems.count {
                insertBefore = vm.queueItems[targetIndex].id
            } else {
                insertBefore = (vm.queueItems.last?.id ?? 0) + 1
            }
            guard fromTrack != insertBefore else { return }
            Task { @MainActor in await vm.moveTrack(from: fromTrack, to: insertBefore) }
        }
        return true
    }
}

// MARK: - Queue Item Row

struct QueueItemRow: View {
    let item: QueueItem
    let isCurrentTrack: Bool
    var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CachedAsyncImage(url: item.albumArtURI.flatMap { URL(string: $0) })
                    .frame(width: 36, height: 36)
                if isPlaying {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.black.opacity(0.4))
                        .frame(width: 36, height: 36)
                    NowPlayingBars()
                        .frame(width: 16, height: 14)
                }
            }

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

// MARK: - Animated Now Playing Bars

private struct NowPlayingBars: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3)
                    .scaleEffect(y: animate ? CGFloat.random(in: 0.3...1.0) : 0.4, anchor: .bottom)
                    .animation(
                        .easeInOut(duration: 0.4 + Double(i) * 0.15)
                        .repeatForever(autoreverses: true),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
