import Foundation
import Observation
import Security
import RecipeCore

/// Which AI does the recipe extraction.
enum AIEngine: String, CaseIterable, Identifiable {
    /// Apple Intelligence on the iPhone — free, private, offline.
    case onDevice
    /// The user's own API key (Claude or an OpenAI-compatible provider) — paid by the user, more accurate.
    case cloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: "Apple Intelligence (free)"
        case .cloud: "My own API"
        }
    }
}

/// AI settings. Choices live in UserDefaults; API keys live only in the Keychain (this device only,
/// never synced, never written to logs, exports or the repo).
@MainActor
@Observable
final class AISettings {
    var engine: AIEngine {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }
    var provider: CloudProvider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }
    var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: Keys.anthropicModel) }
    }
    var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Keys.openAIModel) }
    }
    var openAIBaseURL: String {
        didSet { defaults.set(openAIBaseURL, forKey: Keys.openAIBaseURL) }
    }
    /// Whether a key is stored for each provider (the key itself is never kept in memory here).
    private(set) var hasKey: [CloudProvider: Bool] = [:]

    /// Tokens used by cloud calls since the app started (for Diagnostics).
    private(set) var sessionUsage = TokenUsage(inputTokens: 0, outputTokens: 0)
    private(set) var sessionCalls = 0

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let engine = "ai.engine"
        static let provider = "ai.provider"
        static let anthropicModel = "ai.anthropic.model"
        static let openAIModel = "ai.openai.model"
        static let openAIBaseURL = "ai.openai.baseURL"
    }

    init() {
        engine = AIEngine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .onDevice
        provider = CloudProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .anthropic
        anthropicModel = defaults.string(forKey: Keys.anthropicModel) ?? ClaudeModelPreset.haiku.rawValue
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? ""
        openAIBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? EndpointPreset.all[0].baseURL
        for provider in CloudProvider.allCases {
            hasKey[provider] = KeychainStore.read(account: provider.rawValue) != nil
        }
    }

    // MARK: - Keys

    func saveKey(_ key: String, for provider: CloudProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(trimmed, account: provider.rawValue)
        hasKey[provider] = KeychainStore.read(account: provider.rawValue) != nil
        AppLog.shared.log("ai", "API key saved for \(provider.displayName)")   // never log the key
    }

    func deleteKey(for provider: CloudProvider) {
        KeychainStore.delete(account: provider.rawValue)
        hasKey[provider] = false
        AppLog.shared.log("ai", "API key removed for \(provider.displayName)")
    }

    // MARK: - Current configuration

    var model: String {
        provider == .anthropic ? anthropicModel : openAIModel
    }

    /// The cloud configuration, with the key read from the Keychain. Nil when no key is stored.
    func cloudConfig() -> CloudConfig? {
        guard let key = KeychainStore.read(account: provider.rawValue) else { return nil }
        return CloudConfig(provider: provider, model: model, baseURL: openAIBaseURL, apiKey: key)
    }

    /// Short description for logs and Diagnostics (never includes the key).
    var cloudLabel: String {
        CloudConfig(provider: provider, model: model, baseURL: openAIBaseURL, apiKey: "").label
    }

    /// Makes the cloud extractor, recording token usage. Throws a readable error when not set up.
    func makeCloudExtractor() throws -> CloudExtractor {
        guard let config = cloudConfig() else { throw CloudAPIError.missingKey }
        return try CloudExtractor(config: config) { [weak self] usage in
            Task { @MainActor in self?.record(usage) }
        }
    }

    private func record(_ usage: TokenUsage) {
        sessionCalls += 1
        sessionUsage.inputTokens += usage.inputTokens
        sessionUsage.outputTokens += usage.outputTokens
    }
}

/// Minimal Keychain wrapper for API keys (generic passwords, this device only, after first unlock).
enum KeychainStore {
    private static let service = "RecipeReel.apiKey"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.shared.log("ai", "Keychain save failed (OSStatus \(status))")
        }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
