/// QueueViewModel.swift — Business logic for the Queue view.
import SwiftUI
import SonosKit

@MainActor
final class QueueViewModel: ObservableObject {
    var sonosManager: any QueueServices
    /// Mutable so `QueueView` can push a new selected-speaker group into the
    /// view model when the user switches rooms in the sidebar.
    var group: SonosGroup

    @Published var queueItems: [QueueItem] = []
    @Published var currentTrack: Int = 0
    @Published var totalTracks: Int = 0
    @Published var isLoading = true
    @Published var saveMessage: String?
    @Published var playingTrack: Int? // Track currently being started (shows spinner)

    /// Optimistic flag set immediately when user taps a queue track,
    /// before the next poll confirms isQueueSource from the speaker.
    private var userStartedQueuePlayback = false

    /// True when the speaker is playing from the queue.
    var isPlayingFromQueue: Bool {
        if userStartedQueuePlayback { return true }
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID]
        return meta?.isQueueSource == true
    }

    init(sonosManager: any QueueServices, group: SonosGroup) {
        self.sonosManager = sonosManager
        self.group = group
    }

    /// Updates current track number from transport metadata
    func updateCurrentTrack() {
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID]
        // Clear optimistic flag once speaker confirms queue playback
        if meta?.isQueueSource == true {
            userStartedQueuePlayback = false
        }
        let playing = isPlayingFromQueue

        sonosDebugLog("[QUEUE] updateCurrentTrack: title='\(meta?.title ?? "nil")' trackNum=\(meta?.trackNumber ?? -1) station='\(meta?.stationName ?? "")' isQueue=\(playing) isQueueSource=\(meta?.isQueueSource ?? false) uri=\(String(meta?.trackURI?.prefix(40) ?? "nil")) currentTrack=\(currentTrack) queueCount=\(queueItems.count)")

        guard playing else { return }

        // Authoritative source: Sonos's `Track` field from GetPositionInfo
        // is the 1-based queue position currently playing. Title matching
        // can't disambiguate when the queue has multiple tracks with the
        // same title (e.g. several recordings of "Theme From X" on a
        // movie-soundtracks playlist) — title match always returns the
        // FIRST occurrence. Use trackNumber whenever the speaker reports
        // a sane value, fall back to title only when it doesn't.
        if let trackNum = meta?.trackNumber, trackNum > 0,
           queueItems.contains(where: { $0.id == trackNum }) {
            if trackNum != currentTrack {
                sonosDebugLog("[QUEUE] TrackNumber match: \(trackNum)")
                currentTrack = trackNum
            }
            return
        }

        // Fallback: title+artist match (used when trackNumber isn't
        // populated yet — early after a track change, or for service
        // tracks where Sonos sometimes lags on position reporting).
        if let title = meta?.title, !title.isEmpty, !queueItems.isEmpty {
            let artist = meta?.artist ?? ""
            if let match = queueItems.first(where: { $0.title == title && $0.artist == artist }) {
                if match.id != currentTrack {
                    sonosDebugLog("[QUEUE] Title+artist fallback: '\(title)' -> queue pos \(match.id)")
                    currentTrack = match.id
                }
                return
            }
            if let match = queueItems.first(where: { $0.title == title }) {
                if match.id != currentTrack {
                    sonosDebugLog("[QUEUE] Title-only fallback: '\(title)' -> queue pos \(match.id)")
                    currentTrack = match.id
                }
                return
            }
        }

        // Final fallback (kept for absolute safety — should rarely fire
        // because the trackNumber check above already handles this).
        if let trackNum = meta?.trackNumber, trackNum > 0 {
            if trackNum != currentTrack {
                sonosDebugLog("[QUEUE] TrackNumber final fallback: \(trackNum)")
                currentTrack = trackNum
            }
        }
    }

    /// Appends tracks the user just added, without hitting the speaker again.
    /// A real `loadQueue` later will reconcile. Skips items whose id already
    /// exists so a racing real reload doesn't produce duplicates.
    func optimisticallyAppend(_ items: [QueueItem]) {
        let existing = Set(queueItems.map(\.id))
        let fresh = items.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queueItems.append(contentsOf: fresh)
        totalTracks = max(totalTracks, queueItems.map(\.id).max() ?? totalTracks)
    }

    func loadQueue() async {
        // Show the spinner whenever we're actually fetching. Covers first
        // launch, speaker switch (queueItems just got cleared), and the
        // post-add reload after a batch — all cases where the user should
        // see that something is happening rather than a stale or empty list.
        isLoading = true
        defer { isLoading = false }
        do {
            let (items, total) = try await sonosManager.getQueue(group: group, start: 0, count: 100)
            queueItems = items
            totalTracks = total
            let posInfo = try await sonosManager.getPositionInfo(group: group)
            currentTrack = posInfo.trackNumber
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }

    func playTrack(_ trackNumber: Int) async {
        playingTrack = trackNumber
        userStartedQueuePlayback = true
        do {
            try await sonosManager.playTrackFromQueue(group: group, trackNumber: trackNumber)
            currentTrack = trackNumber
        } catch {
            userStartedQueuePlayback = false
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
        playingTrack = nil
    }

    func removeTrack(_ trackIndex: Int) async {
        do {
            try await sonosManager.removeFromQueue(group: group, trackIndex: trackIndex)
            await loadQueue()
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }

    @Published var isClearing = false

    func clearQueue() async {
        isClearing = true
        defer { isClearing = false }
        do {
            try await sonosManager.clearQueue(group: group)
            queueItems = []
            totalTracks = 0
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }

    @Published var isShuffling = false

    /// Shuffles the queue order randomly on the speaker
    func shuffleQueue() async {
        guard queueItems.count > 1 else { return }
        isShuffling = true

        // Fisher-Yates shuffle: move each track to a random position
        for i in stride(from: queueItems.count, through: 2, by: -1) {
            let randomPos = Int.random(in: 1...i)
            if randomPos != i {
                do {
                    try await sonosManager.moveTrackInQueue(group: group, from: i, to: randomPos)
                } catch {
                    ErrorHandler.shared.handle(error, context: "QUEUE")
                    break
                }
            }
        }

        // Reload queue with new order
        do {
            let (items, total) = try await sonosManager.getQueue(group: group, start: 0, count: 100)
            queueItems = items
            totalTracks = total
        } catch {
            sonosDebugLog("[QUEUE] Reload after shuffle failed: \(error)")
        }

        isShuffling = false
    }

    func saveAsPlaylist(name: String) async {
        do {
            _ = try await sonosManager.saveQueueAsPlaylist(group: group, title: name)
            saveMessage = "Saved as \"\(name)\""
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.saveMessage = nil
            }
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
    }

    func addBrowseItem(_ item: BrowseItem, atPosition: Int = 0) async {
        do {
            try await sonosManager.addBrowseItemToQueue(item, in: group, playNext: false, atPosition: atPosition)
            await loadQueue()
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }

    func moveTrack(from: Int, to: Int) async {
        do {
            try await sonosManager.moveTrackInQueue(group: group, from: from, to: to)
            await loadQueue()
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
    }
}
