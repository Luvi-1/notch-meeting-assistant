import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai = "OpenAI", anthropic = "Anthropic", gemini = "Gemini"
    case openrouter = "OpenRouter", groq = "Groq", opencode = "OpenCode Zen", custom = "Custom"
    public var id: String { rawValue }
    public var baseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .opencode: return "https://opencode.ai/zen/v1"
        case .custom: return "http://127.0.0.1:11434/v1"
        }
    }
    public var defaultModel: String {
        switch self {
        case .openai, .opencode: return "gpt-6-astra"
        case .anthropic: return "claude-sonnet-5"
        case .gemini: return "gemini-3.8-flash"
        case .openrouter: return "openai/gpt-6-astra"
        case .groq: return "llama-3.3-70b-versatile"
        case .custom: return ""
        }
    }
}

public enum ProviderDialect: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic", responses = "Responses", chat = "Chat Completions"
    case anthropic = "Anthropic Messages", gemini = "Gemini"
    public var id: String { rawValue }
}

/// Credentials are deliberately absent from this Codable configuration.
public struct ProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ProviderKind
    public var name: String
    public var baseURL: String
    public var model: String
    public var dialect: ProviderDialect
    public var ultrafast: Bool
    public init(kind: ProviderKind, id: String? = nil) {
        self.id = id ?? kind.rawValue
        self.kind = kind
        name = kind.rawValue
        baseURL = kind.baseURL
        model = kind.defaultModel
        dialect = .automatic
        ultrafast = false
    }
    public var wireDialect: ProviderDialect {
        if kind == .custom || kind == .opencode, dialect != .automatic { return dialect }
        switch kind {
        case .openai: return .responses
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .opencode:
            if model.hasPrefix("claude-") { return .anthropic }
            if model.hasPrefix("gemini-") { return .gemini }
            if model.hasPrefix("gpt-") || model.hasPrefix("grok-") || model.hasPrefix("muse-") { return .responses }
            return .chat
        default: return .chat
        }
    }
    public func endpoint() throws -> URL {
        try ProviderHTTP.validatedURL(kind == .custom ? baseURL : kind.baseURL)
    }
}

public enum AIJob: String, Codable, CaseIterable, Identifiable, Sendable {
    case live = "Live Question Answering", summary = "Session Summary"
    case deep = "Deep Analysis", quick = "Quick Commands"
    public var id: String { rawValue }
}

public struct ModelRoute: Codable, Equatable, Sendable {
    public var providerID: String
    public var model: String
    public init(providerID: String = "", model: String = "") {
        self.providerID = providerID; self.model = model
    }
    public static func resolve(job: AIJob, route: ModelRoute, providers: [ProviderConfiguration],
                               configured: Set<String>) throws -> ProviderConfiguration {
        var result: ProviderConfiguration?
        if !route.providerID.isEmpty {
            result = providers.first { $0.id == route.providerID && configured.contains($0.id) }
            guard result != nil else { throw AssistantError("Configure the provider selected for \(job.rawValue).") }
        } else {
            let order: [ProviderKind] = job == .live || job == .quick
                ? [.gemini, .groq, .openai, .anthropic, .openrouter, .opencode, .custom]
                : [.anthropic, .openai, .gemini, .openrouter, .groq, .opencode, .custom]
            for kind in order {
                if let found = providers.first(where: { $0.kind == kind && configured.contains($0.id) && !$0.model.isEmpty }) {
                    result = found; break
                }
            }
        }
        guard var chosen = result else { throw AssistantError("Connect an AI provider in Settings to use \(job.rawValue).") }
        if !route.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chosen.model = route.model }
        return chosen
    }
}

public enum QuestionAssistance: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "Off", detect = "Detect only", suggest = "Detect + suggested answer", automatic = "Automatically answer questions"
    public var id: String { rawValue }
    public var detects: Bool { self != .off }
    public var generates: Bool { self == .suggest || self == .automatic }
    public func speaks(output: OutputMode) -> Bool { self == .automatic && output.usesVoice }
}

public enum ProviderHTTP {
    public static func validatedURL(_ value: String, localOnly: Bool = false) throws -> URL {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw AssistantError("Enter a base URL without credentials, query parameters, or fragments.") }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard parts.scheme == "https" || (parts.scheme == "http" && local), !localOnly || local else {
            throw AssistantError(localOnly ? "Local Whisper must use a loopback server on this Mac." : "Use HTTPS. HTTP is allowed only for a server on this Mac.")
        }
        return url
    }
    public static func validatedModel(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200,
              value.range(of: "^[A-Za-z0-9_./:-]+$", options: .regularExpression) != nil,
              !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AssistantError("Enter a valid model ID or refresh the provider's model list.")
        }
        return value
    }
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: NoProviderRedirects(), delegateQueue: nil)
    }()
    public static func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw AssistantError("The provider returned an invalid response.") }
        guard (200...299).contains(response.statusCode) else {
            let help: String
            switch response.statusCode {
            case 401, 403: help = "Check the saved API key and access."
            case 400, 404, 422: help = "Check the model, endpoint, and selected API format."
            case 429: help = "Check API credit and rate limits. Retry manually."
            default: help = "The service is unavailable. Retry manually."
            }
            throw AssistantError("Provider returned HTTP \(response.statusCode). \(help)")
        }
        return response
    }
    public static func data(for request: URLRequest, limit: Int = 10_000_000) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        _ = try check(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw AssistantError("The provider response exceeded the size limit.") }
            data.append(byte)
        }
        return data
    }
}

private final class NoProviderRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public protocol LLMProvider {
    func stream(system: String, prompt: String, maxTokens: Int,
                onDelta: @escaping @Sendable (String) async -> Void) async throws
    func getModels() async throws -> [String]
    func validateApiKey() async throws
}

public struct ConfiguredLLMProvider: LLMProvider, Sendable {
    public let configuration: ProviderConfiguration
    private let key: String
    public init(configuration: ProviderConfiguration, key: String) {
        self.configuration = configuration; self.key = key
    }
    private func authorized(_ url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        if !key.isEmpty {
            let safe = try AnswerClient.validatedKey(key)
            if configuration.wireDialect == .anthropic {
                request.setValue(safe, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if configuration.wireDialect == .gemini {
                request.setValue(safe, forHTTPHeaderField: "x-goog-api-key")
            } else { request.setValue("Bearer \(safe)", forHTTPHeaderField: "Authorization") }
        } else {
            let host = url.host ?? ""
            guard configuration.kind == .custom, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                throw AssistantError("Save an API key for \(configuration.name).")
            }
        }
        return request
    }
    public func makeRequest(system: String, prompt: String, maxTokens: Int = 2048) throws -> URLRequest {
        let model = try ProviderHTTP.validatedModel(configuration.model)
        let base = try configuration.endpoint()
        let tokens = min(16000, max(512, maxTokens))
        var body: [String: Any]
        let url: URL
        switch configuration.wireDialect {
        case .responses:
            url = base.appendingPathComponent("responses")
            body = ["model": model, "instructions": system, "input": prompt, "stream": true, "store": false, "max_output_tokens": tokens]
            if model == AnswerClient.astraModel {
                body["reasoning"] = ["effort": "low"]
                if configuration.kind == .openai && configuration.ultrafast { body["service_tier"] = "ultrafast" }
            }
        case .anthropic:
            url = base.appendingPathComponent("messages")
            body = ["model": model, "system": system, "messages": [["role": "user", "content": prompt]], "stream": true, "max_tokens": tokens]
        case .gemini:
            let id = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            var components = URLComponents(url: base.appendingPathComponent("models/\(id):streamGenerateContent"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            url = components.url!
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": prompt]]]],
                    "generationConfig": ["maxOutputTokens": tokens]]
        default:
            url = base.appendingPathComponent("chat/completions")
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]], "stream": true, "max_tokens": tokens]
        }
        var request = try authorized(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public func stream(system: String, prompt: String, maxTokens: Int = 2048,
                       onDelta: @escaping @Sendable (String) async -> Void) async throws {
        let request = try makeRequest(system: system, prompt: prompt, maxTokens: maxTokens)
        let (bytes, response) = try await ProviderHTTP.session.bytes(for: request)
        let http = try ProviderHTTP.check(response)
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw AssistantError("This endpoint did not return an event stream. Check the selected API format.")
        }
        var decoder = EventStreamDecoder()
        var finish: String?
        var count = 0
        var pending = ""
        var lastDelivery = 0.0
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let event = try decoder.feed(byte: byte) else { continue }
            if let reason = event.finishReason { finish = reason }
            count += event.text.count
            guard count <= 120_000 else { throw AssistantError("The generated response exceeded the size limit.") }
            pending += event.text
            let now = ProcessInfo.processInfo.systemUptime
            if !pending.isEmpty && (now - lastDelivery >= 0.04 || event.done) {
                await onDelta(pending); pending = ""; lastDelivery = now
            }
            if event.done {
                guard count > 0, ["stop", "end_turn", "stop_sequence", "STOP"].contains(finish ?? "") else {
                    throw AssistantError("The answer was incomplete or blocked. Retry manually.")
                }
                return
            }
        }
        throw AssistantError("The connection ended before the answer finished. Retry manually.")
    }
    public func complete(system: String, prompt: String, maxTokens: Int = 4096) async throws -> String {
        let result = CollectedText()
        try await stream(system: system, prompt: prompt, maxTokens: maxTokens) { await result.append($0) }
        return await result.value
    }
    public func getModels() async throws -> [String] {
        let base = try configuration.endpoint()
        var next = base.appendingPathComponent("models")
        var models: [String] = []
        for _ in 0..<10 {
            // The catalog uses the provider's credentials, independent of the selected Zen wire format.
            var request = try authorized(next)
            if configuration.kind == .opencode, !key.isEmpty {
                request.setValue("Bearer \(try AnswerClient.validatedKey(key))", forHTTPHeaderField: "Authorization")
            }
            let data = try await ProviderHTTP.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AssistantError("Invalid model catalog.") }
            let entries = object["models"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
            models += entries.compactMap { item -> String? in
                if configuration.kind == .gemini, let methods = item["supportedGenerationMethods"] as? [String], !methods.contains("generateContent") { return nil }
                guard let id = item["id"] as? String ?? item["name"] as? String else { return nil }
                return id.hasPrefix("models/") ? String(id.dropFirst(7)) : id
            }
            var components = URLComponents(url: base.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            if let token = object["nextPageToken"] as? String, !token.isEmpty {
                components.queryItems = [URLQueryItem(name: "pageToken", value: token)]
            } else if object["has_more"] as? Bool == true, let last = object["last_id"] as? String {
                components.queryItems = [URLQueryItem(name: "after_id", value: last)]
            } else { break }
            next = components.url!
        }
        return Array(Set(models)).sorted()
    }
    public func validateApiKey() async throws { _ = try await getModels() }
}

private actor CollectedText {
    var value = ""
    func append(_ text: String) { value += text }
}
