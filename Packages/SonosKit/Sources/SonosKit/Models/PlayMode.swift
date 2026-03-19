/// PlayMode.swift — Maps Sonos play mode strings to shuffle/repeat state.
///
/// Sonos represents play mode as a single enum with 6 values combining shuffle
/// and repeat dimensions. togglingShuffle() and cyclingRepeat() handle independent
/// toggling by mapping across the 2x3 matrix (shuffle on/off x repeat off/all/one).
import Foundation

public enum PlayMode: String {
    case normal = "NORMAL"
    case repeatAll = "REPEAT_ALL"
    case repeatOne = "REPEAT_ONE"
    case shuffleNoRepeat = "SHUFFLE_NOREPEAT"
    case shuffle = "SHUFFLE"                   // shuffle + repeat all
    case shuffleRepeatOne = "SHUFFLE_REPEAT_ONE"

    public var isShuffled: Bool {
        switch self {
        case .shuffleNoRepeat, .shuffle, .shuffleRepeatOne: return true
        default: return false
        }
    }

    public var repeatMode: RepeatMode {
        switch self {
        case .normal, .shuffleNoRepeat: return .off
        case .repeatAll, .shuffle: return .all
        case .repeatOne, .shuffleRepeatOne: return .one
        }
    }

    /// Flips shuffle on/off while preserving the current repeat setting
    public func togglingShuffle() -> PlayMode {
        switch self {
        case .normal: return .shuffleNoRepeat
        case .repeatAll: return .shuffle
        case .repeatOne: return .shuffleRepeatOne
        case .shuffleNoRepeat: return .normal
        case .shuffle: return .repeatAll
        case .shuffleRepeatOne: return .repeatOne
        }
    }

    /// Cycles repeat: off -> all -> one -> off, preserving shuffle state
    public func cyclingRepeat() -> PlayMode {
        switch repeatMode {
        case .off:
            return isShuffled ? .shuffle : .repeatAll
        case .all:
            return isShuffled ? .shuffleRepeatOne : .repeatOne
        case .one:
            return isShuffled ? .shuffleNoRepeat : .normal
        }
    }
}

public enum RepeatMode {
    case off, all, one
}
