import XCTest
import NotchCore
@testable import NotchMeetingAssistant

final class ProviderConfigurationFlowTests: XCTestCase {
    @MainActor
    func testEditingAnOpenAIChatConfigurationPreservesItsProtocol() async throws {
        let model = MeetingModel(previewSessions: [])
        let chat = ProviderConfiguration(id: .openAI, model: "my-chat-model", enabled: true, apiProtocol: .chatCompletions)
        model.updateProviderConfiguration(chat)
        var edited = try XCTUnwrap(model.settings.providers.first(where: { $0.id == .openAI }))
        XCTAssertEqual(edited.apiProtocol, .chatCompletions)
        edited.model = "another-chat-model"
        edited.enabled = false
        model.updateProviderConfiguration(edited)
        let stored = try XCTUnwrap(model.settings.providers.first(where: { $0.id == .openAI }))
        XCTAssertEqual(stored.apiProtocol, .chatCompletions)
        XCTAssertEqual(stored.model, "another-chat-model")
        XCTAssertFalse(stored.enabled)
    }

    @MainActor
    func testSpeechProviderChangesCannotAlterAnActiveCaptureConfiguration() async {
        let session = ListeningSession()
        let model = MeetingModel(previewSessions: [session], activeSessionID: session.id)
        let original = TranscriptionConfiguration(provider: .groq, model: "whisper-large-v3", language: "hi", autoDetectLanguage: false)
        model.settings.transcription = original
        model.setTranscriptionProvider(.openAI)
        XCTAssertEqual(model.settings.transcription, original)
        model.resetTranscriptionConfiguration()
        XCTAssertEqual(model.settings.transcription, original)
    }
}
