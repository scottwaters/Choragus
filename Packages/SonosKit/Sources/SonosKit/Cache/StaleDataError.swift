import Foundation

public enum StaleDataError: Error, LocalizedError, Equatable {
    case deviceUnreachable(String) // room name
    case groupChanged(String) // group name
    case topologyStale
    /// Raised when the speaker rejects the URI/metadata we sent (UPnP
    /// 714 "no such resource"). NOT a topology event — bundling it
    /// with `topologyStale` previously led users to think their group
    /// layout was broken when in reality the speaker simply refused
    /// the single-track URI we built (issue #42). The real fix is to
    /// route those plays through the queue path; this case exists so
    /// the user sees an actionable message in the meantime.
    case serviceRejected

    public var errorDescription: String? {
        switch self {
        case .deviceUnreachable(let name):
            return "\(name) is not responding. Your network layout may have changed — refreshing now."
        case .groupChanged(let name):
            return "\(name) group has changed. Refreshing speaker list."
        case .topologyStale:
            return "Speaker layout has changed since last cached. Refreshing now."
        case .serviceRejected:
            return "Speaker rejected request. Please raise bug report."
        }
    }
}
