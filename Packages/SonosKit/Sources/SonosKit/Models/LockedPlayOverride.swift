/// LockedPlayOverride.swift — Decides when a refused play key should be honoured.
///
/// Choragus ignores media-key play commands while the Mac's screen is locked:
/// a Bluetooth headset or USB call headset emits a play command when its audio
/// session ends, and macOS routes it to whichever app last published Now
/// Playing info, so music starts in an empty house.
///
/// The guard yields to a person: repeated presses are not a stray device
/// event. N presses inside a rolling window grant exactly one play. Presses
/// closer together than the minimum gap are one device event burst folded
/// into the press before them. Granting clears the tally so a trailing
/// duplicate cannot reuse the grant.
import Foundation

public struct LockedPlayOverride: Equatable {

    /// Presses required inside `window` before one play is allowed through.
    public let requiredPresses: Int
    /// Rolling window presses are counted within.
    public let window: TimeInterval
    /// Presses closer than this are treated as one device event burst.
    public let minimumGap: TimeInterval

    private var presses: [Date] = []
    /// The last event seen, counted or folded. Folding against the last
    /// event rather than the last *counted* press means a continuous device
    /// stream never accumulates toward a grant.
    private var lastSeen: Date?

    public init(requiredPresses: Int = 3,
                window: TimeInterval = 5,
                minimumGap: TimeInterval = 0.3) {
        self.requiredPresses = requiredPresses
        self.window = window
        self.minimumGap = minimumGap
    }

    /// Records a refused play press and reports whether this one should be
    /// honoured. Returns true at most once per satisfied burst.
    public mutating func registerRefusedPress(at now: Date = Date()) -> Bool {
        // `window` is read into a local first: reading it from `self` inside
        // the closure overlaps the exclusive access `removeAll` holds on
        // `presses`, which Swift 6 rejects.
        let cutoff = window
        presses.removeAll { now.timeIntervalSince($0) > cutoff }

        let previous = lastSeen
        lastSeen = now
        if let previous, now.timeIntervalSince(previous) < minimumGap {
            return false
        }
        presses.append(now)

        guard presses.count >= requiredPresses else { return false }
        presses.removeAll()
        return true
    }

    /// Clears the tally. Called on lock, unlock, and when media keys are
    /// turned off, so a burst cannot span two sessions.
    public mutating func reset() {
        presses.removeAll()
        lastSeen = nil
    }

    /// Presses currently counted toward the next grant. Diagnostics only.
    public var pendingPresses: Int { presses.count }
}
