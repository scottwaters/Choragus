/// ChoragusMCPServer.swift — Model Context Protocol endpoint for agents.
///
/// Speaks MCP over Streamable HTTP (`POST /mcp`, JSON-RPC 2.0, one
/// response per request; no server-initiated stream). Every request
/// carries one of the named bearer tokens Settings manages, passes the
/// origin, lockout and rate checks in `MCPAccessGuard`, and is written
/// to `MCPActivityLog`. The listener stays on loopback unless the user
/// opens it to the LAN. Tools call the same `SonosManager` paths the UI
/// uses, gated by the token's `MCPScope`.
import Foundation

/// Who is calling, carried from authentication into every tool.
struct MCPCallContext {
    let client: String
    let scope: MCPScope
    let remote: String
    var skipsConfirmations = false

    /// Tests and in-process callers.
    static let trusted = MCPCallContext(client: "internal", scope: .manage, remote: "")
}

@MainActor
public final class ChoragusMCPServer: ObservableObject {
    public static let shared = ChoragusMCPServer()

    public static let protocolVersion = "2025-06-18"
    public static let defaultPort: UInt16 = 52080
    public static let defaultMaxVolume = 80
    /// Search results handed to an agent, so `play_item` can name one.
    static let itemCacheLimit = 500

    public enum Status: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    @Published public private(set) var status: Status = .stopped

    private var server: LocalHTTPServer?
    private let sleepInhibitor = SleepInhibitor()
    var itemCache: [String: BrowseItem] = [:]
    var itemCacheOrder: [String] = []
    /// Background playlist builds started by `build_playlist`.
    let buildJobs = MCPBuildJobs()
    let accessGuard = MCPAccessGuard()
    public let activity = MCPActivityLog.shared
    /// The scope of the token behind the tool call in progress.
    var currentScope: MCPScope = .manage
    /// Whether that token may skip `confirm: true`.
    var currentSkipsConfirmations = false
    /// Grouping layouts saved by `snapshot_grouping` / `group_all` so a
    /// party can be undone to what was there before, not to all-singles.
    var groupingSnapshots: [String: MCPGroupingSnapshot] = [:]
    var groupingSnapshotOrder: [String] = []
    /// Results of mutating calls keyed by client + tool + request_id, so a
    /// client that lost the reply can repeat the call without acting twice.
    /// Coordinator id and whether the job created (not appended to) a
    /// playlist, per build job — what undo needs.
    var buildRooms: [String: String] = [:]
    var buildCreatedPlaylist: [String: Bool] = [:]
    var dedupeResults: [String: [String: Any]] = [:]
    var dedupeOrder: [String] = []
    static let dedupeLimit = 200
    /// Tests compare against this instead of the keychain token.
    var tokenOverride: String?

    // MARK: - App-side hooks
    //
    // Windows, lyrics, artist metadata and scrobbling live in the app
    // target, not in SonosKit. The app installs these at launch; a tool
    // that needs one refuses cleanly when it is absent (a unit test or a
    // kit-only host).

    /// Opens a Choragus window by name for `open_window`.
    public var windowOpener: (@MainActor (String, SonosGroup?) -> Bool)?
    /// Lyrics for a track: plain text, synced LRC, and whether the track
    /// is marked instrumental.
    public var lyricsProvider: (@MainActor (_ artist: String, _ title: String, _ album: String?, _ trackURI: String?) async -> (plain: String?, synced: String?, instrumental: Bool)?)?
    /// Artist biography, tags and similar artists.
    public var artistInfoProvider: (@MainActor (String) async -> [String: Any]?)?
    /// Album release year, summary and art.
    public var albumInfoProvider: (@MainActor (_ artist: String, _ album: String) async -> [String: Any]?)?
    /// Scrobbling state, and a way to send what is pending.
    public var scrobbleStatusProvider: (@MainActor () -> [String: Any])?
    public var scrobbleSender: (@MainActor () async -> Void)?

    private init() {}

    // MARK: - Settings

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: UDKey.mcpEnabled) }
    public var allowsLAN: Bool { UserDefaults.standard.bool(forKey: UDKey.mcpAllowLAN) }
    public var preventsSleep: Bool { UserDefaults.standard.bool(forKey: UDKey.mcpPreventSleep) }
    public var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: UDKey.mcpPort)
        return (1024...65535).contains(stored) ? UInt16(stored) : Self.defaultPort
    }
    /// The loudest an agent may set any speaker right now: the standing
    /// limit, or the quiet-hours limit while those apply.
    public var maxVolume: Int {
        let standing: Int
        if UserDefaults.standard.object(forKey: UDKey.mcpMaxVolume) != nil {
            standing = min(100, max(0, UserDefaults.standard.integer(forKey: UDKey.mcpMaxVolume)))
        } else {
            standing = Self.defaultMaxVolume
        }
        guard quietHoursActive else { return standing }
        let quiet = UserDefaults.standard.object(forKey: UDKey.mcpQuietMaxVolume) == nil
            ? Self.defaultQuietMaxVolume : UserDefaults.standard.integer(forKey: UDKey.mcpQuietMaxVolume)
        return min(standing, min(100, max(0, quiet)))
    }
    public static let defaultQuietMaxVolume = 25

    /// Quiet hours run from `mcp.quietStart` to `mcp.quietEnd` (hours,
    /// 0-23) on this Mac's clock, wrapping past midnight when the end is
    /// earlier than the start.
    public var quietHoursActive: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: UDKey.mcpQuietEnabled) else { return false }
        let start = defaults.integer(forKey: UDKey.mcpQuietStart), end = defaults.integer(forKey: UDKey.mcpQuietEnd)
        guard start != end else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
    func cappedVolume(_ level: Int) -> Int { min(maxVolume, max(0, level)) }

    public let tokens = MCPTokenStore.shared

    public var endpointURL: String { "http://127.0.0.1:\(port)/mcp" }

    /// Addresses waiting out an authentication lockout.
    public var lockouts: [(address: String, until: Date)] { accessGuard.lockouts }

    // MARK: - Lifecycle

    /// Reconciles the running server with the stored settings.
    public func applySettings() {
        stop()
        sleepInhibitor.set(isEnabled && preventsSleep, reason: "Choragus MCP server")
        guard isEnabled else { return }
        do {
            let loopbackOnly = !allowsLAN
            let created = try LocalHTTPServer(port: port, loopbackOnly: loopbackOnly,
                                              bonjourName: "Choragus") { request in
                await ChoragusMCPServer.shared.handle(request)
            }
            server = created
            created.onStateChange = { state in
                Task { @MainActor in
                    sonosDiagLog(state.hasPrefix("ready") ? .info : .warning, tag: "MCP", "Listener \(state)")
                    if state.hasPrefix("failed") { ChoragusMCPServer.shared.status = .failed(state) }
                }
            }
            Task { [weak self] in
                do {
                    try await created.start()
                    self?.status = .running(port: created.port)
                    sonosDiagLog(.info, tag: "MCP", "Server listening",
                                 context: ["port": String(created.port), "lan": loopbackOnly ? "no" : "yes"])
                } catch {
                    self?.status = .failed(error.localizedDescription)
                    sonosDiagLog(.error, tag: "MCP", "Server failed to start",
                                 context: ["error": error.localizedDescription])
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        status = .stopped
        sleepInhibitor.set(false, reason: "")
    }

    // MARK: - HTTP

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let started = Date()
        let remote = request.remoteAddress
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else {
            return HTTPResponse(status: 404)
        }
        switch accessGuard.check(request, allowLAN: allowsLAN) {
        case .allow:
            break
        case .lockedOut(let seconds):
            activity.record(client: "-", remote: remote, action: "auth", summary: "locked out",
                            outcome: .unauthorised, started: started)
            return HTTPResponse(status: 429, headers: ["Retry-After": String(seconds)])
        case .badOrigin(let origin):
            activity.record(client: "-", remote: remote, action: "origin", summary: origin, outcome: .rejected, started: started)
            return HTTPResponse(status: 403)
        case .badHost(let host):
            activity.record(client: "-", remote: remote, action: "host", summary: host, outcome: .rejected, started: started)
            return HTTPResponse(status: 403)
        }

        guard let context = authenticate(request) else {
            let lockout = accessGuard.recordAuthFailure(from: remote)
            activity.record(client: "-", remote: remote, action: "auth",
                            summary: lockout > 0 ? "wrong token; locked out \(lockout)s" : "wrong token",
                            outcome: .unauthorised, started: started)
            var headers = ["WWW-Authenticate": "Bearer"]
            if lockout > 0 { headers["Retry-After"] = String(lockout) }
            return HTTPResponse(status: 401, headers: headers)
        }
        accessGuard.recordAuthSuccess(from: remote)
        guard accessGuard.allowCall(token: context.client) else {
            activity.record(client: context.client, remote: remote, action: "rate", summary: "limit reached",
                            outcome: .rateLimited, started: started)
            return HTTPResponse(status: 429, headers: ["Retry-After": String(Int(MCPAccessGuard.rateWindow))])
        }
        switch request.method {
        case "POST":
            return await handlePost(request.body, context: context)
        case "DELETE":
            return HTTPResponse(status: 200)
        default:
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }
    }

    /// The caller behind a bearer credential, or nil.
    private func authenticate(_ request: HTTPRequest) -> MCPCallContext? {
        guard let auth = request.headers["authorization"], auth.hasPrefix("Bearer ") else { return nil }
        let bearer = String(auth.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard !bearer.isEmpty else { return nil }
        if let override = tokenOverride {
            guard MCPTokenStore.constantTimeEquals(bearer, override) else { return nil }
            return MCPCallContext(client: "test", scope: .manage, remote: request.remoteAddress)
        }
        guard let client = tokens.authenticate(bearer: bearer) else { return nil }
        tokens.recordUse(of: client.id)
        return MCPCallContext(client: client.name, scope: client.scope, remote: request.remoteAddress,
                              skipsConfirmations: client.skipsConfirmations)
    }

    private func handlePost(_ body: Data, context: MCPCallContext) async -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return .json(Self.errorResponse(id: nil, code: -32700, message: "Parse error"), status: 400)
        }
        if let batch = object as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for message in batch {
                if let reply = await dispatch(message, context: context) { replies.append(reply) }
            }
            return replies.isEmpty ? HTTPResponse(status: 202) : .json(replies)
        }
        guard let message = object as? [String: Any] else {
            return .json(Self.errorResponse(id: nil, code: -32600, message: "Invalid request"), status: 400)
        }
        guard let reply = await dispatch(message, context: context) else { return HTTPResponse(status: 202) }
        return .json(reply)
    }

    // MARK: - JSON-RPC

    /// In-process entry with full access; tests use it.
    func dispatch(_ message: [String: Any]) async -> [String: Any]? {
        await dispatch(message, context: .trusted)
    }

    /// Nil for notifications (no id).
    func dispatch(_ message: [String: Any], context: MCPCallContext) async -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : Self.errorResponse(id: id, code: -32600, message: "Invalid request")
        }
        if id == nil { return nil }   // notifications/initialized, notifications/cancelled
        let params = message["params"] as? [String: Any] ?? [:]
        let started = Date()
        do {
            let result: [String: Any]
            switch method {
            case "initialize":
                result = [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": ["tools": [:], "resources": [:], "prompts": [:]],
                    "serverInfo": ["name": "Choragus", "version": Self.appVersion],
                    "instructions": Self.instructions,
                ]
                activity.record(client: context.client, remote: context.remote, action: "initialize",
                                summary: (params["clientInfo"] as? [String: Any])?["name"] as? String ?? "",
                                outcome: .ok, started: started)
            case "ping":
                result = [:]
            case "tools/list":
                result = ["tools": MCPTool.all.map(\.descriptor)]
            case "tools/call":
                guard let name = params["name"] as? String, let tool = MCPTool.all.first(where: { $0.name == name }) else {
                    throw MCPError.invalidParams("Unknown tool")
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                result = await callTool(tool, arguments: arguments, context: context, started: started)
            case "resources/list":
                result = ["resources": MCPResource.all.map(\.descriptor)]
            case "resources/read":
                guard let uri = params["uri"] as? String, let resource = MCPResource.all.first(where: { $0.uri == uri }) else {
                    throw MCPError.invalidParams("Unknown resource")
                }
                result = ["contents": [["uri": uri, "mimeType": "application/json", "text": try readResource(resource)]]]
                activity.record(client: context.client, remote: context.remote, action: uri, summary: "",
                                outcome: .ok, started: started)
            case "prompts/list":
                result = ["prompts": MCPPrompt.all.map(\.descriptor)]
            case "prompts/get":
                guard let name = params["name"] as? String, let prompt = MCPPrompt.all.first(where: { $0.name == name }) else {
                    throw MCPError.invalidParams("Unknown prompt")
                }
                let arguments = (params["arguments"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
                for argument in prompt.arguments where argument.required && (arguments[argument.name] ?? "").isEmpty {
                    throw MCPError.invalidParams("Missing \(argument.name)")
                }
                result = ["description": prompt.description,
                          "messages": [["role": "user", "content": ["type": "text", "text": prompt.render(arguments)]]]]
                activity.record(client: context.client, remote: context.remote, action: "prompt \(name)",
                                summary: MCPActivityLog.summarise(arguments), outcome: .ok, started: started)
            default:
                throw MCPError.methodNotFound
            }
            return ["jsonrpc": "2.0", "id": id!, "result": result]
        } catch let error as MCPError {
            return Self.errorResponse(id: id, code: error.code, message: error.message)
        } catch {
            return Self.errorResponse(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    private func callTool(_ tool: MCPTool, arguments: [String: Any], context: MCPCallContext, started: Date) async -> [String: Any] {
        let summary = MCPActivityLog.summarise(arguments)
        guard context.scope.covers(tool.scope) else {
            activity.record(client: context.client, remote: context.remote, action: tool.name, summary: summary,
                            outcome: .denied, started: started, request: arguments)
            let message = "Token \"\(context.client)\" has \(context.scope.title.lowercased()) access; \(tool.name) needs \(tool.scope.title.lowercased())"
            return ["content": [["type": "text", "text": message]], "isError": true]
        }
        // Idempotent retry: same client, tool and request_id → same answer.
        var dedupeKey: String?
        if tool.scope != .readOnly, let requestID = arguments["request_id"] as? String, !requestID.isEmpty {
            let key = "\(context.client)|\(tool.name)|\(requestID)"
            if let cached = dedupeResults[key] {
                activity.record(client: context.client, remote: context.remote, action: tool.name,
                                summary: "\(summary) (repeat of request_id, not re-run)", outcome: .ok, started: started)
                return cached
            }
            dedupeKey = key
        }
        currentScope = context.scope
        currentSkipsConfirmations = context.skipsConfirmations
        defer { currentScope = .manage; currentSkipsConfirmations = false }
        do {
            var output = try await tool.run(arguments, self)
            activity.record(client: context.client, remote: context.remote, action: tool.name, summary: summary,
                            outcome: .ok, started: started, request: arguments, response: output)
            if let dedupeKey {
                output["request_id"] = arguments["request_id"]
                let reply: [String: Any] = ["content": [["type": "text", "text": Self.jsonText(output)]], "structuredContent": output, "isError": false]
                dedupeResults[dedupeKey] = reply
                dedupeOrder.append(dedupeKey)
                while dedupeOrder.count > Self.dedupeLimit { dedupeResults.removeValue(forKey: dedupeOrder.removeFirst()) }
                return reply
            }
            let text = Self.jsonText(output)
            return ["content": [["type": "text", "text": text]], "structuredContent": output, "isError": false]
        } catch let error as MCPError {
            activity.record(client: context.client, remote: context.remote, action: tool.name,
                            summary: "\(summary) → \(error.message)", outcome: .toolError, started: started,
                            request: arguments, response: ["error": error.message])
            return ["content": [["type": "text", "text": error.message]], "isError": true]
        } catch {
            activity.record(client: context.client, remote: context.remote, action: tool.name,
                            summary: "\(summary) → \(error.localizedDescription)", outcome: .toolError, started: started,
                            request: arguments, response: ["error": error.localizedDescription])
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    /// Destructive tools call this instead of reading `confirm` directly:
    /// a token marked to skip confirmations passes without the flag.
    func requireConfirm(_ args: [String: Any]) throws {
        if currentSkipsConfirmations { return }
        guard args.optionalBool("confirm") == true else { throw MCPError.invalidParams("confirm must be true") }
    }

    /// Throws unless the token behind the current call has `scope`.
    func requireScope(_ scope: MCPScope, for action: String) throws {
        guard currentScope.covers(scope) else {
            throw MCPError.invalidParams("\(action) needs a token with \(scope.title.lowercased()) access")
        }
    }

    private func readResource(_ resource: MCPResource) throws -> String {
        Self.jsonText(try resource.read(self))
    }

    static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    static func jsonText(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static let instructions = """
    Choragus controls Sonos speakers on this Mac's network. Rooms are named as in the Sonos app; a grouped set of rooms is addressed by any member's name. \
    Music: search (the Sonos library, with a type filter), browse_library, search_service, search_radio and list_favorites return ids; play_item, add_to_queue and the playlist tools take them. \
    Playlists: build_playlist matches a song list on the library or a service as a background job — poll build_status, and use deliver "queue" or "play" to fill a room's queue as matches land. \
    Volume is 0-100, capped by the user's agent limit and, during the user's quiet hours, by a lower one. Tools with a confirm flag remove something that cannot be put back; ask before calling them. Playing something replaces the room's queue, which the app can restore from its queue history. Pass request_id on any call that changes something so a retry after a lost reply cannot act twice. The prompts list has step-by-step playbooks.
    """

    // MARK: - Helpers for tools

    var manager: SonosManager {
        get throws {
            guard let manager = SonosManager.current else { throw MCPError.internal("Choragus is still starting") }
            return manager
        }
    }

    /// A room or group by name (any member room, case-insensitive) or
    /// coordinator id.
    func group(named name: String) throws -> SonosGroup {
        let groups = try manager.groups
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let byID = groups.first(where: { $0.coordinatorID.lowercased() == needle }) { return byID }
        if let byName = groups.first(where: { $0.name.lowercased() == needle
            || $0.members.contains { $0.roomName.lowercased() == needle } }) { return byName }
        throw MCPError.invalidParams("No room named \(name)")
    }

    func remember(_ items: [BrowseItem]) -> [BrowseItem] {
        for item in items {
            let key = item.id.uuidString
            if itemCache[key] == nil { itemCacheOrder.append(key) }
            itemCache[key] = item
        }
        while itemCacheOrder.count > Self.itemCacheLimit {
            itemCache.removeValue(forKey: itemCacheOrder.removeFirst())
        }
        return items
    }
}

enum MCPError: Error {
    case invalidParams(String)
    case methodNotFound
    case `internal`(String)

    var code: Int {
        switch self {
        case .invalidParams: return -32602
        case .methodNotFound: return -32601
        case .internal: return -32603
        }
    }
    var message: String {
        switch self {
        case .invalidParams(let m), .internal(let m): return m
        case .methodNotFound: return "Method not found"
        }
    }
}
