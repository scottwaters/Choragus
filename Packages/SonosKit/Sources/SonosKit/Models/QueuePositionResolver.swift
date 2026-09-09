/// QueuePositionResolver.swift — Decides which queue row is playing.
///
/// The rule, in priority order:
///   1. The speaker's `Track` field from `GetPositionInfo` is authoritative
///      whenever it names a row that exists.
///   2. A URI already resolved authoritatively is never re-litigated by a
///      title match, which can only disagree with it.
///   3. Title matching is a fallback for the window where the speaker has not
///      yet reported a position, and it refuses ambiguous matches rather than
///      taking the first — picking one of several identically titled rows
///      moves the highlight to the wrong track and fights rule 1.
import Foundation

public enum QueuePositionResolver {

    /// What the speaker reported about the currently playing track.
    public struct Report: Equatable {
        public let trackNumber: Int?
        public let trackURI: String?
        public let title: String?
        public let artist: String?

        public init(trackNumber: Int? = nil, trackURI: String? = nil,
                    title: String? = nil, artist: String? = nil) {
            self.trackNumber = trackNumber
            self.trackURI = trackURI
            self.title = title
            self.artist = artist
        }
    }

    /// Why a resolution landed where it did. Carried so the caller can log
    /// it and tests can assert on the path taken.
    public enum Basis: Equatable {
        case trackNumber
        case titleAndArtist
        case titleOnly
        /// The speaker named a position that is not in the loaded queue —
        /// paging lag, or a queue mutation the view has not caught up with.
        case trackNumberBeyondQueue
    }

    public enum Resolution: Equatable {
        /// Move the highlight to this 1-based position.
        case position(Int, basis: Basis)
        /// Keep the current position.
        case hold(HoldReason)
    }

    public enum HoldReason: Equatable {
        /// Not playing from the queue at all.
        case notPlayingFromQueue
        /// The speaker's URI already has a confirmed position.
        case alreadyAuthoritative
        /// Several rows match the reported title; guessing would be worse
        /// than staying put.
        case ambiguousTitle(matches: Int)
        /// Nothing in the report identifies a row.
        case noSignal
    }

    /// Resolves the playing row.
    ///
    /// - Parameters:
    ///   - report: what the speaker last reported.
    ///   - queue: the loaded queue rows, whose `id` is the 1-based position.
    ///   - playingFromQueue: false when the source is radio, a line-in, or a
    ///     direct URI, in which case no row is playing.
    ///   - authoritativelyResolvedURI: the URI whose position rule 1 already
    ///     confirmed, if any.
    public static func resolve(report: Report,
                               queue: [QueueItem],
                               playingFromQueue: Bool,
                               authoritativelyResolvedURI: String?) -> Resolution {
        guard playingFromQueue else { return .hold(.notPlayingFromQueue) }

        // 1. The speaker's own position, when it names a loaded row.
        if let number = report.trackNumber, number > 0,
           queue.contains(where: { $0.id == number }) {
            return .position(number, basis: .trackNumber)
        }

        // 2. A URI with a confirmed position is not re-litigated.
        if let uri = report.trackURI, uri == authoritativelyResolvedURI {
            return .hold(.alreadyAuthoritative)
        }

        // 3. Title fallback, unique matches only.
        if let title = report.title, !title.isEmpty, !queue.isEmpty {
            let artist = report.artist ?? ""
            let byTitleAndArtist = queue.filter { $0.title == title && $0.artist == artist }
            if byTitleAndArtist.count == 1, let match = byTitleAndArtist.first {
                return .position(match.id, basis: .titleAndArtist)
            }
            let byTitle = queue.filter { $0.title == title }
            if byTitle.count == 1, let match = byTitle.first {
                return .position(match.id, basis: .titleOnly)
            }
            let matches = max(byTitleAndArtist.count, byTitle.count)
            if matches > 1 { return .hold(.ambiguousTitle(matches: matches)) }
        }

        // 4. A position the loaded queue does not contain is still better than
        //    nothing: the queue is mid-page or mid-mutation, and the speaker
        //    is the one playing the track.
        if let number = report.trackNumber, number > 0 {
            return .position(number, basis: .trackNumberBeyondQueue)
        }

        return .hold(.noSignal)
    }

    /// True when this resolution should be recorded as the authoritative
    /// position for the reported URI, closing the door on later title matches.
    public static func confirmsAuthority(_ resolution: Resolution) -> Bool {
        if case .position(_, basis: .trackNumber) = resolution { return true }
        return false
    }
}
