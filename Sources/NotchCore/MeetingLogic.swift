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
    public init() {}

    // SSE events end at a blank line. Comment/heartbeat lines are deliberately ignored.
    public mutating func feed(_ line: String) throws -> StreamEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            if payload == "[DONE]" { return StreamEvent(done: true) }
            let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
            if let error = chunk.error { throw AssistantError(String(error.message.prefix(300))) }
            guard let choice = chunk.choices?.first else { return StreamEvent() }
            return StreamEvent(text: choice.delta.content ?? choice.delta.refusal ?? "",
                               finishReason: choice.finish_reason)
        }
        if line.hasPrefix("data:") {
            var data = String(line.dropFirst(5))
            if data.first == " " { data.removeFirst() }
            dataLines.append(data)
            guard dataLines.reduce(0, { $0 + $1.utf8.count }) < 262_144 else {
                throw AssistantError("The response stream contained an oversized event.")
            }
        }
        return nil
    }

    private struct Chunk: Decodable {
        let choices: [Choice]?
        let error: APIError?
    }
    private struct APIError: Decodable { let message: String }
    private struct Choice: Decodable { let delta: Delta; let finish_reason: String? }
    private struct Delta: Decodable { let content: String?; let refusal: String? }
}
