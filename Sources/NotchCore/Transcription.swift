import Foundation

public enum AudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case microphone = "Microphone", system = "System audio", both = "Microphone + system audio"
    public var id: String { rawValue }
    public var usesMicrophone: Bool { self != .system }
    public var usesSystem: Bool { self != .microphone }
}
public enum TranscriptionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "Auto", apple = "Apple Speech", groq = "Groq", openai = "OpenAI"
    case localWhisper = "Local Whisper", custom = "Other / custom"
    public var id: String { rawValue }
    public var defaultModel: String {
        switch self {
        case .groq: return "whisper-large-v3-turbo"
        case .openai, .custom: return "whisper-1"
        case .localWhisper: return "Managed by local server"
        default: return "Apple Speech"
        }
    }
    public var keyID: String {
        switch self {
        case .groq: return ProviderKind.groq.rawValue
        case .openai: return ProviderKind.openai.rawValue
        case .custom: return "transcription-custom"
        default: return ""
        }
    }
}
public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    public var kind: TranscriptionKind = .auto
    public var model = "Apple Speech"
    public var baseURL = "https://api.example.com/v1"
    public var localURL = "http://127.0.0.1:8080"
    public var language = "en"
    public var automaticLanguage = true
    public var chunkSeconds = 6.0
    public init() {}
    // Auto uses Apple speech until the user explicitly selects a remote transcription provider.
    public var resolvedKind: TranscriptionKind { kind == .auto ? .apple : kind }
    public var sendsAudio: Bool { ![.auto, .apple, .localWhisper].contains(kind) }
    public func endpoint() throws -> URL {
        switch resolvedKind {
        case .groq: return try ProviderHTTP.validatedURL(ProviderKind.groq.baseURL).appendingPathComponent("audio/transcriptions")
        case .openai: return try ProviderHTTP.validatedURL(ProviderKind.openai.baseURL).appendingPathComponent("audio/transcriptions")
        case .localWhisper: return try ProviderHTTP.validatedURL(localURL, localOnly: true).appendingPathComponent("inference")
        case .custom: return try ProviderHTTP.validatedURL(baseURL).appendingPathComponent("audio/transcriptions")
        default: throw AssistantError("Apple Speech uses the native on-device audio pipeline.")
        }
    }
}
public struct TranscribedPart: Sendable {
    public let text: String
    public let start: Double
    public let speaker: String?
}
public struct TranscriptionResult: Sendable {
    public let text: String
    public let parts: [TranscribedPart]
}
public protocol TranscriptionProvider {
    func transcribe(wav: Data, context: String) async throws -> TranscriptionResult
    func getModels() async throws -> [String]
    func validateApiKey() async throws
}

public struct WhisperProvider: TranscriptionProvider, Sendable {
    public let configuration: TranscriptionConfiguration
    private let key: String
    public init(configuration: TranscriptionConfiguration, key: String) { self.configuration = configuration; self.key = key }
    public func makeRequest(wav: Data, context: String = "") throws -> URLRequest {
        guard wav.count >= 44, wav.count <= 24_000_000 else { throw AssistantError("Audio chunk is empty or exceeds the upload limit.") }
        let url = try configuration.endpoint()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !key.isEmpty { request.setValue("Bearer \(try AnswerClient.validatedKey(key))", forHTTPHeaderField: "Authorization") }
        else if configuration.resolvedKind != .localWhisper {
            let host = url.host ?? ""
            guard configuration.resolvedKind == .custom, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                throw AssistantError("Save a transcription API key in Settings.")
            }
        }
        let boundary = "Notch-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let diarized = configuration.resolvedKind == .openai && configuration.model.contains("diarize")
        if configuration.resolvedKind != .localWhisper { field("model", try ProviderHTTP.validatedModel(configuration.model)) }
        let whisper = configuration.model.lowercased().contains("whisper") || configuration.resolvedKind == .localWhisper
        field("response_format", diarized ? "diarized_json" : (whisper && configuration.resolvedKind != .localWhisper ? "verbose_json" : "json"))
        if diarized { field("chunking_strategy", "auto") }
        if !configuration.automaticLanguage {
            let language = configuration.language.lowercased()
            guard language.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil else { throw AssistantError("Use a language code such as en, hi, or pa.") }
            field("language", language)
        } else if configuration.resolvedKind == .localWhisper { field("language", "auto") }
        if !context.isEmpty && !diarized { field("prompt", String(context.suffix(600))) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
    public func transcribe(wav: Data, context: String = "") async throws -> TranscriptionResult {
        let data = try await ProviderHTTP.data(for: makeRequest(wav: wav, context: context), limit: 2_000_000)
        return try Self.decode(data)
    }
    public static func decode(_ data: Data) throws -> TranscriptionResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String else {
            throw AssistantError("The transcription endpoint returned an unsupported response.")
        }
        let parts = (object["segments"] as? [[String: Any]] ?? []).compactMap { item -> TranscribedPart? in
            guard let text = item["text"] as? String, (item["no_speech_prob"] as? Double ?? 0) < 0.85 else { return nil }
            let start = item["start"] as? Double ?? 0
            guard start.isFinite, start >= 0 else { return nil }
            return TranscribedPart(text: text.trimmingCharacters(in: .whitespacesAndNewlines), start: start, speaker: item["speaker"] as? String)
        }
        return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), parts: parts)
    }
    public func getModels() async throws -> [String] {
        if configuration.resolvedKind == .localWhisper { return ["Managed by local server"] }
        var provider = ProviderConfiguration(kind: configuration.resolvedKind == .groq ? .groq : .openai)
        if configuration.resolvedKind == .custom { provider = ProviderConfiguration(kind: .custom); provider.baseURL = configuration.baseURL }
        return try await ConfiguredLLMProvider(configuration: provider, key: key).getModels().filter {
            $0.lowercased().contains("whisper") || $0.lowercased().contains("transcrib")
        }
    }
    public func validateApiKey() async throws {
        if configuration.resolvedKind == .localWhisper {
            _ = try await transcribe(wav: PCMChunk.wav(samples: Array(repeating: 0, count: 3200)), context: "")
        } else { _ = try await getModels() }
    }
}

public enum PCMChunk {
    public static let sampleRate = 16_000
    public static func wav(samples: [Float]) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        let size = UInt32(samples.count * 2)
        data.append(Data("RIFF".utf8)); u32(36 + size); data.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(size)
        for sample in samples {
            let safe = sample.isFinite ? min(1, max(-1, sample)) : 0
            u16(UInt16(bitPattern: Int16(safe * 32767)))
        }
        return data
    }
    /// Remove only a short overlap at chunk boundaries, preserving repeated words elsewhere.
    public static func removingOverlap(previous: String, next: String) -> String {
        let old = previous.split(whereSeparator: \.isWhitespace)
        let new = next.split(whereSeparator: \.isWhitespace)
        let maximum = min(10, old.count, new.count)
        guard maximum >= 2 else { return next }
        for length in stride(from: maximum, through: 2, by: -1) {
            if TranscriptStore.normalized(old.suffix(length).joined(separator: " ")) == TranscriptStore.normalized(new.prefix(length).joined(separator: " ")) {
                return new.dropFirst(length).joined(separator: " ")
            }
        }
        return next
    }
}
