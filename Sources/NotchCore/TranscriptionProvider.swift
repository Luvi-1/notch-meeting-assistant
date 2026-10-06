import Foundation

public struct TranscribedSpan: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double?
    public var speaker: String?
    public init(text: String, start: Double = 0, end: Double? = nil, speaker: String? = nil) {
        self.text = text; self.start = start; self.end = end; self.speaker = speaker
    }
}
public struct TranscriptionResult: Sendable {
    public var spans: [TranscribedSpan]
    public var language: String?
    public init(spans: [TranscribedSpan], language: String? = nil) { self.spans = spans; self.language = language }
}
public protocol TranscriptionProvider: Sendable {
    func transcribe(wav: Data, configuration: TranscriptionConfiguration, key: String) async throws -> TranscriptionResult
    func getModels(configuration: TranscriptionConfiguration, key: String) async throws -> [String]
    func validateApiKey(configuration: TranscriptionConfiguration, key: String) async throws
}
public extension TranscriptionProvider {
    /// Whisper file APIs are streamed as ordered audio chunks, not advertised as native realtime APIs.
    func stream(chunks: AsyncThrowingStream<Data, Error>, configuration: TranscriptionConfiguration,
                key: String) -> AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    for try await wav in chunks {
                        try Task.checkCancellation()
                        continuation.yield(try await transcribe(wav: wav, configuration: configuration, key: key))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
public struct WhisperTranscriptionProvider: TranscriptionProvider {
    public init() {}
    public func makeRequest(wav: Data, configuration c: TranscriptionConfiguration, key value: String) throws -> URLRequest {
        guard wav.count >= 44, wav.count <= 24_000_000, wav.prefix(4) == Data("RIFF".utf8) else { throw AssistantError("The audio chunk is not a supported WAV file.") }
        let base: String
        switch c.provider {
        case .openai: base = AIProvider.openai.baseURL
        case .groq: base = AIProvider.groq.baseURL
        case .localWhisper: base = c.localURL
        case .custom: base = c.customBaseURL
        default: throw AssistantError("Select a Whisper provider before sending audio.")
        }
        let local = c.provider == .localWhisper
        let url = try ProviderNetwork.endpoint(base, path: local ? "inference" : "audio/transcriptions")
        if local && !ProviderNetwork.isLoopback(url.host ?? "") { throw AssistantError("Local Whisper must run on this Mac. Use Custom for a remote server.") }
        let key = try ProviderNetwork.key(value, optional: local || (c.provider == .custom && ProviderNetwork.isLoopback(url.host ?? "")))
        let model = c.resolvedModel
        guard model.count <= 200, !model.contains("\r"), !model.contains("\n") else { throw AssistantError("Enter a valid transcription model ID.") }
        guard c.language.isEmpty || c.language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$", options: .regularExpression) != nil else { throw AssistantError("Use a language code such as en, hi, or pa, or automatic detection.") }
        let boundary = "Notch-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if !local { field("model", model) }
        let diarized = c.provider == .openai && model.contains("diarize")
        let verbose = c.provider == .groq || (c.provider == .openai && model == "whisper-1")
        field("response_format", diarized ? "diarized_json" : (verbose ? "verbose_json" : "json"))
        if diarized { field("chunking_strategy", "auto") }
        if !c.language.isEmpty { field("language", c.language.components(separatedBy: "-")[0]) }
        else if local { field("language", "auto") }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }
    public func transcribe(wav: Data, configuration: TranscriptionConfiguration, key: String) async throws -> TranscriptionResult {
        let request = try makeRequest(wav: wav, configuration: configuration, key: key)
        let data = try await ProviderNetwork.data(for: request, provider: configuration.provider.rawValue, limit: 2_000_000)
        return try Self.decode(data)
    }
    public static func decode(_ data: Data) throws -> TranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AssistantError("The transcription response is invalid.") }
        if json["error"] != nil { throw AssistantError("The transcription provider reported an error.") }
        var spans: [TranscribedSpan] = []
        for item in json["segments"] as? [[String: Any]] ?? [] {
            guard let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = item["start"] as? Double ?? 0
            let end = item["end"] as? Double
            guard start.isFinite, start >= 0, end == nil || (end!.isFinite && end! >= start) else { continue }
            // Silence hallucinations must not become questions or notes.
            if let silence = item["no_speech_prob"] as? Double, silence > 0.85 { continue }
            spans.append(TranscribedSpan(text: text.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end, speaker: item["speaker"] as? String))
        }
        if spans.isEmpty, json["segments"] == nil || (json["segments"] as? [Any])?.isEmpty == true,
           let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spans = [TranscribedSpan(text: text.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        guard json["text"] != nil || json["segments"] != nil else { throw AssistantError("The endpoint did not return a Whisper transcription response.") }
        return TranscriptionResult(spans: spans, language: json["language"] as? String)
    }
    public func getModels(configuration c: TranscriptionConfiguration, key: String) async throws -> [String] {
        if c.provider == .localWhisper { return ["Server's loaded Whisper model"] }
        let provider: AIProvider = c.provider == .groq ? .groq : (c.provider == .openai ? .openai : .custom)
        var config = ProviderConfiguration(provider)
        if c.provider == .custom { config.customBaseURL = c.customBaseURL }
        let models = try await ProviderClient().getModels(configuration: config, key: key)
        return models.filter { c.provider == .custom || $0.contains("whisper") || $0.contains("transcribe") }
    }
    public func validateApiKey(configuration c: TranscriptionConfiguration, key: String) async throws {
        if c.provider == .localWhisper {
            _ = try await transcribe(wav: PCMEncoding.wav(samples: Array(repeating: 0, count: 8000)), configuration: c, key: "")
        } else { _ = try await getModels(configuration: c, key: key) }
    }
}
public enum PCMEncoding {
    public static func wav(samples: [Int16], sampleRate: UInt32 = 16_000) -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) { var value = number.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        append(UInt32(36 + samples.count * 2)); result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16)); result.append(Data("data".utf8)); append(UInt32(samples.count * 2))
        for sample in samples { append(sample) }
        return result
    }
}
