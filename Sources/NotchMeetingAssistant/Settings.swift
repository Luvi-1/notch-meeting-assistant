import Foundation
import Security
import NotchCore

struct MeetingApplication: Identifiable {
    let id: String
    let name: String
}

struct UserSettings: Codable {
    var answerMode: AnswerMode = .automatic
    var outputMode: OutputMode = .text
    var autoDelay = 1.8
    var model = "gpt-4.1-mini"
    var locale = "en-US"
    var includeMicrophone = false
    var onDeviceOnly = false
    var applicationID = ""
    var voiceRate = 0.48

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "preferences"),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.autoDelay = value.autoDelay.isFinite ? min(4, max(0.7, value.autoDelay)) : 1.8
        value.voiceRate = value.voiceRate.isFinite ? min(0.65, max(0.35, value.voiceRate)) : 0.48
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "preferences") }
    }
}

enum APIKeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.luvi.notchmeetingassistant",
         kSecAttrAccount as String: "openai-api-key"]
    }

    static func load() throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else {
            throw AssistantError("Could not read the API key from Keychain (\(status)).")
        }
        return text
    }

    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AssistantError("Could not save the API key to Keychain (\(status)).")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AssistantError("Could not remove the API key from Keychain (\(status)).")
        }
    }
}
