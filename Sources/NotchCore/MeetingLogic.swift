import Foundation

public enum AnswerMode: String, CaseIterable, Codable, Identifiable {
    case automatic = "Automatic", manual = "Manual"
    public var id: String { rawValue }
}

public enum OutputMode: String, CaseIterable, Codable, Identifiable {
    case text = "Text", voice = "Voice", both = "Both"
    public var id: String { rawValue }
    public var showsText: Bool { self != .voice }
    public var usesVoice: Bool { self != .text }
}

public struct TranscriptLine: Identifiable, Equatable {
    public let id: UUID
    public let source: String
    public var text: String
    public let time: Date
}

public struct TranscriptStore {
    public private(set) var lines: [TranscriptLine] = []
    public init() {}

    // Speech results replace the same recognition segment; they do not append duplicates.
    @discardableResult
    public mutating func update(id: UUID, source: String, text: String, at: Date = Date()) -> Bool {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(6_000))
        guard !text.isEmpty else { return false }
        if let index = lines.firstIndex(where: { $0.id == id }) {
            let changed = Self.normalized(lines[index].text) != Self.normalized(text)
            lines[index].text = text
            return changed
        }
        lines.append(TranscriptLine(id: id, source: source, text: text, time: at))
        if lines.count > 120 { lines.removeFirst(lines.count - 120) }
        return true
    }

    public var context: String {
        String(lines.map { "\($0.source): \($0.text)" }.joined(separator: "\n").suffix(16_000))
    }

    public static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct AutoAnswerGate {
    public private(set) var revision = 0
    public private(set) var consumedRevision = 0
    private var changedAt: Date?
    private var requestedAt = Date.distantPast
    public init() {}

    public mutating func changed(at: Date = Date()) {
        revision += 1
        changedAt = at
    }

    public mutating func consume(_ revision: Int, at: Date = Date()) {
        consumedRevision = max(consumedRevision, min(revision, self.revision))
        requestedAt = at
    }

    public func ready(at now: Date = Date(), delay: Double, listening: Bool,
                      mode: AnswerMode, busy: Bool, speaking: Bool) -> Bool {
        guard listening, mode == .automatic, !busy, !speaking,
              revision > consumedRevision, let changedAt else { return false }
        return now.timeIntervalSince(changedAt) >= max(0.7, delay)
            && now.timeIntervalSince(requestedAt) >= 4
    }
}

public struct AssistantError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct StreamEvent: Equatable {
    public var text: String = ""
    public var done = false
    public var finishReason: String?
}

public struct EventStreamDecoder {
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var lineBytes: [UInt8] = []
    private var afterCR = false
    public init() {}

    // Frame bytes ourselves so empty SSE boundaries and split UTF-8 characters survive.
    public mutating func feed(byte: UInt8) throws -> StreamEvent? {
        if afterCR {
            afterCR = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            afterCR = byte == 13
            guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                throw AssistantError("The response contained invalid UTF-8.")
            }
            lineBytes.removeAll(keepingCapacity: true)
            return try feed(line)
        }
        guard lineBytes.count < 262_144 else {
            throw AssistantError("The response contained an oversized line.")
        }
        lineBytes.append(byte)
        return nil
    }

    public mutating func feed(_ line: String) throws -> StreamEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            if payload == "[DONE]" { return StreamEvent(done: true) }
            let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
            if let error = chunk.error { throw AssistantError(String(error.message.prefix(300))) }
            switch chunk.type {
            case "response.output_text.delta", "response.refusal.delta":
                return StreamEvent(text: chunk.delta ?? "")
            case "response.completed":
                guard chunk.response?.status == "completed" else {
                    throw AssistantError("The provider returned an incomplete answer.")
                }
                return StreamEvent(done: true, finishReason: "stop")
            case "response.failed", "response.incomplete", "error":
                let detail = chunk.response?.error?.message ?? chunk.message
                    ?? "The answer ended early. Retry manually or shorten the question."
                throw AssistantError(String(detail.prefix(300)))
            default:
                // Retain the previous framing format for stored fixtures and older stream checks.
                guard let choice = chunk.choices?.first else { return StreamEvent() }
                return StreamEvent(text: choice.delta.content ?? choice.delta.refusal ?? "",
                                   finishReason: choice.finish_reason)
            }
        }
        if line.hasPrefix("data:") {
            var data = String(line.dropFirst(5))
            if data.first == " " { data.removeFirst() }
            eventBytes += data.utf8.count + 1
            guard eventBytes <= 262_144 else {
                throw AssistantError("The response stream contained an oversized event.")
            }
            dataLines.append(data)
        }
        return nil
    }

    private struct Chunk: Decodable {
        let type: String?
        let delta: String?
        let response: Response?
        let message: String?
        let choices: [Choice]?
        let error: APIError?
    }
    private struct Response: Decodable { let status: String?; let error: APIError? }
    private struct APIError: Decodable { let message: String }
    private struct Choice: Decodable { let delta: Delta; let finish_reason: String? }
    private struct Delta: Decodable { let content: String?; let refusal: String? }
}
