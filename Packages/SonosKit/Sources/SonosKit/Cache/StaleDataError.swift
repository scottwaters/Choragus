import Foundation

public enum StaleDataError: Error, LocalizedError {
    case deviceUnreachable(String) // room name
    case groupChanged(String) // group name
    case topologyStale

    public var errorDescription: String? {
        switch self {
        case .deviceUnreachable(let name):
            return "\(name) is not responding. Your network layout may have changed — refreshing now."
        case .groupChanged(let name):
            return "\(name) group has changed. Refreshing speaker list."
        case .topologyStale:
            return "Speaker layout has changed since last cached. Refreshing now."
        }
    }
}
