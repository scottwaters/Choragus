/// LastFMScrobbler.swift — Concrete ScrobbleService for Last.fm.
///
/// Orchestrates the LastFMClient + LastFMTokenStore on behalf of
/// ScrobbleManager. Owns the Last.fm-specific auth flow (browser
/// hand-off → poll `auth.getSession`) and maps `LastFMClient.scrobble`
/// results into the generic `ScrobbleResult` surface.
import Foundation
import AppKit

@MainActor
public final class LastFMScrobbler: ObservableObject, ScrobbleService {
    public let serviceID = "lastfm"
    public let displayName = "Last.fm"

    @Published public private(set) var isConnected: Bool
    @Published public private(set) var connectedUsername: String?

    public let tokenStore: LastFMTokenStore
    private let client: LastFMClient

    public init(tokenStore: LastFMTokenStore? = nil) {
        let store = tokenStore ?? LastFMTokenStore()
        self.tokenStore = store
        self.client = LastFMClient(tokenStore: store)
        self.isConnected = store.hasSession
        self.connectedUsername = store.username
    }

    /// Quick test of the user-supplied API credentials. Attempts an
    /// unauthenticated `auth.getToken` — a successful response proves the
    /// API key + shared secret are valid. Throws on any failure so the
    /// Settings UI can surface the Last.fm error message.
    public func testCredentials() async throws {
        _ = try await client.getAuthToken()
    }

    // MARK: - ScrobbleService

    public func connect() async throws {
        let token = try await client.getAuthToken()
        guard let url = client.authorizeURL(token: token) else {
            throw LastFMError.invalidURL
        }
        NSWorkspace.shared.open(url)

        // Poll auth.getSession until the user approves in the browser.
        // Cadence and timeout are centralized in `Timing` so they're
        // discoverable alongside other app-wide timers.
        let start = Date()
        while Date().timeIntervalSince(start) < Timing.lastFMAuthTimeout {
            try? await Task.sleep(nanoseconds: Timing.lastFMAuthPollInterval)
            if let result = try await client.pollForSession(token: token) {
                tokenStore.sessionKey = result.sessionKey
                tokenStore.username = result.username
                isConnected = true
                connectedUsername = result.username
                sonosDebugLog("[LASTFM] Connected as \(result.username)")
                return
            }
        }
        throw LastFMError.service(14, "Authorization timed out. Please try Connect again.")
    }

    public func disconnect() {
        tokenStore.clearSession()
        isConnected = false
        connectedUsername = nil
        sonosDebugLog("[LASTFM] Disconnected")
    }

    public func scrobble(_ entries: [PlayHistoryEntry]) async throws -> [ScrobbleResult] {
        guard !entries.isEmpty else { return [] }
        guard tokenStore.hasSession else { throw LastFMError.missingSession }

        var results: [ScrobbleResult] = []
        // Chunk by Last.fm's 50-per-call cap.
        for chunkStart in stride(from: 0, to: entries.count, by: LastFMClient.maxBatchSize) {
            let chunk = Array(entries[chunkStart..<min(chunkStart + LastFMClient.maxBatchSize, entries.count)])
            let payloads = chunk.map { e in
                LastFMScrobblePayload(
                    artist: e.artist,
                    title: e.title,
                    album: e.album,
                    timestamp: e.timestamp,
                    duration: e.duration
                )
            }
            do {
                let acks = try await client.scrobble(payloads)
                // Pair entries with their acks in order. If Last.fm returns
                // fewer acks than submitted, the missing ones are treated
                // as retryable failures.
                for (i, entry) in chunk.enumerated() {
                    if i < acks.count {
                        let ack = acks[i]
                        if ack.accepted {
                            results.append(.accepted(historyID: entry.id))
                        } else {
                            // Ignored: timestamp-out-of-window (1), artist-invalid (2),
                            // track-invalid (3), daily-limit (4), etc. Non-retryable.
                            results.append(.ignored(
                                historyID: entry.id,
                                reason: "Last.fm ignored (\(ack.ignoredCode)): \(ack.ignoredMessage)"
                            ))
                        }
                    } else {
                        results.append(.failed(historyID: entry.id, error: "no ack from service"))
                    }
                }
            } catch let error as LastFMError {
                // Whole-batch failure — record every entry as retryable-failed
                // (or ignored if the error is non-retryable).
                let reason = error.errorDescription ?? "Last.fm error"
                sonosDebugLog("[LASTFM] Scrobble batch failed: \(reason)")
                for entry in chunk {
                    if error.isRetryable {
                        results.append(.failed(historyID: entry.id, error: reason))
                    } else {
                        results.append(.ignored(historyID: entry.id, reason: reason))
                    }
                }
            } catch {
                sonosDebugLog("[LASTFM] Scrobble batch failed (unknown): \(error)")
                for entry in chunk {
                    results.append(.failed(historyID: entry.id, error: error.localizedDescription))
                }
            }
        }
        return results
    }
}
