import Foundation

/// Credentials are deliberately excluded from Codable provider preferences.
public struct ProviderConnection: Sendable {
    public var configuration: ProviderConfiguration
    public var key: String
    public init(_ configuration: ProviderConfiguration, key: String) { self.configuration = configuration; self.key = key }
}

public protocol LLMProvider: Sendable {
    func stream(connection: ProviderConnection, system: String, prompt: String, maxTokens: Int,
                onDelta: @escaping @Sendable (String) async -> Void) async throws
    func getModels(configuration: ProviderConfiguration, key: String) async throws -> [String]
    func validateApiKey(configuration: ProviderConfiguration, key: String) async throws
}

public enum ProviderNetwork {
    public static func endpoint(_ base: String, path: String = "") throws -> URL {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && isLoopback(host)) else {
            throw AssistantError("Use an HTTPS base URL. HTTP is allowed only for a local server on this Mac.")
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !components.path.isEmpty { components.path = "/" + components.path }
        if !path.isEmpty { components.path += "/" + path }
        guard let url = components.url else { throw AssistantError("The provider URL is invalid.") }
        return url
    }
    public static func isLoopback(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) }
    public static func key(_ value: String, optional: Bool = false) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if optional && key.isEmpty { return "" }
        guard !key.isEmpty, key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AssistantError("Enter an API key without spaces or line breaks.")
        }
        return key
    }
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 45; c.timeoutIntervalForResource = 180
        return URLSession(configuration: c, delegate: NoProviderRedirects(), delegateQueue: nil)
    }()
    public static func check(_ response: URLResponse, provider: String) throws {
        guard let response = response as? HTTPURLResponse else { throw AssistantError("\(provider) returned an invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            let advice: String
            switch response.statusCode {
            case 400: advice = "Check the model and API format."
            case 401, 403: advice = "Check the saved key and your account's model access."
            case 404: advice = "Check the endpoint and model ID."
            case 429: advice = "Check API credit or rate limits, then retry manually."
            default: advice = "Try again when the provider is available."
            }
            throw AssistantError("\(provider) returned HTTP \(response.statusCode). \(advice)")
        }
    }
    public static func data(for request: URLRequest, provider: String, limit: Int = 4_000_000) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        try check(response, provider: provider)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw AssistantError("\(provider)'s response exceeded the size limit.") }
            data.append(byte)
        }
        return data
    }
}

private final class NoProviderRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct ProviderClient: LLMProvider {
    public init() {}
    public func makeRequest(connection: ProviderConnection, system: String, prompt: String, maxTokens: Int = 2048) throws -> URLRequest {
        let c = connection.configuration
        let model = c.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200,
              model.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$", options: .regularExpression) != nil,
              prompt.utf8.count + system.utf8.count <= 400_000 else { throw AssistantError("Choose a valid model and a shorter input.") }
        if c.provider == .opencode && model.hasPrefix("jev-") { throw AssistantError("This OpenCode model uses System One, not text generation. Choose a text model.") }
        let base = try ProviderNetwork.endpoint(c.baseURL)
        let optional = c.provider == .custom && ProviderNetwork.isLoopback(base.host ?? "")
        let key = try ProviderNetwork.key(connection.key, optional: optional)
        let tokens = min(16_384, max(256, maxTokens))
        var path: String
        var payload: [String: Any]
        switch c.wireFormat {
        case .responses:
            path = "responses"
            payload = ["model": model, "instructions": system, "input": prompt, "stream": true, "store": false, "max_output_tokens": tokens]
            if c.provider == .openai && model == "gpt-6-astra" {
                payload["reasoning"] = ["effort": "low"]
                if c.ultrafast { payload["service_tier"] = "ultrafast" }
            }
        case .anthropic:
            path = "messages"
            payload = ["model": model, "system": system, "messages": [["role": "user", "content": prompt]], "max_tokens": tokens, "stream": true]
        case .gemini:
            let clean = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard clean.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw AssistantError("Enter a Gemini model ID without a URL.") }
            path = "models/\(clean):streamGenerateContent"
            payload = ["systemInstruction": ["parts": [["text": system]]],
                       "contents": [["role": "user", "parts": [["text": prompt]]]],
                       "generationConfig": ["maxOutputTokens": tokens]]
        case .chat, .automatic:
            path = "chat/completions"
            payload = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]], "stream": true, "max_tokens": tokens]
        }
        var url = try ProviderNetwork.endpoint(c.baseURL, path: path)
        if c.wireFormat == .gemini {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            url = parts.url!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authenticate(&request, configuration: c, key: key)
        return request
    }
    private func authenticate(_ request: inout URLRequest, configuration c: ProviderConfiguration, key: String) {
        if c.provider == .gemini || (c.provider == .custom && c.wireFormat == .gemini) {
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        } else if c.wireFormat == .anthropic {
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            if c.provider == .opencode { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if c.provider == .opencode && c.wireFormat == .gemini { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
    }
    public func stream(connection: ProviderConnection, system: String, prompt: String, maxTokens: Int = 2048,
                       onDelta: @escaping @Sendable (String) async -> Void) async throws {
        let request = try makeRequest(connection: connection, system: system, prompt: prompt, maxTokens: maxTokens)
        let (bytes, response) = try await ProviderNetwork.session.bytes(for: request)
        try ProviderNetwork.check(response, provider: connection.configuration.provider.title)
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw AssistantError("The provider did not return an event stream. Check the API format.")
        }
        var framer = SSEFramer()
        var decoder = ProviderStreamDecoder(format: connection.configuration.wireFormat)
        var count = 0
        var pending = ""
        var lastDelivery = Date.distantPast
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let payload = try framer.feed(byte) else { continue }
            let event = try decoder.decode(payload)
            count += event.text.count
            guard count <= 100_000 else { throw AssistantError("The generated response exceeded the limit.") }
            pending += event.text
            if !pending.isEmpty && (count == pending.count || Date().timeIntervalSince(lastDelivery) > 0.035 || event.done) {
                await onDelta(pending); pending = ""; lastDelivery = Date()
            }
            if event.done {
                guard count > 0 else { throw AssistantError("The model returned no text.") }
                return
            }
        }
        if let payload = try framer.finish() {
            let event = try decoder.decode(payload)
            pending += event.text; count += event.text.count
            if event.done && count > 0 { if !pending.isEmpty { await onDelta(pending) }; return }
        }
        throw AssistantError("The connection ended before the response finished. Retry manually.")
    }
    public func generate(connection: ProviderConnection, system: String, prompt: String, maxTokens: Int = 4096) async throws -> String {
        let text = ProviderTextBuffer()
        try await stream(connection: connection, system: system, prompt: prompt, maxTokens: maxTokens) { await text.append($0) }
        return await text.value
    }
    public func validateApiKey(configuration: ProviderConfiguration, key: String) async throws {
        _ = try await getModels(configuration: configuration, key: key)
    }
    public func getModels(configuration c: ProviderConfiguration, key value: String) async throws -> [String] {
        let base = try ProviderNetwork.endpoint(c.baseURL)
        let key = try ProviderNetwork.key(value, optional: (c.provider == .custom && ProviderNetwork.isLoopback(base.host ?? "")))
        var names: [String] = []
        var pageToken: String?
        for _ in 0..<10 {
            var components = URLComponents(url: try ProviderNetwork.endpoint(c.baseURL, path: "models"), resolvingAgainstBaseURL: false)!
            if c.provider == .gemini {
                components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            } else if c.provider == .anthropic {
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let pageToken { components.queryItems?.append(URLQueryItem(name: "after_id", value: pageToken)) }
            }
            var request = URLRequest(url: components.url!)
            authenticate(&request, configuration: c, key: key)
            // Model discovery on Zen is OpenAI-shaped regardless of the selected inference format.
            if c.provider == .opencode { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let data = try await ProviderNetwork.data(for: request, provider: c.provider.title)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AssistantError("The models response is invalid.") }
            let models = (object["data"] ?? object["models"]) as? [[String: Any]] ?? []
            for item in models {
                guard var name = (item["id"] ?? item["name"]) as? String else { continue }
                if c.provider == .gemini {
                    let methods = item["supportedGenerationMethods"] as? [String] ?? []
                    guard methods.contains("generateContent") else { continue }
                    if name.hasPrefix("models/") { name = String(name.dropFirst(7)) }
                }
                names.append(name)
            }
            if c.provider == .gemini { pageToken = object["nextPageToken"] as? String }
            else if c.provider == .anthropic && object["has_more"] as? Bool == true { pageToken = object["last_id"] as? String }
            else { pageToken = nil }
            if pageToken == nil { break }
        }
        guard !names.isEmpty else { throw AssistantError("No models were returned. A custom server may require entering its model ID manually.") }
        return Array(Set(names)).sorted()
    }
}

private actor ProviderTextBuffer {
    var value = ""
    func append(_ text: String) { value += text }
}

/// Framing is separate from provider payloads; split UTF-8 and CRLF survive byte delivery.
public struct SSEFramer {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var bytes = 0
    private var afterCR = false
    public init() {}
    public mutating func feed(_ byte: UInt8) throws -> String? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte == 10 || byte == 13 {
            afterCR = byte == 13
            return try consumeLine()
        }
        guard line.count < 262_144 else { throw AssistantError("The provider sent an oversized stream line.") }
        line.append(byte)
        return nil
    }
    private mutating func consumeLine() throws -> String? {
        guard let text = String(bytes: line, encoding: .utf8) else { throw AssistantError("The provider stream contains invalid UTF-8.") }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            guard !data.isEmpty else { return nil }
            let result = data.joined(separator: "\n"); data.removeAll(keepingCapacity: true); bytes = 0
            return result
        }
        if text.hasPrefix("data:") {
            var value = String(text.dropFirst(5)); if value.first == " " { value.removeFirst() }
            bytes += value.utf8.count
            guard bytes <= 262_144 else { throw AssistantError("The provider sent an oversized stream event.") }
            data.append(value)
        }
        return nil
    }
    public mutating func finish() throws -> String? {
        if !line.isEmpty { _ = try consumeLine() }
        return try consumeLine()
    }
}

public struct ProviderStreamDecoder {
    private let format: APIFormat
    private var normalFinish = false
    public init(format: APIFormat) { self.format = format }
    public mutating func decode(_ payload: String) throws -> StreamEvent {
        if payload == "[DONE]" {
            guard normalFinish else { throw AssistantError("The provider stream ended without a complete response.") }
            return StreamEvent(done: true)
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw AssistantError("The provider stream is malformed.") }
        if json["error"] != nil || json["type"] as? String == "error" { throw AssistantError("The provider reported a streaming error. Retry manually.") }
        switch format {
        case .responses:
            switch json["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta": return StreamEvent(text: json["delta"] as? String ?? "")
            case "response.completed":
                guard (json["response"] as? [String: Any])?["status"] as? String == "completed" else { throw AssistantError("The answer was incomplete.") }
                return StreamEvent(done: true)
            case "response.incomplete", "response.failed": throw AssistantError("The answer ended early. Retry with a shorter request or another configured model.")
            default: return StreamEvent()
            }
        case .anthropic:
            let delta = json["delta"] as? [String: Any] ?? [:]
            if json["type"] as? String == "content_block_delta", delta["type"] as? String == "text_delta" { return StreamEvent(text: delta["text"] as? String ?? "") }
            if json["type"] as? String == "message_delta", let reason = delta["stop_reason"] as? String {
                guard reason == "end_turn" || reason == "stop_sequence" else { throw AssistantError("Claude's answer ended early (\(reason)).") }
                normalFinish = true
            }
            if json["type"] as? String == "message_stop" {
                guard normalFinish else { throw AssistantError("Claude did not finish the response.") }
                return StreamEvent(done: true)
            }
            return StreamEvent()
        case .gemini:
            if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil { throw AssistantError("Gemini could not answer this request.") }
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return StreamEvent() }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            if let reason = candidate["finishReason"] as? String {
                guard reason == "STOP" else { throw AssistantError("Gemini's answer ended early (\(reason)).") }
                return StreamEvent(text: text, done: true)
            }
            return StreamEvent(text: text)
        case .chat, .automatic:
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return StreamEvent() }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let text = delta["content"] as? String ?? delta["refusal"] as? String ?? ""
            if let reason = choice["finish_reason"] as? String {
                guard reason == "stop" else { throw AssistantError("The answer ended early (\(reason)).") }
                normalFinish = true
                return StreamEvent(text: text, done: true)
            }
            return StreamEvent(text: text)
        }
    }
}
