/// SMAPITokenStore.swift — Secure storage for SMAPI authentication tokens.
///
/// Tokens and private keys live in the app-wide unified `SecretsStore`
/// (single keychain item). Non-sensitive metadata (service id, name,
/// device id, etc.) lives in a JSON file under Application Support —
/// reading it doesn't trigger a keychain prompt.
import Foundation

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
    private let secrets: SecretsStore

    public init(secrets: SecretsStore = .shared) {
        self.secrets = secrets
        self.fileURL = AppPaths.appSupportDirectory.appendingPathComponent("smapi_tokens.json")
        load()
    }

    // Key naming: keep dot-separated style consistent with the unified
    // secrets dict so migrate-from-legacy handles both halves uniformly.
    private func tokenKey(_ serviceID: Int) -> String { "smapi.token.\(serviceID)" }
    private func keyKey(_ serviceID: Int) -> String { "smapi.key.\(serviceID)" }

    // MARK: - Public API

    public func store(token: SMAPIToken) {
        authenticatedServices[token.serviceID] = token
        secrets.set(tokenKey(token.serviceID), token.authToken)
        secrets.set(keyKey(token.serviceID), token.privateKey)
        save()
    }

    public func getToken(for serviceID: Int) -> SMAPIToken? {
        guard var token = authenticatedServices[serviceID] else { return nil }
        if let t = secrets.get(tokenKey(serviceID)) { token.authToken = t }
        if let k = secrets.get(keyKey(serviceID)) { token.privateKey = k }
        return token
    }

    public func removeToken(for serviceID: Int) {
        authenticatedServices.removeValue(forKey: serviceID)
        secrets.set(tokenKey(serviceID), nil)
        secrets.set(keyKey(serviceID), nil)
        save()
    }

    public func updateToken(serviceID: Int, authToken: String, privateKey: String) {
        if var token = authenticatedServices[serviceID] {
            token.authToken = authToken
            token.privateKey = privateKey
            token.lastRefreshed = Date()
            authenticatedServices[serviceID] = token
            secrets.set(tokenKey(serviceID), authToken)
            secrets.set(keyKey(serviceID), privateKey)
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

}
