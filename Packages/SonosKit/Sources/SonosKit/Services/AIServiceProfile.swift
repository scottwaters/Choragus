/// AIServiceProfile.swift — User-named AI services for the Playlist Builder.
///
/// A profile is a provider + model (+ endpoint for custom servers) under a
/// name the user picks; the Playlist Builder's source menu lists profiles
/// by that name. The API key never sits in the profile — it lives in the
/// keychain under `apiKeySecretName`, keyed by the profile's id, so three
/// custom servers can each carry their own key.
import Foundation

public struct AIServiceProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var provider: SongListAIProvider
    public var model: String
    /// Chat-completions base URL; used by `.custom` only.
    public var baseURL: String
    /// True after a Settings connection test passed; cleared by any
    /// edit to model, endpoint, or key.
    public var verified: Bool

    public init(id: UUID = UUID(), name: String, provider: SongListAIProvider,
                model: String, baseURL: String = "", verified: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.verified = verified
    }

    public var apiKeySecretName: String { "aiProfile.\(id.uuidString)" }

    /// Menu labels stay readable; longer names are cut at entry.
    public static let maxNameLength = 40

    /// "Claude · claude-opus-5" — the list row's second line.
    public var subtitle: String {
        let detail = provider == .custom && !baseURL.isEmpty ? baseURL : model
        return detail.isEmpty ? provider.displayName : "\(provider.displayName) · \(detail)"
    }

    /// A fresh profile with the provider's defaults, named after the
    /// provider and numbered past any existing name clash.
    public static func template(_ provider: SongListAIProvider, existingNames: [String]) -> AIServiceProfile {
        let base = provider.displayName
        var name = base
        var n = 2
        while existingNames.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        let model: String
        switch provider {
        case .claude: model = SongListAIConfig.claudeDefaultModel
        case .openAI: model = SongListAIConfig.openAIDefaultModel
        case .custom: model = ""
        }
        return AIServiceProfile(name: name, provider: provider, model: model)
    }
}

/// The profile list and current selection, as JSON in UserDefaults.
/// Settings writes; the builder reads.
@MainActor
public enum AIServiceProfileStore {

    public static func load() -> [AIServiceProfile] {
        migrateLegacyIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: UDKey.playlistAIProfiles),
              let profiles = try? JSONDecoder().decode([AIServiceProfile].self, from: data) else { return [] }
        // Names longer than the cap are cut on load so they cannot
        // overflow menus.
        return profiles.map { profile in
            var p = profile
            p.name = String(p.name.prefix(AIServiceProfile.maxNameLength))
            return p
        }
    }

    public static func save(_ profiles: [AIServiceProfile]) {
        let data = (try? JSONEncoder().encode(profiles)) ?? Data()
        UserDefaults.standard.set(data, forKey: UDKey.playlistAIProfiles)
    }

    public static var selectedID: UUID? {
        get { UserDefaults.standard.string(forKey: UDKey.playlistAISelectedProfile).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: UDKey.playlistAISelectedProfile) }
    }

    /// The selected profile, or the first one when the selection is
    /// missing or stale.
    public static func selected() -> AIServiceProfile? {
        let profiles = load()
        return profiles.first { $0.id == selectedID } ?? profiles.first
    }

    /// One-time move of the pre-profile settings (a single provider with
    /// per-provider keys) into a profile carrying the same values and
    /// key. Runs once: an existing profiles entry, even an empty one,
    /// means it already ran.
    static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UDKey.playlistAIProfiles) == nil else { return }
        // A locked keychain reads as "no key"; leave the migration for a
        // later launch rather than stamping it done without the key.
        guard SecretsStore.shared.isReadable else { return }
        defer { if defaults.object(forKey: UDKey.playlistAIProfiles) == nil { save([]) } }
        // An absent provider is the pre-profile default (Claude), not
        // "unset".
        let provider = defaults.string(forKey: UDKey.playlistAIProvider)
            .flatMap(SongListAIProvider.init(rawValue:)) ?? .claude
        let legacyKey = SecretsStore.shared.get(provider.legacyAPIKeySecretName) ?? ""
        let touched = defaults.object(forKey: UDKey.playlistAIProvider) != nil
            || defaults.bool(forKey: UDKey.playlistAIEnabled)
        // Nothing configured: no profile to carry over.
        guard touched || !legacyKey.isEmpty else { return }
        var profile = AIServiceProfile.template(provider, existingNames: [])
        switch provider {
        case .claude:
            profile.model = defaults.string(forKey: UDKey.playlistAIClaudeModel) ?? profile.model
        case .openAI:
            profile.model = defaults.string(forKey: UDKey.playlistAIOpenAIModel) ?? profile.model
        case .custom:
            profile.model = defaults.string(forKey: UDKey.playlistAICustomModel) ?? ""
            profile.baseURL = defaults.string(forKey: UDKey.playlistAICustomBaseURL) ?? ""
        }
        profile.verified = defaults.bool(forKey: UDKey.playlistAIVerified)
        if !legacyKey.isEmpty {
            SecretsStore.shared.set(profile.apiKeySecretName, legacyKey)
            SecretsStore.shared.set(provider.legacyAPIKeySecretName, nil)
        }
        save([profile])
        selectedID = profile.id
    }
}
