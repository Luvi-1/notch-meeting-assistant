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
        let groq = bytes(#"{"data":[{"id":"llama-text"},{"id":"whisper-large-v3"},{"id":"llama-guard"}]}"#)
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
