import Foundation

// Provider settings contain identifiers only. Credentials belong in the app's Keychain store.
public enum AIProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI, anthropic, gemini, openRouter, groq, openCode, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        case .openCode: return "OpenCode Zen"
        case .custom: return "Custom endpoint"
        }
    }
}

public enum LLMAPIProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case responses, chatCompletions, anthropicMessages, gemini
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .responses: return "OpenAI Responses"
        case .chatCompletions: return "OpenAI-compatible chat"
        case .anthropicMessages: return "Anthropic Messages"
        case .gemini: return "Native Gemini"
        }
    }
}

public struct ProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: AIProviderID
    public var baseURL: String
    public var model: String
    public var enabled: Bool
    public var apiProtocol: LLMAPIProtocol
    public var ultrafast: Bool

    public init(id: AIProviderID, baseURL: String? = nil, model: String? = nil,
                enabled: Bool = false, apiProtocol: LLMAPIProtocol? = nil,
                ultrafast: Bool = false) {
        self.id = id
        self.baseURL = baseURL ?? Self.baseURL(for: id)
        self.model = model ?? Self.initialModel(for: id)
        self.enabled = enabled
        self.apiProtocol = apiProtocol ?? Self.initialProtocol(for: id)
        self.ultrafast = ultrafast
    }

    public var displayName: String { id.displayName }
    public static var defaults: [ProviderConfiguration] { AIProviderID.allCases.map { .init(id: $0) } }
    public static func defaultConfiguration(for id: AIProviderID) -> ProviderConfiguration { .init(id: id) }

    /// Repair only known Groq connection mistakes; retain model choices and unrelated providers.
    public func repairedSavedConfiguration() -> Self {
        guard id == .groq else { return self }
        var value = self
        if let canonical = try? ProviderHTTP.groqBaseURL(baseURL) { value.baseURL = canonical }
        if apiProtocol == .anthropicMessages || apiProtocol == .gemini { value.apiProtocol = .chatCompletions }
        return value
    }

    func requestBaseURL() throws -> String {
        guard id == .groq else { return baseURL }
        guard apiProtocol == .chatCompletions || apiProtocol == .responses else {
            throw AssistantError("Groq uses OpenAI-compatible chat or Responses. Reset the Groq connection in Settings → AI Providers.")
        }
        return try ProviderHTTP.groqBaseURL(baseURL)
    }

    private static func baseURL(for id: AIProviderID) -> String {
        switch id {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openCode: return "https://opencode.ai/zen/v1"
        case .custom: return ""
        }
    }

    private static func initialModel(for id: AIProviderID) -> String {
        // Initial suggestions, not an inventory. Refresh models or enter an account's model ID.
        switch id {
        case .openAI: return "gpt-6-astra"
        case .anthropic: return "claude-sonnet-4-5"
        case .gemini: return "gemini-3.8-flash"
        case .openRouter: return "openai/gpt-5"
        case .groq: return "llama-3.3-70b-versatile"
        case .openCode: return "big-pickle"
        case .custom: return ""
        }
    }

    private static func initialProtocol(for id: AIProviderID) -> LLMAPIProtocol {
        switch id {
        case .openAI: return .responses
        case .anthropic: return .anthropicMessages
        case .gemini: return .gemini
        default: return .chatCompletions
        }
    }
}

public enum AITask: String, CaseIterable, Codable, Identifiable, Sendable {
    case questionDetection, liveQuestion, sessionSummary, deepAnalysis, quickCommand
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .questionDetection: return "Question detection"
        case .liveQuestion: return "Live question answering"
        case .sessionSummary: return "Session summaries"
        case .deepAnalysis: return "Deep analysis"
        case .quickCommand: return "Quick commands"
        }
    }
}

public struct ModelSelection: Codable, Equatable, Sendable {
    public var provider: AIProviderID?
    public var model: String
    public init(provider: AIProviderID? = nil, model: String = "") {
        self.provider = provider
        self.model = model
    }
}

public struct ProviderModel: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var apiProtocol: LLMAPIProtocol?
    public init(id: String, name: String? = nil, apiProtocol: LLMAPIProtocol? = nil) {
        self.id = id
        self.name = name ?? id
        self.apiProtocol = apiProtocol
    }
}

public protocol LLMProvider {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
    func stream(system: String, user: String, maxTokens: Int,
                onDelta: @escaping @Sendable (String) async -> Void) async throws
    func getModels() async throws -> [ProviderModel]
    func validateApiKey() async throws
}

/// Native wire formats stay here, outside the SwiftUI and listening state layers.
public struct LLMService: LLMProvider, Sendable {
    public let configuration: ProviderConfiguration
    private let key: String
    public init(configuration: ProviderConfiguration, key: String) {
        self.configuration = configuration
        self.key = key
    }

    public func makeRequest(system: String, user: String, maxTokens: Int = 2_048,
                            stream: Bool = false) throws -> URLRequest {
        let model = try ProviderHTTP.model(configuration.model)
        if configuration.id == .groq && (model.lowercased().contains("whisper") || model.lowercased().contains("transcrib")) {
            throw AssistantError("A speech model cannot answer questions. Choose a Groq language model in AI Providers or Models for each task; choose Whisper under Transcription.")
        }
        guard (1...32_768).contains(maxTokens) else { throw AssistantError("Choose an output budget from 1 to 32,768 tokens.") }
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError("There is no content to send to the model.") }
        guard system.utf8.count + user.utf8.count <= 600_000 else { throw AssistantError("The selected context is too large. Narrow the question or use fewer passages.") }
        let endpoint: String
        var payload: [String: Any]
        switch configuration.apiProtocol {
        case .responses:
            endpoint = "responses"
            payload = ["model": model, "instructions": system, "input": user,
                       "max_output_tokens": maxTokens, "stream": stream, "store": false]
            if configuration.id == .openAI && model == AnswerClient.astraModel {
                payload["reasoning"] = ["effort": "low"]
                if configuration.ultrafast { payload["service_tier"] = "ultrafast" }
            }
        case .chatCompletions:
            endpoint = "chat/completions"
            payload = ["model": model, "messages": [["role": "system", "content": system],
                                                        ["role": "user", "content": user]], "stream": stream]
            payload[configuration.id == .openAI || configuration.id == .groq ? "max_completion_tokens" : "max_tokens"] = maxTokens
        case .anthropicMessages:
            endpoint = "messages"
            payload = ["model": model, "system": system, "messages": [["role": "user", "content": user]],
                       "max_tokens": maxTokens, "stream": stream]
        case .gemini:
            let modelID = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard !modelID.contains("/") else { throw AssistantError("Enter a Gemini model ID, without an endpoint path.") }
            endpoint = "models/\(modelID):\(stream ? "streamGenerateContent" : "generateContent")"
            payload = ["systemInstruction": ["parts": [["text": system]]],
                       "contents": [["role": "user", "parts": [["text": user]]]],
                       "generationConfig": ["maxOutputTokens": maxTokens]]
        }
        var request = try ProviderHTTP.request(baseURL: configuration.requestBaseURL(), endpoint: endpoint,
                                               key: key, apiProtocol: configuration.apiProtocol)
        if configuration.apiProtocol == .gemini && stream {
            var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            request.url = parts.url
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    public func complete(system: String, user: String, maxTokens: Int = 2_048) async throws -> String {
        let request = try makeRequest(system: system, user: user, maxTokens: maxTokens)
        let data = try await ProviderHTTP.data(for: request, provider: configuration.displayName)
        return try Self.decodeCompletion(data, apiProtocol: configuration.apiProtocol)
    }

    public func stream(system: String, user: String, maxTokens: Int = 2_048,
                       onDelta: @escaping @Sendable (String) async -> Void) async throws {
        let request = try makeRequest(system: system, user: user, maxTokens: maxTokens, stream: true)
        let (bytes, response) = try await ProviderHTTP.session.bytes(for: request)
        try ProviderHTTP.check(response, provider: configuration.displayName, request: request)
        guard let http = response as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw AssistantError("The provider did not return an event stream. Check its API protocol in Settings.")
        }
        var decoder = ProviderStreamDecoder(apiProtocol: configuration.apiProtocol)
        var characters = 0
        var pending = ""
        var lastDelivery = ProcessInfo.processInfo.systemUptime
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let event = try decoder.feed(byte: byte) else { continue }
            if !event.text.isEmpty {
                characters += event.text.count
                guard characters <= 160_000 else { throw AssistantError("The response exceeded the output limit.") }
                pending += event.text
                let now = ProcessInfo.processInfo.systemUptime
                if characters == event.text.count || now - lastDelivery >= 0.025 {
                    await onDelta(pending)
                    pending = ""
                    lastDelivery = now
                }
            }
            if event.done {
                guard characters > 0 else { throw AssistantError("The model returned no text. Try another model or a larger output budget.") }
                if !pending.isEmpty { await onDelta(pending) }
                return
            }
        }
        // A disconnected or truncated stream must not be treated as a complete answer.
        throw AssistantError("The connection ended before the response finished. Please retry.")
    }

    public func getModels() async throws -> [ProviderModel] {
        var request = try ProviderHTTP.request(baseURL: configuration.requestBaseURL(), endpoint: "models", key: key,
                                               apiProtocol: configuration.apiProtocol)
        request.httpMethod = "GET"
        var all: [ProviderModel] = []
        for _ in 0..<8 {
            let data = try await ProviderHTTP.data(for: request, provider: configuration.displayName)
            let object = try ProviderHTTP.object(data)
            all += try Self.decodeModels(data, provider: configuration.id)
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            if configuration.id == .gemini, let token = object["nextPageToken"] as? String, !token.isEmpty {
                components.queryItems = [URLQueryItem(name: "pageToken", value: token)]
            } else if configuration.id == .anthropic, object["has_more"] as? Bool == true,
                      let last = object["last_id"] as? String {
                components.queryItems = [URLQueryItem(name: "after_id", value: last)]
            } else { break }
            request.url = components.url
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func validateApiKey() async throws {
        // OpenRouter has a dedicated authenticated key endpoint; its public catalogue is not an auth test.
        if configuration.id == .openRouter {
            let request = try makeValidationRequest()
            let data = try await ProviderHTTP.data(for: request, provider: configuration.displayName)
            guard try ProviderHTTP.object(data)["data"] is [String: Any] else {
                throw AssistantError("OpenRouter could not verify this key.")
            }
            return
        }
        // Some compatible servers publish model lists. Availability alone does not prove generation access or credit.
        _ = try await getModels()
    }

    func makeValidationRequest() throws -> URLRequest {
        var request = try ProviderHTTP.request(baseURL: configuration.requestBaseURL(),
                                               endpoint: configuration.id == .openRouter ? "key" : "models",
                                               key: key, apiProtocol: configuration.apiProtocol)
        request.httpMethod = "GET"
        return request
    }

    static func decodeModels(_ data: Data, provider: AIProviderID) throws -> [ProviderModel] {
        let object = try ProviderHTTP.object(data)
        guard let entries = (object["data"] ?? object["models"]) as? [[String: Any]] else {
            throw AssistantError("This endpoint did not return a model list. Enter a model ID manually.")
        }
        return entries.compactMap { entry in
            if provider == .groq, entry["active"] as? Bool == false { return nil }
            guard let rawID = (entry["id"] ?? entry["name"]) as? String else { return nil }
            let id = provider == .gemini && rawID.hasPrefix("models/") ? String(rawID.dropFirst(7)) : rawID
            guard (try? ProviderHTTP.model(id)) != nil else { return nil }
            if provider == .gemini {
                let methods = entry["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { return nil }
            }
            if provider == .groq || provider == .openAI {
                let lower = id.lowercased()
                if ["whisper", "transcri", "tts", "embedding", "dall-e", "image", "sora", "moderation", "realtime", "audio", "guard"].contains(where: { lower.contains($0) }) { return nil }
            }
            let name = (entry["displayName"] ?? entry["display_name"] ?? entry["name"]) as? String ?? id
            // OpenCode serves several protocols. Only attach a protocol when its metadata identifies one.
            let endpoint = (entry["endpoint"] ?? entry["url"]) as? String ?? ""
            let style: LLMAPIProtocol?
            if endpoint.contains("/chat/completions") { style = .chatCompletions }
            else if endpoint.contains("/responses") { style = .responses }
            else if endpoint.contains("/messages") { style = .anthropicMessages }
            else if endpoint.contains(":generateContent") { style = .gemini }
            else { style = nil }
            return ProviderModel(id: id, name: name, apiProtocol: style)
        }
    }

    static func decodeCompletion(_ data: Data, apiProtocol: LLMAPIProtocol) throws -> String {
        let object = try ProviderHTTP.object(data)
        let text: String
        switch apiProtocol {
        case .responses:
            guard object["status"] as? String == "completed" else { throw AssistantError("The model did not finish its response. Try a larger output budget.") }
            let output = object["output"] as? [[String: Any]] ?? []
            text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .compactMap { part -> String? in
                    if part["type"] as? String == "output_text" { return part["text"] as? String }
                    if part["type"] as? String == "refusal" { return part["refusal"] as? String }
                    return nil
                }.joined()
        case .chatCompletions:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { throw AssistantError("The model returned no completion.") }
            try ProviderHTTP.checkFinish(choice["finish_reason"] as? String, allowed: ["stop"])
            let message = choice["message"] as? [String: Any] ?? [:]
            text = message["content"] as? String ?? message["refusal"] as? String ?? ""
        case .anthropicMessages:
            try ProviderHTTP.checkFinish(object["stop_reason"] as? String, allowed: ["end_turn", "stop_sequence"])
            text = (object["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { throw AssistantError("Gemini returned no text. The request may have been blocked.") }
            try ProviderHTTP.checkFinish(candidate["finishReason"] as? String, allowed: ["STOP"])
            text = ProviderHTTP.geminiText(candidate)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 160_000 else {
            throw AssistantError("The model returned empty or oversized text. Try another model or output budget.")
        }
        return text
    }
}

public enum TranscriptionProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto, apple, groq, openAI, localWhisper, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .auto: return "Auto — Recommended"
        case .apple: return "Apple Speech"
        case .groq: return "Groq Whisper"
        case .openAI: return "OpenAI"
        case .localWhisper: return "Local Whisper (server)"
        case .custom: return "Custom transcription"
        }
    }
}

public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    public var provider: TranscriptionProviderID
    public var model: String
    public var baseURL: String
    public var language: String
    public var autoDetectLanguage: Bool
    public init(provider: TranscriptionProviderID = .auto, model: String = "", baseURL: String = "",
                language: String = "en", autoDetectLanguage: Bool = true) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.language = language
        self.autoDetectLanguage = autoDetectLanguage
    }

    /// Provider changes must not reuse another provider's model or credential destination.
    public func selectingProvider(_ provider: TranscriptionProviderID) -> Self {
        guard provider != self.provider else { return self }
        return Self(provider: provider, language: language, autoDetectLanguage: autoDetectLanguage)
    }

    /// Older settings kept the previous provider's hidden fields when the speech provider changed.
    /// Repair identifiable built-in leftovers; unknown endpoints remain visible as validation errors.
    public func repairedSavedConfiguration() -> Self {
        var value = self
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedURL = try? ProviderHTTP.baseURL(baseURL)
        switch provider {
        case .groq:
            if cleanModel == "whisper-1" || cleanModel.hasPrefix("gpt-") && cleanModel.contains("transcrib") {
                value.model = ""
            }
            if let canonical = try? ProviderHTTP.groqBaseURL(baseURL) {
                // An empty field deliberately follows the provider default.
                if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.baseURL = canonical }
            } else if let savedURL, savedURL.host?.lowercased() == "api.openai.com",
                      savedURL.port == nil || savedURL.port == 443,
                      ["", "/", "/v1", "/v1/", "/v1/audio/transcriptions"].contains(savedURL.path) {
                value.baseURL = ""
            }
        case .openAI:
            if cleanModel == "whisper-large-v3" || cleanModel == "whisper-large-v3-turbo" { value.model = "" }
            if let savedURL, savedURL.host?.lowercased() == "api.groq.com",
               (try? ProviderHTTP.groqBaseURL(baseURL)) != nil { value.baseURL = "" }
        default: break
        }
        return value
    }

    func requestBaseURL() throws -> String {
        if provider == .groq { return try ProviderHTTP.groqBaseURL(resolvedBaseURL) }
        return resolvedBaseURL
    }
    public var resolvedBaseURL: String {
        if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return baseURL }
        switch provider {
        case .groq: return "https://api.groq.com/openai/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .localWhisper: return "http://127.0.0.1:8080/v1"
        default: return ""
        }
    }
    public var resolvedModel: String {
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return model }
        if provider == .custom { return "" }
        return provider == .groq ? "whisper-large-v3-turbo" : "whisper-1"
    }
}

public struct TranscriptionSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

public struct TranscriptionResult: Codable, Equatable, Sendable {
    public var text: String
    public var segments: [TranscriptionSegment]
    public var language: String?
    public init(text: String, segments: [TranscriptionSegment] = [], language: String? = nil) {
        self.text = text
        self.segments = segments
        self.language = language
    }
}

public struct TranscriptionPassage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: String
    public let text: String
    /// Provider timestamps are relative to this clip, never inferred as a person's identity across clips.
    public let start: Double?
    public let end: Double?
}

public enum TranscriptionPassages {
    /// Only complete, temporally valid segmentation replaces the full transcript. Voice aliases are clip-scoped.
    public static func make(from result: TranscriptionResult, source: String, chunkID: UUID,
                            clipIndex: Int, clipDuration: Double, previousText: String = "",
                            overlappingPrefixDuration: Double = 0) -> [TranscriptionPassage] {
        let cleanSource = String(source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(40))
        let sourceLabel = cleanSource.isEmpty ? "Audio" : cleanSource
        let overlap = overlappingPrefixDuration.isFinite ? max(0, min(0.25, overlappingPrefixDuration)) : 0
        func fallback() -> [TranscriptionPassage] {
            let text = TranscriptOverlap.removingRepeatedPrefix(result.text, previous: previousText,
                                                                overlappingAudio: overlap > 0, maximumWords: 4)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [.init(id: chunkID, source: sourceLabel, text: text, start: nil, end: nil)]
        }
        let segments = result.segments
        guard !segments.isEmpty, segments.count <= 512, clipDuration.isFinite, clipDuration > 0,
              segments.contains(where: { speakerToken($0.speaker) != nil }) else { return fallback() }
        var previousStart = -Double.infinity
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                  segment.start >= previousStart, segment.end >= segment.start,
                  segment.end <= clipDuration + 0.05,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback() }
            previousStart = segment.start
        }
        // Preserve punctuation and word boundaries: incomplete metadata must never swallow part of the transcript.
        let joined = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
        guard canonical(joined) == canonical(result.text) else { return fallback() }

        var aliases: [String: String] = [:]
        let labels = segments.map { segment -> String in
            guard let token = speakerToken(segment.speaker) else { return sourceLabel }
            if aliases[token] == nil {
                let count = aliases.count
                aliases[token] = count < 26 ? String(UnicodeScalar(65 + count)!) : String(count + 1)
            }
            // Never display a provider token as a named person or reuse its apparent identity in another clip.
            return "\(sourceLabel) · Voice \(aliases[token]!) · clip \(max(1, clipIndex))"
        }
        let skip = overlappingSegmentCount(segments, previous: previousText, duration: overlap)
        return segments.enumerated().compactMap { index, segment in
            guard index >= skip else { return nil }
            return .init(id: passageID(chunkID: chunkID, index: index), source: labels[index], text: segment.text,
                         start: min(segment.start, clipDuration), end: min(segment.end, clipDuration))
        }
    }

    private static func canonical(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func speakerToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !token.isEmpty && token.count <= 128 ? token : nil
    }

    private static func passageID(chunkID: UUID, index: Int) -> UUID {
        // Stable for this clip and source segment; emitting or filtering a neighboring segment does not change it.
        var value = chunkID.uuid
        let ordinal = UInt32(index + 1)
        value.12 ^= UInt8(truncatingIfNeeded: ordinal >> 24)
        value.13 ^= UInt8(truncatingIfNeeded: ordinal >> 16)
        value.14 ^= UInt8(truncatingIfNeeded: ordinal >> 8)
        value.15 ^= UInt8(truncatingIfNeeded: ordinal)
        return UUID(uuid: value)
    }

    private static func overlappingSegmentCount(_ segments: [TranscriptionSegment], previous: String,
                                                 duration: Double) -> Int {
        guard duration > 0, segments.count > 1 else { return 0 }
        let prior = TranscriptStore.normalized(previous).split(separator: " ").map(String.init)
        var prefix: [String] = []
        var matched = 0
        for (index, segment) in segments.dropLast().enumerated() {
            // Without word timestamps, never cut a segment that extends beyond the actual overlapping audio.
            guard segment.end <= duration + 0.01 else { break }
            prefix += TranscriptStore.normalized(segment.text).split(separator: " ").map(String.init)
            guard !prefix.isEmpty, prefix.count <= 4 else { break }
            if prior.count >= prefix.count, Array(prior.suffix(prefix.count)) == prefix { matched = index + 1 }
        }
        return matched
    }
}

public protocol TranscriptionProvider {
    func transcribe(wavData: Data) async throws -> TranscriptionResult
    /// Each input is a complete WAV chunk. Returned timestamps are relative to that chunk.
    func stream(chunks: AsyncThrowingStream<Data, Error>,
                onResult: @escaping @Sendable (TranscriptionResult) async -> Void) async throws
    func getModels() async throws -> [ProviderModel]
    func validateApiKey() async throws
}

/// Near-live transcription via complete file chunks; this does not claim Whisper has a native socket stream.
public struct HTTPTranscriptionProvider: TranscriptionProvider, Sendable {
    public let configuration: TranscriptionConfiguration
    private let key: String
    public init(configuration: TranscriptionConfiguration, key: String) {
        self.configuration = configuration
        self.key = key
    }

    public func makeRequest(wavData: Data, boundary: String = "Notch-\(UUID().uuidString)") throws -> URLRequest {
        try checkConfiguration()
        guard wavData.count >= 44, wavData.count <= 25 * 1_024 * 1_024,
              String(data: wavData.prefix(4), encoding: .ascii) == "RIFF",
              String(data: wavData.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else {
            throw AssistantError("Transcription needs a complete WAV chunk smaller than 25 MB.")
        }
        guard boundary.range(of: "^[A-Za-z0-9-]{1,80}$", options: .regularExpression) != nil else { throw AssistantError("Invalid upload boundary.") }
        let model = try ProviderHTTP.model(configuration.resolvedModel)
        if configuration.provider == .groq {
            let lower = model.lowercased()
            if lower == "whisper-1" || lower.hasPrefix("gpt-") || lower.hasPrefix("llama")
                || lower.hasPrefix("qwen") || lower.hasPrefix("gemma") || lower.hasPrefix("openai/") {
                throw AssistantError("Choose a Groq speech model such as whisper-large-v3-turbo in Settings → Transcription. OpenAI speech IDs and language models cannot transcribe on Groq.")
            }
        }
        var request = try ProviderHTTP.request(baseURL: configuration.requestBaseURL(), endpoint: "audio/transcriptions",
                                               key: key, apiProtocol: .chatCompletions)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        let diarize = configuration.provider == .openAI
            && (model == "gpt-4o-transcribe-diarize" || model.hasPrefix("gpt-4o-transcribe-diarize-"))
        let timestamps = configuration.provider == .groq || model == "whisper-1" || configuration.provider == .localWhisper || configuration.provider == .custom
        field("response_format", diarize ? "diarized_json" : (timestamps ? "verbose_json" : "json"))
        if timestamps { field("timestamp_granularities[]", "segment") }
        if diarize { field("chunking_strategy", "auto") }
        if !configuration.autoDetectLanguage {
            let language = configuration.language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$", options: .regularExpression) != nil else {
                throw AssistantError("Enter a language code such as en, hi, or pa.")
            }
            if configuration.provider == .groq && language.count != 2 {
                throw AssistantError("Groq expects a two-letter language code such as en, hi, or pa.")
            }
            if configuration.provider == .openAI && model == "gpt-transcribe" {
                field("languages[]", language)
            } else { field("language", language) }
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    public func transcribe(wavData: Data) async throws -> TranscriptionResult {
        let request = try makeRequest(wavData: wavData)
        let data = try await ProviderHTTP.data(for: request, provider: configuration.provider.displayName)
        return try Self.decodeResult(data)
    }

    public func stream(chunks: AsyncThrowingStream<Data, Error>,
                       onResult: @escaping @Sendable (TranscriptionResult) async -> Void) async throws {
        // Sequential processing preserves chunk order and applies backpressure at this boundary.
        // Capture owns the bounded input buffer, silence detection, overlap, and global time offsets.
        for try await chunk in chunks {
            try Task.checkCancellation()
            let result = try await transcribe(wavData: chunk)
            await onResult(result)
        }
    }

    public func getModels() async throws -> [ProviderModel] {
        try checkConfiguration()
        var request = try ProviderHTTP.request(baseURL: configuration.requestBaseURL(), endpoint: "models",
                                               key: key, apiProtocol: .chatCompletions)
        request.httpMethod = "GET"
        let data = try await ProviderHTTP.data(for: request, provider: configuration.provider.displayName)
        let object = try ProviderHTTP.object(data)
        guard let models = object["data"] as? [[String: Any]] else { throw AssistantError("This server does not list models. Enter the installed model ID manually.") }
        return models.compactMap { item in
            if configuration.provider == .groq, item["active"] as? Bool == false { return nil }
            guard let id = item["id"] as? String, (try? ProviderHTTP.model(id)) != nil else { return nil }
            if configuration.provider == .groq || configuration.provider == .openAI {
                guard id.contains("whisper") || id.contains("transcrib") else { return nil }
            }
            return ProviderModel(id: id, name: item["name"] as? String)
        }.sorted { $0.id < $1.id }
    }

    public func validateApiKey() async throws { _ = try await getModels() }

    private func checkConfiguration() throws {
        guard configuration.provider != .auto && configuration.provider != .apple else {
            throw AssistantError("Choose a cloud transcription provider or use Apple Speech through the audio capture service.")
        }
        if configuration.provider == .localWhisper {
            let url = try ProviderHTTP.baseURL(configuration.resolvedBaseURL)
            guard ProviderHTTP.isLoopback(url) else { throw AssistantError("Local Whisper needs a server on localhost. Use Custom for a remote server.") }
        }
    }

    static func decodeResult(_ data: Data) throws -> TranscriptionResult {
        let object = try ProviderHTTP.object(data)
        guard let text = object["text"] as? String, text.count <= 160_000 else {
            throw AssistantError("The transcription provider returned an invalid transcript.")
        }
        let segments = (object["segments"] as? [[String: Any]] ?? []).compactMap { segment -> TranscriptionSegment? in
            guard let start = segment["start"] as? Double, let end = segment["end"] as? Double,
                  start.isFinite, end.isFinite, start >= 0, end >= start,
                  let content = segment["text"] as? String else { return nil }
            return .init(start: start, end: end, text: content, speaker: segment["speaker"] as? String)
        }
        // Silence can legitimately produce empty text. Never invent speakers when a provider has no diarization.
        return .init(text: text, segments: segments, language: object["language"] as? String)
    }
}

enum ProviderHTTP {
    static let groqAPIBaseURL = "https://api.groq.com/openai/v1"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: ProviderRejectRedirects(), delegateQueue: nil)
    }()

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func baseURL(_ value: String) throws -> URL {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 2_048,
              let url = URL(string: clean), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              (parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http" && isLoopback(url))),
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AssistantError("Use an HTTPS base URL without credentials or query parameters. HTTP is allowed only for localhost.")
        }
        return url
    }

    /// Accept common pasted Groq URLs without duplicating an operation path. Never rewrite a host,
    /// downgrade transport, retain query credentials, or silently repoint a custom server.
    static func groqBaseURL(_ value: String) throws -> String {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return groqAPIBaseURL }
        let url = try baseURL(value)
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.groq.com",
              url.port == nil || url.port == 443 else {
            throw AssistantError("Groq uses https://api.groq.com/openai/v1. Reset the Groq connection in Settings; use Custom for another server.")
        }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let roots = ["", "/v1", "/openai", "/openai/v1"]
        let operations = ["/chat/completions", "/audio/transcriptions", "/models", "/responses"]
        guard roots.contains(path) || roots.contains(where: { root in operations.contains(where: { path == root + $0 }) }) else {
            throw AssistantError("The Groq base URL must be https://api.groq.com/openai/v1. Reset the connection in Settings; Notch adds the request path automatically.")
        }
        return groqAPIBaseURL
    }

    static func model(_ value: String) throws -> String {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 256,
              model.range(of: "^[A-Za-z0-9._:/@~-]+$", options: .regularExpression) != nil,
              !model.contains("..") else { throw AssistantError("Enter a valid model ID in Settings.") }
        return model
    }

    static func request(baseURL value: String, endpoint: String, key valueKey: String,
                        apiProtocol: LLMAPIProtocol) throws -> URLRequest {
        let base = try baseURL(value)
        let trimmed = valueKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if trimmed.isEmpty && isLoopback(base) { key = "" }
        else {
            do { key = try AnswerClient.validatedKey(valueKey) }
            catch { throw AssistantError("Enter a valid API key without spaces or line breaks.") }
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/" + endpoint
        guard let url = components.url else { throw AssistantError("The provider URL is invalid.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if !key.isEmpty {
            switch apiProtocol {
            case .anthropicMessages:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            case .gemini:
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        if apiProtocol == .anthropicMessages { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        return request
    }

    static func check(_ response: URLResponse, provider: String, request: URLRequest? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw AssistantError("The provider returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let detail: String
            switch http.statusCode {
            case 300..<400: detail = "Redirects are blocked. Enter the final API base URL in Settings."
            case 400, 422: detail = "Check the model ID, API protocol, and request settings."
            case 401, 403: detail = "Check the API key and model access."
            case 402: detail = "Check the provider account's credit or spending limit."
            case 404:
                if request?.url?.host?.lowercased() == "api.groq.com" {
                    switch request?.url?.path {
                    case "/openai/v1/models":
                        detail = "Groq's model-list endpoint was not found. Reset the Groq connection in Settings → AI Providers. This connection check does not send a completion model."
                    case "/openai/v1/audio/transcriptions":
                        detail = "Groq could not find the speech model or transcription endpoint. In Settings → Transcription, choose the Groq default or fetch available speech models."
                    case "/openai/v1/chat/completions", "/openai/v1/responses":
                        detail = "Groq could not find the language model or generation endpoint. Fetch models in Settings → AI Providers → Groq and choose an available model. Also check Groq model overrides under Models for each task."
                    default: detail = "Reset the Groq connection to https://api.groq.com/openai/v1 in Settings. Notch adds the request path automatically."
                    }
                } else { detail = "Check the base URL, model ID, and supported API protocol." }
            case 413: detail = "Use a smaller audio chunk or less context."
            case 429: detail = "Check credit and rate limits, then retry."
            default: detail = "The service is unavailable. Retry when it is reachable."
            }
            // Do not echo a server body: custom providers may include credentials or transcript content in errors.
            var operation = ""
            if request?.url?.host?.lowercased() == "api.groq.com", let path = request?.url?.path,
               ["/openai/v1/models", "/openai/v1/audio/transcriptions", "/openai/v1/chat/completions", "/openai/v1/responses"].contains(path),
               let method = request?.httpMethod, ["GET", "POST"].contains(method) {
                operation = " (\(method) \(path))"
            }
            throw AssistantError("\(provider) returned HTTP \(http.statusCode)\(operation). \(detail)")
        }
    }

    static func data(for request: URLRequest, provider: String) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        try check(response, provider: provider, request: request)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1_024 * 1_024 else { throw AssistantError("The provider returned an oversized response.") }
            data.append(byte)
        }
        return data
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 4 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError("The provider returned invalid JSON. Check the selected API protocol.")
        }
        guard object["error"] == nil || object["error"] is NSNull else { throw AssistantError("The provider reported an error. Check its settings and availability.") }
        return object
    }

    static func checkFinish(_ value: String?, allowed: [String]) throws {
        guard let value, allowed.contains(value) else { throw AssistantError("The model did not finish a text response. Try a larger output budget or another model.") }
    }

    static func geminiText(_ candidate: [String: Any]) -> String {
        let content = candidate["content"] as? [String: Any] ?? [:]
        return (content["parts"] as? [[String: Any]] ?? [])
            .filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
    }
}

private final class ProviderRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct LLMStreamEvent: Equatable {
    var text = ""
    var done = false
}

/// Bounded byte framing preserves split UTF-8, multi-line SSE, CRLF, and provider-specific terminal events.
struct ProviderStreamDecoder {
    let apiProtocol: LLMAPIProtocol
    private var lineBytes: [UInt8] = []
    private var lines: [String] = []
    private var eventBytes = 0
    private var afterCR = false
    private var anthropicFinish: String?
    init(apiProtocol: LLMAPIProtocol) { self.apiProtocol = apiProtocol }

    mutating func feed(byte: UInt8) throws -> LLMStreamEvent? {
        if afterCR {
            afterCR = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            afterCR = byte == 13
            guard let line = String(bytes: lineBytes, encoding: .utf8) else { throw AssistantError("The provider sent invalid UTF-8.") }
            lineBytes.removeAll(keepingCapacity: true)
            return try feed(line)
        }
        guard lineBytes.count < 262_144 else { throw AssistantError("The provider sent an oversized stream line.") }
        lineBytes.append(byte)
        return nil
    }

    mutating func feed(_ line: String) throws -> LLMStreamEvent? {
        if line.isEmpty {
            guard !lines.isEmpty else { return nil }
            let payload = lines.joined(separator: "\n")
            lines.removeAll(keepingCapacity: true)
            eventBytes = 0
            // Chat streams terminate on a checked finish_reason, not an unverified [DONE] sentinel.
            if payload == "[DONE]" { throw AssistantError("The stream ended without a completed response.") }
            return try decode(ProviderHTTP.object(Data(payload.utf8)))
        }
        if line.hasPrefix("data:") {
            var content = String(line.dropFirst(5))
            if content.first == " " { content.removeFirst() }
            eventBytes += content.utf8.count + 1
            guard eventBytes <= 262_144 else { throw AssistantError("The provider sent an oversized stream event.") }
            lines.append(content)
        }
        return nil
    }

    private mutating func decode(_ object: [String: Any]) throws -> LLMStreamEvent {
        switch apiProtocol {
        case .responses:
            switch object["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta": return .init(text: object["delta"] as? String ?? "")
            case "response.completed":
                let response = object["response"] as? [String: Any] ?? [:]
                try ProviderHTTP.checkFinish(response["status"] as? String, allowed: ["completed"])
                return .init(done: true)
            case "response.failed", "response.incomplete", "error": throw AssistantError("The provider could not complete this response.")
            default: return .init()
            }
        case .chatCompletions:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return .init() }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let text = delta["content"] as? String ?? delta["refusal"] as? String ?? ""
            if let finish = choice["finish_reason"] as? String {
                try ProviderHTTP.checkFinish(finish, allowed: ["stop"])
                return .init(text: text, done: true)
            }
            return .init(text: text)
        case .anthropicMessages:
            switch object["type"] as? String {
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any] ?? [:]
                return .init(text: delta["type"] as? String == "text_delta" ? delta["text"] as? String ?? "" : "")
            case "message_delta":
                anthropicFinish = (object["delta"] as? [String: Any])?["stop_reason"] as? String
                if let finish = anthropicFinish { try ProviderHTTP.checkFinish(finish, allowed: ["end_turn", "stop_sequence"]) }
                return .init()
            case "message_stop":
                try ProviderHTTP.checkFinish(anthropicFinish, allowed: ["end_turn", "stop_sequence"])
                return .init(done: true)
            case "error": throw AssistantError("Anthropic could not complete this response.")
            default: return .init()
            }
        case .gemini:
            if let feedback = object["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
                throw AssistantError("Gemini could not answer this request.")
            }
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { return .init() }
            let text = ProviderHTTP.geminiText(candidate)
            if let finish = candidate["finishReason"] as? String {
                try ProviderHTTP.checkFinish(finish, allowed: ["STOP"])
                return .init(text: text, done: true)
            }
            return .init(text: text)
        }
    }
}
