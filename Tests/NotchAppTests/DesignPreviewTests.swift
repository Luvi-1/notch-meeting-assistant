import AppKit
import SwiftUI
import XCTest
import NotchCore
@testable import NotchMeetingAssistant

/// Renders the shipping SwiftUI views with fictional, in-memory fixtures for design review.
/// This opt-in harness never opens capture, loads credentials, or calls a provider.
final class DesignPreviewTests: XCTestCase {
    @MainActor
    func testRenderNativeDesignPreviews() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCH_PREVIEW_DIRECTORY"], !directory.isEmpty else {
            throw XCTSkip("Set NOTCH_PREVIEW_DIRECTORY to render native design previews.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let sessions = Self.fixtureSessions()
        let model = MeetingModel(previewSessions: sessions)
        let size = NSSize(width: 900, height: 700)

        let empty = MeetingModel(previewSessions: [])
        try await render(CompanionWindow(model: empty), size: size, name: "01-home-empty", output: output)
        try await render(CompanionWindow(model: model), size: size, name: "02-home", output: output)

        model.destination = .sessions
        model.selectedSessionID = sessions[0].id
        try await render(CompanionWindow(model: model), size: size, name: "03-session-review", output: output)
        model.highlightedTranscriptID = sessions[0].transcript[0].id
        try await render(CompanionWindow(model: model), size: size, name: "04-transcript", output: output)

        model.destination = .notes
        try await render(CompanionWindow(model: model), size: size, name: "05-notes", output: output)
        model.destination = .search
        try await render(CompanionWindow(model: model), size: size, name: "06-memory", output: output)
        model.destination = .settings
        try await render(CompanionWindow(model: model), size: size, name: "07-settings", output: output)
        try await render(ProviderConfigurationView(model: model, provider: .groq),
                         size: NSSize(width: 600, height: 660), name: "08-groq", output: output)
        try await render(ProviderSettingsView(model: model, initialTab: .providers), size: size,
                         name: "11-ai-providers", output: output)
        model.setTranscriptionProvider(.groq)
        try await render(ProviderSettingsView(model: model, initialTab: .transcription), size: size,
                         name: "12-groq-transcription", output: output)

        var liveSession = sessions[0]
        liveSession.endedAt = nil
        let question = try XCTUnwrap(liveSession.moments.first(where: { $0.category == .question }))
        let live = MeetingModel(previewSessions: [liveSession], activeSessionID: liveSession.id,
                                question: question, answer: "People have more time to find alternatives, so demand becomes more elastic.")
        live.cutoutWidth = 185
        live.cutoutHeight = 34
        live.panelWidth = 690
        live.panelHeight = 120
        try await render(NotchView(model: live), size: NSSize(width: 690, height: 120),
                         name: "09-question-notch", output: output)
        live.collapse()
        live.panelWidth = 329
        live.panelHeight = 34
        try await render(NotchView(model: live), size: NSSize(width: 329, height: 34),
                         name: "10-listening-notch", output: output)

        let index = """
        # Native design previews

        Rendered from the app's actual SwiftUI views on macOS. Session text is fictional test data.
        No audio capture, provider credentials, network requests, or saved user sessions are involved.

        1. Empty Home
        2. Home with recent sessions
        3. Session review
        4. Transcript
        5. Notes
        6. Ask your memory
        7. Settings
        8. Groq configuration
        9. Horizontal question preview
        10. Compact listening indicator
        11. AI provider list
        12. Groq transcription settings

        These images verify rendered layout. They do not test live audio or physical-notch placement.
        """
        try index.write(to: output.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    @MainActor
    private func render<Content: View>(_ content: Content, size: NSSize, name: String, output: URL) async throws {
        let root = content
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(identifier: "America/Los_Angeles")!)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        // Allow SwiftUI navigation/onAppear and native controls to complete their first layout.
        try await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        host.displayIfNeeded()
        let bitmap: NSBitmapImageRep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png: Data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 250, "The rendered view should produce image data.")
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private static func fixtureSessions() -> [ListeningSession] {
        let start = Date(timeIntervalSince1970: 1_791_302_400)
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let lines = [
            TranscriptLine(source: "Microphone", text: "Price elasticity measures how much quantity demanded responds to a change in price.", time: start),
            TranscriptLine(source: "Microphone", text: "The important distinction is the time horizon. In the long run, people have more alternatives.", time: start.addingTimeInterval(90)),
            TranscriptLine(source: "Microphone", text: "Why does demand become more elastic over time?", time: start.addingTimeInterval(150)),
            TranscriptLine(source: "Microphone", text: "Think about a rise in the price of fuel. Today, you still need to get to class. Over a year, you might move closer or use transit.", time: start.addingTimeInterval(195)),
            TranscriptLine(source: "Microphone", text: "Remember the midpoint formula for the exam. Assignment three is due Friday.", time: start.addingTimeInterval(280))
        ]
        let moments = [
            SessionMoment(transcriptID: lines[0].id, category: .definition, text: lines[0].text, speaker: lines[0].source, time: lines[0].time),
            SessionMoment(transcriptID: lines[2].id, category: .question, text: lines[2].text, speaker: lines[2].source, time: lines[2].time),
            SessionMoment(transcriptID: lines[3].id, category: .example, text: lines[3].text, speaker: lines[3].source, time: lines[3].time),
            SessionMoment(transcriptID: lines[4].id, category: .exam, text: "Remember the midpoint formula for the exam.", speaker: lines[4].source, time: lines[4].time),
            SessionMoment(transcriptID: lines[4].id, category: .assignment, text: "Assignment three is due Friday.", speaker: lines[4].source, time: lines[4].time)
        ]
        let summary = SessionSummary(
            overview: "How people respond to price changes, and why having more time to adjust changes that response.",
            sections: [
                SummarySection(title: "Key concepts", content: ["Elasticity measures the responsiveness of demand to price.", "More time to find alternatives makes demand more elastic."], sourceTranscriptIDs: [lines[0].id, lines[1].id]),
                SummarySection(title: "Questions asked", content: [lines[2].text], sourceTranscriptIDs: [lines[2].id]),
                SummarySection(title: "Assignments", content: ["Assignment three is due Friday."], sourceTranscriptIDs: [lines[4].id])
            ], generatedAt: start.addingTimeInterval(2700), overviewSourceTranscriptIDs: [lines[0].id, lines[1].id])
        let notes = [
            SessionNote(sessionID: id, transcriptID: lines[1].id, text: "Review the short-run and long-run examples before the next class.", time: start.addingTimeInterval(220)),
            SessionNote(sessionID: id, transcriptID: lines[4].id, text: lines[4].text, time: start.addingTimeInterval(300), isBookmark: true)
        ]
        return [
            ListeningSession(id: id, startedAt: start, endedAt: start.addingTimeInterval(2700), title: "Elasticity & the time horizon", kind: .lecture,
                             transcript: lines, moments: moments, summary: summary, notes: notes),
            ListeningSession(startedAt: start.addingTimeInterval(-86_400), endedAt: start.addingTimeInterval(-85_080), title: "A study session on derivatives", kind: .study),
            ListeningSession(startedAt: start.addingTimeInterval(-172_800), endedAt: start.addingTimeInterval(-170_820), title: "Ideas for the next project", kind: .brainstorming)
        ]
    }
}
