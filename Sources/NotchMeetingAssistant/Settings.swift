import Foundation
import Security
import NotchCore

struct MeetingApplication: Identifiable { let id: String; let name: String }

struct UserSettings: Codable {
    var answerMode: AnswerMode = .automatic
    var outputMode: OutputMode = .text
    var autoDelay = 1.2
    var model = AnswerClient.astraModel
    var ultrafast: Bool? = true
    var locale = "en-US"
    var includeMicrophone = true
    var onDeviceOnly = false
    var applicationID = ""
    var voiceRate = 0.48
    var audioSource: AudioSource = .microphone
    var assistance: QuestionAssistance = .suggest
    var transcription = TranscriptionConfiguration()
    var providers = ProviderKind.allCases.map { ProviderConfiguration(kind: $0) }
    var routes: [String: ModelRoute] = [:]
    var automaticSummary = true
    init() {}
    private enum CodingKeys: String, CodingKey {
        case answerMode, outputMode, autoDelay, model, ultrafast, locale, includeMicrophone, onDeviceOnly, applicationID, voiceRate
        case audioSource, assistance, transcription, providers, routes, automaticSummary
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answerMode = try c.decodeIfPresent(AnswerMode.self, forKey: .answerMode) ?? answerMode
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? outputMode
        autoDelay = try c.decodeIfPresent(Double.self, forKey: .autoDelay) ?? autoDelay
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        ultrafast = try c.decodeIfPresent(Bool.self, forKey: .ultrafast) ?? ultrafast
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? locale
        includeMicrophone = try c.decodeIfPresent(Bool.self, forKey: .includeMicrophone) ?? includeMicrophone
        onDeviceOnly = try c.decodeIfPresent(Bool.self, forKey: .onDeviceOnly) ?? onDeviceOnly
        applicationID = try c.decodeIfPresent(String.self, forKey: .applicationID) ?? applicationID
        voiceRate = try c.decodeIfPresent(Double.self, forKey: .voiceRate) ?? voiceRate
        audioSource = try c.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? .microphone
        assistance = try c.decodeIfPresent(QuestionAssistance.self, forKey: .assistance) ?? (answerMode == .manual ? .detect : .suggest)
        transcription = try c.decodeIfPresent(TranscriptionConfiguration.self, forKey: .transcription) ?? transcription
        if let saved = try c.decodeIfPresent([ProviderConfiguration].self, forKey: .providers) { providers = saved }
        else if let index = providers.firstIndex(where: { $0.kind == .openai }) {
            providers[index].model = model; providers[index].ultrafast = ultrafast == true
        }
        routes = try c.decodeIfPresent([String: ModelRoute].self, forKey: .routes) ?? routes
        automaticSummary = try c.decodeIfPresent(Bool.self, forKey: .automaticSummary) ?? automaticSummary
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "preferences"), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.autoDelay = value.autoDelay.isFinite ? min(4, max(0.7, value.autoDelay)) : 1.2
        value.voiceRate = value.voiceRate.isFinite ? min(0.65, max(0.35, value.voiceRate)) : 0.48
        value.transcription.chunkSeconds = value.transcription.chunkSeconds.isFinite ? min(12, max(3, value.transcription.chunkSeconds)) : 6
        for kind in ProviderKind.allCases where !value.providers.contains(where: { $0.kind == kind }) { value.providers.append(ProviderConfiguration(kind: kind)) }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "preferences") }
    }
}

enum APIKeyStore {
    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.luvi.notchmeetingassistant",
         kSecAttrAccount as String: provider == ProviderKind.openai.rawValue ? "openai-api-key" : "provider:\(provider)"]
    }
    static func load(_ provider: String = ProviderKind.openai.rawValue) throws -> String {
        var query = query(provider)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AssistantError("Could not read the provider key from Keychain (\(status)).")
        }
        return value
    }
    static func save(_ value: String, provider: String = ProviderKind.openai.rawValue) throws {
        let data = Data(try AnswerClient.validatedKey(value).utf8)
        let query = query(provider)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantError("Could not save the provider key in Keychain (\(status)).") }
    }
    static func remove(_ provider: String = ProviderKind.openai.rawValue) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError("Could not remove the provider key (\(status)).") }
    }
}
