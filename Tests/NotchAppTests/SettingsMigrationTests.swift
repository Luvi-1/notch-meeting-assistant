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
}
