/// SMAPITokenStore.swift — Secure storage for SMAPI authentication tokens.
/// Uses macOS Keychain for token/key storage. Service metadata stored in JSON.
import Foundation
import Security

public struct SMAPIToken: Codable {
    public let serviceID: Int
    public let serviceName: String
    public var authToken: String
    public var privateKey: String
    public let deviceID: String
    public let householdID: String
    public var lastRefreshed: Date

    public init(serviceID: Int, serviceName: String, authToken: String, privateKey: String,
                deviceID: String, householdID: String) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.authToken = authToken
        self.privateKey = privateKey
        self.deviceID = deviceID
        self.householdID = householdID
        self.lastRefreshed = Date()
    }
}

@MainActor
public final class SMAPITokenStore: ObservableObject {
    @Published public var authenticatedServices: [Int: SMAPIToken] = [:]
    private let fileURL: URL

    public init() {
        self.fileURL = AppPaths.appSupportDirectory.appendingPathComponent("smapi_tokens.json")
        load()
    }

    // MARK: - Public API

    public func store(token: SMAPIToken) {
        authenticatedServices[token.serviceID] = token
        // Store token/key in Keychain
        setKeychainItem(key: "smapi_token_\(token.serviceID)", value: token.authToken)
        setKeychainItem(key: "smapi_key_\(token.serviceID)", value: token.privateKey)
        save()
    }

    public func getToken(for serviceID: Int) -> SMAPIToken? {
        guard var token = authenticatedServices[serviceID] else { return nil }
        // Retrieve actual token/key from Keychain
        if let t = getKeychainItem(key: "smapi_token_\(serviceID)") { token.authToken = t }
        if let k = getKeychainItem(key: "smapi_key_\(serviceID)") { token.privateKey = k }
        return token
    }

    public func removeToken(for serviceID: Int) {
        authenticatedServices.removeValue(forKey: serviceID)
        deleteKeychainItem(key: "smapi_token_\(serviceID)")
        deleteKeychainItem(key: "smapi_key_\(serviceID)")
        save()
    }

    public func updateToken(serviceID: Int, authToken: String, privateKey: String) {
        if var token = authenticatedServices[serviceID] {
            token.authToken = authToken
            token.privateKey = privateKey
            token.lastRefreshed = Date()
            authenticatedServices[serviceID] = token
            setKeychainItem(key: "smapi_token_\(serviceID)", value: authToken)
            setKeychainItem(key: "smapi_key_\(serviceID)", value: privateKey)
            save()
        }
    }

    // MARK: - Persistence (metadata only — tokens in Keychain)

    private func save() {
        // Save metadata without actual tokens
        var safeCopy = authenticatedServices
        for (id, var token) in safeCopy {
            token.authToken = ""
            token.privateKey = ""
            safeCopy[id] = token
        }
        guard let data = try? JSONEncoder().encode(safeCopy) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Int: SMAPIToken].self, from: data) else { return }
        authenticatedServices = decoded
    }

    // MARK: - Keychain

    private let keychainService = "com.sonoscontroller.smapi"

    private func setKeychainItem(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            sonosDebugLog("[KEYCHAIN] Store failed for \(key): OSStatus \(status)")
        }
    }

    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                sonosDebugLog("[KEYCHAIN] Read failed for \(key): OSStatus \(status)")
            }
            return nil
        }
        return str
    }

    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            sonosDebugLog("[KEYCHAIN] Delete failed for \(key): OSStatus \(status)")
        }
    }
}
