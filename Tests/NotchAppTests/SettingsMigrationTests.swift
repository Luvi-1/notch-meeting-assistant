import XCTest
import NotchCore
@testable import NotchMeetingAssistant

final class SettingsMigrationTests: XCTestCase {
    func testLegacyPreferencesKeepAudioModelAndManualIntent() throws {
        let json = #"{"answerMode":"Manual","outputMode":"Both","autoDelay":2.0,"model":"custom-model","ultrafast":true,"locale":"hi-IN","includeMicrophone":false,"onDeviceOnly":true,"applicationID":"example.app","voiceRate":0.5}"#
        let value = try JSONDecoder().decode(UserSettings.self, from: Data(json.utf8))
        XCTAssertTrue(value.captureSystemAudio)
        XCTAssertFalse(value.includeMicrophone)
        XCTAssertEqual(value.locale, "hi-IN")
        XCTAssertEqual(value.questionAssistance, .detectOnly)
        XCTAssertEqual(value.outputMode, .both)
        XCTAssertEqual(value.providers.first(where: { $0.id == .openAI })?.model, "custom-model")
        XCTAssertEqual(value.providers.first(where: { $0.id == .openAI })?.enabled, true)
        XCTAssertEqual(value.transcription.provider, .auto)
    }

    func testFreshSetupUsesMicrophoneWithoutScreenCapture() {
        let value = UserSettings()
        XCTAssertTrue(value.includeMicrophone)
        XCTAssertFalse(value.captureSystemAudio)
        XCTAssertEqual(value.questionAssistance, .suggestedAnswer)
        XCTAssertEqual(value.outputMode, .text)
        XCTAssertEqual(value.transcription.provider, .auto)
        XCTAssertEqual(value.ultrafast, false)
    }

    func testNewTaskRoutingAndProviderConfigurationRoundTrip() throws {
        var value = UserSettings()
        value.captureSystemAudio = true
        value.taskModels[AITask.liveQuestion.rawValue] = ModelSelection(provider: .gemini, model: "my-selected-model")
        value.transcription = TranscriptionConfiguration(provider: .groq, model: "whisper-large-v3", language: "hi", autoDetectLanguage: false)
        value.providers[0].enabled = true
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertEqual(restored.taskModels, value.taskModels)
        XCTAssertEqual(restored.transcription, value.transcription)
        XCTAssertEqual(restored.providers, value.providers)
        XCTAssertEqual(restored.captureSystemAudio, true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["apiKey"])
        XCTAssertNil(object["keys"])
    }

    func testSavedGroqSpeechRepairsOpenAIModelAndHiddenEndpoint() throws {
        var value = UserSettings()
        value.transcription = TranscriptionConfiguration(provider: .groq, model: "whisper-1",
                                                         baseURL: "https://api.openai.com/v1", language: "hi", autoDetectLanguage: false)
        let restored = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.transcription.provider, .groq)
        XCTAssertEqual(restored.transcription.resolvedBaseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(restored.transcription.resolvedModel, "whisper-large-v3-turbo")
        XCTAssertEqual(restored.transcription.language, "hi")
        XCTAssertFalse(restored.transcription.autoDetectLanguage)

        value.transcription = TranscriptionConfiguration(provider: .openAI, model: "whisper-large-v3",
                                                         baseURL: "https://api.groq.com/openai/v1/audio/transcriptions")
        let openAI = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(openAI.transcription.resolvedModel, "whisper-1")
        XCTAssertEqual(openAI.transcription.resolvedBaseURL, "https://api.openai.com/v1")
    }

    func testGroqConnectionMigrationKeepsModelRoutingAndEnabledState() throws {
        var value = UserSettings()
        let index = try XCTUnwrap(value.providers.firstIndex(where: { $0.id == .groq }))
        value.providers[index] = ProviderConfiguration(id: .groq, baseURL: "https://api.groq.com/openai/v1/chat/completions",
                                                       model: "my-selected-model", enabled: true, apiProtocol: .anthropicMessages)
        value.taskModels[AITask.liveQuestion.rawValue] = ModelSelection(provider: .groq, model: "my-task-model")
        let restored = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(value))
        let groq = try XCTUnwrap(restored.providers.first(where: { $0.id == .groq }))
        XCTAssertEqual(groq.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(groq.apiProtocol, .chatCompletions)
        XCTAssertEqual(groq.model, "my-selected-model")
        XCTAssertTrue(groq.enabled)
        XCTAssertEqual(restored.taskModels, value.taskModels)
        let again = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(again.providers, restored.providers)
        XCTAssertEqual(again.transcription, restored.transcription)
    }

    func testMigrationPreservesCustomEndpointsAndDoesNotUpgradeUnsafeGroqURL() throws {
        var value = UserSettings()
        let custom = try XCTUnwrap(value.providers.firstIndex(where: { $0.id == .custom }))
        value.providers[custom] = ProviderConfiguration(id: .custom, baseURL: "http://127.0.0.1:8080/v1",
                                                        model: "local-model", enabled: true, apiProtocol: .responses)
        value.transcription = TranscriptionConfiguration(provider: .custom, model: "local-whisper",
                                                         baseURL: "http://127.0.0.1:8081/v1", language: "en", autoDetectLanguage: false)
        let groq = try XCTUnwrap(value.providers.firstIndex(where: { $0.id == .groq }))
        value.providers[groq].baseURL = "http://api.groq.com/openai/v1"
        let restored = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.providers[custom], value.providers[custom])
        XCTAssertEqual(restored.transcription, value.transcription)
        XCTAssertEqual(restored.providers[groq].baseURL, value.providers[groq].baseURL)
        XCTAssertThrowsError(try LLMService(configuration: restored.providers[groq], key: "fixture-key").makeRequest(system: "", user: "Hi"))
    }
}
