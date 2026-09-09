/// MCPDiagnostics.swift — What support needs to know about the MCP
/// server: settings, tokens (names and scopes, never secrets), lockouts,
/// running builds and the recent request log. Shown in Diagnostics →
/// Agent access and included in the encrypted bug-report bundle.
import Foundation

public struct MCPDiagnosticsPayload: Codable, Sendable {
    public struct Token: Codable, Sendable {
        public let name: String
        public let scope: String
        public let createdAt: String
        public let lastUsedAt: String?
        public let callsSinceLaunch: Int
    }
    public struct Activity: Codable, Sendable {
        public let at: String
        public let client: String
        public let remote: String
        public let action: String
        public let summary: String
        public let outcome: String
        public let milliseconds: Int
        /// Present in bug bundles for the newest calls; trimmed to `bundlePayloadCap`.
        public var request: String?
        public var response: String?
    }
    public static let bundlePayloadCap = 8 * 1024
    public static let bundlePayloadRows = 100
    public struct Build: Codable, Sendable {
        public let jobID: String
        public let name: String
        public let status: String
        public let done: Int
        public let total: Int
        public let matched: Int
        public let queueErrors: Int
        public let elapsedSeconds: Int
    }

    public let enabled: Bool
    public let status: String
    public let port: Int
    public let allowLAN: Bool
    public let preventSleep: Bool
    public let maxVolume: Int
    public let tokens: [Token]
    public let lockedOutAddresses: [String]
    public let failedAuthSinceLaunch: Int
    public let builds: [Build]
    public let activity: [Activity]
}

extension ChoragusMCPServer {
    /// Snapshot for the Diagnostics window and the bug-report bundle.
    /// `activityLimit` bounds the request log; the bundle takes more than
    /// the window shows.
    /// Bundle variant: the snapshot plus request/response payloads for
    /// the newest calls, read from disk.
    public func diagnosticsPayloadWithPayloads(activityLimit: Int) -> MCPDiagnosticsPayload {
        var snapshot = diagnosticsPayload(activityLimit: activityLimit)
        let ids = activity.entries.prefix(MCPDiagnosticsPayload.bundlePayloadRows).map { ($0.id, $0.hasPayload) }
        var rows = snapshot.activity
        for (index, pair) in ids.enumerated() where pair.1 && index < rows.count {
            guard let payload = activity.payloads.loadSync(id: pair.0) else { continue }
            rows[index].request = payload.request.map { String($0.prefix(MCPDiagnosticsPayload.bundlePayloadCap)) }
            rows[index].response = payload.response.map { String($0.prefix(MCPDiagnosticsPayload.bundlePayloadCap)) }
        }
        snapshot = MCPDiagnosticsPayload(enabled: snapshot.enabled, status: snapshot.status, port: snapshot.port,
                                         allowLAN: snapshot.allowLAN, preventSleep: snapshot.preventSleep,
                                         maxVolume: snapshot.maxVolume, tokens: snapshot.tokens,
                                         lockedOutAddresses: snapshot.lockedOutAddresses,
                                         failedAuthSinceLaunch: snapshot.failedAuthSinceLaunch,
                                         builds: snapshot.builds, activity: rows)
        return snapshot
    }

    public func diagnosticsPayload(activityLimit: Int = 100) -> MCPDiagnosticsPayload {
        let iso = ISO8601DateFormatter()
        let statusText: String
        switch status {
        case .stopped: statusText = "stopped"
        case .running(let port): statusText = "running:\(port)"
        case .failed(let reason): statusText = "failed: \(reason)"
        }
        return MCPDiagnosticsPayload(
            enabled: isEnabled,
            status: statusText,
            port: Int(port),
            allowLAN: allowsLAN,
            preventSleep: preventsSleep,
            maxVolume: maxVolume,
            tokens: tokens.tokens.map {
                .init(name: $0.name, scope: $0.scope.rawValue, createdAt: iso.string(from: $0.createdAt),
                      lastUsedAt: $0.lastUsedAt.map(iso.string), callsSinceLaunch: activity.callsByClient[$0.name] ?? 0)
            },
            lockedOutAddresses: lockouts.map { "\($0.address) until \(iso.string(from: $0.until))" },
            failedAuthSinceLaunch: activity.failedAuthCount,
            builds: buildJobs.allJobs.map {
                .init(jobID: $0.id, name: $0.name, status: $0.state.rawValue, done: $0.done, total: $0.total,
                      matched: $0.matched.count, queueErrors: $0.hitErrors, elapsedSeconds: Int(Date().timeIntervalSince($0.startedAt)))
            },
            activity: activity.entries.prefix(activityLimit).map {
                .init(at: iso.string(from: $0.date), client: $0.client, remote: $0.remote, action: $0.action,
                      summary: $0.summary, outcome: $0.outcome.rawValue, milliseconds: $0.milliseconds)
            }
        )
    }
}
