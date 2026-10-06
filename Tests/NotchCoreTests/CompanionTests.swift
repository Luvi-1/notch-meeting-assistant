import Foundation
import XCTest
@testable import NotchCore

final class CompanionTests: XCTestCase {
    func testProviderDialectsAndCredentialBoundaries() throws {
        for (kind, path, header) in [(ProviderKind.openai, "/v1/responses", "Authorization"), (.anthropic, "/v1/messages", "x-api-key"), (.gemini, "/v1beta/models/gemini-3.8-flash:streamGenerateContent", "x-goog-api-key"), (.groq, "/openai/v1/chat/completions", "Authorization"), (.openrouter, "/api/v1/chat/completions", "Authorization")] {
            let configuration = ProviderConfiguration(kind: kind)
            let request = try ConfiguredLLMProvider(configuration: configuration, key: "test-private-key").makeRequest(system: "Stay grounded", prompt: "Explain elasticity")
            XCTAssertEqual(request.url?.path, path)
            XCTAssertNotNil(request.value(forHTTPHeaderField: header))
            XCTAssertFalse(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!.contains("test-private-key"))
            XCTAssertFalse(String(data: try JSONEncoder().encode(configuration), encoding: .utf8)!.contains("test-private-key"))
            XCTAssertEqual(request.url?.query, kind == .gemini ? "alt=sse" : nil)
        }
        var configuration = ProviderConfiguration(kind: .openai)
        configuration.ultrafast = true
        let request = try ConfiguredLLMProvider(configuration: configuration, key: "test").makeRequest(system: "", prompt: "Hi")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["service_tier"] as? String, "ultrafast")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
    }
    func testCustomEndpointValidationAndZenFormats() throws {
        for value in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/data", "https://example.com/#fragment"] {
            XCTAssertThrowsError(try ProviderHTTP.validatedURL(value))
        }
        XCTAssertNoThrow(try ProviderHTTP.validatedURL("http://127.0.0.1:11434/v1"))
        XCTAssertThrowsError(try ProviderHTTP.validatedURL("https://example.com", localOnly: true))
        for id in ["", "../secret", "model?key=x", "bad model", "foo//bar"] { XCTAssertThrowsError(try ProviderHTTP.validatedModel(id)) }
        XCTAssertEqual(try ProviderHTTP.validatedModel("openai/gpt-6-astra"), "openai/gpt-6-astra")
        var zen = ProviderConfiguration(kind: .opencode)
        for (model, format) in [("gpt-6-astra", ProviderDialect.responses), ("claude-sonnet-5", .anthropic), ("gemini-3.8-flash", .gemini), ("glm-5.3", .chat)] {
            zen.model = model; XCTAssertEqual(zen.wireDialect, format)
        }
        zen.dialect = .anthropic; XCTAssertEqual(zen.wireDialect, .anthropic)
    }
    func testNativeStreamsNeverExposeReasoningAsAnswerText() throws {
        var claude = EventStreamDecoder()
        let messages = [
            #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private"}}"#,
            #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Answer"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#
        ]
        var events: [StreamEvent] = []
        for message in messages { _ = try claude.feed("data: " + message); events.append(try XCTUnwrap(claude.feed(""))) }
        XCTAssertEqual(events.map(\.text).joined(), "Answer")
        XCTAssertEqual(events[2].finishReason, "end_turn"); XCTAssertTrue(events[3].done)
        var gemini = EventStreamDecoder()
        _ = try gemini.feed(#"data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"private"},{"text":"Visible"}]},"finishReason":"STOP"}]}"#)
        let event = try XCTUnwrap(gemini.feed(""))
        XCTAssertEqual(event.text, "Visible"); XCTAssertTrue(event.done); XCTAssertEqual(event.finishReason, "STOP")
        _ = try gemini.feed(#"data: {"promptFeedback":{"blockReason":"SAFETY"}}"#)
        XCTAssertThrowsError(try gemini.feed(""))
    }
    func testJobRoutingDoesNotSilentlyReplaceExplicitProvider() throws {
        let providers = [ProviderConfiguration(kind: .openai), ProviderConfiguration(kind: .gemini)]
        let connected: Set<String> = [ProviderKind.openai.rawValue]
        XCTAssertEqual(try ModelRoute.resolve(job: .live, route: ModelRoute(), providers: providers, configured: connected).kind, .openai)
        XCTAssertThrowsError(try ModelRoute.resolve(job: .summary, route: ModelRoute(providerID: ProviderKind.gemini.rawValue), providers: providers, configured: connected))
        let route = ModelRoute(providerID: ProviderKind.openai.rawValue, model: "user-selected-model")
        XCTAssertEqual(try ModelRoute.resolve(job: .deep, route: route, providers: providers, configured: connected).model, "user-selected-model")
        XCTAssertFalse(QuestionAssistance.suggest.speaks(output: .both))
        XCTAssertTrue(QuestionAssistance.automatic.speaks(output: .both))
        XCTAssertFalse(QuestionAssistance.off.detects)
    }
    func testGroundedSemanticMomentsAndDeduplication() throws {
        var record = SessionRecord()
        let id = UUID()
        let words = "Can anyone explain why demand shifts here"
        record.ingest(id: id, source: "Room", text: words + ". Homework is due Friday.")
        let payload: [String: Any] = ["topic": "Demand", "kind": "Lecture", "moments": [
            ["segmentID": id.uuidString, "category": "Question", "quote": words],
            ["segmentID": id.uuidString, "category": "Deadline", "quote": "Homework is due Friday"],
            ["segmentID": id.uuidString, "category": "Assignment", "quote": "Submit assignment three tomorrow"],
            ["segmentID": UUID().uuidString, "category": "Question", "quote": "Something invented"]
        ]]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let analysis = try SessionAnalysis.decode("```json\n" + json + "\n```")
        let added = record.apply(analysis, allowedIDs: [id], detectQuestions: true)
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(record.kind, .lecture)
        XCTAssertEqual(added.first?.source, "Room", "A model must not invent a professor or student identity")
        XCTAssertEqual(record.apply(analysis, allowedIDs: [id], detectQuestions: true).count, 0)
        var off = SessionRecord(); off.ingest(id: id, source: "Room", text: words + ". Homework is due Friday.")
        let silent = off.apply(analysis, allowedIDs: [id], detectQuestions: false)
        XCTAssertEqual(silent.map(\.category), [.deadline])
    }
    func testDurableTranscriptSurvivesBeyondLiveWindowAndStaleSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SessionArchive(directory: directory)
        var record = SessionRecord()
        for number in 0..<180 { record.ingest(id: UUID(), source: "Room", text: "Passage \(number)") }
        let old = record
        record.notes.append(SessionNote(text: "Review this later")); record.touch()
        try await archive.save(record); try await archive.save(old)
        let loaded = try await SessionArchive(directory: directory).load()
        XCTAssertEqual(loaded.sessions.first?.segments.count, 180)
        XCTAssertEqual(loaded.sessions.first?.notes.first?.text, "Review this later")
        try await archive.remove(id: record.id); try await archive.save(record)
        let deleted = try await SessionArchive(directory: directory).load()
        XCTAssertTrue(deleted.sessions.isEmpty)
    }
    func testCorruptSessionIsPreservedRatherThanOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), data = Data("broken-json".utf8)
        let file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        try data.write(to: file)
        let archive = SessionArchive(directory: directory)
        let loaded = try await archive.load(); XCTAssertEqual(loaded.warnings.count, 1)
        do { try await archive.save(SessionRecord(id: id)); XCTFail("Corrupt source should have been preserved") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testContextChunkingPreservesEveryCharacterAtAllLimits() {
        let rows = ["First 🧠 concept", "Second definition", "Homework Friday"]
        for limit in [0, 1, 2, 12, 100] {
            let chunks = ContextSelection.chunks(rows, limit: limit)
            XCTAssertEqual(chunks.joined(), rows.joined(separator: "\n"))
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= max(1, limit) })
        }
        XCTAssertTrue(ContextSelection.chunks([]).isEmpty)
    }
    func testWhisperMultipartDiarizationAndAudioBoundaries() throws {
        let wav = PCMChunk.wav(samples: [0, 1, -1, .nan, .infinity])
        XCTAssertEqual(wav.count, 54)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .utf8), "WAVE")
        var config = TranscriptionConfiguration(); config.kind = .groq; config.model = "whisper-large-v3-turbo"
        let groq = try WhisperProvider(configuration: config, key: "test-key").makeRequest(wav: wav)
        XCTAssertEqual(groq.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertTrue(groq.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
        config.kind = .openai; config.model = "gpt-4o-transcribe-diarize"
        let request = try WhisperProvider(configuration: config, key: "test-key").makeRequest(wav: wav, context: "Earlier text")
        let form = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(form.contains("diarized_json")); XCTAssertTrue(form.contains("chunking_strategy")); XCTAssertFalse(form.contains("Earlier text"))
        XCTAssertEqual(PCMChunk.removingOverlap(previous: "Here is the curve", next: "the curve shifts right"), "shifts right")
        XCTAssertEqual(PCMChunk.removingOverlap(previous: "This repeats", next: "Another topic"), "Another topic")
    }
    func testMemoryEvidenceLinksToOriginalPassage() async {
        var session = SessionRecord(); session.title = "Economics discussion"
        let id = UUID(); session.ingest(id: id, source: "Room", text: "Project Tokoyo research is due Friday.")
        session.segments[0].bookmarked = true
        session.segments[0].note = "Discuss with the study group"
        let items = MemoryIndex.evidence(session)
        XCTAssertTrue(items.contains { $0.segmentID == id && $0.kind == "Bookmark" })
        XCTAssertTrue(items.contains { $0.segmentID == id && $0.kind == "Note" })
        let results = await MemoryIndex().search(query: "Tokoyo", sessions: [session]).results
        XCTAssertEqual(results.first?.sessionID, session.id)
        XCTAssertEqual(results.first?.segmentID, id)
        XCTAssertEqual(MemoryIndex.cosine([0, 0], [0, 0]), 0)
    }
    func testQuestionPreviewIsShallowStateAndHonorsDismissal() {
        var presentation = NotchPresentation()
        presentation.beginAnswer(); presentation.reveal()
        XCTAssertEqual(presentation.phase, .preview)
        presentation.dismiss(); presentation.reveal(duration: 30)
        XCTAssertEqual(presentation.phase, .compact)
    }
}
