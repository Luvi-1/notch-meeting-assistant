import XCTest
import SwiftUI
import AppKit
import NotchCore
@testable import NotchMeetingAssistant

@MainActor
final class AppTests: XCTestCase {
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("notch-app-test-" + UUID().uuidString) }
    private func waitForLoad(_ model: MeetingModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isLoadingSessions && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.isLoadingSessions)
    }
    private func fixture() -> ListeningSession {
        let date = Date(timeIntervalSince1970: 1_791_220_000)
        var session = ListeningSession(startedAt: date)
        session.title = "Sample lecture · Price elasticity"; session.kind = "Lecture"; session.topic = "Price elasticity and time horizons"; session.endedAt = date.addingTimeInterval(1200)
        var first = SessionSegment(time: date, source: "Microphone", text: "Price elasticity measures how much demand changes when the price changes.", speaker: "Professor (sample)")
        first.categories = [.definition, .important]
        var second = SessionSegment(time: date.addingTimeInterval(120), source: "Microphone", text: "Why does elasticity change depending on the time horizon", speaker: "Student (sample)")
        second.categories = [.question]
        var third = SessionSegment(time: date.addingTimeInterval(180), source: "Microphone", text: "Over time, people have more opportunities to find substitutes. Remember this distinction for the exam.", speaker: "Professor (sample)")
        third.categories = [.explanation, .exam]
        session.segments = [first, second, third]
        var question = SessionQuestion(segmentID: second.id, text: second.text, time: second.time)
        question.answer = "Over time, people can find substitutes and adjust their habits, so demand often becomes more elastic."
        session.questions = [question]
        session.summary = SessionSummary(title: session.title, kind: "Lecture", overview: "This synthetic test lecture introduces price elasticity and how the time available to adjust changes consumer responses.", sections: [
            SummarySection(title: "Key Concepts", body: "Elasticity describes how responsive quantity demanded is to a price change.", sources: [first.id]),
            SummarySection(title: "Things to Review", body: "Compare the short-run and long-run responses to a price change.", sources: [third.id])
        ])
        return session
    }
    func testLegacySettingsMigrateWithoutLosingAstraAndTaskOverrides() throws {
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"model":"gpt-6-astra","ultrafast":true,"answerMode":"Automatic","includeMicrophone":false,"outputMode":"Both"}"#.utf8))
        XCTAssertTrue(settings.includeMicrophone); XCTAssertFalse(settings.captureSystemAudio)
        XCTAssertEqual(settings.questionAssistance, .automatic); XCTAssertEqual(settings.outputMode, .both)
        let selected = try settings.configuration(for: .liveQuestion, available: [.openai])
        XCTAssertEqual(selected.model, "gpt-6-astra"); XCTAssertTrue(selected.ultrafast)
        var changed = settings
        changed.assignments[AITask.summary.rawValue] = ModelAssignment(provider: .anthropic, model: "claude-test")
        XCTAssertThrowsError(try changed.configuration(for: .summary, available: [.openai]))
        XCTAssertEqual(try changed.configuration(for: .summary, available: [.anthropic]).model, "claude-test")
        let encoded = String(decoding: try JSONEncoder().encode(changed), as: UTF8.self)
        XCTAssertFalse(encoded.contains("apiKey")); XCTAssertFalse(encoded.contains("api-key"))
    }
    func testSavedSessionActionsSurviveReloadAndDeleteOnlyThatSession() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory); let session = fixture()
        try await repository.save(session)
        let oldPreferences = UserDefaults.standard.data(forKey: "preferences")
        defer { UserDefaults.standard.set(oldPreferences, forKey: "preferences") }
        let model = MeetingModel(directory: directory, readCredentials: false)
        try await waitForLoad(model)
        model.settings = UserSettings(); model.selectedSessionID = session.id
        XCTAssertTrue(model.canAnswer)
        XCTAssertTrue(model.keyDraft.isEmpty); XCTAssertTrue(model.keyedProviders.isEmpty)
        model.bookmark(session.segments[0].id, sessionID: session.id)
        model.addNote("Review this definition", sessionID: session.id, segmentID: session.segments[0].id)
        model.renameSession(session.id, title: "Economics review")
        model.labelSpeaker(session.segments[0].id, sessionID: session.id, name: "My professor")
        model.settings.questionAssistance = .detect
        model.presentQuestion(session.questions[0], sessionID: session.id)
        XCTAssertEqual(model.presentation.phase, .preview)
        XCTAssertFalse(model.isAnswering, "Detect-only must not generate an answer")
        model.saveNotice(); XCTAssertTrue(model.notice?.saved == true)
        let saved = await model.shutdown(); XCTAssertTrue(saved)
        XCTAssertTrue(model.settings.generateSummaries, "Quitting must not change the user's summary preference")
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.sessions.first?.title, "Economics review")
        XCTAssertEqual(loaded.sessions.first?.notes.first?.text, "Review this definition")
        XCTAssertEqual(loaded.sessions.first?.segments.first?.speaker, "My professor")
        XCTAssertTrue(loaded.sessions.first?.segments.first?.bookmarked == true)
        XCTAssertTrue(loaded.sessions.first?.questions.first?.saved == true)
        await model.deleteSession(session.id)
        let afterDelete = try await repository.load(); XCTAssertTrue(afterDelete.sessions.isEmpty)
        XCTAssertTrue(model.sessions.isEmpty)
    }
    func testNoProviderOrConsentNeverPretendsToStartOrAnswer() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = MeetingModel(directory: directory, readCredentials: false)
        try await waitForLoad(model)
        XCTAssertFalse(model.canAnswer)
        await model.start()
        XCTAssertFalse(model.busyListening); XCTAssertNotNil(model.error)
        model.question = "Explain elasticity"
        XCTAssertTrue(model.canAnswer)
        model.requestAnswer()
        XCTAssertFalse(model.isAnswering); XCTAssertTrue(model.answer.isEmpty)
        XCTAssertEqual(model.destination, .settings)
        _ = await model.shutdown()
    }
    func testQuitRefusesToLoseASessionWhenPersistenceFails() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory); let session = fixture(); try await repository.save(session)
        let model = MeetingModel(directory: directory, readCredentials: false); try await waitForLoad(model)
        try FileManager.default.removeItem(at: directory)
        try Data("a file where the session directory should be".utf8).write(to: directory)
        let saved = await model.shutdown()
        XCTAssertFalse(saved); XCTAssertNotNil(model.error); XCTAssertEqual(model.sessions.count, 1)
        try FileManager.default.removeItem(at: directory)
        let recovered = await model.shutdown(); XCTAssertTrue(recovered)
    }
    func testRenderNativeViewsWithSyntheticSessionOnly() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["NOTCH_PREVIEW_DIR"] else { throw XCTSkip("Set NOTCH_PREVIEW_DIR to render native view previews") }
        _ = NSApplication.shared
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory); let session = fixture(); try await repository.save(session)
        let oldPreferences = UserDefaults.standard.data(forKey: "preferences")
        defer { UserDefaults.standard.set(oldPreferences, forKey: "preferences") }
        let model = MeetingModel(directory: directory, readCredentials: false); try await waitForLoad(model)
        model.settings = UserSettings(); model.hasConsent = true
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await render(LibraryView(model: model), size: NSSize(width: 1040, height: 730), appearance: .aqua, file: output.appendingPathComponent("home-light.png"))
        try await render(LibraryView(model: model), size: NSSize(width: 1040, height: 730), appearance: .darkAqua, file: output.appendingPathComponent("home-dark.png"))
        model.destination = .sessions; model.selectedSessionID = session.id
        try await render(LibraryView(model: model), size: NSSize(width: 1040, height: 730), appearance: .aqua, file: output.appendingPathComponent("session.png"))
        model.destination = .settings
        try await render(LibraryView(model: model), size: NSSize(width: 800, height: 570), appearance: .aqua, file: output.appendingPathComponent("providers-small-window.png"))
        model.cutoutWidth = 185; model.cutoutHeight = 34; model.settings.questionAssistance = .detect
        model.presentQuestion(session.questions[0], sessionID: session.id)
        try await render(NotchView(model: model), size: NSSize(width: 640, height: 126), appearance: .darkAqua, file: output.appendingPathComponent("notch-question.png"))
        model.collapse(); model.detachedNotch = true; model.cutoutWidth = 0
        try await render(NotchView(model: model), size: NSSize(width: 206, height: 34), appearance: .darkAqua, file: output.appendingPathComponent("floating-compact.png"))
        try "Synthetic fixture renders only. No microphone, live API account, speaker identification or physical notch was exercised.\n".write(to: output.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        _ = await model.shutdown()
    }
    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let root = view.environment(\.colorScheme, scheme).environment(\.accessibilityReduceMotion, true).frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root); host.frame = NSRect(origin: .zero, size: size); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 20, y: 20), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 500)
        try data.write(to: file)
    }
}
