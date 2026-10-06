import Foundation

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai, anthropic, gemini, openrouter, groq, opencode, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openrouter: return "OpenRouter"
        case .groq: return "Groq"
        case .opencode: return "OpenCode Zen"
        case .custom: return "Custom endpoint"
        }
    }
    public var baseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .opencode: return "https://opencode.ai/zen/v1"
        case .custom: return "http://127.0.0.1:1234/v1"
        }
    }
}

public enum APIFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic", responses = "OpenAI Responses", chat = "OpenAI Chat Completions"
    case anthropic = "Anthropic Messages", gemini = "Gemini"
    public var id: String { rawValue }
}

public struct ProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var provider: AIProvider
    public var model: String
    public var customBaseURL: String
    public var format: APIFormat = .automatic
    public var models: [String] = []
    public var verifiedAt: Date?
    public var ultrafast = false
    public var id: AIProvider { provider }
    public init(_ provider: AIProvider, model: String = "") {
        self.provider = provider
        self.model = model
        customBaseURL = provider.baseURL
    }
    public var baseURL: String { provider == .custom ? customBaseURL : provider.baseURL }
    public var wireFormat: APIFormat {
        if provider == .custom { return format == .automatic ? .chat : format }
        if provider == .opencode {
            if format != .automatic { return format }
            if model.hasPrefix("gpt-") || model.hasPrefix("grok-") || model.hasPrefix("muse-") { return .responses }
            if model.hasPrefix("claude-") || ["qwen3.8-flash", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus", "qwen3.5-plus"].contains(model) { return .anthropic }
            if model.hasPrefix("gemini-") { return .gemini }
            return .chat
        }
        switch provider {
        case .openai: return .responses
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        default: return .chat
        }
    }
}

public enum AITask: String, Codable, CaseIterable, Identifiable, Sendable {
    case liveQuestion = "Live Question Answering", summary = "Session Summary"
    case deepAnalysis = "Deep Analysis", quickCommand = "Quick Commands", memory = "Ask Your Memory"
    public var id: String { rawValue }
    public var preference: [AIProvider] {
        switch self {
        case .summary: return [.anthropic, .openai, .gemini, .openrouter, .opencode, .groq, .custom]
        case .deepAnalysis, .memory: return [.openai, .anthropic, .gemini, .openrouter, .opencode, .groq, .custom]
        case .liveQuestion, .quickCommand: return [.gemini, .groq, .openai, .openrouter, .opencode, .anthropic, .custom]
        }
    }
}

public struct ModelAssignment: Codable, Equatable, Sendable {
    public var provider: AIProvider?
    public var model: String
    public init(provider: AIProvider? = nil, model: String = "") { self.provider = provider; self.model = model }
}

public enum QuestionAssistance: String, Codable, CaseIterable, Identifiable, Sendable {
    case off = "Off", detect = "Detect only", suggest = "Detect + suggested answer", automatic = "Automatically answer questions"
    public var id: String { rawValue }
}

public enum TranscriptionService: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Auto", apple = "Apple Speech", groq = "Groq", openai = "OpenAI"
    case localWhisper = "Local Whisper", custom = "Other / custom provider"
    public var id: String { rawValue }
}

public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    public var provider: TranscriptionService = .automatic
    public var model = ""
    public var customBaseURL = "https://example.com/v1"
    public var localURL = "http://127.0.0.1:8080"
    public var language = ""
    public var chunkSeconds = 6.0
    public init() {}
    public var resolvedModel: String {
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return model }
        switch provider {
        case .groq: return "whisper-large-v3-turbo"
        case .openai: return "whisper-1"
        default: return "whisper-1"
        }
    }
}

public enum MomentCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case important = "Important", exam = "Exam", assignment = "Assignment", definition = "Definition"
    case formula = "Formula", example = "Example", question = "Question", explanation = "Explanation"
    case deadline = "Deadline", action = "Action item", decision = "Decision", topic = "Topic"
    public var id: String { rawValue }
}

public struct SessionSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let time: Date
    public var source: String
    public var speaker: String?
    public var text: String
    public var categories: [MomentCategory] = []
    public var bookmarked = false
    public var note = ""
    public init(id: UUID = UUID(), time: Date = Date(), source: String, text: String, speaker: String? = nil) {
        self.id = id; self.time = time; self.source = source; self.text = text; self.speaker = speaker
    }
    public var speakerLabel: String { speaker?.isEmpty == false ? speaker! : source }
    public var reference: String { "[\(id.uuidString)] \(time.formatted(date: .omitted, time: .standard))) · \(speakerLabel): \(text)" }
}

public struct SessionQuestion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let segmentID: UUID
    public let time: Date
    public let text: String
    public var answer = ""
    public var saved = false
    public init(segmentID: UUID, text: String, time: Date = Date()) {
        id = UUID(); self.segmentID = segmentID; self.text = text; self.time = time
    }
}

public struct SessionNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let time: Date
    public var text: String
    public var segmentID: UUID?
    public init(text: String, segmentID: UUID? = nil, time: Date = Date()) {
        id = UUID(); self.text = text; self.segmentID = segmentID; self.time = time
    }
}

public struct SummarySection: Codable, Equatable, Identifiable, Sendable {
    public var title: String
    public var body: String
    public var sources: [UUID]
    public var id: String { title }
    public init(title: String, body: String, sources: [UUID] = []) { self.title = title; self.body = body; self.sources = sources }
}

public struct SessionSummary: Codable, Equatable, Sendable {
    public var title: String
    public var kind: String
    public var overview: String
    public var sections: [SummarySection]
    public init(title: String, kind: String, overview: String, sections: [SummarySection]) {
        self.title = title; self.kind = kind; self.overview = overview; self.sections = sections
    }
}

public struct ListeningSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var title = "Listening session"
    public var kind = "Conversation"
    public var topic = ""
    public var segments: [SessionSegment] = []
    public var questions: [SessionQuestion] = []
    public var notes: [SessionNote] = []
    public var summary: SessionSummary?
    public var summaryError: String?
    public var recovered = false
    public init(id: UUID = UUID(), startedAt: Date = Date()) { self.id = id; self.startedAt = startedAt }
    @discardableResult public mutating func update(_ segment: SessionSegment) -> Bool {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let i = segments.firstIndex(where: { $0.id == segment.id }) {
            let changed = TranscriptStore.normalized(segments[i].text) != TranscriptStore.normalized(segment.text)
            segments[i].text = segment.text
            if let speaker = segment.speaker { segments[i].speaker = speaker }
            return changed
        }
        segments.append(segment)
        segments.sort { $0.time < $1.time }
        return true
    }
    @discardableResult public mutating func addQuestion(_ question: SessionQuestion) -> Bool {
        let normalized = TranscriptStore.normalized(question.text)
        guard !normalized.isEmpty, !questions.contains(where: {
            $0.segmentID == question.segmentID && TranscriptStore.normalized($0.text) == normalized
        }) else { return false }
        questions.append(question)
        return true
    }
    public var markdown: String {
        var parts = ["# \(title)", startedAt.formatted(date: .complete, time: .shortened)]
        if let summary {
            parts.append(summary.overview)
            parts += summary.sections.map { "## \($0.title)\n\n\($0.body)" }
        }
        if !questions.isEmpty { parts.append("## Questions\n\n" + questions.map { "\($0.text)\n\($0.answer)" }.joined(separator: "\n\n")) }
        if !notes.isEmpty { parts.append("## Notes\n\n" + notes.map(\.text).joined(separator: "\n\n")) }
        parts.append("## Full Transcript\n\n" + segments.map { "\($0.time.formatted(date: .omitted, time: .standard)) · \($0.speakerLabel)\n\($0.text)" }.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }
}
