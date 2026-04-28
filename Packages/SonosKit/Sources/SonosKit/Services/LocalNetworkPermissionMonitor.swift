/// LocalNetworkPermissionMonitor.swift — Detects macOS Local Network TCC denial.
///
/// macOS 15+ gates outbound traffic to RFC1918 ranges behind the Local
/// Network privacy switch. When denied, every URLSession request to a
/// 192.168.x.x speaker fails with NSURLErrorNotConnectedToInternet (-1009)
/// and the underlying NWPath description "unsatisfied (Local network
/// prohibited)" — which surfaces in the error's stringified description.
///
/// Without explicit detection the user sees an empty speaker list and a
/// silent app: the OS dropped the packets, no error dialog appeared,
/// nothing tells them to flip a switch in System Settings. This monitor
/// observes the error stream from `SOAPClient` and `SMAPIClient`,
/// latches a flag the UI can react to, and exposes a deep link straight
/// to the Privacy → Local Network panel.
import Foundation

@MainActor
public final class LocalNetworkPermissionMonitor: ObservableObject {

    public static let shared = LocalNetworkPermissionMonitor()

    /// True once we've seen at least one error matching the local-network
    /// denial signature. Latches — once set, only `clear()` resets it.
    /// Latching is intentional: a user who fixes the toggle still benefits
    /// from a one-time "now relaunch" reminder, but we don't want the
    /// alert to flap on intermittent Wi-Fi blips after a single bad call.
    @Published public private(set) var isBlocked: Bool = false

    /// True once the user dismissed the alert (either button) this session.
    /// Decoupled from `isBlocked` because polling continues to fail while
    /// the user walks over to System Settings — clearing `isBlocked`
    /// directly would let the next failed call re-trigger the alert seconds
    /// later. The user-facing `shouldShowAlert` is the AND of "blocked"
    /// and "not yet acknowledged"; relaunching the app resets it.
    @Published public private(set) var userAcknowledged: Bool = false

    /// What the UI binds to. Goes false the moment the user dismisses
    /// the alert and stays false for the rest of this app launch, even
    /// though the underlying network failures keep happening.
    public var shouldShowAlert: Bool {
        isBlocked && !userAcknowledged
    }

    /// macOS deep link for System Settings → Privacy & Security → Local
    /// Network. Same scheme as the official Sonos app uses for its
    /// "Open Settings" button.
    public static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    )!

    private init() {}

    /// Inspect any thrown error for the local-network denial signature.
    /// Safe to call from any context (network calls happen off-MainActor).
    nonisolated public func record(_ error: Error) {
        guard Self.isLocalNetworkBlockedError(error) else { return }
        Task { @MainActor in
            if !self.isBlocked {
                self.isBlocked = true
                sonosDebugLog("[LOCAL-NET] Local Network access denied by macOS — surfaced to UI")
            }
        }
    }

    /// Called when the user dismisses the alert. Suppresses re-presentation
    /// for this app launch without resetting `isBlocked` (the underlying
    /// condition is still true).
    public func acknowledge() {
        userAcknowledged = true
    }

    /// Resets both flags. For tests / "I genuinely fixed it, check again".
    public func clear() {
        isBlocked = false
        userAcknowledged = false
    }

    /// Pattern-matches the NSURLError chain for the NWPath description
    /// macOS emits when Local Network is denied. Stringifying the whole
    /// error catches both the top-level `NSURLErrorDomain` and the
    /// nested `kCFErrorDomainCFNetwork` variants without having to
    /// reach into the userInfo dictionary directly (the key
    /// `_NSURLErrorNWPathKey` is private and the value type is
    /// undocumented across OS versions).
    nonisolated public static func isLocalNetworkBlockedError(_ error: Error) -> Bool {
        let description = String(describing: error)
        return description.contains("Local network prohibited")
    }
}
