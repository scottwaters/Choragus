/// SongListAIService.swift — turns a natural-language brief ("top 3
/// songs of each year since 1970") into an ordered [SongSpec] via a
/// chat AI. The reply is constrained to a JSON array of
/// {title, artist} objects, decoded straight into the same SongSpec
/// list the Playlist Builder resolves and saves.
///
/// Providers: the Claude API (raw HTTP against POST /v1/messages — no
/// official Swift SDK), or any OpenAI-compatible chat-completions
/// endpoint (OpenAI itself, Ollama, LM Studio, ...). API keys live in
/// SecretsStore; non-secret settings (model, base URL) in UserDefaults.
import Foundation

public enum SongListAIError: LocalizedError {
    case missingKey
    case badBaseURL
    case insecureEndpoint
    case httpError(Int, String)
    /// An error event inside an otherwise successful stream; no HTTP
    /// status applies.
    case streamError(String)
    case refused
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: return L10n.aiKeyNotConfigured
        case .badBaseURL: return L10n.aiEndpointInvalid
        case .insecureEndpoint: return L10n.aiInsecureEndpoint
        case .httpError(let code, let detail): return L10n.aiServiceErrorFormat(code, detail)
        case .streamError(let detail):
            return detail.isEmpty ? L10n.aiStreamError : "\(L10n.aiStreamError): \(detail)"
        case .refused: return L10n.aiRequestDeclined
        case .badResponse: return L10n.aiResponseNotSongList
        }
    }
}

/// The API family a profile talks to (see `AIServiceProfile`).
public enum SongListAIProvider: String, CaseIterable, Codable, Sendable {
    case claude
    case openAI
    case custom

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "OpenAI"
        case .custom: return L10n.playlistBuilderAICustom
        }
    }

    /// Pre-profile keychain slot, read only by the legacy migration.
    var legacyAPIKeySecretName: String {
        switch self {
        case .claude: return "anthropicAPIKey"
        case .openAI: return "openaiAPIKey"
        case .custom: return "customAIKey"
        }
    }
}

/// Everything one generation call needs, resolved by the caller from
/// UserDefaults + SecretsStore so this service stays storage-free.
public struct SongListAIConfig {
    public let provider: SongListAIProvider
    public let model: String
    /// Chat-completions base URL for `.openAI`/`.custom`; ignored for `.claude`.
    public let baseURL: String
    public let apiKey: String

    public init(provider: SongListAIProvider, model: String, baseURL: String, apiKey: String) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public static let claudeDefaultModel = "claude-opus-5"
    public static let claudeModels = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
    public static let openAIDefaultModel = "gpt-5"
    public static let openAIModels = ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4o"]

    /// The picker's contents before (or without) the provider's own
    /// list; `.custom` has no fixed catalog.
    public static func defaultModels(for provider: SongListAIProvider) -> [String] {
        switch provider {
        case .claude: return claudeModels
        case .openAI: return openAIModels
        case .custom: return []
        }
    }
    public static let openAIBaseURL = "https://api.openai.com/v1"
    private static let chatCompletionsPath = "/chat/completions"

    /// The chat-completions URL for an OpenAI-compatible base URL. Every
    /// such server (OpenAI, DeepSeek, LM Studio, Ollama, vLLM) serves
    /// under `/v1`, so a bare host — `http://127.0.0.1:1234` — gets
    /// `/v1` added; a URL that already carries a path is used as given.
    /// A pasted URL that already names the endpoint is reduced to its
    /// base first. Nil when the text is not an http(s) URL.
    public static func chatCompletionsURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasSuffix(Self.chatCompletionsPath) {
            base.removeLast(Self.chatCompletionsPath.count)
            while base.hasSuffix("/") { base.removeLast() }
        }
        guard let parsed = URL(string: base),
              let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parsed.host != nil else { return nil }
        if parsed.path.isEmpty { base += "/v1" }
        return URL(string: base + Self.chatCompletionsPath)
    }

    /// The one place a profile and its keychain key are assembled into
    /// a config — every call site (builder generation, Settings
    /// connection test) uses this.
    @MainActor
    public init(profile: AIServiceProfile) {
        self.init(provider: profile.provider,
                  model: profile.model,
                  baseURL: profile.provider == .openAI ? Self.openAIBaseURL : profile.baseURL,
                  apiKey: SecretsStore.shared.get(profile.apiKeySecretName) ?? "")
    }

    /// Config for the selected profile; nil when none is configured.
    @MainActor
    public static func stored() -> SongListAIConfig? {
        AIServiceProfileStore.selected().map(SongListAIConfig.init(profile:))
    }
}

public enum SongListAIService {

    /// Session for every provider call. Redirects are refused so a key
    /// bound for one host cannot follow a 30x to another.
    public static let session: URLSession = URLSession(configuration: .ephemeral,
                                                        delegate: NoRedirectDelegate(),
                                                        delegateQueue: nil)

    final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Validation bounds for untrusted AI output. The reply is data
    /// from an external service: typed decode alone does not bound
    /// size or content, so every field is length-capped, control
    /// characters are stripped, and the list itself is capped.
    public static let maxBriefLength = 1000
    public static let maxFieldLength = 200
    public static let maxSongs = 500
    static let maxStreamBytes = 2 * 1024 * 1024

    /// Trims, strips control characters, and length-caps one field.
    /// Empty after cleaning = invalid (caller drops the entry).
    static func cleanField(_ s: String) -> String? {
        let cleaned = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxFieldLength))
    }

    static func validated(_ specs: [SongSpec]) -> [SongSpec] {
        specs.prefix(maxSongs).compactMap { spec in
            guard let title = cleanField(spec.title),
                  let artist = cleanField(spec.artist) else { return nil }
            return SongSpec(title: title, artist: artist)
        }
    }

    private static let systemPrompt = """
    You produce song lists for playlists. Reply with ONLY a JSON array, \
    no code fences and no commentary. Each element is an object with \
    exactly two string fields: "title" and "artist". Order the array as \
    the playlist should play. Use the primary artist name as credited \
    on the original release. If the request is not a request for a song \
    list, reply with an empty JSON array.
    """

    /// Streams the generation; `onProgress` receives the songs parsed
    /// so far after each delta (main-actor hop is the caller's job).
    /// Returns the final decoded list from the complete reply.
    /// `catalogHint` names the streaming catalog the songs will be
    /// matched on (e.g. "Spotify"); the AI is told to include only
    /// songs available there. Pass nil for local sources — the AI
    /// cannot know a local library's holdings.
    public static func generate(brief: String, config: SongListAIConfig,
                                catalogHint: String? = nil,
                                onProgress: (@Sendable ([SongSpec]) async -> Void)? = nil) async throws -> [SongSpec] {
        try await generateWithRaw(brief: brief, config: config,
                                  catalogHint: catalogHint, onProgress: onProgress).specs
    }

    /// Same call, also returning the raw reply text (capped upstream at
    /// `maxStreamBytes`) so the UI can show the raw reply. The brief
    /// is bounded the same way the reply is — a
    /// pathological brief is refused, not silently truncated.
    public static func generateWithRaw(brief: String, config: SongListAIConfig,
                                       catalogHint: String? = nil,
                                       onProgress: (@Sendable ([SongSpec]) async -> Void)? = nil
    ) async throws -> (specs: [SongSpec], rawText: String) {
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, brief.count <= maxBriefLength else {
            throw SongListAIError.badResponse
        }
        var system = systemPrompt
        if let catalogHint, !catalogHint.isEmpty {
            system += " Only include songs that are actually available on \(catalogHint). Only list songs you are confident really exist as recorded releases; if unsure about a song, substitute one you are certain of, even if it fits the request less exactly."
        }
        let text: String
        switch config.provider {
        case .claude:
            text = try await claudeStream(brief: brief, system: system, config: config, onProgress: onProgress)
        case .openAI, .custom:
            text = try await openAIStream(brief: brief, system: system, config: config, onProgress: onProgress)
        }
        return (validated(try decodeSongArray(from: text)), text)
    }

    /// The model's reply text for `brief`, undecoded. Diagnostics: shows
    /// what a prompt that fails to yield a song list drew instead.
    public static func rawReply(brief: String, config: SongListAIConfig,
                                catalogHint: String? = nil) async throws -> String {
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, brief.count <= maxBriefLength else { throw SongListAIError.badResponse }
        var system = systemPrompt
        if let catalogHint, !catalogHint.isEmpty {
            system += " Only include songs that are actually available on \(catalogHint). Only list songs you are confident really exist as recorded releases; if unsure about a song, substitute one you are certain of, even if it fits the request less exactly."
        }
        switch config.provider {
        case .claude:
            return try await claudeStream(brief: brief, system: system, config: config, onProgress: nil)
        case .openAI, .custom:
            return try await openAIStream(brief: brief, system: system, config: config, onProgress: nil)
        }
    }

    /// Minimal round trip proving the configured provider, model, and
    /// key work: the system prompt returns an empty JSON array for a
    /// non-song request, so success is a decodable (empty) reply.
    /// Throws with the provider's error on any failure.
    public static func testConnection(config: SongListAIConfig) async throws {
        _ = try await generateWithRaw(brief: "Connection test. This is not a song list request.",
                                      config: config)
    }

    /// A copy-paste prompt for using ANY external AI (a web chat, another
    /// app) to produce a list the builder's "Paste list" understands.
    public static func externalPromptTemplate(brief: String, catalogHint: String?) -> String {
        var lines = ["Create a song list: \(brief.isEmpty ? "<describe the playlist here>" : brief)"]
        if let catalogHint, !catalogHint.isEmpty {
            lines.append("Only include songs that are actually available on \(catalogHint). If you are not sure a song really exists there, substitute one you are certain of.")
        }
        lines.append("""
        Reply with one song per line in exactly this format, and nothing else:
        Title - Artist
        No numbering, no commentary, no blank lines.
        """)
        return lines.joined(separator: "\n")
    }

    /// Incremental best-effort parse of a streamed JSON array: each
    /// complete {"title": …, "artist": …} object (either key order) is
    /// consumed as it arrives; only the unmatched tail is kept, so a
    /// long stream never re-scans what it has already parsed.
    struct IncrementalSongParser {
        private var pending = ""
        private static let patterns: [(NSRegularExpression, titleFirst: Bool)] = {
            let title = #""title"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"artist"\s*:\s*"((?:[^"\\]|\\.)*)""#
            let artist = #""artist"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"title"\s*:\s*"((?:[^"\\]|\\.)*)""#
            return [(try! NSRegularExpression(pattern: title), true),
                    (try! NSRegularExpression(pattern: artist), false)]
        }()

        /// Feed one chunk; returns the specs completed by it.
        mutating func ingest(_ chunk: String) -> [SongSpec] {
            pending += chunk
            var found: [SongSpec] = []
            while let (spec, end) = Self.firstMatch(in: pending) {
                found.append(spec)
                pending = String(pending[end...])
            }
            // Bound the tail a hostile stream could grow between
            // matches; a real object is far under this.
            if pending.count > 65536 { pending = String(pending.suffix(4096)) }
            return found
        }

        private static func firstMatch(in s: String) -> (SongSpec, String.Index)? {
            let range = NSRange(s.startIndex..., in: s)
            for (regex, titleFirst) in patterns {
                guard let match = regex.firstMatch(in: s, range: range),
                      let full = Range(match.range, in: s),
                      let firstRange = Range(match.range(at: 1), in: s),
                      let secondRange = Range(match.range(at: 2), in: s) else { continue }
                let first = unescapeJSON(String(s[firstRange]))
                let second = unescapeJSON(String(s[secondRange]))
                let spec = titleFirst ? SongSpec(title: first, artist: second)
                                      : SongSpec(title: second, artist: first)
                return (spec, full.upperBound)
            }
            return nil
        }
    }

    private static func unescapeJSON(_ s: String) -> String {
        guard s.contains("\\"),
              let data = "\"\(s)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else { return s }
        return decoded
    }

    // MARK: - Claude (Messages API, SSE)

    private static func claudeStream(brief: String, system: String, config: SongListAIConfig,
                                     onProgress: (@Sendable ([SongSpec]) async -> Void)?) async throws -> String {
        guard !config.apiKey.isEmpty else { throw SongListAIError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Server-side refusal fallbacks exist for the Opus/Fable tier
        // only; sending the parameter to Sonnet or Haiku is rejected.
        let wantsFallbacks = config.model.hasPrefix("claude-opus") || config.model.hasPrefix("claude-fable")
        if wantsFallbacks {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.timeoutInterval = 600

        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 16000,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": brief]]
        ]
        if wantsFallbacks { body["fallbacks"] = "default" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var text = ""
        var parser = IncrementalSongParser()
        var streamed: [SongSpec] = []
        for try await payload in sseData(for: request) {
            guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let chunk = delta["text"] as? String {
                    text += chunk
                    guard text.utf8.count <= Self.maxStreamBytes else { throw SongListAIError.badResponse }
                    let fresh = parser.ingest(chunk)
                    if !fresh.isEmpty {
                        streamed.append(contentsOf: fresh)
                        await onProgress?(validated(streamed))
                    }
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "refusal" {
                    throw SongListAIError.refused
                }
            case "error":
                // Mid-stream API errors (overloaded, rate limit) arrive
                // as SSE events, not HTTP status — surface the API's
                // message instead of a generic parse failure.
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? ""
                throw SongListAIError.streamError(message)
            default:
                break
            }
        }
        return text
    }

    // MARK: - OpenAI-compatible (chat completions, SSE)

    private static func openAIStream(brief: String, system: String, config: SongListAIConfig,
                                     onProgress: (@Sendable ([SongSpec]) async -> Void)?) async throws -> String {
        // http(s) only: a custom endpoint is user-configured, and any
        // other scheme (file:, ftp:) has no legitimate use here.
        guard let url = SongListAIConfig.chatCompletionsURL(baseURL: config.baseURL),
              let scheme = url.scheme?.lowercased() else {
            throw SongListAIError.badBaseURL
        }
        // OpenAI itself requires a key; a local endpoint may not — only
        // the hosted provider treats an empty key as a config error.
        if config.provider == .openAI && config.apiKey.isEmpty { throw SongListAIError.missingKey }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            // Never put a bearer token on cleartext HTTP unless the
            // host is on the local network (Ollama / LM Studio) — a
            // hosted http:// URL would leak the key on the wire.
            // Refuse rather than silently strip: a stripped key just
            // produces an opaque 401 downstream.
            guard scheme == "https" || IPAddress.isPrivate(url.host ?? "") else {
                throw SongListAIError.insecureEndpoint
            }
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 600

        // No token-limit field: OpenAI's newer models take
        // `max_completion_tokens`, older ones and most local servers
        // take `max_tokens` — omitting the field is the one form every
        // implementation accepts.
        let body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": brief]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var text = ""
        var parser = IncrementalSongParser()
        var streamed: [SongSpec] = []
        for try await payload in sseData(for: request) {
            guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let chunk = delta["content"] as? String else { continue }
            text += chunk
            guard text.utf8.count <= Self.maxStreamBytes else { throw SongListAIError.badResponse }
            let fresh = parser.ingest(chunk)
            if !fresh.isEmpty {
                streamed.append(contentsOf: fresh)
                await onProgress?(validated(streamed))
            }
        }
        return text
    }

    // MARK: - Shared SSE plumbing

    /// Total raw bytes accepted from one stream, and the longest single
    /// SSE line. Both are hard caps on a hostile endpoint: `bytes.lines`
    /// would otherwise buffer an unterminated line without bound, and
    /// endless non-content events would keep an idle-based timeout
    /// alive forever.
    static let maxRawStreamBytes = 8 * 1024 * 1024
    static let maxLineBytes = 1024 * 1024

    /// Runs the request and yields the JSON payload of each SSE `data:`
    /// line ("[DONE]" markers skipped). Throws `httpError` with the
    /// collected body when the response status is not 200. Reads raw
    /// bytes with explicit line assembly so both caps above are
    /// enforced on everything received, not only on content deltas.
    private static func sseData(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw SongListAIError.badResponse
                    }
                    // A non-200, or a 200 that is not an event stream
                    // (LM Studio answers an unknown path with 200 + a
                    // JSON error), is an error with a body to quote —
                    // read otherwise it looks like an empty reply.
                    let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    guard http.statusCode == 200, contentType.contains("text/event-stream") else {
                        // Byte-wise, capped: `bytes.lines` buffers an
                        // unterminated line without bound.
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                            if errorData.count >= 500 { break }
                        }
                        let errorBody = String(data: errorData, encoding: .utf8) ?? ""
                        throw SongListAIError.httpError(http.statusCode, errorDetail(from: errorBody))
                    }

                    var lineBuffer = [UInt8]()
                    var totalBytes = 0
                    var finished = false

                    func processLine() {
                        guard !finished, !lineBuffer.isEmpty,
                              let line = String(bytes: lineBuffer, encoding: .utf8) else { return }
                        // SSE permits `data:` with or without one
                        // leading space; some local servers omit it.
                        guard line.hasPrefix("data:") else { return }
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        if payload == "[DONE]" { finished = true; return }
                        continuation.yield(Data(payload.utf8))
                    }

                    for try await byte in bytes {
                        totalBytes += 1
                        guard totalBytes <= maxRawStreamBytes else { throw SongListAIError.badResponse }
                        switch byte {
                        case 0x0A:   // \n — line complete
                            processLine()
                            lineBuffer.removeAll(keepingCapacity: true)
                            if finished { break }
                        case 0x0D:   // \r — ignore (CRLF tolerance)
                            continue
                        default:
                            guard lineBuffer.count < maxLineBytes else { throw SongListAIError.badResponse }
                            lineBuffer.append(byte)
                        }
                        if finished { break }
                    }
                    processLine()   // trailing unterminated line
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `{"error":{"message":…}}` (OpenAI), `{"error":"…"}` (LM Studio),
    /// or the raw body, capped.
    static func errorDetail(from body: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            if let message = (object["error"] as? [String: Any])?["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.aiEmptyResponse : String(trimmed.prefix(200))
    }

    private static func decodeSongArray(from text: String) throws -> [SongSpec] {
        // Tolerate stray prose or fences around the array: decode from
        // the first '[' to the last ']'.
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"),
              start < end else { throw SongListAIError.badResponse }
        let jsonSlice = String(text[start...end])
        guard let sliceData = jsonSlice.data(using: .utf8),
              let specs = try? JSONDecoder().decode([SongSpec].self, from: sliceData) else {
            throw SongListAIError.badResponse
        }
        return specs
    }
}
