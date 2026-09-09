import Foundation

/// The transport commands the speaker currently accepts, as reported by
/// `AVTransport:1` — either the `GetCurrentTransportActions` action or the
/// `CurrentTransportActions` variable inside a `LastChange` event.
///
/// This is the authoritative answer to "may I skip?". Guessing it from the
/// URI scheme is wrong for service radio: an Amazon Music station arrives as
/// `x-sonosapi-radio:` with a station name, which looks exactly like a
/// non-skippable TuneIn stream, yet the speaker reports
/// `Set, Stop, Pause, Play, Next` — Amazon allows a limited number of skips
/// per station. A real TuneIn
/// stream reports no `Next` at all, so the same check covers both.
///
/// Only the *group coordinator* answers meaningfully; group members whose
/// `CurrentURI` is `x-rincon:` report an empty action list.
public struct TransportActions: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let set = TransportActions(rawValue: 1 << 0)
    public static let play = TransportActions(rawValue: 1 << 1)
    public static let pause = TransportActions(rawValue: 1 << 2)
    public static let stop = TransportActions(rawValue: 1 << 3)
    public static let next = TransportActions(rawValue: 1 << 4)
    public static let previous = TransportActions(rawValue: 1 << 5)
    public static let seek = TransportActions(rawValue: 1 << 6)
    public static let xDVDMenu = TransportActions(rawValue: 1 << 7)

    private static let byName: [String: TransportActions] = [
        "set": .set, "play": .play, "pause": .pause, "stop": .stop,
        "next": .next, "previous": .previous, "seek": .seek,
        "x_dlna_seektime": .seek, "x_dvd_menu": .xDVDMenu
    ]

    /// Parses the comma-separated list Sonos returns, e.g.
    /// `"Set, Stop, Pause, Play, Next"`. Unknown names are ignored.
    /// Returns nil for an empty/absent list so callers can tell
    /// "the speaker says nothing is allowed" (a group member, or a
    /// speaker with nothing loaded) apart from "not yet queried".
    public static func parse(_ raw: String) -> TransportActions? {
        let names = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return names.reduce(into: TransportActions()) { result, name in
            if let action = byName[name] { result.insert(action) }
        }
    }

    public var canSkipNext: Bool { contains(.next) }
    public var canSkipPrevious: Bool { contains(.previous) }
}
