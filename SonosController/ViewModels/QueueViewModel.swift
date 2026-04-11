/// QueueViewModel.swift — Business logic for the Queue view.
import SwiftUI
import SonosKit

@MainActor
final class QueueViewModel: ObservableObject {
    var sonosManager: any QueueServices
    let group: SonosGroup

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

        // Always try title+artist match first — works for both shuffle and sequential
        if let title = meta?.title, !title.isEmpty, !queueItems.isEmpty {
            let artist = meta?.artist ?? ""
            if let match = queueItems.first(where: { $0.title == title && $0.artist == artist }) {
                if match.id != currentTrack {
                    sonosDebugLog("[QUEUE] Title+artist match: '\(title)' -> queue pos \(match.id)")
                    currentTrack = match.id
                }
                return
            }
            if let match = queueItems.first(where: { $0.title == title }) {
                if match.id != currentTrack {
                    sonosDebugLog("[QUEUE] Title-only match: '\(title)' -> queue pos \(match.id)")
                    currentTrack = match.id
                }
                return
            }
        }

        // Fallback: use track number (1-based queue position from GetPositionInfo)
        if let trackNum = meta?.trackNumber, trackNum > 0 {
            if trackNum != currentTrack {
                sonosDebugLog("[QUEUE] TrackNumber fallback: \(trackNum)")
                currentTrack = trackNum
            }
        }
    }

    func loadQueue() async {
        // Only show loading spinner on first load — reloads keep current items visible
        let isFirstLoad = queueItems.isEmpty && isLoading
        if isFirstLoad { isLoading = true }
        do {
            let (items, total) = try await sonosManager.getQueue(group: group, start: 0, count: 100)
            queueItems = items
            totalTracks = total
            let posInfo = try await sonosManager.getPositionInfo(group: group)
            currentTrack = posInfo.trackNumber
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE")
        }
        isLoading = false
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

    func clearQueue() async {
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
