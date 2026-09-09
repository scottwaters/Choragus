/// AIModelCatalog.swift — The model ids a hosted AI provider offers.
///
/// Settings → AI fills the model picker from the provider itself so a
/// new model is selectable the day it ships. Claude lists models at
/// `GET /v1/models` (paginated); OpenAI at `GET {base}/models` (one
/// page, every model family the account can call — chat and non-chat
/// alike, so the reply is filtered to chat-capable ids). Both replies
/// are untrusted input: ids are length-capped and control characters
/// dropped before they reach a menu.
import Foundation

public enum AIModelCatalog {

    /// A model id longer than this is not a model id.
    public static let maxIDLength = 80
    /// Claude's page cap; one request covers the whole catalog.
    static let claudePageSize = 1000

    /// Model ids the provider reports for the profile's key, newest
    /// first as the provider orders them. `.custom` endpoints are not
    /// queried: their model field stays free text.
    public static func models(for config: SongListAIConfig,
                              session: URLSession = SongListAIService.session) async throws -> [String] {
        switch config.provider {
        case .claude: return try await claudeModels(config: config, session: session)
        case .openAI: return try await openAIModels(config: config, session: session)
        case .custom: return []
        }
    }

    // MARK: - Claude

    private static func claudeModels(config: SongListAIConfig, session: URLSession) async throws -> [String] {
        guard !config.apiKey.isEmpty else { throw SongListAIError.missingKey }
        var ids: [String] = []
        var afterID: String?
        // Bounded loop: the catalog is far below one page, and a server
        // that keeps answering `has_more` must not spin this forever.
        for _ in 0..<5 {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            var query = [URLQueryItem(name: "limit", value: String(claudePageSize))]
            if let afterID { query.append(URLQueryItem(name: "after_id", value: afterID)) }
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 20
            let data = try await fetch(request, session: session)
            let page = try parseClaudePage(data)
            ids.append(contentsOf: page.ids)
            guard page.hasMore, let last = page.lastID else { break }
            afterID = last
        }
        return ids
    }

    struct ClaudePage: Equatable {
        let ids: [String]
        let hasMore: Bool
        let lastID: String?
    }

    /// `{"data":[{"id":..,"display_name":..,"created_at":..,"type":"model"}],"has_more":..,"first_id":..,"last_id":..}`
    static func parseClaudePage(_ data: Data) throws -> ClaudePage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw SongListAIError.badResponse
        }
        let ids = rows.compactMap { sanitisedID($0["id"] as? String) }
        return ClaudePage(ids: ids,
                          hasMore: object["has_more"] as? Bool ?? false,
                          lastID: object["last_id"] as? String)
    }

    // MARK: - OpenAI

    private static func openAIModels(config: SongListAIConfig, session: URLSession) async throws -> [String] {
        guard !config.apiKey.isEmpty else { throw SongListAIError.missingKey }
        guard let chat = SongListAIConfig.chatCompletionsURL(baseURL: config.baseURL) else {
            throw SongListAIError.badBaseURL
        }
        // `.../v1/chat/completions` → `.../v1/models`.
        let url = chat.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let data = try await fetch(request, session: session)
        return try parseOpenAIModels(data)
    }

    /// `{"object":"list","data":[{"id":..,"object":"model","created":..,"owned_by":..}]}`,
    /// reduced to chat-capable model families, newest first.
    static func parseOpenAIModels(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw SongListAIError.badResponse
        }
        return rows
            .compactMap { row -> (id: String, created: Double)? in
                guard let id = sanitisedID(row["id"] as? String), isOpenAIChatModel(id) else { return nil }
                return (id, row["created"] as? Double ?? 0)
            }
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.id < $1.id }
            .map(\.id)
    }

    /// Chat-completions families only: the list also carries speech,
    /// image, embedding, moderation and search models, plus dated
    /// snapshots of each family that the alias already covers.
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
        guard chatPrefixes.contains(where: id.hasPrefix) else { return false }
        let nonChat = ["audio", "realtime", "transcribe", "tts", "image", "embedding",
                       "moderation", "search", "instruct", "codex"]
        guard !nonChat.contains(where: id.contains) else { return false }
        // Dated snapshots: `-2024-08-06` or `-0613` suffixes (a bare
        // version digit as in `gpt-5` is the family alias and stays).
        if let last = id.split(separator: "-").last, last.count >= 4, last.allSatisfy(\.isNumber) { return false }
        if id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return false }
        return true
    }

    // MARK: - Shared

    private static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SongListAIError.badResponse }
        guard http.statusCode == 200 else {
            throw SongListAIError.httpError(http.statusCode,
                                            SongListAIService.errorDetail(from: String(decoding: data, as: UTF8.self)))
        }
        return data
    }

    /// Drops ids that are empty, over-long, or carry control characters.
    static func sanitisedID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= maxIDLength,
              raw.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return raw
    }
}
