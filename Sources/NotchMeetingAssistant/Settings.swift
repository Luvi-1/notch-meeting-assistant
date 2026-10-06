import Foundation
import Security
import NotchCore

struct MeetingApplication: Identifiable {
    let id: String
    let name: String
}

enum CompanionDestination: String, CaseIterable, Identifiable {
    case home = "Home", sessions = "Sessions", notes = "Notes", search = "Search", settings = "Settings"
    var id: String { rawValue }
}

enum QuestionAssistance: String, CaseIterable, Codable, Identifiable {
    case off, detectOnly, suggestedAnswer, automaticAnswer
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .detectOnly: return "Detect only"
        case .suggestedAnswer: return "Detect + suggested answer"
        case .automaticAnswer: return "Automatically answer questions"
        }
    }
}

/// Preferences contain configuration only. All credentials live in Keychain.
struct UserSettings: Codable {
    var answerMode: AnswerMode = .automatic
    var outputMode: OutputMode = .text
    var autoDelay = 1.2
    var model = AnswerClient.astraModel
    var ultrafast: Bool? = false
    var locale = "en-US"
    var includeMicrophone = true
    var captureSystemAudio = false
    var onDeviceOnly = false
    var applicationID = ""
    var voiceRate = 0.48
    var questionAssistance: QuestionAssistance = .suggestedAnswer
    var providers = ProviderConfiguration.defaults
    var taskModels: [String: ModelSelection] = [:]
    var transcription = TranscriptionConfiguration()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case answerMode, outputMode, autoDelay, model, ultrafast, locale, includeMicrophone
        case captureSystemAudio, onDeviceOnly, applicationID, voiceRate, questionAssistance
        case providers, taskModels, transcription
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        answerMode = try values.decodeIfPresent(AnswerMode.self, forKey: .answerMode) ?? .automatic
        outputMode = try values.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .text
        autoDelay = try values.decodeIfPresent(Double.self, forKey: .autoDelay) ?? 1.2
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? AnswerClient.astraModel
        ultrafast = try values.decodeIfPresent(Bool.self, forKey: .ultrafast) ?? false
        locale = try values.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
        includeMicrophone = try values.decodeIfPresent(Bool.self, forKey: .includeMicrophone) ?? true
        // Preserve the old app's chosen system-audio setup when migrating saved preferences.
        captureSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        onDeviceOnly = try values.decodeIfPresent(Bool.self, forKey: .onDeviceOnly) ?? false
        applicationID = try values.decodeIfPresent(String.self, forKey: .applicationID) ?? ""
        voiceRate = try values.decodeIfPresent(Double.self, forKey: .voiceRate) ?? 0.48
        questionAssistance = try values.decodeIfPresent(QuestionAssistance.self, forKey: .questionAssistance)
            ?? (answerMode == .manual ? .detectOnly : .suggestedAnswer)
        providers = try values.decodeIfPresent([ProviderConfiguration].self, forKey: .providers)
            ?? ProviderConfiguration.defaults
        if !values.contains(.providers), let index = providers.firstIndex(where: { $0.id == .openAI }) {
            providers[index].model = model
            providers[index].ultrafast = ultrafast == true
            providers[index].enabled = true
        }
        for candidate in ProviderConfiguration.defaults where !providers.contains(where: { $0.id == candidate.id }) {
            providers.append(candidate)
        }
        providers = providers.map { $0.repairedSavedConfiguration() }
        taskModels = try values.decodeIfPresent([String: ModelSelection].self, forKey: .taskModels) ?? [:]
        transcription = try values.decodeIfPresent(TranscriptionConfiguration.self, forKey: .transcription)
            ?? TranscriptionConfiguration()
        transcription = transcription.repairedSavedConfiguration()
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "preferences"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.autoDelay = value.autoDelay.isFinite ? min(4, max(0.7, value.autoDelay)) : 1.2
        value.voiceRate = value.voiceRate.isFinite ? min(0.65, max(0.35, value.voiceRate)) : 0.48
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "preferences")
        }
    }
}

enum APIKeyStore {
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.luvi.notchmeetingassistant",
         kSecAttrAccount as String: account]
    }

    private static func account(for provider: AIProviderID) -> String {
        // Keep the original account name so existing OpenAI credentials migrate without copying.
        provider == .openAI ? "openai-api-key" : "provider-\(provider.rawValue)-api-key"
    }

    static func load(provider: AIProviderID = .openAI) throws -> String {
        try load(account: account(for: provider))
    }

    static func save(_ value: String, provider: AIProviderID = .openAI) throws {
        try save(value, account: account(for: provider))
    }

    static func remove(provider: AIProviderID = .openAI) throws {
        try remove(account: account(for: provider))
    }

    static func loadTranscriptionKey() throws -> String { try load(account: "custom-transcription-api-key") }
    static func saveTranscriptionKey(_ value: String) throws { try save(value, account: "custom-transcription-api-key") }
    static func removeTranscriptionKey() throws { try remove(account: "custom-transcription-api-key") }

    private static func load(account: String) throws -> String {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else {
            throw AssistantError("Could not read the API credential from Keychain (\(status)).")
        }
        return text
    }

    private static func save(_ value: String, account: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4_096,
              key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AssistantError("Enter a valid API key without spaces or line breaks.")
        }
        let data = Data(key.utf8)
        let query = query(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AssistantError("Could not save the API credential to Keychain (\(status)).")
        }
    }

    private static func remove(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantError("Could not remove the API credential from Keychain (\(status)).")
        }
    }
}
