import XCTest
@testable import NotchCore

final class SessionIntelligenceTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_791_300_000)

    func testQuestionsAreDetectedWithoutPunctuationAndDeclarationsStayQuiet() {
        let questions = [
            "Can anyone explain why demand shifts here",
            "So would this still happen if interest rates were lower",
            "What do you think our next step should be",
            "Wait, how does that actually work",
            "Please explain the difference between nominal and real rates"
        ]
        for question in questions { XCTAssertTrue(QuestionDetector.isCandidate(question), question) }
        for statement in ["Today we're going to discuss supply and demand.",
                          "We explained why demand shifts.",
                          "The question is whether elasticity changes with time.",
                          "The assignment is due Friday."] {
            XCTAssertFalse(QuestionDetector.isCandidate(statement), statement)
        }
    }

    func testQuestionExtractionUsesTailOfRecognitionSegmentAndPreservesSeparateQuestions() {
        let unpunctuated = "Demand has changed as incomes rise can anyone explain why demand shifts here"
        XCTAssertEqual(SessionIntelligence.questionText(in: unpunctuated), "can anyone explain why demand shifts here")
        XCTAssertEqual(SessionIntelligence.questionText(in: unpunctuated + "?"), "can anyone explain why demand shifts here?")
        let line = TranscriptLine(source: "System audio", text: "What is elasticity? It measures responsiveness. Why does the time horizon matter?", time: time)
        XCTAssertEqual(SessionIntelligence.questionText(in: line.text), "Why does the time horizon matter?")
        let questions = SessionIntelligence.classify(line).filter { $0.category == .question }
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(Set(questions.map(\.id)).count, 2)
        XCTAssertTrue(questions.allSatisfy { $0.speaker == "System audio" && $0.transcriptID == line.id })
    }

    func testPartialQuestionsAndDuplicateSegmentsDoNotRetrigger() {
        var detector = QuestionDetector(cooldown: 5, repeatWindow: 60)
        let id = UUID()
        let partial = TranscriptLine(id: id, source: "Microphone", text: "Why does elasticity change", time: time)
        XCTAssertTrue(detector.consume(partial, at: time))
        let revision = TranscriptLine(id: id, source: "Microphone", text: "Why does elasticity change depending on the time horizon?", time: time)
        XCTAssertFalse(detector.consume(revision, at: time.addingTimeInterval(9)))
        let duplicate = TranscriptLine(source: "Microphone", text: partial.text, time: time.addingTimeInterval(10))
        XCTAssertFalse(detector.consume(duplicate, at: time.addingTimeInterval(10)))
        let different = TranscriptLine(id: id, source: "Microphone", text: "What is our homework for Friday?", time: time)
        XCTAssertTrue(detector.consume(different, at: time.addingTimeInterval(11)))
        XCTAssertFalse(detector.consume(partial, at: time.addingTimeInterval(12)))
        XCTAssertTrue(detector.consume(partial, at: time.addingTimeInterval(80)))
        detector.reset()
        XCTAssertTrue(detector.consume(partial, at: time.addingTimeInterval(81)))
    }

    func testClassificationPreservesDecimalsAndQuestionsSeparatedByNewlines() {
        let line = TranscriptLine(source: "Mic", text: "Remember this formula: y = 2.5x.\nCan you explain the intercept\nIt describes the starting value.", time: time)
        let moments = SessionIntelligence.classify(line)
        XCTAssertTrue(moments.contains { $0.category == .formula && $0.text == "Remember this formula: y = 2.5x." })
        XCTAssertTrue(moments.contains { $0.category == .question && $0.text == "Can you explain the intercept" })
    }

    func testSessionKeepsCompleteTranscriptAndReplacesOnlyRecognitionRevision() {
        var session = ListeningSession(startedAt: time)
        for index in 0..<350 {
            session.upsertTranscript(TranscriptLine(source: "Microphone", text: "Passage \(index)", time: time.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(session.transcript.count, 350)
        let first = session.transcript[0]
        session.upsertTranscript(TranscriptLine(id: first.id, source: first.source, text: "Corrected first passage", time: first.time))
        XCTAssertEqual(session.transcript.count, 350)
        XCTAssertEqual(session.transcript[0].text, "Corrected first passage")
        // The legacy live buffer stays bounded without truncating the authoritative session.
        XCTAssertEqual(TranscriptStore(lines: session.transcript).lines.count, 120)
    }

    func testMomentMergingPreservesMultipleQuestionsAndReconcilesCorrections() {
        var session = ListeningSession(startedAt: time)
        let id = UUID()
        let first = TranscriptLine(id: id, source: "Microphone", text: "Why does demand shift? What is elasticity? Homework is due Friday.", time: time)
        session.upsertTranscript(first)
        session.mergeMoments(SessionIntelligence.classify(first))
        session.mergeMoments(SessionIntelligence.classify(first))
        XCTAssertEqual(session.moments.filter { $0.category == .question }.count, 2)
        XCTAssertEqual(Set(session.moments.map(\.id)).count, session.moments.count)
        let correction = TranscriptLine(id: id, source: "Microphone", text: "Why does demand shift? What is elasticity? Homework is due Thursday.", time: time)
        session.upsertTranscript(correction)
        session.mergeMoments(SessionIntelligence.classify(correction))
        XCTAssertFalse(session.moments.contains { $0.text.contains("Friday") })
        XCTAssertTrue(session.moments.contains { $0.category == .deadline && $0.text.contains("Thursday") })
    }

    func testPartialMomentKeepsIDButClearsStaleAnswerAndNeverInventsSpeaker() {
        var session = ListeningSession(startedAt: time)
        let id = UUID()
        let line = TranscriptLine(id: id, source: "System audio", text: "Why does demand shift", time: time)
        session.upsertTranscript(line)
        var initial = SessionIntelligence.classify(line).first { $0.category == .question }!
        initial.answer = "An initial answer"
        initial.speaker = "Invented professor name"
        session.mergeMoments([initial])
        let stableID = session.moments[0].id
        let revision = TranscriptLine(id: id, source: "System audio", text: "Why does demand shift when income rises?", time: time)
        session.upsertTranscript(revision)
        session.mergeMoments(SessionIntelligence.classify(revision))
        let updated = session.moments.first { $0.category == .question }!
        XCTAssertEqual(updated.id, stableID)
        XCTAssertEqual(updated.speaker, "System audio")
        XCTAssertNil(updated.answer)
        session.mergeMoments([SessionMoment(transcriptID: UUID(), category: .question, text: "What happened?", speaker: "Unknown")])
        XCTAssertEqual(session.moments.filter { $0.category == .question }.count, 1)
    }

    func testMomentJSONRequiresExistingSourcesAndExtractiveText() throws {
        let line = TranscriptLine(source: "System audio", text: "Your homework is due Friday. Can anyone explain why demand shifts?", time: time)
        let json = """
        ```json
        {"moments":[{"transcriptID":"\(line.id)","category":"Assignment","text":"Your homework is due Friday."},{"sourceID":"\(line.id)","category":"question","text":"Can anyone explain why demand shifts?","speaker":"Fabricated identity"}]}
        ```
        """
        let values = try SessionIntelligence.parseMoments(json, transcript: [line])
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.allSatisfy { $0.speaker == line.source && $0.time == line.time })
        let fabricatedSource = "{\"moments\":[{\"transcriptID\":\"\(UUID())\",\"category\":\"Exam\",\"text\":\"Your homework is due Friday.\"}]}"
        XCTAssertThrowsError(try SessionIntelligence.parseMoments(fabricatedSource, transcript: [line]))
        let fabricatedFact = "{\"moments\":[{\"transcriptID\":\"\(line.id)\",\"category\":\"Assignment\",\"text\":\"Your homework is due Monday.\"}]}"
        XCTAssertThrowsError(try SessionIntelligence.parseMoments(fabricatedFact, transcript: [line]))
        XCTAssertThrowsError(try SessionIntelligence.parseMoments("Not JSON", transcript: [line]))
    }

    func testSummaryRejectsUnsupportedDatesAndMissingCitations() throws {
        let line = TranscriptLine(source: "Microphone", text: "Assignment 3 is due Friday.", time: time)
        let session = ListeningSession(startedAt: time, transcript: [line])
        func json(_ day: String, citeOverview: Bool = true) -> String {
            "{\"overview\":\"An assignment deadline was discussed.\",\"overviewSourceTranscriptIDs\":\(citeOverview ? "[\"\(line.id)\"]" : "[]"),\"sections\":[{\"title\":\"Assignments\",\"content\":[\"Assignment 3 is due \(day).\"],\"sourceTranscriptIDs\":[\"\(line.id)\"]}]}"
        }
        let summary = try SessionIntelligence.parseSummary(json("Friday"), session: session)
        XCTAssertEqual(summary.sections[0].sourceTranscriptIDs, [line.id])
        XCTAssertFalse(summary.usedFallback)
        XCTAssertThrowsError(try SessionIntelligence.parseSummary(json("Monday"), session: session))
        XCTAssertThrowsError(try SessionIntelligence.parseSummary(json("October 9, 2026"), session: session))
        XCTAssertThrowsError(try SessionIntelligence.parseSummary(json("next Friday"), session: session))
        XCTAssertThrowsError(try SessionIntelligence.parseSummary(json("in two weeks"), session: session))
        XCTAssertThrowsError(try SessionIntelligence.parseSummary(json("Friday", citeOverview: false), session: session))
    }

    func testFallbackSummaryIsMarkedAndDoesNotInventCalendarDatesOrOwners() {
        let line = TranscriptLine(source: "System audio", text: "This will be on the exam. Your homework is due Friday. Elasticity is defined as responsiveness.", time: time)
        let session = ListeningSession(startedAt: time, transcript: [line])
        XCTAssertEqual(SessionIntelligence.detectKind(in: session.transcript), .lecture)
        let summary = SessionIntelligence.fallbackSummary(for: session)
        XCTAssertTrue(summary.usedFallback)
        XCTAssertTrue(summary.sections.contains { $0.title == "Exam Mentions" })
        XCTAssertTrue(summary.sections.contains { $0.title == "Assignments" && $0.content.contains("Your homework is due Friday.") })
        XCTAssertTrue(summary.sections.allSatisfy { $0.sourceTranscriptIDs == [line.id] })
        XCTAssertFalse(summary.sections.flatMap(\.content).joined().contains("2026"))
    }

    func testBoundedContextIncludesRecentSpeechRelevantEarlierConceptAndNote() {
        var session = ListeningSession(startedAt: time, kind: .lecture)
        let relevant = TranscriptLine(source: "System audio", text: "Elasticity is defined as responsiveness to price changes over time.", time: time)
        session.upsertTranscript(relevant)
        for index in 1...35 {
            session.upsertTranscript(TranscriptLine(source: "System audio", text: "Background discussion passage \(index). " + String(repeating: "Other context. ", count: 20), time: time.addingTimeInterval(Double(index))))
        }
        session.mergeMoments(SessionIntelligence.classify(relevant))
        let note = SessionNote(sessionID: session.id, transcriptID: relevant.id, text: "Review elasticity and time horizon", time: time)
        session.notes.append(note)
        let context = SessionContextSelector.select(for: "Why does elasticity change with time?", in: session, maxCharacters: 4_000)
        XCTAssertLessThanOrEqual(context.prompt.count, 4_000)
        XCTAssertTrue(context.transcriptIDs.contains(relevant.id))
        XCTAssertTrue(context.transcriptIDs.contains(session.transcript.last!.id))
        XCTAssertEqual(context.noteIDs, [note.id])
        XCTAssertTrue(context.prompt.contains("Review elasticity"))
        XCTAssertGreaterThan(context.omittedTranscriptCount, 0)
        for id in context.transcriptIDs { XCTAssertTrue(context.prompt.contains(id.uuidString)) }
        for budget in [0, 1, 30, 100, 500] {
            XCTAssertLessThanOrEqual(SessionContextSelector.select(for: "elasticity", in: session, maxCharacters: budget).prompt.count, budget)
        }
    }

    func testSummaryPromptIncludesShortPassagesAndDisclosesOmissions() {
        let short = TranscriptLine(source: "Mic", text: "Homework is due Friday.", time: time)
        var session = ListeningSession(startedAt: time, kind: .lecture, transcript: [short])
        let shortPrompt = SessionIntelligence.summaryPrompt(for: session, maxCharacters: 3_000)
        XCTAssertTrue(shortPrompt.contains(short.id.uuidString))
        for _ in 0..<10 { session.transcript.append(TranscriptLine(source: "Mic", text: String(repeating: "Long passage. ", count: 500), time: time)) }
        let prompt = SessionIntelligence.summaryPrompt(for: session, maxCharacters: 3_000)
        XCTAssertLessThanOrEqual(prompt.count, 3_000)
        XCTAssertTrue(prompt.contains("omitted"))
        XCTAssertTrue(prompt.contains("[excerpt]"))
    }

    func testPersistenceRoundTripReplacementDeletionAndCorruptionAreVisible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = MemoryStore(directory: directory, semanticSearchEnabled: false)
        XCTAssertTrue(try memory.load().isEmpty)
        var session = ListeningSession(startedAt: time, title: "Economics")
        for index in 0..<200 { session.upsertTranscript(TranscriptLine(source: "Mic", text: "Passage \(index)", time: time)) }
        session.notes.append(SessionNote(sessionID: session.id, transcriptID: session.transcript[0].id, text: "Review this", time: time, isBookmark: true))
        try memory.save(session)
        XCTAssertEqual(try memory.load(), [session])
        session.title = "Economics · elasticity"
        try memory.save(session)
        XCTAssertEqual(try memory.load(), [session])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.count, 1)
        try memory.delete(id: session.id)
        XCTAssertTrue(try memory.load().isEmpty)
        try memory.delete(id: session.id)
        let corrupt = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("broken json".utf8).write(to: corrupt)
        XCTAssertThrowsError(try memory.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testSearchCoversTailOfLongTranscriptNotesBookmarksAndSourceLinks() {
        let memory = MemoryStore(directory: FileManager.default.temporaryDirectory, semanticSearchEnabled: false)
        let long = TranscriptLine(source: "Mic", text: String(repeating: "Background material. ", count: 500) + "Assignment 3 is due Friday.", time: time)
        var session = ListeningSession(startedAt: time, title: "ECON", kind: .lecture, transcript: [long])
        session.notes.append(SessionNote(sessionID: session.id, text: "Project Tokoyo discussion with research collaborators", time: time))
        session.notes.append(SessionNote(sessionID: session.id, transcriptID: long.id, text: "Review elasticity example", time: time, isBookmark: true))
        let assignment = memory.search("when is assignment 3 due", sessions: [session])
        XCTAssertFalse(assignment.usedSemanticSearch)
        XCTAssertEqual(assignment.results.count, 1)
        XCTAssertEqual(assignment.results.first?.transcriptID, long.id)
        XCTAssertTrue(assignment.results.first?.excerpt.contains("Friday") == true)
        XCTAssertTrue(assignment.evidenceContext().contains(long.id.uuidString))
        XCTAssertTrue(memory.search("Tokoyo", sessions: [session]).results.contains { $0.kind == "Note" })
        XCTAssertTrue(memory.search("elasticity", sessions: [session]).results.contains { $0.kind == "Bookmark" })
        XCTAssertTrue(memory.search("", sessions: [session]).results.isEmpty)
        XCTAssertTrue(memory.search("assignment", sessions: [session], limit: 0).results.isEmpty)
    }

    func testSearchDateScopesUseEvidenceTimestampAndCalendarTimezone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3_600)!
        let day = calendar.startOfDay(for: time)
        let today = TranscriptLine(source: "Mic", text: "Elasticity example today", time: day.addingTimeInterval(3_600))
        let yesterday = TranscriptLine(source: "Mic", text: "Elasticity example yesterday", time: day.addingTimeInterval(-3_600))
        // This session crossed midnight: scope follows the actual passage, not session start.
        let session = ListeningSession(startedAt: yesterday.time, transcript: [yesterday, today])
        let memory = MemoryStore(directory: FileManager.default.temporaryDirectory, semanticSearchEnabled: false)
        let scoped = memory.search("elasticity today", sessions: [session], now: time, calendar: calendar)
        XCTAssertEqual(scoped.scope, .today)
        XCTAssertEqual(scoped.results.map(\.transcriptID), [today.id])
        XCTAssertEqual(memory.search("elasticity", sessions: [session], now: time, calendar: calendar).results.count, 2)
    }
}
