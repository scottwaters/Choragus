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
/// Service name aligns with the bundle ID (`com.choragus.app`). The
/// previous build used `com.sonoscontroller.app` — those legacy items are
/// orphaned by design after the v4.0 rename: trying to migrate would
/// trigger a fresh round of "Choragus wants to access keychain item
/// created by SonosController" prompts every launch until the user
/// clicked through them. Cleaner to ask users for a one-time re-auth
/// of Last.fm / SMAPI services and let everything line up with the
/// signed bundle identity from then on.
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

    public init(service: String = "com.choragus.app",
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
        }
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
