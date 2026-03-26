/// QueueViewModel.swift — Business logic for the Queue view.
import SwiftUI
import SonosKit

@MainActor
final class QueueViewModel: ObservableObject {
    let sonosManager: SonosManager
    let group: SonosGroup

    @Published var queueItems: [QueueItem] = []
    @Published var currentTrack: Int = 0
    @Published var totalTracks: Int = 0
    @Published var isLoading = true
    @Published var saveMessage: String?

    /// True when the speaker is playing a radio/stream, not the queue
    var isPlayingStation: Bool {
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID]
        if let stationName = meta?.stationName, !stationName.isEmpty { return true }
        if let uri = meta?.trackURI, URIPrefix.isRadio(uri) { return true }
        return false
    }

    init(sonosManager: SonosManager, group: SonosGroup) {
        self.sonosManager = sonosManager
        self.group = group
    }

    /// Updates current track number from transport metadata
    func updateCurrentTrack() {
        let meta = sonosManager.groupTrackMetadata[group.coordinatorID]
        if let trackNum = meta?.trackNumber, trackNum > 0, trackNum != currentTrack {
            currentTrack = trackNum
        }
    }

    func loadQueue() async {
        isLoading = true
        do {
            let (items, total) = try await sonosManager.getQueue(group: group)
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
        do {
            try await sonosManager.playTrackFromQueue(group: group, trackNumber: trackNumber)
            currentTrack = trackNumber
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUE", userFacing: true)
        }
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
            try await sonosManager.addBrowseItemToQueue(item, in: group, atPosition: atPosition)
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
