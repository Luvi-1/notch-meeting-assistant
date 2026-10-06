import Foundation
import Security
import NotchCore

struct MeetingApplication: Identifiable { let id: String; let name: String }

struct UserSettings: Codable {
    var outputMode: OutputMode = .text
    var questionAssistance: QuestionAssistance = .suggest
    var autoDelay = 1.2
    var locale = "en-US"
    var includeMicrophone = true
    var captureSystemAudio = false
    var onDeviceOnly = false
    var applicationID = ""
    var voiceRate = 0.48
    var silenceThreshold = 0.001
    var transcription = TranscriptionConfiguration()
    var providers = AIProvider.allCases.map { ProviderConfiguration($0, model: $0 == .openai ? "gpt-6-astra" : "") }
    var assignments: [String: ModelAssignment] = [:]
    var generateSummaries = true
    var saveSessions = true
    var backgroundContext = ""
    init() {}
    private enum CodingKeys: String, CodingKey {
        case outputMode, questionAssistance, autoDelay, locale, includeMicrophone, captureSystemAudio, onDeviceOnly, applicationID, voiceRate, silenceThreshold
        case transcription, providers, assignments, generateSummaries, saveSessions, backgroundContext
        case model, ultrafast, answerMode
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? outputMode
        questionAssistance = try c.decodeIfPresent(QuestionAssistance.self, forKey: .questionAssistance)
            ?? ((try c.decodeIfPresent(AnswerMode.self, forKey: .answerMode)) == .automatic ? .automatic : .suggest)
        autoDelay = try c.decodeIfPresent(Double.self, forKey: .autoDelay) ?? autoDelay
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? locale
        // The first companion launch defaults to microphone listening; system audio is an explicit input option.
        if c.contains(.captureSystemAudio) {
            includeMicrophone = try c.decodeIfPresent(Bool.self, forKey: .includeMicrophone) ?? true
            captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? false
        }
        onDeviceOnly = try c.decodeIfPresent(Bool.self, forKey: .onDeviceOnly) ?? onDeviceOnly
        applicationID = try c.decodeIfPresent(String.self, forKey: .applicationID) ?? applicationID
        voiceRate = try c.decodeIfPresent(Double.self, forKey: .voiceRate) ?? voiceRate
        silenceThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceThreshold) ?? silenceThreshold
        transcription = try c.decodeIfPresent(TranscriptionConfiguration.self, forKey: .transcription) ?? transcription
        assignments = try c.decodeIfPresent([String: ModelAssignment].self, forKey: .assignments) ?? assignments
        if let saved = try c.decodeIfPresent([ProviderConfiguration].self, forKey: .providers) {
            providers = AIProvider.allCases.map { provider in saved.first(where: { $0.provider == provider }) ?? ProviderConfiguration(provider) }
        } else {
            let oldModel = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-6-astra"
            providers[0].model = oldModel
            providers[0].ultrafast = try c.decodeIfPresent(Bool.self, forKey: .ultrafast) ?? false
            assignments[AITask.liveQuestion.rawValue] = ModelAssignment(provider: .openai, model: oldModel)
        }
        generateSummaries = try c.decodeIfPresent(Bool.self, forKey: .generateSummaries) ?? true
        saveSessions = try c.decodeIfPresent(Bool.self, forKey: .saveSessions) ?? true
        backgroundContext = try c.decodeIfPresent(String.self, forKey: .backgroundContext) ?? ""
        autoDelay = autoDelay.isFinite ? min(4, max(0.7, autoDelay)) : 1.2
        voiceRate = voiceRate.isFinite ? min(0.65, max(0.35, voiceRate)) : 0.48
        silenceThreshold = silenceThreshold.isFinite ? min(0.02, max(0, silenceThreshold)) : 0.001
        transcription.chunkSeconds = transcription.chunkSeconds.isFinite ? min(20, max(2, transcription.chunkSeconds)) : 6
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outputMode, forKey: .outputMode); try c.encode(questionAssistance, forKey: .questionAssistance)
        try c.encode(autoDelay, forKey: .autoDelay); try c.encode(locale, forKey: .locale)
        try c.encode(includeMicrophone, forKey: .includeMicrophone); try c.encode(captureSystemAudio, forKey: .captureSystemAudio)
        try c.encode(onDeviceOnly, forKey: .onDeviceOnly); try c.encode(applicationID, forKey: .applicationID)
        try c.encode(voiceRate, forKey: .voiceRate); try c.encode(silenceThreshold, forKey: .silenceThreshold)
        try c.encode(transcription, forKey: .transcription); try c.encode(providers, forKey: .providers)
        try c.encode(assignments, forKey: .assignments); try c.encode(generateSummaries, forKey: .generateSummaries)
        try c.encode(saveSessions, forKey: .saveSessions); try c.encode(backgroundContext, forKey: .backgroundContext)
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "preferences"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "preferences") }
    }
    func configuration(for task: AITask, available: Set<AIProvider>) throws -> ProviderConfiguration {
        let assignment = assignments[task.rawValue] ?? ModelAssignment()
        if let provider = assignment.provider {
            guard available.contains(provider), var config = providers.first(where: { $0.provider == provider }) else { throw AssistantError("Configure \(provider.title) for \(task.rawValue) in Settings.") }
            if !assignment.model.isEmpty { config.model = assignment.model }
            guard !config.model.isEmpty else { throw AssistantError("Choose a model for \(task.rawValue).") }
            return config
        }
        for provider in task.preference where available.contains(provider) {
            if let config = providers.first(where: { $0.provider == provider }), !config.model.isEmpty { return config }
        }
        throw AssistantError("Connect an AI provider in Settings. Listening and local notes still work without one.")
    }
}

enum APIKeyStore {
    static func account(_ provider: AIProvider) -> String { provider.rawValue + "-api-key" }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.luvi.notchmeetingassistant", kSecAttrAccount as String: account]
    }
    static func load(account: String = "openai-api-key") throws -> String {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = "Use the saved provider key for Notch"
        q[kSecUseOperationPrompt as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw AssistantError("Could not read the provider key from Keychain (\(status)).") }
        return key
    }
    static func save(_ value: String, account: String = "openai-api-key") throws {
        let data = Data(try ProviderNetwork.key(value).utf8)
        let q = query(account)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantError("Could not save the provider key to Keychain (\(status)).") }
    }
    static func remove(account: String = "openai-api-key") throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError("Could not remove the key from Keychain (\(status)).") }
    }
}
