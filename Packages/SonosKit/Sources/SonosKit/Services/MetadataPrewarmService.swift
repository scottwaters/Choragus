/// Hydrates lyrics + artist/album caches in the background for every
/// track that begins playing in any group, so reads are always cache
/// hits regardless of which UI surface (panel, karaoke window, none)
/// is observing.
import Combine
import Foundation

@MainActor
public final class MetadataPrewarmService: ObservableObject {
    private let lyricsService: LyricsService
    private let metadataService: MusicMetadataService
    private var trackCancellable: AnyCancellable?

    private var lastKeyByGroup: [String: String] = [:]
    private var seenKeys: Set<String> = []

    public init(lyricsService: LyricsService, metadataService: MusicMetadataService) {
        self.lyricsService = lyricsService
        self.metadataService = metadataService
    }

    public func attach(to manager: SonosManager) {
        trackCancellable?.cancel()
        trackCancellable = manager.groupTrackMetadataPublisher
            .removeDuplicates()
            .sink { [weak self] map in
                self?.handle(map)
            }
    }

    private func handle(_ map: [String: TrackMetadata]) {
        for (groupID, metadata) in map {
            guard !metadata.title.isEmpty else { continue }
            if metadata.isAdBreak { continue }
            if metadata.title == "TV" || metadata.title == "Line-In" { continue }

            let key = metadata.stableKey
            if lastKeyByGroup[groupID] == key { continue }
            lastKeyByGroup[groupID] = key

            guard seenKeys.insert(key).inserted else { continue }

            prewarm(metadata)
        }
    }

    private func prewarm(_ metadata: TrackMetadata) {
        let title = metadata.title
        let artist = metadata.artist
        let album = metadata.album
        let duration = metadata.duration > 0 ? Int(metadata.duration) : nil
        let lyricsRef = lyricsService
        let metaRef = metadataService

        Task {
            _ = await lyricsRef.fetch(
                artist: artist, title: title,
                album: album.isEmpty ? nil : album,
                durationSeconds: duration
            )
        }

        Task {
            _ = await metaRef.artistInfo(name: artist)
            if !album.isEmpty {
                _ = await metaRef.albumInfo(artist: artist, album: album)
            }
        }
    }
}
