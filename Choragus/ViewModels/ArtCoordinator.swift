/// Per-group `ArtResolver` registry + driver. Single resolver per
/// `coordinatorID`, driven from `SonosManager.$groupTrackMetadata`
/// so resolvers run for groups with no mounted view (e.g.
/// `ClubVisWindow`'s locked group while the main view is on a
/// different speaker).
import Foundation
import Combine
import SonosKit

@MainActor
final class ArtCoordinator: ObservableObject {
    private let albumArtSearch: AlbumArtSearchProtocol
    private var playHistoryManager: PlayHistoryManager?
    private var resolvers: [String: ArtResolver] = [:]
    private weak var sonosManager: SonosManager?
    private var metadataCancellable: AnyCancellable?
    /// Composite of URI + title + albumArtURI — URI alone misses
    /// radio-station within-stream track changes.
    private var lastMetadataKeyByGroup: [String: String] = [:]

    init(albumArtSearch: AlbumArtSearchProtocol,
         playHistoryManager: PlayHistoryManager? = nil) {
        self.albumArtSearch = albumArtSearch
        self.playHistoryManager = playHistoryManager
    }

    func attachPlayHistory(_ manager: PlayHistoryManager) {
        playHistoryManager = manager
    }

    func start(sonosManager: SonosManager) {
        self.sonosManager = sonosManager
        metadataCancellable = sonosManager.groupTrackMetadataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] map in
                self?.dispatch(metadataByGroup: map)
            }
    }

    private func dispatch(metadataByGroup map: [String: TrackMetadata]) {
        guard let sonosManager else { return }
        for (coordinatorID, metadata) in map {
            let key = "\(metadata.trackURI ?? "")|\(metadata.title)|\(metadata.albumArtURI ?? "")"
            if lastMetadataKeyByGroup[coordinatorID] == key { continue }
            // Don't commit the key if group lookup misses — lets the next
            // republish retry once topology refresh repopulates.
            guard let group = sonosManager.groups.first(where: { $0.coordinatorID == coordinatorID }) else {
                continue
            }
            lastMetadataKeyByGroup[coordinatorID] = key
            let resolver = resolver(for: coordinatorID)
            resolver.handleMetadataChanged(metadata, group: group, dependencies: sonosManager)
        }
    }

    func resolver(for coordinatorID: String) -> ArtResolver {
        if let existing = resolvers[coordinatorID] {
            return existing
        }
        let resolver = ArtResolver(
            playHistoryManager: playHistoryManager,
            albumArtSearch: albumArtSearch
        )
        resolvers[coordinatorID] = resolver
        return resolver
    }
}

extension SonosManager: ArtResolver.Dependencies {}

@MainActor
final class ArtCoordinatorHolder: ObservableObject {
    private var instance: ArtCoordinator?

    func ensureReady(sonosManager: SonosManager,
                     playHistory: PlayHistoryManager) -> ArtCoordinator {
        if let instance {
            instance.attachPlayHistory(playHistory)
            return instance
        }
        let coordinator = ArtCoordinator(
            albumArtSearch: sonosManager.albumArtSearch,
            playHistoryManager: playHistory
        )
        coordinator.start(sonosManager: sonosManager)
        instance = coordinator
        return coordinator
    }
}
