/// QueueView.swift — Queue panel displaying the current play queue.
///
/// Thin view layer — all business logic lives in QueueViewModel.
/// Supports drag-drop reordering and cross-view drag from browse panel.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct QueueView: View {
    /// External prop — the group currently selected in the sidebar. When the
    /// user switches speakers, SwiftUI passes a new value here and we need
    /// to push it into the view model (which otherwise holds onto the
    /// group captured at StateObject construction) and reload the queue.
    let group: SonosGroup

    @StateObject private var vm: QueueViewModel
    @State private var dropTargetIndex: Int?
    @State private var showSavePlaylist = false
    @State private var newPlaylistName = ""

    @EnvironmentObject private var sonosManager: SonosManager

    init(group: SonosGroup, sonosManager: SonosManager) {
        self.group = group
        _vm = StateObject(wrappedValue: QueueViewModel(sonosManager: sonosManager, group: group))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        // Full-window overlay shown whenever the queue is mid-mutation
        // (a batch add-to-queue or a refresh fetch in flight). The
        // earlier inline header indicator was easy to miss for the
        // long Plex / local-library batch adds where the user is left
        // wondering "is anything happening?". Translucent so the
        // existing queue stays visible underneath as a reassurance
        // that the prior state is still there. Excluded when the
        // queue is empty — that state already has its own dedicated
        // full-screen progress block in `content`.
        .overlay {
            if (vm.isLoading || sonosManager.isAddingToQueue) && !vm.queueItems.isEmpty {
                queueBusyOverlay
            }
        }
        .onAppear { Task { await vm.loadQueue() } }
        .onChange(of: group.id) { _, newID in
            // Propagate the speaker-selection change into the view model,
            // then refresh the queue from the newly-selected coordinator.
            vm.group = group
            vm.queueItems = []
            vm.currentTrack = 0
            Task { await vm.loadQueue() }
            _ = newID
        }
        .onReceive(sonosManager.$groupTrackMetadata) { _ in
            vm.updateCurrentTrack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .queueChanged)) { note in
            // Fast path — the sender told us exactly what was appended. Skips
            // the Browse(Q:0) round-trip, which is expensive on S1 coordinators.
            if let items = note.userInfo?[QueueChangeKey.optimisticItems] as? [QueueItem] {
                sonosDiagLog(.info, tag: "QUEUE",
                             "queueChanged: optimistic append \(items.count) items")
                vm.optimisticallyAppend(items)
            } else {
                sonosDiagLog(.info, tag: "QUEUE",
                             "queueChanged: triggering full reload")
                vm.pendingPostAddRetry = true
                Task { await vm.loadQueue() }
            }
        }
        .alert(L10n.saveAsPlaylist, isPresented: $showSavePlaylist) {
            TextField(L10n.playlistNamePlaceholder, text: $newPlaylistName)
            Button(L10n.cancel, role: .cancel) { newPlaylistName = "" }
            Button(L10n.save) {
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
        HStack(spacing: 6) {
            // Title — lowest priority. Shrinks / truncates first
            // when the panel is narrow.
            Text(L10n.queue)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
                .fixedSize(horizontal: false, vertical: false)
            // The mid-mutation indicator now lives as a full-window
            // overlay (see `queueBusyOverlay`) so it's hard to miss
            // during long Plex / local-library batch adds. The header
            // stays clean.
            Spacer(minLength: 0)
            // Track count is informational — drops out before any
            // button gets clipped.
            ViewThatFits(in: .horizontal) {
                Text("\(vm.totalTracks) \(L10n.tracks)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                EmptyView()
            }
            .layoutPriority(2)
            // Buttons get the HIGHEST layout priority and each is
            // .fixedSize so SwiftUI can't ever shrink them below
            // their natural icon width. Putting them as direct
            // children of the parent HStack (not nested in a Group)
            // ensures the priority is applied per-view.
            Button { Task { await vm.loadQueue() } } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip("Refresh queue")
            .fixedSize()
            .layoutPriority(3)

            Button { Task { await vm.shuffleQueue() } } label: {
                Image(systemName: "shuffle").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip(L10n.shuffleQueueTooltip)
            .disabled(vm.queueItems.count < 2)
            .fixedSize()
            .layoutPriority(3)

            Button { showSavePlaylist = true } label: {
                Image(systemName: "text.badge.plus").font(.caption)
            }
            .buttonStyle(.plain)
            .tooltip(L10n.saveAsPlaylist)
            .disabled(vm.queueItems.isEmpty)
            .fixedSize()
            .layoutPriority(3)

            Button { Task { await vm.clearQueue() } } label: {
                if vm.isClearing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "trash").font(.caption)
                }
            }
            .buttonStyle(.plain)
            .tooltip(L10n.clearQueue)
            .disabled(vm.queueItems.isEmpty || vm.isClearing)
            .fixedSize()
            .layoutPriority(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Translucent full-window overlay shown while a batch add-to-queue
    /// or a queue refresh is in flight. Sits on top of the existing
    /// queue list so the user can still see what's there (reassurance
    /// the prior state is intact) but the spinner makes "work in
    /// progress" unmistakable. The `.allowsHitTesting(false)` means
    /// row interactions still pass through, so the user can scroll /
    /// reorder / delete unrelated rows while the batch lands.
    private var queueBusyOverlay: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).opacity(0.55)
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.4)
                Text(addingStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var addingStatusText: String {
        if sonosManager.isAddingToQueue {
            let n = sonosManager.addingToQueueProgress
            if n > 0 {
                return "Adding \(n) tracks…"
            }
            return L10n.addingToQueueEllipsis
        }
        return L10n.loadingQueueEllipsis
    }

    @ViewBuilder
    private var content: some View {
        if vm.isShuffling {
            // Full-screen spinner during a shuffle (user-initiated, brief).
            VStack(spacing: 8) {
                ProgressView()
                Text(L10n.shufflingEllipsis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else if (vm.isLoading || sonosManager.isAddingToQueue) && vm.queueItems.isEmpty {
            // Full-screen spinner when we have nothing to show — first launch,
            // speaker switch, cleared queue, or an add-to-queue in flight on
            // a currently-empty queue. On a reload where items are already
            // present, the inline header spinner is used instead so the list
            // stays visible.
            VStack(spacing: 8) {
                ProgressView()
                Text(sonosManager.isAddingToQueue ? L10n.addingToQueueEllipsis : L10n.loadingQueueEllipsis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Text(L10n.dragTracksHere)
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

                        QueueItemRow(item: item,
                                     isCurrentTrack: item.id == vm.currentTrack && vm.isPlayingFromQueue,
                                     isPlaying: item.id == vm.currentTrack && vm.isPlayingFromQueue && vm.sonosManager.groupTransportStates[vm.group.coordinatorID]?.isPlaying == true,
                                     isLoading: vm.playingTrack == item.id)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard vm.playingTrack == nil else { return } // Don't queue another play while one is pending
                                Task { await vm.playTrack(item.id) }
                            }
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
            guard vm.currentTrack > 0, vm.isPlayingFromQueue else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(vm.currentTrack, anchor: .center)
            }
        }
        .onChange(of: vm.isShuffling) {
            if !vm.isShuffling, let firstID = vm.queueItems.first?.id {
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(firstID, anchor: .top)
                }
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
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CachedAsyncImage(url: item.albumArtURI.flatMap { URL(string: $0) })
                    .frame(width: 36, height: 36)
                    .opacity(isLoading ? 0.4 : 1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if isPlaying {
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
