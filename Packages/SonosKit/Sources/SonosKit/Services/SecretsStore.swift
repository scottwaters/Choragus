/// SecretsStore.swift — One keychain item for the whole app.
///
/// Why: macOS Keychain issues a separate "allow" prompt for each stored
/// item whenever the binary's code signature changes (every ad-hoc dev
/// build). Previously this app kept LastFM credentials in one service and
/// SMAPI credentials in another, with several accounts each — meaning 6-10
/// prompts on every rebuild.
///
/// This store keeps *all* secrets in a single JSON blob under a single
/// (service, account) pair. Result: one allow prompt per rebuild, one
/// Keychain item to manage.
///
/// Migration: on first access, if the unified item isn't present, the
/// store pulls values from the legacy LastFM / SMAPI keychain services,
/// writes them to the unified item, and deletes the legacy items. The
/// user sees their old prompts once more (to read the legacy items during
/// migration), then never again.
///
/// Thread safety: access is gated on the main actor — token stores that
/// own credentials are already `@MainActor` in this codebase.
import Foundation
import Security

@MainActor
public final class SecretsStore {

    public static let shared = SecretsStore()

    private let service: String
    private let account: String

    private var cache: [String: String] = [:]
    private var loaded = false

    /// Legacy service names we migrate from on first access. The (service,
    /// account-prefix) pairs define the items to harvest.
    private let legacyLastFMService = "com.sonoscontroller.app.lastfm"
    private let legacySMAPIService = "com.sonoscontroller.smapi"

    public init(service: String = "com.sonoscontroller.app",
                account: String = "secrets.v1") {
        self.service = service
        self.account = account
    }

    // MARK: - Public API

    public func get(_ key: String) -> String? {
        ensureLoaded()
        if let value = cache[key] { return value }
        return legacyFallbackValue(for: key)
    }

    public func set(_ key: String, _ value: String?) {
        ensureLoaded()
        if let value, !value.isEmpty {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
        persist()
    }

    /// Removes every key whose name starts with `prefix`. Useful for the
    /// SMAPI store's per-service deletions (keys like "smapi.token.123",
    /// "smapi.key.123").
    public func removeAll(withPrefix prefix: String) {
        ensureLoaded()
        for key in cache.keys where key.hasPrefix(prefix) {
            cache.removeValue(forKey: key)
        }
        persist()
    }

    /// Wipes the unified item entirely. Dev use only.
    public func clearAll() {
        cache.removeAll()
        loaded = true
        deleteKeychainItem(service: service, account: account)
    }

    // MARK: - Load / save

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let data = readKeychain(service: service, account: account),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = decoded
        }
        // No up-front legacy harvest. Running `SecItemCopyMatching` with
        // `kSecReturnData` against the legacy service triggered a Keychain
        // prompt for *every* item on every launch — user was being asked
        // to approve 5+ times. Instead, `get(_:)` falls back to the
        // legacy locations when a key isn't in the unified cache, and
        // promotes the value on first successful read. That way:
        //   - Unified store is still authoritative.
        //   - Items we never read never get harvested, so no prompts.
        //   - Items we do read migrate lazily with a single prompt each.
    }

    private static let legacyFallbackMap: [String: (service: String, account: String)] = [
        "lastfm.apiKey":        ("com.sonoscontroller.app.lastfm", "lastfm.apiKey"),
        "lastfm.sharedSecret":  ("com.sonoscontroller.app.lastfm", "lastfm.sharedSecret"),
        "lastfm.sessionKey":    ("com.sonoscontroller.app.lastfm", "lastfm.sessionKey"),
        "lastfm.username":      ("com.sonoscontroller.app.lastfm", "lastfm.username"),
    ]

    /// Lazy legacy fallback for keys not yet in the unified cache. Tries
    /// the fixed legacy LastFM accounts first, then the pattern-based
    /// SMAPI accounts (`smapi.token.<id>` → `smapi_token_<id>`). Returns
    /// the legacy value if found and promotes it into the unified store
    /// so future reads skip the legacy lookup.
    private func legacyFallbackValue(for key: String) -> String? {
        let fallback: (service: String, account: String)?
        if let mapped = Self.legacyFallbackMap[key] {
            fallback = mapped
        } else if key.hasPrefix("smapi.") {
            // "smapi.token.12" → account "smapi_token_12"
            let underscored = key.replacingOccurrences(of: ".", with: "_")
            fallback = (legacySMAPIService, underscored)
        } else {
            fallback = nil
        }
        guard let fallback,
              let data = readKeychain(service: fallback.service, account: fallback.account),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        // Promote to unified store so next read is free.
        cache[key] = value
        persist()
        return value
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else {
            sonosDebugLog("[SECRETS] Failed to encode cache")
            return
        }
        writeKeychain(service: service, account: account, data: data)
    }

    // MARK: - Keychain primitives

    private func readKeychain(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            // -25300 = errSecItemNotFound (normal first-run / no items yet)
            // -25308 = errSecInteractionNotAllowed (keychain locked / user dismissed prompt)
            // -34018 = errSecMissingEntitlement (sandbox / signing mismatch)
            if status != errSecItemNotFound {
                sonosDebugLog("[SECRETS] Keychain read failed: service=\(service) account=\(account) OSStatus=\(status)")
            }
            return nil
        }
        return result as? Data
    }

    private func writeKeychain(service: String, account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            sonosDebugLog("[SECRETS] Keychain write failed: OSStatus \(status)")
        }
    }

    private func deleteKeychainItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

}
