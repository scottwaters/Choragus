/// MCPActivityLog.swift — What agents did through the MCP server.
///
/// One entry per request: who (token name), what (method or tool),
/// outcome, duration, and where it came from. Kept in memory for the
/// Settings pane, capped so a chatty agent cannot grow it without
/// bound; every entry also goes to the diagnostics log so a bug report
/// carries the same history. Arguments are summarised, never stored
/// whole — tool inputs can carry playlist names and search terms, not
/// secrets, but the summary keeps the log small and the bundle short.
import Foundation

public struct MCPActivityEntry: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case ok, toolError, denied, unauthorised, rateLimited, rejected
    }

    public let id = UUID()
    public let date: Date
    public let client: String
    public let remote: String
    public let action: String
    public let summary: String
    public let outcome: Outcome
    public let milliseconds: Int
    /// True when the call's arguments and result were written to the
    /// payload store; Diagnostics loads them on selection.
    public let hasPayload: Bool

    public var isFailure: Bool { outcome != .ok }
}

@MainActor
public final class MCPActivityLog: ObservableObject {
    public static let shared = MCPActivityLog()

    public static let keepLimit = 300

    @Published public private(set) var entries: [MCPActivityEntry] = []
    /// Calls per token name since launch, successes only.
    @Published public private(set) var callsByClient: [String: Int] = [:]
    @Published public private(set) var failedAuthCount = 0

    public init() {}

    public let payloads = MCPPayloadStore.shared

    func record(client: String, remote: String, action: String, summary: String,
                outcome: MCPActivityEntry.Outcome, started: Date,
                request: [String: Any]? = nil, response: Any? = nil) {
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let entry = MCPActivityEntry(date: Date(), client: client, remote: remote, action: action,
                                     summary: summary, outcome: outcome, milliseconds: elapsed,
                                     hasPayload: request != nil || response != nil)
        if entry.hasPayload { payloads.save(id: entry.id, request: request, response: response) }
        entries.insert(entry, at: 0)
        if entries.count > Self.keepLimit { entries.removeLast(entries.count - Self.keepLimit) }
        if outcome == .ok { callsByClient[client, default: 0] += 1 }
        if outcome == .unauthorised { failedAuthCount += 1 }
        let level: DiagnosticLevel = outcome == .ok ? .info : .warning
        sonosDiagLog(level, tag: "MCP", "\(action) \(outcome.rawValue)",
                     context: ["client": client, "remote": remote, "ms": String(elapsed), "args": summary])
    }

    public func clear() {
        entries.removeAll()
        callsByClient.removeAll()
        failedAuthCount = 0
        payloads.removeAll()
    }

    /// A short, stable rendering of tool arguments for the log: keys
    /// in name order, strings cut short, arrays as counts.
    static func summarise(_ arguments: [String: Any]) -> String {
        arguments.keys.sorted().map { key -> String in
            switch arguments[key] {
            case let text as String: return "\(key)=\(text.prefix(40))"
            case let list as [Any]: return "\(key)=[\(list.count)]"
            case let value?: return "\(key)=\(value)"
            case nil: return key
            }
        }.joined(separator: " ")
    }
}
