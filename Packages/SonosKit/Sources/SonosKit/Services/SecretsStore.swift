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
        return cache[key]
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
            return
        }
        // Nothing at the new location — migrate anything we find in the
        // legacy per-store services, then persist under the unified key.
        cache = harvestLegacy()
        if !cache.isEmpty {
            persist()
            purgeLegacy()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else {
            sonosDebugLog("[SECRETS] Failed to encode cache")
            return
        }
        writeKeychain(service: service, account: account, data: data)
    }

    // MARK: - Legacy migration

    /// Best-effort pull of pre-v3.6 keychain items. Each legacy account
    /// name becomes a namespaced key in the unified dictionary.
    private func harvestLegacy() -> [String: String] {
        var result: [String: String] = [:]

        // LastFM: four fixed accounts.
        for legacy in ["lastfm.apiKey", "lastfm.sharedSecret",
                       "lastfm.sessionKey", "lastfm.username"] {
            if let data = readKeychain(service: legacyLastFMService, account: legacy),
               let value = String(data: data, encoding: .utf8) {
                result[legacy] = value
            }
        }

        // SMAPI: unknown number of per-service accounts, "smapi_token_<id>"
        // and "smapi_key_<id>". Enumerate every item under that service.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacySMAPIService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecSuccess, let array = items as? [[String: Any]] {
            for entry in array {
                guard let account = entry[kSecAttrAccount as String] as? String,
                      let data = entry[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) else { continue }
                // "smapi_token_12" → "smapi.token.12"; keeps names readable
                // while living alongside the LastFM keys.
                let key = account.replacingOccurrences(of: "_", with: ".")
                result[key] = value
            }
        }

        if !result.isEmpty {
            sonosDebugLog("[SECRETS] Migrated \(result.count) legacy keychain items")
        }
        return result
    }

    private func purgeLegacy() {
        deleteAllKeychainItems(service: legacyLastFMService)
        deleteAllKeychainItems(service: legacySMAPIService)
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
        guard status == errSecSuccess else { return nil }
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

    private func deleteAllKeychainItems(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
