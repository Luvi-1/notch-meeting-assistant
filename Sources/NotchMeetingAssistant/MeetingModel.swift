import AppKit
import Combine
import NotchCore

@MainActor
final class MeetingModel: ObservableObject {
    @Published var settings = UserSettings.load() {
        didSet {
            settings.save()
            if oldValue.answerMode != settings.answerMode,
               settings.answerMode == .manual, answeringAutomatically { cancelAnswer() }
            if oldValue.outputMode != settings.outputMode, !settings.outputMode.usesVoice { stopVoice() }
        }
    }
    @Published var expanded = true
    @Published var showSettings = false
    @Published var hasConsent = false
    @Published var question = ""
    @Published var meetingContext = ""
    @Published var keyDraft = ""
    @Published var keyStatus = ""
    @Published var error: String?
    @Published var applications: [MeetingApplication] = []
    @Published var loadingApplications = false
    @Published private(set) var transcript = TranscriptStore()
    @Published private(set) var answer = ""
    @Published private(set) var answerComplete = false
    @Published private(set) var isStarting = false
    @Published private(set) var isListening = false
    @Published private(set) var isAnswering = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var hasKey = false
    @Published var cutoutWidth: CGFloat = 185
    @Published var cutoutHeight: CGFloat = 32
    @Published var panelWidth: CGFloat = 620
    @Published var panelHeight: CGFloat = 620

    private var apiKey = ""
    private var capture: MeetingCapture?
    private let voice = VoiceOutput()
    private var autoTimer: Timer?
    private var gate = AutoAnswerGate()
    private var sentText: [UUID: String] = [:]
    private var answerTask: Task<Void, Never>?
    private var responseID = UUID()
    private var sessionID = UUID()
    private var answeringAutomatically = false
    private var rawAnswer = ""

    var canAnswer: Bool {
        !isStarting && !isAnswering && (!transcript.lines.isEmpty || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var status: String {
        if isStarting { return "Requesting access…" }
        if isSpeaking { return isListening ? "Speaking · transcription paused" : "Speaking" }
        if isAnswering { return isListening ? "Listening · answering" : "Answering" }
        if isListening { return hasKey ? "Listening" : "Listening · add API key" }
        return "Ready"
    }

    init() {
        do {
            apiKey = try APIKeyStore.load()
            keyDraft = apiKey
            hasKey = !apiKey.isEmpty
        } catch { self.error = error.localizedDescription }
        voice.onFinished = { [weak self] in self?.finishVoice() }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.automaticTick() }
        }
        autoTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func start() async {
        guard !isStarting, !isListening else { return }
        guard hasConsent else {
            expanded = true
            error = "Confirm that everyone agrees to transcription before starting."
            return
        }
        cancelAnswer()
        transcript = TranscriptStore()
        sentText = [:]
        gate = AutoAnswerGate()
        answer = ""
        answerComplete = false
        error = nil
        isStarting = true
        let token = UUID()
        sessionID = token
        let input = MeetingCapture()
        capture = input
        input.onText = { [weak self] id, source, text in
            guard let self, self.sessionID == token, self.isListening || self.isStarting else { return }
            let changed = self.transcript.update(id: id, source: source, text: text)
            if changed { self.gate.changed() }
        }
        input.onFailure = { [weak self] message in
            guard let self, self.sessionID == token else { return }
            self.error = message
            Task { await self.stop() }
        }
        do {
            try await input.start(options: settings)
            guard sessionID == token else { await input.stop(); return }
            isStarting = false
            isListening = true
            if !hasKey { error = "Transcription is ready. Add an API key in Settings to generate answers." }
        } catch {
            guard sessionID == token else { return }
            isStarting = false
            isListening = false
            await input.stop()
            if sessionID == token {
                capture = nil
                self.error = "Could not start: \(error.localizedDescription)"
            }
        }
    }

    func stop() async {
        sessionID = UUID()
        isListening = false
        isStarting = false
        hasConsent = false
        cancelAnswer()
        let old = capture
        capture = nil
        await old?.stop()
    }

    func clearTranscript() {
        cancelAnswer()
        transcript = TranscriptStore()
        sentText = [:]
        gate = AutoAnswerGate()
        answer = ""
        answerComplete = false
        do { try capture?.restartRecognition() }
        catch { failCapture(error.localizedDescription) }
    }

    func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            keyStatus = "Enter a valid API key."
            return
        }
        do {
            try APIKeyStore.save(value)
            apiKey = value
            keyDraft = value
            hasKey = true
            keyStatus = "Saved in Keychain."
            error = nil
        } catch { keyStatus = error.localizedDescription }
    }

    func removeKey() {
        cancelAnswer()
        do {
            try APIKeyStore.remove()
            apiKey = ""
            keyDraft = ""
            hasKey = false
            keyStatus = "Key removed."
        } catch { keyStatus = error.localizedDescription }
    }

    func refreshApplications() async {
        guard !loadingApplications else { return }
        loadingApplications = true
        defer { loadingApplications = false }
        do { applications = try await MeetingCapture.applications() }
        catch { self.error = "Could not list apps: \(error.localizedDescription). Allow Screen & System Audio Recording in System Settings." }
    }

    private var newSpeech: String {
        transcript.lines.compactMap { line -> String? in
            let current = TranscriptStore.normalized(line.text).split(separator: " ")
            let previous = TranscriptStore.normalized(sentText[line.id] ?? "").split(separator: " ")
            let shared = zip(current, previous).prefix { $0 == $1 }.count
            let added = current.dropFirst(shared).joined(separator: " ")
            return added.isEmpty ? nil : "\(line.source): \(added)"
        }.joined(separator: "\n")
    }

    private func automaticTick() {
        guard hasKey, gate.ready(delay: settings.autoDelay, listening: isListening,
                                 mode: settings.answerMode, busy: isAnswering, speaking: isSpeaking),
              !newSpeech.isEmpty else { return }
        requestAnswer(automatic: true)
    }

    func requestAnswer(automatic: Bool = false) {
        guard canAnswer else { return }
        guard hasKey else {
            expanded = true
            showSettings = true
            error = "Save an OpenAI API key to generate answers."
            return
        }
        stopVoice()
        let latest = newSpeech
        let transcriptSnapshot = transcript.context
        let context = meetingContext
        let question = automatic ? "" : self.question
        let modelID = settings.model
        let key = apiKey
        if !automatic { self.question = "" }
        sentText = Dictionary(uniqueKeysWithValues: transcript.lines.map { ($0.id, $0.text) })
        gate.consume(gate.revision)
        answerTask?.cancel()
        responseID = UUID()
        let id = responseID
        isAnswering = true
        answeringAutomatically = automatic
        answer = ""
        rawAnswer = ""
        answerComplete = false
        error = nil
        answerTask = Task { [weak self] in
            do {
                try await AnswerClient().stream(key: key, model: modelID, transcript: transcriptSnapshot,
                                                latest: latest, context: context, question: question,
                                                automatic: automatic) { [weak self] delta in
                    await self?.receive(delta, id: id, automatic: automatic)
                }
                guard let self, self.responseID == id, !Task.isCancelled else { return }
                self.isAnswering = false
                self.answeringAutomatically = false
                self.answerTask = nil
                let result = self.rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                if automatic && result == "[NO_ANSWER]" {
                    self.answer = ""
                    return
                }
                self.answer = result
                self.answerComplete = true
                self.expanded = true
                if self.settings.outputMode.usesVoice { self.readAnswer() }
            } catch {
                guard let self, self.responseID == id else { return }
                self.isAnswering = false
                self.answeringAutomatically = false
                self.answerTask = nil
                if error is CancellationError { return }
                self.error = error.localizedDescription
                // An API error must not cause a paid automatic retry loop.
                if automatic { self.settings.answerMode = .manual }
            }
        }
    }

    private func receive(_ delta: String, id: UUID, automatic: Bool) {
        guard responseID == id, !Task.isCancelled else { return }
        rawAnswer += delta
        if !automatic || !"[NO_ANSWER]".hasPrefix(rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)) {
            answer = rawAnswer
            expanded = true
        }
    }

    func cancelAnswer() {
        responseID = UUID()
        answerTask?.cancel()
        answerTask = nil
        isAnswering = false
        answeringAutomatically = false
        stopVoice()
    }

    func readAnswer() {
        guard answerComplete, !answer.isEmpty else { return }
        stopVoice()
        do {
            try capture?.setSuppressed(true)
            isSpeaking = true
            voice.speak(answer, language: settings.locale, rate: settings.voiceRate)
        } catch { failCapture(error.localizedDescription) }
    }

    func stopVoice() {
        voice.stop()
        finishVoice()
    }

    private func finishVoice() {
        guard isSpeaking else { return }
        isSpeaking = false
        guard isListening else { return }
        do { try capture?.setSuppressed(false) }
        catch { failCapture(error.localizedDescription) }
    }

    private func failCapture(_ message: String) {
        error = message
        Task { await stop() }
    }

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }
}
