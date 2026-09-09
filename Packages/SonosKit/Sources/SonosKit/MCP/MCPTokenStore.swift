/// MCPTokenStore.swift — Named access tokens for the MCP server.
///
/// One token per assistant, so each can be revoked on its own. The
/// names and dates live in UserDefaults; the secrets live in the
/// keychain under `mcp.token.<id>`.
import Foundation

public struct MCPClientToken: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var lastUsedAt: Date?
    /// What the token may do; tokens from before scopes existed keep
    /// full access so a configured assistant does not stop working.
    public var scope: MCPScope
    /// When set, tools that normally need `confirm: true` run without it
    /// for this token — for an assistant the user trusts to act alone.
    public var skipsConfirmations: Bool

    public init(id: UUID, name: String, createdAt: Date, lastUsedAt: Date?, scope: MCPScope, skipsConfirmations: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.scope = scope
        self.skipsConfirmations = skipsConfirmations
    }

    private enum CodingKeys: String, CodingKey { case id, name, createdAt, lastUsedAt, scope, skipsConfirmations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        scope = try c.decodeIfPresent(MCPScope.self, forKey: .scope) ?? .manage
        skipsConfirmations = try c.decodeIfPresent(Bool.self, forKey: .skipsConfirmations) ?? false
    }

    public var secretName: String { "mcp.token.\(id.uuidString)" }
    public static let maxNameLength = 40
}

/// Where secrets are kept; the keychain in the app, memory in tests.
public protocol SecretsStoring: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

extension SecretsStore: SecretsStoring {}

@MainActor
public final class MCPTokenStore {
    public static let shared = MCPTokenStore(defaults: .standard, secrets: SecretsStore.shared)

    static let legacySecretName = "mcp.token"
    private let defaults: UserDefaults
    private let secrets: SecretsStoring

    public init(defaults: UserDefaults, secrets: SecretsStoring) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public var tokens: [MCPClientToken] {
        get {
            migrateLegacyIfNeeded()
            guard let data = defaults.data(forKey: UDKey.mcpTokens),
                  let list = try? JSONDecoder().decode([MCPClientToken].self, from: data) else { return [] }
            return list
        }
        set {
            defaults.set((try? JSONEncoder().encode(newValue)) ?? Data(), forKey: UDKey.mcpTokens)
        }
    }

    /// Creates a token and returns it with its secret; the secret is
    /// also readable later through `secret(for:)`.
    @discardableResult
    public func create(name: String, scope: MCPScope = .control) -> (token: MCPClientToken, secret: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(MCPClientToken.maxNameLength))
        let token = MCPClientToken(id: UUID(), name: trimmed.isEmpty ? "Token" : trimmed, createdAt: Date(), lastUsedAt: nil, scope: scope)
        let secret = Self.randomSecret()
        secrets.set(token.secretName, secret)
        tokens.append(token)
        return (token, secret)
    }

    public func revoke(id: UUID) {
        guard let token = tokens.first(where: { $0.id == id }) else { return }
        secrets.set(token.secretName, nil)
        tokens.removeAll { $0.id == id }
    }

    public func rename(id: UUID, to name: String) {
        var list = tokens
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = String(name.trimmingCharacters(in: .whitespaces).prefix(MCPClientToken.maxNameLength))
        tokens = list
    }

    public func setSkipsConfirmations(id: UUID, _ skips: Bool) {
        var list = tokens
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].skipsConfirmations = skips
        tokens = list
    }

    public func setScope(id: UUID, to scope: MCPScope) {
        var list = tokens
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].scope = scope
        tokens = list
    }

    public func secret(for token: MCPClientToken) -> String? {
        secrets.get(token.secretName)
    }

    /// The token whose secret matches the bearer credential, or nil.
    public func authenticate(bearer: String) -> MCPClientToken? {
        var match: MCPClientToken?
        for token in tokens {
            guard let secret = secrets.get(token.secretName), !secret.isEmpty else { continue }
            if Self.constantTimeEquals(bearer, secret) { match = token }
        }
        return match
    }

    /// Stamps the token's last use, at most once a minute per token.
    public func recordUse(of id: UUID) {
        var list = tokens
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        if let last = list[index].lastUsedAt, Date().timeIntervalSince(last) < 60 { return }
        list[index].lastUsedAt = Date()
        tokens = list
    }

    /// The single token of the first release becomes a named entry.
    private func migrateLegacyIfNeeded() {
        guard defaults.object(forKey: UDKey.mcpTokens) == nil else { return }
        defaults.set(Data(), forKey: UDKey.mcpTokens)
        guard let legacy = secrets.get(Self.legacySecretName), !legacy.isEmpty else { return }
        let token = MCPClientToken(id: UUID(), name: "Default", createdAt: Date(), lastUsedAt: nil, scope: .manage)
        secrets.set(token.secretName, legacy)
        secrets.set(Self.legacySecretName, nil)
        defaults.set((try? JSONEncoder().encode([token])) ?? Data(), forKey: UDKey.mcpTokens)
    }

    /// 24 bytes from the system CSPRNG. `SystemRandomNumberGenerator`
    /// cannot fail, unlike `SecRandomCopyBytes`, whose ignored status would
    /// have left the buffer at zero.
    static func randomSecret() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
