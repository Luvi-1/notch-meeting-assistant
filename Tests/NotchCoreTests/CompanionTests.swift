import XCTest
@testable import NotchCore

final class CompanionTests: XCTestCase {
    func testProviderRequestsUseTheirNativeFormatsAndPrivateHeaders() throws {
        let cases: [(AIProvider, String, String, String)] = [
            (.openai, "gpt-6-astra", "/v1/responses", "Authorization"),
            (.anthropic, "claude-sonnet-test", "/v1/messages", "x-api-key"),
            (.gemini, "gemini-flash-test", "/v1beta/models/gemini-flash-test:streamGenerateContent", "x-goog-api-key"),
            (.openrouter, "vendor/model", "/api/v1/chat/completions", "Authorization"),
            (.groq, "llama-test", "/openai/v1/chat/completions", "Authorization"),
            (.opencode, "claude-test", "/zen/v1/messages", "x-api-key")
        ]
        for (provider, model, path, header) in cases {
            let connection = ProviderConnection(ProviderConfiguration(provider, model: model), key: "test-secret")
            let request = try ProviderClient().makeRequest(connection: connection, system: "System instructions", prompt: "Reference data")
            XCTAssertEqual(request.url?.path, path)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: header))
            XCTAssertFalse(request.url!.absoluteString.contains("test-secret"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            switch provider {
            case .openai:
                XCTAssertEqual(body["store"] as? Bool, false)
                XCTAssertEqual(body["instructions"] as? String, "System instructions")
                XCTAssertNil(body["service_tier"])
            case .anthropic, .opencode:
                XCTAssertEqual(body["system"] as? String, "System instructions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            case .gemini:
                XCTAssertNotNil(body["systemInstruction"])
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "sse")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            default: XCTAssertNotNil(body["messages"])
            }
        }
    }
    func testAstraTierNeverLeaksToOtherProviders() throws {
        for provider in [AIProvider.openai, .opencode, .openrouter] {
            var config = ProviderConfiguration(provider, model: "gpt-6-astra"); config.ultrafast = true
            let request = try ProviderClient().makeRequest(connection: ProviderConnection(config, key: "test"), system: "", prompt: "Hello")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["service_tier"] as? String, provider == .openai ? "ultrafast" : nil)
        }
    }
    func testEndpointsRejectRemoteHTTPAndCredentialInjection() throws {
        for url in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=bad", "https://example.com/#fragment", "file:///tmp/anything", "http://localhost.example.com/v1"] {
            XCTAssertThrowsError(try ProviderNetwork.endpoint(url))
        }
        XCTAssertEqual(try ProviderNetwork.endpoint("http://127.0.0.1:1234/v1/", path: "chat/completions").absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions")
        for key in ["bad\r\nAuthorization: wrong", "bad key", "", String(repeating: "a", count: 4097)] { XCTAssertThrowsError(try ProviderNetwork.key(key)) }
        var local = ProviderConfiguration(.custom, model: "local-model")
        XCTAssertNoThrow(try ProviderClient().makeRequest(connection: ProviderConnection(local, key: ""), system: "", prompt: "Hello"))
        local.customBaseURL = "https://example.com/v1"
        XCTAssertThrowsError(try ProviderClient().makeRequest(connection: ProviderConnection(local, key: ""), system: "", prompt: "Hello"))
        let encoded = try JSONEncoder().encode(local)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("api-key"))
    }
    func testOpenCodeRoutesModelFamiliesAndAllowsAnExplicitOverride() throws {
        XCTAssertEqual(ProviderConfiguration(.opencode, model: "gpt-6-astra").wireFormat, .responses)
        XCTAssertEqual(ProviderConfiguration(.opencode, model: "claude-fable-5").wireFormat, .anthropic)
        XCTAssertEqual(ProviderConfiguration(.opencode, model: "gemini-flash").wireFormat, .gemini)
        XCTAssertEqual(ProviderConfiguration(.opencode, model: "qwen3.8-flash").wireFormat, .anthropic)
        XCTAssertEqual(ProviderConfiguration(.opencode, model: "other-model").wireFormat, .chat)
        var custom = ProviderConfiguration(.opencode, model: "next-model"); custom.format = .responses
        XCTAssertEqual(custom.wireFormat, .responses)
        XCTAssertThrowsError(try ProviderClient().makeRequest(connection: ProviderConnection(ProviderConfiguration(.opencode, model: "jev-test"), key: "test"), system: "", prompt: "Hello"))
    }
    func testNativeStreamDecodersAcceptTextButRejectIncompleteAnswers() throws {
        var anthropic = ProviderStreamDecoder(format: .anthropic)
        XCTAssertEqual(try anthropic.decode(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#).text, "Hello")
        _ = try anthropic.decode(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
        XCTAssertTrue(try anthropic.decode(#"{"type":"message_stop"}"#).done)
        var invalidAnthropic = ProviderStreamDecoder(format: .anthropic)
        XCTAssertThrowsError(try invalidAnthropic.decode(#"{"type":"message_stop"}"#))
        var gemini = ProviderStreamDecoder(format: .gemini)
        let response = try gemini.decode(#"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"Visible"}]},"finishReason":"STOP"}]}"#)
        XCTAssertEqual(response.text, "Visible"); XCTAssertTrue(response.done)
        XCTAssertThrowsError(try gemini.decode(#"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#))
        var responses = ProviderStreamDecoder(format: .responses)
        XCTAssertThrowsError(try responses.decode(#"{"type":"response.incomplete"}"#))
        var chat = ProviderStreamDecoder(format: .chat)
        XCTAssertThrowsError(try chat.decode("[DONE]"))
        XCTAssertThrowsError(try chat.decode(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#))
    }
    func testSSEFramerPreservesSplitUnicodeCRLFAndEOF() throws {
        let raw = ": comment\r\nevent: content\r\ndata: {\"text\":\"Hello 🌎 नमस्ते\"}\r\n\r\n"
        var framer = SSEFramer(); var output: [String] = []
        for byte in raw.utf8 { if let event = try framer.feed(byte) { output.append(event) } }
        XCTAssertEqual(output, ["{\"text\":\"Hello 🌎 नमस्ते\"}"])
        for byte in "data: [DONE]".utf8 { _ = try framer.feed(byte) }
        XCTAssertEqual(try framer.finish(), "[DONE]")
        var invalid = SSEFramer()
        _ = try invalid.feed(255)
        XCTAssertThrowsError(try invalid.feed(10))
    }
    func testWhisperRequestsAreMultipartAndDoNotSaveAudio() throws {
        let wav = PCMEncoding.wav(samples: [0, 1, -1, 32767, -32768])
        XCTAssertEqual(wav.count, 54)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(Array(wav.suffix(4)), [255, 127, 0, 128])
        var config = TranscriptionConfiguration(); config.provider = .groq
        let request = try WhisperTranscriptionProvider().makeRequest(wav: wav, configuration: config, key: "test")
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("whisper-large-v3-turbo")); XCTAssertTrue(body.contains("verbose_json"))
        XCTAssertFalse(body.contains("name=\"language\""))
        config.provider = .openai; config.model = "gpt-4o-transcribe-diarize"
        let diarized = try WhisperTranscriptionProvider().makeRequest(wav: wav, configuration: config, key: "test")
        XCTAssertTrue(String(decoding: diarized.httpBody!, as: UTF8.self).contains("diarized_json"))
        config.provider = .localWhisper
        XCTAssertEqual(try WhisperTranscriptionProvider().makeRequest(wav: wav, configuration: config, key: "").url?.path, "/inference")
        config.localURL = "https://remote.example.com"
        XCTAssertThrowsError(try WhisperTranscriptionProvider().makeRequest(wav: wav, configuration: config, key: ""))
    }
    func testTranscriptionRejectsSilenceHallucinationsAndKeepsSpeakerOffsets() throws {
        let data = Data(#"{"text":"Do not resurrect filtered silence","language":"en","segments":[{"text":"Question","start":1.2,"end":2.4,"speaker":"A"},{"text":"Thank you","start":3,"end":4,"no_speech_prob":0.99},{"text":"Invalid","start":-1,"end":3}]}"#.utf8)
        let result = try WhisperTranscriptionProvider.decode(data)
        XCTAssertEqual(result.spans, [TranscribedSpan(text: "Question", start: 1.2, end: 2.4, speaker: "A")])
        let silence = try WhisperTranscriptionProvider.decode(Data(#"{"text":"hallucination","segments":[{"text":"hallucination","no_speech_prob":1}]}"#.utf8))
        XCTAssertTrue(silence.spans.isEmpty)
        XCTAssertThrowsError(try WhisperTranscriptionProvider.decode(Data(#"{"unexpected":"response"}"#.utf8)))
    }
    func testLongSessionKeepsAllSegmentsAndPreservesBookmarksOnPartialUpdates() {
        var session = ListeningSession()
        for i in 0..<500 { session.update(SessionSegment(time: Date(timeIntervalSince1970: Double(i)), source: "Microphone", text: "Segment \(i)")) }
        XCTAssertEqual(session.segments.count, 500)
        let first = session.segments[0]
        session.segments[0].bookmarked = true; session.segments[0].note = "Remember"; session.segments[0].speaker = "Professor"
        session.update(SessionSegment(id: first.id, time: first.time, source: "Microphone", text: "Corrected text"))
        XCTAssertTrue(session.segments[0].bookmarked); XCTAssertEqual(session.segments[0].note, "Remember")
        XCTAssertEqual(session.segments[0].speakerLabel, "Professor")
        XCTAssertTrue(session.markdown.contains("Segment 499"))
        let question = SessionQuestion(segmentID: first.id, text: "Can anyone explain this")
        XCTAssertTrue(session.addQuestion(question)); XCTAssertFalse(session.addQuestion(SessionQuestion(segmentID: first.id, text: "Can anyone explain this?")))
    }
    func testAnalysisRequiresGroundedQuestionsAndKnownPassageIDs() throws {
        let segment = SessionSegment(source: "Microphone", text: "Can anyone explain why demand shifts here")
        let object: [String: Any] = ["topic": "Demand", "kind": "Lecture", "moments": [
            ["segment_id": segment.id.uuidString, "categories": ["Question"], "question": segment.text, "confidence": 0.9],
            ["segment_id": segment.id.uuidString, "categories": ["Question"], "question": "An invented question", "confidence": 0.95],
            ["segment_id": UUID().uuidString, "categories": ["Exam"], "question": NSNull(), "confidence": 0.99],
            ["segment_id": segment.id.uuidString, "categories": ["Important"], "question": NSNull(), "confidence": 2]
        ]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let analysis = try SessionIntelligence.validatedAnalysis(json, segments: [segment])
        XCTAssertEqual(analysis.moments.count, 1)
        XCTAssertEqual(analysis.moments[0].question, segment.text)
        XCTAssertFalse(segment.text.contains("?"), "A question mark is not required by the semantic analysis contract")
    }
    func testPreviewHoverDoesNotExpandAndDismissalIsRespected() {
        let now = Date(timeIntervalSince1970: 100)
        var notch = NotchPresentation(); notch.beginAnswer(); notch.reveal(at: now)
        notch.hover(true, at: now); notch.tick(at: now.addingTimeInterval(100))
        XCTAssertEqual(notch.phase, .preview)
        notch.dismiss(); notch.reveal(at: now.addingTimeInterval(101))
        XCTAssertEqual(notch.phase, .compact)
        notch.hover(false, at: now); notch.beginAnswer(); notch.reveal(at: now)
        notch.tick(at: now.addingTimeInterval(9)); XCTAssertEqual(notch.phase, .compact)
    }
    func testSummaryBatchingRetainsTheWholeTranscript() {
        let material = (0..<200).map { "segment\($0) " + String(repeating: "word ", count: 40) }
        let batches = SessionIntelligence.batches(material, limit: 700)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 701 })
        let normalizedOriginal = material.joined().filter { !$0.isWhitespace }
        let normalizedBatches = batches.joined().filter { !$0.isWhitespace }
        XCTAssertEqual(normalizedBatches, normalizedOriginal)
    }
    func testRepositoryRoundTripRecoveryAndCorruptionPreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionRepository(directory: directory)
        var session = ListeningSession(); session.update(SessionSegment(source: "Microphone", text: "Assignment due Friday"))
        session.notes.append(SessionNote(text: "Ask about the deadline"))
        try await repository.save(session)
        let first = try await repository.load()
        XCTAssertEqual(first.sessions.count, 1); XCTAssertTrue(first.sessions[0].recovered)
        XCTAssertEqual(first.sessions[0].notes, session.notes)
        let corrupt = directory.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: corrupt)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.sessions.count, 1); XCTAssertEqual(loaded.warnings.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(session.id.uuidString + ".json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await repository.delete(session.id)
        let deleted = try await repository.load(); XCTAssertTrue(deleted.sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }
    func testMemorySearchFindsNotesBookmarksAndDatesWithoutCloudRequests() async throws {
        let now = Date()
        var recent = ListeningSession(startedAt: now)
        recent.title = "Project Tokoyo"
        let segment = SessionSegment(time: now, source: "System audio", text: "Tokoyo prototype review is Friday")
        recent.update(segment); recent.segments[0].bookmarked = true
        recent.notes.append(SessionNote(text: "Assignment 3 is due Friday", segmentID: segment.id))
        var old = ListeningSession(startedAt: now.addingTimeInterval(-30 * 86400))
        old.update(SessionSegment(source: "Microphone", text: "Tokoyo was discussed last month"))
        let index = MemoryIndex()
        let hits = try await index.search("Tokoyo today", sessions: [old, recent], now: now)
        XCTAssertFalse(hits.isEmpty); XCTAssertTrue(hits.allSatisfy { $0.sessionID == recent.id })
        let noteHits = try await index.search("assignment 3 Friday", sessions: [recent])
        XCTAssertTrue(noteHits.contains { $0.text.contains("Assignment 3") })
        let context = try await index.context(for: "assignment Friday", session: recent)
        XCTAssertTrue(context.contains("User note:")); XCTAssertTrue(context.contains("Tokoyo prototype"))
        XCTAssertEqual(MemoryIndex.cosine([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(MemoryIndex.cosine([0, 0], [1, 0]), 0)
        XCTAssertEqual(MemoryIndex.cosine([1], [1, 0]), 0)
    }
}
