import XCTest
@testable import SonosKit

@MainActor
final class MCPTokenStoreTests: XCTestCase {
    private final class MemorySecrets: SecretsStoring {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ key: String, _ value: String?) { values[key] = value }
    }

    private func makeStore(secrets: MemorySecrets = MemorySecrets()) -> (MCPTokenStore, UserDefaults, MemorySecrets) {
        let suite = "mcp-tokens-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (MCPTokenStore(defaults: defaults, secrets: secrets), defaults, secrets)
    }

    func testCreateAuthenticateRevoke() {
        let (store, _, secrets) = makeStore()
        let a = store.create(name: "Claude Desktop")
        let b = store.create(name: "Claude Code")
        XCTAssertEqual(store.tokens.map(\.name), ["Claude Desktop", "Claude Code"])
        XCTAssertEqual(store.authenticate(bearer: a.secret)?.id, a.token.id)
        XCTAssertEqual(store.authenticate(bearer: b.secret)?.id, b.token.id)
        XCTAssertNil(store.authenticate(bearer: "nope"))
        store.revoke(id: a.token.id)
        XCTAssertNil(store.authenticate(bearer: a.secret))
        XCTAssertNil(secrets.get(a.token.secretName))
        XCTAssertEqual(store.authenticate(bearer: b.secret)?.id, b.token.id)
    }

    func testLegacySingleTokenBecomesDefault() {
        let secrets = MemorySecrets()
        secrets.set(MCPTokenStore.legacySecretName, "old-secret")
        let (store, _, _) = makeStore(secrets: secrets)
        XCTAssertEqual(store.tokens.map(\.name), ["Default"])
        XCTAssertEqual(store.authenticate(bearer: "old-secret")?.name, "Default")
        XCTAssertNil(secrets.get(MCPTokenStore.legacySecretName))
    }

    func testNamesAreTrimmedAndCapped() {
        let (store, _, _) = makeStore()
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(store.create(name: "  \(long)  ").token.name.count, MCPClientToken.maxNameLength)
        XCTAssertEqual(store.create(name: "   ").token.name, "Token")
    }

    func testRecordUseThrottles() {
        let (store, _, _) = makeStore()
        let t = store.create(name: "A").token
        store.recordUse(of: t.id)
        let first = store.tokens.first?.lastUsedAt
        XCTAssertNotNil(first)
        store.recordUse(of: t.id)
        XCTAssertEqual(store.tokens.first?.lastUsedAt, first)
    }

    /// Secrets are 24 random bytes, URL-safe base64 without padding, and
    /// never repeat.
    func testRandomSecretIsUniqueAndURLSafe() {
        let a = MCPTokenStore.randomSecret(), b = MCPTokenStore.randomSecret()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(a, String(repeating: "A", count: 32), "an all-zero buffer must never be issued")
    }

}
