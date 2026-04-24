/// LastFMTokenStore.swift — Typed accessors for Last.fm credentials.
///
/// As of v3.6 the underlying storage is `SecretsStore`, a single keychain
/// item shared by every credential the app needs. This type is a thin
/// facade that exposes the four Last.fm-specific slots (API key + shared
/// secret from the user's own API app, plus per-session fields from the
/// browser auth flow) under stable key names.
import Foundation

@MainActor
public final class LastFMTokenStore {
    private let secrets: SecretsStore

    private enum Key {
        static let apiKey = "lastfm.apiKey"
        static let sharedSecret = "lastfm.sharedSecret"
        static let sessionKey = "lastfm.sessionKey"
        static let username = "lastfm.username"
    }

    public init(secrets: SecretsStore = .shared) {
        self.secrets = secrets
    }

    // MARK: - Credentials (BYO API app)

    public var apiKey: String? {
        get { secrets.get(Key.apiKey) }
        set { secrets.set(Key.apiKey, newValue) }
    }

    public var sharedSecret: String? {
        get { secrets.get(Key.sharedSecret) }
        set { secrets.set(Key.sharedSecret, newValue) }
    }

    public var hasCredentials: Bool {
        guard let k = apiKey, !k.isEmpty else { return false }
        guard let s = sharedSecret, !s.isEmpty else { return false }
        return true
    }

    // MARK: - Session (per-user)

    public var sessionKey: String? {
        get { secrets.get(Key.sessionKey) }
        set { secrets.set(Key.sessionKey, newValue) }
    }

    public var username: String? {
        get { secrets.get(Key.username) }
        set { secrets.set(Key.username, newValue) }
    }

    public var hasSession: Bool {
        guard let s = sessionKey, !s.isEmpty else { return false }
        return true
    }

    public func clearSession() {
        sessionKey = nil
        username = nil
    }

    public func clearAll() {
        apiKey = nil
        sharedSecret = nil
        clearSession()
    }
}
