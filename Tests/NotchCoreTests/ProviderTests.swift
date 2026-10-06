import XCTest
@testable import NotchCore

final class ProviderTests: XCTestCase {
    private let key = "fixture-secret-not-a-real-key"
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func bytes(_ string: String) -> Data { Data(string.utf8) }
    private var wav: Data {
        var data = Data(repeating: 0, count: 44)
        data.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        data.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        return data
    }

    func testNativeRequestContractsAndCredentialHeaders() throws {
        var openAI = ProviderConfiguration(id: .openAI, enabled: true, ultrafast: true)
        let astra = try LLMService(configuration: openAI, key: key).makeRequest(system: "Trusted instructions", user: "Question", stream: true)
        XCTAssertEqual(astra.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(astra.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(try json(astra)["service_tier"] as? String, "ultrafast")
        XCTAssertEqual(try json(astra)["store"] as? Bool, false)
        openAI.model = "another-model"
        XCTAssertNil(try json(LLMService(configuration: openAI, key: key).makeRequest(system: "", user: "Question"))["service_tier"])

        let anthropic = try LLMService(configuration: .init(id: .anthropic), key: key).makeRequest(system: "Trusted", user: "Speech", maxTokens: 512)
        XCTAssertEqual(anthropic.url?.path, "/v1/messages")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try json(anthropic)["system"] as? String, "Trusted")
        XCTAssertEqual(try json(anthropic)["max_tokens"] as? Int, 512)

        let gemini = try LLMService(configuration: .init(id: .gemini, model: "models/gemini-flash"), key: key)
            .makeRequest(system: "Trusted", user: "Speech", stream: true)
        XCTAssertEqual(gemini.url?.path, "/v1beta/models/gemini-flash:streamGenerateContent")
        XCTAssertEqual(gemini.url?.query, "alt=sse")
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), key)
        XCTAssertFalse(gemini.url!.absoluteString.contains(key))
        XCTAssertNotNil(try json(gemini)["systemInstruction"])
        XCTAssertNil(try json(gemini)["messages"])
    }

    func testOpenCodeAllowsDifferentModelProtocolsAndCustomPaths() throws {
        for (style, suffix) in [(LLMAPIProtocol.chatCompletions, "/chat/completions"), (.responses, "/responses"), (.anthropicMessages, "/messages")] {
            let config = ProviderConfiguration(id: .openCode, model: "test-model", apiProtocol: style)
            let request = try LLMService(configuration: config, key: key).makeRequest(system: "", user: "Hi")
            XCTAssertTrue(request.url!.path.hasSuffix(suffix))
        }
        let custom = ProviderConfiguration(id: .custom, baseURL: "http://127.0.0.1:8080/v1/", model: "model:latest")
        let request = try LLMService(configuration: custom, key: "").makeRequest(system: "", user: "Hi")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let router = try LLMService(configuration: .init(id: .openRouter), key: key).makeValidationRequest()
        XCTAssertEqual(router.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(router.httpMethod, "GET")
    }

    func testGroqDefaultCompletionAndConnectionCheckUseDocumentedRoutes() throws {
        let service = LLMService(configuration: .init(id: .groq), key: key)
        let completion = try service.makeRequest(system: "Context", user: "Question", maxTokens: 512, stream: true)
        XCTAssertEqual(completion.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(completion.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertNil(completion.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(try json(completion)["model"] as? String, "llama-3.3-70b-versatile")
        XCTAssertEqual(try json(completion)["max_completion_tokens"] as? Int, 512)
        XCTAssertNil(try json(completion)["max_tokens"])
        let validation = try service.makeValidationRequest()
        XCTAssertEqual(validation.url?.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(validation.httpMethod, "GET")
        XCTAssertNil(validation.httpBody, "A model-list connection check must not depend on the completion model.")

        let responses = ProviderConfiguration(id: .groq, model: "openai/gpt-oss-120b", apiProtocol: .responses)
        XCTAssertEqual(try LLMService(configuration: responses, key: key).makeRequest(system: "", user: "Hi").url?.path, "/openai/v1/responses")
    }

    func testPastedGroqURLsResolveOnceForChatModelsAndSpeech() throws {
        for root in ["", "/v1", "/openai", "/openai/v1"] {
            for suffix in ["", "/", "/chat/completions", "/audio/transcriptions/", "/models", "/responses"] {
                let base = "https://api.groq.com" + root + suffix
                let service = LLMService(configuration: .init(id: .groq, baseURL: base), key: key)
                XCTAssertEqual(try service.makeRequest(system: "", user: "Hi").url?.absoluteString,
                               "https://api.groq.com/openai/v1/chat/completions", base)
                XCTAssertEqual(try service.makeValidationRequest().url?.absoluteString,
                               "https://api.groq.com/openai/v1/models", base)
                let speech = HTTPTranscriptionProvider(configuration: .init(provider: .groq, baseURL: base), key: key)
                XCTAssertEqual(try speech.makeRequest(wavData: wav).url?.absoluteString,
                               "https://api.groq.com/openai/v1/audio/transcriptions", base)
            }
        }
    }

    func testGroqURLRepairNeverRewritesUnsafeOrDifferentOrigins() throws {
        for base in ["http://api.groq.com/openai/v1", "https://api.groq.com.evil.example/openai/v1",
                     "https://api.openai.com/v1", "http://127.0.0.1:8080/v1", "https://api.groq.com:444/openai/v1",
                     "https://user:secret@api.groq.com/openai/v1", "https://api.groq.com/openai/v1?key=secret",
                     "https://api.groq.com/openai/v1#secret", "https://api.groq.com/private/secret"] {
            let config = ProviderConfiguration(id: .groq, baseURL: base)
            XCTAssertThrowsError(try LLMService(configuration: config, key: key).makeRequest(system: "", user: "Hi"), base) { error in
                XCTAssertFalse(error.localizedDescription.contains(self.key))
                XCTAssertFalse(error.localizedDescription.contains("user:secret"))
                XCTAssertFalse(error.localizedDescription.contains("private/secret"))
            }
            let transcription = TranscriptionConfiguration(provider: .groq, baseURL: base)
            XCTAssertThrowsError(try HTTPTranscriptionProvider(configuration: transcription, key: key).makeRequest(wavData: wav), base)
        }
        for style in [LLMAPIProtocol.anthropicMessages, .gemini] {
            let config = ProviderConfiguration(id: .groq, apiProtocol: style)
            XCTAssertThrowsError(try LLMService(configuration: config, key: key).makeValidationRequest())
            XCTAssertThrowsError(try LLMService(configuration: config, key: key).makeRequest(system: "", user: "Hi"))
        }
    }

    func testChangingSpeechProviderDropsOldModelAndEndpointButKeepsLanguage() {
        let custom = TranscriptionConfiguration(provider: .custom, model: "custom-speech-model",
                                                baseURL: "http://127.0.0.1:8080/v1", language: "hi", autoDetectLanguage: false)
        let groq = custom.selectingProvider(.groq)
        XCTAssertEqual(groq.model, "")
        XCTAssertEqual(groq.baseURL, "")
        XCTAssertEqual(groq.resolvedModel, "whisper-large-v3-turbo")
        XCTAssertEqual(groq.resolvedBaseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(groq.language, "hi")
        XCTAssertFalse(groq.autoDetectLanguage)
        XCTAssertEqual(custom.selectingProvider(.custom), custom, "Selecting the same provider must preserve its current configuration.")
        XCTAssertEqual(groq.selectingProvider(.openAI).resolvedModel, "whisper-1")
        XCTAssertEqual(groq.selectingProvider(.localWhisper).resolvedBaseURL, "http://127.0.0.1:8080/v1")
    }

    func testGroqRejectsSpeechModelsForAnswersAndForeignModelsForSpeech() throws {
        for model in ["whisper-large-v3-turbo", "whisper-1", "gpt-4o-transcribe"] {
            XCTAssertThrowsError(try LLMService(configuration: .init(id: .groq, model: model), key: key).makeRequest(system: "", user: "Hi"))
        }
        for model in ["whisper-1", "gpt-4o-transcribe", "llama-3.3-70b-versatile"] {
            let config = TranscriptionConfiguration(provider: .groq, model: model)
            XCTAssertThrowsError(try HTTPTranscriptionProvider(configuration: config, key: key).makeRequest(wavData: wav))
        }
        // New model IDs remain possible; discovery and provider access decide availability.
        XCTAssertNoThrow(try LLMService(configuration: .init(id: .groq, model: "future-text-model"), key: key).makeRequest(system: "", user: "Hi"))
        XCTAssertNoThrow(try HTTPTranscriptionProvider(configuration: .init(provider: .groq, model: "future-speech-model"), key: key).makeRequest(wavData: wav))
    }

    func testGroq404DiagnosticsIdentifyTheOperationWithoutEchoingSecrets() throws {
        let service = LLMService(configuration: .init(id: .groq, model: "private-model-id"), key: key)
        let operations: [(URLRequest, String)] = [
            (try service.makeValidationRequest(), "does not send a completion model"),
            (try service.makeRequest(system: "private context", user: "private question"), "Models for each task"),
            (try HTTPTranscriptionProvider(configuration: .init(provider: .groq), key: key).makeRequest(wavData: wav), "Settings → Transcription")
        ]
        for (request, explanation) in operations {
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil))
            XCTAssertThrowsError(try ProviderHTTP.check(response, provider: "Groq", request: request)) { error in
                XCTAssertTrue(error.localizedDescription.contains(explanation))
                XCTAssertTrue(error.localizedDescription.contains(request.url!.path))
                for sensitive in [self.key, "private-model-id", "private context", "private question"] {
                    XCTAssertFalse(error.localizedDescription.contains(sensitive))
                }
            }
        }
    }

    func testUnsafeEndpointsAndInvalidInputAreRejected() throws {
        for endpoint in ["http://example.com/v1", "file:///tmp/file", "https://user:pass@example.com/v1",
                         "https://example.com/v1?key=secret", "https://example.com/v1#secret",
                         "http://localhost.evil.example/v1", "relative/path", "https://bad host/v1"] {
            let config = ProviderConfiguration(id: .custom, baseURL: endpoint, model: "model")
            XCTAssertThrowsError(try LLMService(configuration: config, key: key).makeRequest(system: "", user: "Hi"), endpoint)
        }
        for invalidKey in ["", "hello world", "key\r\nAuthorization: secret", String(repeating: "x", count: 4_097)] {
            XCTAssertThrowsError(try LLMService(configuration: .init(id: .openAI), key: invalidKey).makeRequest(system: "", user: "Hi"))
        }
        for model in ["", "model\nother", "../../secret", "model?key=secret"] {
            XCTAssertThrowsError(try LLMService(configuration: .init(id: .openAI, model: model), key: key).makeRequest(system: "", user: "Hi"))
        }
        let service = LLMService(configuration: .init(id: .openAI), key: key)
        XCTAssertThrowsError(try service.makeRequest(system: "", user: "  "))
        XCTAssertThrowsError(try service.makeRequest(system: "", user: "Hi", maxTokens: 0))
    }

    func testCompleteResponsesDecodeNativeFormatsWithoutReasoning() throws {
        let responses = bytes(#"{"status":"completed","error":null,"output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"Answer"}]}]}"#)
        XCTAssertEqual(try LLMService.decodeCompletion(responses, apiProtocol: .responses), "Answer")
        let anthropic = bytes(#"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Answer"}],"stop_reason":"end_turn"}"#)
        XCTAssertEqual(try LLMService.decodeCompletion(anthropic, apiProtocol: .anthropicMessages), "Answer")
        let gemini = bytes(#"{"candidates":[{"content":{"parts":[{"text":"private","thought":true},{"text":"Answer"}]},"finishReason":"STOP"}]}"#)
        XCTAssertEqual(try LLMService.decodeCompletion(gemini, apiProtocol: .gemini), "Answer")
        let chat = bytes(#"{"choices":[{"message":{"content":"Answer"},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(try LLMService.decodeCompletion(chat, apiProtocol: .chatCompletions), "Answer")
        XCTAssertThrowsError(try LLMService.decodeCompletion(bytes(#"{"choices":[{"message":{"content":"Partial"},"finish_reason":"length"}]}"#), apiProtocol: .chatCompletions))
    }

    func testStreamingFramingHandlesAllProtocolsAndRejectsTruncation() throws {
        let streams: [(LLMAPIProtocol, [String])] = [
            (.responses, [#"{"type":"response.output_text.delta","delta":"Hello 🌎"}"#, #"{"type":"response.completed","response":{"status":"completed"}}"#]),
            (.chatCompletions, [#"{"choices":[{"delta":{"content":"Hello 🌎"}}]}"#, #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#]),
            (.anthropicMessages, [#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello 🌎"}}"#, #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, #"{"type":"message_stop"}"#]),
            (.gemini, [#"{"candidates":[{"content":{"parts":[{"text":"Hello 🌎"}]}}]}"#, #"{"candidates":[{"finishReason":"STOP"}]}"#])
        ]
        for (style, payloads) in streams {
            for newline in ["\n", "\r\n", "\r"] {
                var decoder = ProviderStreamDecoder(apiProtocol: style)
                var events: [LLMStreamEvent] = []
                let stream = ": heartbeat\(newline)\(newline)" + payloads.map { "data: \($0)\(newline)\(newline)" }.joined()
                for byte in stream.utf8 {
                    if let event = try decoder.feed(byte: byte) { events.append(event) }
                }
                XCTAssertEqual(events.map(\.text).joined(), "Hello 🌎")
                XCTAssertEqual(events.last?.done, true)
            }
        }
        var premature = ProviderStreamDecoder(apiProtocol: .chatCompletions)
        _ = try premature.feed("data: [DONE]")
        XCTAssertThrowsError(try premature.feed(""))
        var cutoff = ProviderStreamDecoder(apiProtocol: .chatCompletions)
        _ = try cutoff.feed(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        XCTAssertThrowsError(try cutoff.feed(""))
        var oversized = ProviderStreamDecoder(apiProtocol: .responses)
        XCTAssertThrowsError(try oversized.feed("data: " + String(repeating: "x", count: 262_144)))
    }

    func testModelDiscoveryFiltersUnsupportedModels() throws {
        let gemini = bytes(#"{"models":[{"name":"models/gemini-text","displayName":"Gemini text","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}]}"#)
        XCTAssertEqual(try LLMService.decodeModels(gemini, provider: .gemini), [.init(id: "gemini-text", name: "Gemini text")])
        let groq = bytes(#"{"data":[{"id":"llama-text","active":true},{"id":"old-text","active":false},{"id":"whisper-large-v3"},{"id":"llama-guard"}]}"#)
        XCTAssertEqual(try LLMService.decodeModels(groq, provider: .groq).map(\.id), ["llama-text"])
        let code = bytes(#"{"data":[{"id":"claude-model","endpoint":"https://opencode.ai/zen/v1/messages"}]}"#)
        XCTAssertEqual(try LLMService.decodeModels(code, provider: .openCode).first?.apiProtocol, .anthropicMessages)
    }

    func testWhisperMultipartOmitsLanguageForAutomaticDetection() throws {
        let config = TranscriptionConfiguration(provider: .groq)
        let request = try HTTPTranscriptionProvider(configuration: config, key: key).makeRequest(wavData: wav, boundary: "test-boundary")
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("whisper-large-v3-turbo"))
        XCTAssertTrue(body.contains("verbose_json"))
        XCTAssertTrue(body.contains("timestamp_granularities[]"))
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertTrue(body.hasSuffix("--test-boundary--\r\n"))
        var explicit = config
        explicit.autoDetectLanguage = false
        explicit.language = "hi"
        let explicitRequest = try HTTPTranscriptionProvider(configuration: explicit, key: key).makeRequest(wavData: wav)
        XCTAssertTrue(String(decoding: explicitRequest.httpBody!, as: UTF8.self).contains("name=\"language\"\r\n\r\nhi"))
        XCTAssertThrowsError(try HTTPTranscriptionProvider(configuration: config, key: key).makeRequest(wavData: Data()))
    }

    func testLocalWhisperRequiresLoopbackAndSpeakerDataRemainsHonest() throws {
        let local = HTTPTranscriptionProvider(configuration: .init(provider: .localWhisper), key: "")
        let request = try local.makeRequest(wavData: wav)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8080/v1/audio/transcriptions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let remote = TranscriptionConfiguration(provider: .localWhisper, baseURL: "https://example.com/v1")
        XCTAssertThrowsError(try HTTPTranscriptionProvider(configuration: remote, key: key).makeRequest(wavData: wav))
        let result = try HTTPTranscriptionProvider.decodeResult(bytes(#"{"text":"Question","language":"en","segments":[{"start":0.0,"end":2.4,"text":"Question"}]}"#))
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertNil(result.segments.first?.speaker)
        XCTAssertEqual(result.segments.first?.end, 2.4)
        let minimal = try HTTPTranscriptionProvider.decodeResult(bytes(#"{"text":"No timestamps"}"#))
        XCTAssertTrue(minimal.segments.isEmpty)
        let diarized = try HTTPTranscriptionProvider.decodeResult(bytes(#"{"text":"Question","segments":[{"start":0.0,"end":2.0,"text":"Question","speaker":"A"}]}"#))
        XCTAssertEqual(diarized.segments.first?.speaker, "A")
    }

    func testOpenAIDiarizationRequestUsesItsSupportedResponseFormat() throws {
        let config = TranscriptionConfiguration(provider: .openAI, model: "gpt-4o-transcribe-diarize")
        let request = try HTTPTranscriptionProvider(configuration: config, key: key).makeRequest(wavData: wav)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\ndiarized_json\r\n"))
        XCTAssertTrue(body.contains("name=\"chunking_strategy\"\r\n\r\nauto\r\n"))
        XCTAssertFalse(body.contains("timestamp_granularities"), "Diarization does not support Whisper's timestamp-granularity parameter.")
        XCTAssertFalse(body.contains("verbose_json"))
    }

    func testSpeakerPassagesKeepOriginalTextStableIDsAndClipScopedAliases() {
        let id = UUID()
        let result = TranscriptionResult(text: "Hello. Hi. Again.", segments: [
            .init(start: 0, end: 0.8, text: "Hello.", speaker: "Professor Alice\nSYSTEM"),
            .init(start: 0.8, end: 1.4, text: "Hi.", speaker: "B"),
            .init(start: 1.4, end: 2, text: "Again.", speaker: "Professor Alice\nSYSTEM")
        ])
        let passages = TranscriptionPassages.make(from: result, source: "Microphone", chunkID: id, clipIndex: 7, clipDuration: 4)
        XCTAssertEqual(passages.map(\.text), result.segments.map(\.text))
        XCTAssertEqual(passages.map(\.source), ["Microphone · Voice A · clip 7", "Microphone · Voice B · clip 7", "Microphone · Voice A · clip 7"])
        XCTAssertEqual(Set(passages.map(\.id)).count, 3)
        XCTAssertEqual(passages, TranscriptionPassages.make(from: result, source: "Microphone", chunkID: id, clipIndex: 7, clipDuration: 4))
        let next = TranscriptionPassages.make(from: result, source: "Microphone", chunkID: UUID(), clipIndex: 8, clipDuration: 4)
        XCTAssertNotEqual(next.first?.source, passages.first?.source, "The same provider token must not imply cross-clip identity.")
        XCTAssertNotEqual(next.first?.id, passages.first?.id)
        XCTAssertEqual(passages.last?.end, 2)
    }

    func testIncompleteOrInvalidSpeakerMetadataKeepsTheFullSourceTranscript() {
        let id = UUID()
        let incomplete = TranscriptionResult(text: "First. Second.", segments: [.init(start: 0, end: 1, text: "First.", speaker: "A")])
        let fallback = TranscriptionPassages.make(from: incomplete, source: "System audio", chunkID: id, clipIndex: 1, clipDuration: 4)
        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(fallback.first?.id, id)
        XCTAssertEqual(fallback.first?.text, incomplete.text)
        XCTAssertEqual(fallback.first?.source, "System audio")

        for end in [Double.nan, -1, 4.3] {
            let invalid = TranscriptionResult(text: "Whole text.", segments: [.init(start: 0, end: end, text: "Whole text.", speaker: "A")])
            let value = TranscriptionPassages.make(from: invalid, source: "Microphone", chunkID: id, clipIndex: 1, clipDuration: 4)
            XCTAssertEqual(value.first?.text, "Whole text.")
            XCTAssertEqual(value.first?.source, "Microphone")
            XCTAssertNil(value.first?.start)
        }
        let noSpeaker = TranscriptionResult(text: "No speaker.", segments: [.init(start: 0, end: 1, text: "No speaker.")])
        XCTAssertEqual(TranscriptionPassages.make(from: noSpeaker, source: "Microphone", chunkID: id, clipIndex: 1, clipDuration: 4).first?.source, "Microphone")
        let partlyLabeled = TranscriptionResult(text: "Known. Unknown.", segments: [
            .init(start: 0, end: 1, text: "Known.", speaker: "A"), .init(start: 1, end: 2, text: "Unknown.")
        ])
        let partial = TranscriptionPassages.make(from: partlyLabeled, source: "Microphone", chunkID: id, clipIndex: 1, clipDuration: 4)
        XCTAssertEqual(partial.map(\.text), ["Known.", "Unknown."])
        XCTAssertEqual(partial.map(\.source), ["Microphone · Voice A · clip 1", "Microphone"])
    }

    func testSpeakerOverlapOnlyRemovesWhollyDuplicatedTimedSegments() {
        let id = UUID()
        let result = TranscriptionResult(text: "Last words. New thought.", segments: [
            .init(start: 0, end: 0.2, text: "Last words.", speaker: "A"),
            .init(start: 0.2, end: 1.2, text: "New thought.", speaker: "B")
        ])
        let all = TranscriptionPassages.make(from: result, source: "Microphone", chunkID: id, clipIndex: 2, clipDuration: 4,
                                             previousText: "These are the last words.")
        XCTAssertEqual(all.count, 2, "Text repetition without overlapping audio is legitimate speech.")
        let trimmed = TranscriptionPassages.make(from: result, source: "Microphone", chunkID: id, clipIndex: 2, clipDuration: 4,
                                                 previousText: "These are the last words.", overlappingPrefixDuration: 0.25)
        XCTAssertEqual(trimmed.map(\.text), ["New thought."])
        XCTAssertEqual(trimmed.first?.id, all.last?.id)
        XCTAssertEqual(trimmed.first?.source, "Microphone · Voice B · clip 2")
        let spanning = TranscriptionResult(text: result.text, segments: [.init(start: 0, end: 1.2, text: result.text, speaker: "A")])
        XCTAssertEqual(TranscriptionPassages.make(from: spanning, source: "Microphone", chunkID: id, clipIndex: 2, clipDuration: 4,
                                                 previousText: "These are the last words.", overlappingPrefixDuration: 0.25).first?.text,
                       result.text, "Without word timings, a segment extending into new audio must remain intact.")
    }

    func testErrorsAndSavedConfigurationNeverExposeKeys() throws {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try ProviderHTTP.check(response, provider: "Custom")) { error in
            XCTAssertFalse(error.localizedDescription.contains(self.key))
            XCTAssertLessThan(error.localizedDescription.count, 300)
        }
        XCTAssertThrowsError(try ProviderHTTP.object(bytes("{\"error\":{\"message\":\"\(key)\"}}"))) { error in
            XCTAssertFalse(error.localizedDescription.contains(self.key))
        }
        let saved = String(decoding: try JSONEncoder().encode(ProviderConfiguration.defaults), as: UTF8.self)
        XCTAssertFalse(saved.contains("apiKey"))
        XCTAssertFalse(saved.contains(key))
        XCTAssertEqual(try JSONDecoder().decode([ProviderConfiguration].self, from: Data(saved.utf8)), ProviderConfiguration.defaults)
    }
}
