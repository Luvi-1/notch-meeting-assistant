import AppKit
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers
import NotchCore

@MainActor
final class MeetingModel: ObservableObject {
    enum Destination: String, CaseIterable, Identifiable {
        case home = "Home", sessions = "Sessions", notes = "Notes", search = "Search", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: return "house"
            case .sessions: return "rectangle.stack"
            case .notes: return "bookmark"
            case .search: return "magnifyingglass"
            case .settings: return "slider.horizontal.3"
            }
        }
    }
    @Published var settings = UserSettings.load() {
        didSet {
            settings.save()
            if oldValue.questionAssistance != settings.questionAssistance {
                cancelAnalysis(); pendingQuestion = nil
                if settings.questionAssistance == .off || settings.questionAssistance == .detect { cancelAnswer() }
            }
            if oldValue.outputMode != settings.outputMode && !settings.outputMode.usesVoice { stopVoice() }
        }
    }
    @Published private(set) var presentation = NotchPresentation()
    @Published var destination: Destination = .home
    @Published var selectedSessionID: UUID?
    @Published var selectedSegmentID: UUID?
    @Published var hasConsent = false
    @Published var question = ""
    @Published var searchQuery = ""
    @Published var keyDraft = ""
    @Published var providerStatus = ""
    @Published var selectedProvider: AIProvider = .openai { didSet { keyDraft = ""; providerStatus = "" } }
    @Published var error: String?
    @Published private(set) var needsRecordingPermission = false
    @Published private(set) var sessions: [ListeningSession] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var isLoadingSessions = true
    @Published private(set) var isStarting = false
    @Published private(set) var isListening = false
    @Published private(set) var isStopping = false
    @Published private(set) var isAnswering = false
    @Published private(set) var answerComplete = false
    @Published private(set) var answer = ""
    @Published private(set) var answerSessionID: UUID?
    @Published private(set) var notice: SessionQuestion?
    @Published private(set) var noticeSessionID: UUID?
    @Published private(set) var isSpeaking = false
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var elapsed = "00:00"
    @Published private(set) var keyedProviders: Set<AIProvider> = []
    @Published private(set) var providerBusy = false
    @Published private(set) var transcriptionStatus = ""
    @Published private(set) var transcriptionModels: [String] = []
    @Published var transcriptionKeyDraft = ""
    @Published private(set) var hasCustomTranscriptionKey = false
    @Published private(set) var summarizing: Set<UUID> = []
    @Published private(set) var searchResults: [MemoryHit] = []
    @Published private(set) var memorySources: [MemoryHit] = []
    @Published private(set) var memoryAnswer = ""
    @Published private(set) var isSearching = false
    @Published private(set) var isAskingMemory = false
    @Published private(set) var semanticSearchAvailable = false
    @Published private(set) var intelligencePaused = false
    @Published var applications: [MeetingApplication] = []
    @Published var loadingApplications = false
    @Published var cutoutWidth: CGFloat = 185
    @Published var cutoutHeight: CGFloat = 34
    @Published var panelWidth: CGFloat = 305
    @Published var panelHeight: CGFloat = 34
    @Published var detachedNotch = false
    var openLibraryAction: (() -> Void)?

    private let repository: SessionRepository
    private let memoryIndex = MemoryIndex()
    private let voice = VoiceOutput()
    private var keys: [AIProvider: String] = [:]
    private var capture: MeetingCapture?
    private var timer: Timer?
    private var sessionToken = UUID()
    private var analysisToken = UUID()
    private var responseToken = UUID()
    private var searchToken = UUID()
    private var memoryToken = UUID()
    private var analysisTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    private var analyzedText: [UUID: String] = [:]
    private var lastSpeechAt = Date.distantPast
    private var lastAnalysisAt = Date.distantPast
    private var lastLevelAt = Date.distantPast
    private var persistedIDs: Set<UUID> = []
    private var isShuttingDown = false
    private var pendingQuestion: (sessionID: UUID, question: SessionQuestion)?
    private var answerQuestionID: UUID?

    var activeSession: ListeningSession? { sessions.first { $0.id == activeSessionID } }
    var selectedSession: ListeningSession? { sessions.first { $0.id == selectedSessionID } }
    var expanded: Bool { presentation.phase == .expanded }
    var busyListening: Bool { isStarting || isListening || isStopping }
    var previewAnswer: String { notice == nil || answerQuestionID == notice?.id ? answer : (notice?.answer ?? "") }
    var availableProviders: Set<AIProvider> {
        var available = keyedProviders
        if let custom = settings.providers.first(where: { $0.provider == .custom }),
           !custom.model.isEmpty, let url = try? ProviderNetwork.endpoint(custom.baseURL), ProviderNetwork.isLoopback(url.host ?? "") {
            available.insert(.custom)
        }
        return available
    }
    var status: String {
        if isStarting { return "Requesting access…" }
        if isStopping { return "Finishing transcript…" }
        if isSpeaking { return isListening ? "Speaking · transcription paused" : "Speaking" }
        if isListening { return intelligencePaused ? "Listening · AI paused" : "Listening" }
        if error != nil { return "Needs attention" }
        return "Ready when you are"
    }
    var canAnswer: Bool {
        let hasTranscript = (selectedSession ?? activeSession)?.segments.isEmpty == false
        return !isStarting && !isStopping && !isAnswering &&
            (!question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notice != nil || hasTranscript)
    }
    var resolvedTranscriptionService: TranscriptionService {
        if settings.transcription.provider != .automatic { return settings.transcription.provider }
        return !settings.onDeviceOnly && keyedProviders.contains(.groq) ? .groq : .apple
    }
    var resolvedTranscriptionLabel: String { resolvedTranscriptionService.rawValue }
    var dataFlowLabel: String {
        let source = [settings.includeMicrophone ? "Microphone" : nil, settings.captureSystemAudio ? "System audio" : nil].compactMap { $0 }.joined(separator: " + ")
        return "\(source.isEmpty ? "Choose an audio input" : source) · \(resolvedTranscriptionLabel) · \(settings.saveSessions ? "Sessions saved on this Mac" : "This session stays in memory")"
    }
    var aiDataFlowLabel: String {
        let names = Set(AITask.allCases.compactMap { try? settings.configuration(for: $0, available: availableProviders).provider.title }).sorted()
        return names.isEmpty ? "Connect a provider for question help and summaries." : "Selected transcript excerpts go to \(names.joined(separator: ", ")) for AI assistance."
    }

    init(directory: URL? = nil, readCredentials: Bool = true) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch/Sessions", isDirectory: true)
        repository = SessionRepository(directory: folder)
        if readCredentials { refreshKeys() }
        voice.onFinished = { [weak self] in self?.finishVoice() }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.repository.load()
                self.sessions = loaded.sessions
                self.persistedIDs = Set(loaded.sessions.map(\.id))
                if !loaded.warnings.isEmpty { self.error = loaded.warnings.joined(separator: "\n") }
            } catch { self.error = "Could not load saved sessions: \(error.localizedDescription)" }
            self.semanticSearchAvailable = await self.memoryIndex.semanticAvailable()
            self.isLoadingSessions = false
        }
    }
    func openNotch() { presentation.open() }
    func hover(_ inside: Bool) { presentation.hover(inside) }
    func collapse() { presentation.dismiss() }
    func showLibrary(_ destination: Destination = .home) {
        self.destination = destination; openLibraryAction?(); collapse()
    }
    func viewSession(_ id: UUID, segmentID: UUID? = nil) {
        selectedSessionID = id; selectedSegmentID = segmentID; showLibrary(.sessions)
    }
    func showCurrentSession() {
        if let id = noticeSessionID ?? activeSessionID ?? answerSessionID ?? selectedSessionID ?? sessions.first?.id { viewSession(id) }
        else { showLibrary() }
    }
    private func tick() {
        var next = presentation; next.tick()
        if next != presentation { presentation = next }
        if let session = activeSession {
            let seconds = max(0, Int(Date().timeIntervalSince(session.startedAt)))
            let text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            if elapsed != text { elapsed = text }
        }
        analyzeWhenReady()
    }
    func start() async {
        guard !busyListening, !isLoadingSessions, !isShuttingDown else { return }
        guard hasConsent else { showLibrary(); error = "Confirm permission from the people being transcribed before starting."; return }
        cancelAnswer(); cancelAnalysis(); pendingQuestion = nil
        error = nil; needsRecordingPermission = false; intelligencePaused = false
        isStarting = true; elapsed = "00:00"; notice = nil; noticeSessionID = nil; answer = ""; answerComplete = false
        let token = UUID(); sessionToken = token
        let session = ListeningSession()
        sessions.insert(session, at: 0); activeSessionID = session.id; selectedSessionID = session.id
        analyzedText = [:]; lastSpeechAt = .distantPast; lastAnalysisAt = .distantPast
        let input = MeetingCapture(); capture = input
        input.onSegment = { [weak self] segment in
            guard let self, self.sessionToken == token, self.activeSessionID == session.id,
                  let i = self.sessions.firstIndex(where: { $0.id == session.id }) else { return }
            if self.sessions[i].update(segment) { self.lastSpeechAt = Date(); self.scheduleSave(session.id) }
        }
        input.onFailure = { [weak self] message in
            guard let self, self.sessionToken == token else { return }
            self.error = message; self.addNote("Capture issue: " + message, sessionID: session.id)
            Task { await self.stop() }
        }
        input.onLevel = { [weak self] level in
            guard let self, Date().timeIntervalSince(self.lastLevelAt) >= 0.1 else { return }
            self.lastLevelAt = Date(); self.audioLevel = level
        }
        do {
            let (configuration, key) = try transcriptionConnection()
            try await input.start(options: settings, transcription: configuration, key: key)
            guard sessionToken == token, isStarting else { await input.cancel(); return }
            isStarting = false; isListening = true; collapse(); scheduleSave(session.id)
        } catch {
            await input.cancel()
            guard sessionToken == token else { return }
            isStarting = false; isListening = false; capture = nil; activeSessionID = nil
            if let i = sessions.firstIndex(where: { $0.id == session.id }) {
                if sessions[i].segments.isEmpty { sessions.remove(at: i) }
                else { sessions[i].endedAt = Date(); await persist(session.id) }
            }
            if error is CancellationError { return }
            let failure = error as NSError
            needsRecordingPermission = failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue
            self.error = needsRecordingPermission
                ? "Allow Notch in Privacy & Security → Screen & System Audio Recording, then quit and reopen it. Microphone-only listening does not need screen recording access."
                : error.localizedDescription
            showLibrary()
        }
    }
    func stop() async {
        guard !isStopping, busyListening || capture != nil else { return }
        let id = activeSessionID
        isStopping = true; isListening = false; isStarting = false
        cancelAnalysis(); cancelAnswer(); pendingQuestion = nil
        let old = capture; capture = nil
        await old?.stop()
        sessionToken = UUID(); activeSessionID = nil; isStopping = false
        audioLevel = 0; hasConsent = false
        if let id, let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].endedAt = Date()
            pendingSaves[id]?.cancel(); pendingSaves[id] = nil
            await persist(id)
            if !isShuttingDown, settings.generateSummaries,
               sessions.first(where: { $0.id == id })?.segments.isEmpty == false { generateSummary(id) }
        }
    }
    func shutdown() async -> Bool {
        isShuttingDown = true
        // Wait for a Stop already draining the final audio chunk; don't close a file halfway through it.
        while isStopping { try? await Task.sleep(nanoseconds: 100_000_000) }
        await stop()
        cancelAnalysis(); cancelAnswer(); searchTask?.cancel(); memoryTask?.cancel()
        summaryTasks.values.forEach { $0.cancel() }; pendingSaves.values.forEach { $0.cancel() }
        var saved = true
        for session in sessions where settings.saveSessions || persistedIDs.contains(session.id) {
            do { try await repository.save(session) }
            catch { saved = false; self.error = "Could not save \(session.title): \(error.localizedDescription). Export this session before quitting." }
        }
        if saved { timer?.invalidate() }
        else { isShuttingDown = false; showLibrary(.sessions) }
        return saved
    }
    private func scheduleSave(_ id: UUID) {
        guard settings.saveSessions || persistedIDs.contains(id) else { return }
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000); try Task.checkCancellation() } catch { return }
            await self?.persist(id)
        }
    }
    @discardableResult private func persist(_ id: UUID) async -> Bool {
        guard settings.saveSessions || persistedIDs.contains(id), let session = sessions.first(where: { $0.id == id }) else { return true }
        do { try await repository.save(session); persistedIDs.insert(id); return true }
        catch { self.error = "Could not save this session: \(error.localizedDescription). Keep the app open and export the transcript."; return false }
    }
    func deleteSession(_ id: UUID) async {
        guard id != activeSessionID else { error = "Stop listening before deleting this session."; return }
        summaryTasks[id]?.cancel(); summaryTasks[id] = nil; summarizing.remove(id)
        pendingSaves[id]?.cancel(); pendingSaves[id] = nil
        searchTask?.cancel(); searchToken = UUID(); isSearching = false
        memoryTask?.cancel(); memoryToken = UUID(); isAskingMemory = false
        if answerSessionID == id { cancelAnswer(); answer = ""; answerSessionID = nil }
        if noticeSessionID == id { notice = nil; noticeSessionID = nil }
        if pendingQuestion?.sessionID == id { pendingQuestion = nil }
        do {
            try await repository.delete(id)
            sessions.removeAll { $0.id == id }; persistedIDs.remove(id)
            searchResults.removeAll { $0.sessionID == id }; memorySources = []; memoryAnswer = ""
            if selectedSessionID == id { selectedSessionID = nil }
        } catch { self.error = error.localizedDescription }
    }
    func exportSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Notch session.md"; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try session.markdown.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "Could not export: \(error.localizedDescription)" }
    }
    func renameSession(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = String(title.prefix(160)); scheduleSave(id)
    }
    func bookmark(_ segmentID: UUID, sessionID: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), let j = sessions[i].segments.firstIndex(where: { $0.id == segmentID }) else { return }
        sessions[i].segments[j].bookmarked.toggle(); scheduleSave(sessionID)
    }
    func labelSpeaker(_ segmentID: UUID, sessionID: UUID, name: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), let j = sessions[i].segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[i].segments[j].speaker = name.isEmpty ? nil : String(name.prefix(80)); scheduleSave(sessionID)
    }
    func addNote(_ text: String, sessionID: UUID? = nil, segmentID: UUID? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = sessionID ?? activeSessionID ?? selectedSessionID,
              let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].notes.append(SessionNote(text: String(text.prefix(20_000)), segmentID: segmentID)); scheduleSave(id)
    }
    func saveNotice() {
        guard let notice, let id = noticeSessionID,
              let i = sessions.firstIndex(where: { $0.id == id }), let j = sessions[i].questions.firstIndex(where: { $0.id == notice.id }) else { return }
        sessions[i].questions[j].saved = true; self.notice = sessions[i].questions[j]
        if let k = sessions[i].segments.firstIndex(where: { $0.id == notice.segmentID }) { sessions[i].segments[k].bookmarked = true }
        scheduleSave(id)
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    private func connection(_ task: AITask) throws -> ProviderConnection {
        let config = try settings.configuration(for: task, available: availableProviders)
        return ProviderConnection(config, key: keys[config.provider] ?? "")
    }
    private func analyzeWhenReady() {
        guard isListening, !isSpeaking, !intelligencePaused, analysisTask == nil, !availableProviders.isEmpty,
              let session = activeSession else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysisAt) >= 6,
              now.timeIntervalSince(lastSpeechAt) >= settings.autoDelay || now.timeIntervalSince(lastAnalysisAt) >= 10 else { return }
        let changed = session.segments.filter { analyzedText[$0.id] != $0.text }
        guard !changed.isEmpty else { return }
        let segments = Array(changed.prefix(10)); lastAnalysisAt = now
        let token = UUID(); analysisToken = token
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try self.connection(.quickCommand)
                let context = try await self.memoryIndex.context(for: segments.map(\.text).joined(separator: " "), session: session, limit: 10_000)
                let result = try await SessionIntelligence.analyze(segments: segments, context: context, connection: connection)
                guard self.analysisToken == token, self.activeSessionID == session.id, self.isListening, !Task.isCancelled,
                      let i = self.sessions.firstIndex(where: { $0.id == session.id }) else { return }
                self.sessions[i].topic = result.topic; self.sessions[i].kind = result.kind
                if self.sessions[i].title == "Listening session", !result.topic.isEmpty { self.sessions[i].title = result.topic }
                for segment in segments { self.analyzedText[segment.id] = segment.text }
                var newest: SessionQuestion?
                for moment in result.moments where moment.confidence >= 0.65 {
                    guard let j = self.sessions[i].segments.firstIndex(where: { $0.id == moment.segmentID }) else { continue }
                    self.sessions[i].segments[j].categories = Array(Set(self.sessions[i].segments[j].categories + moment.categories)).sorted { $0.rawValue < $1.rawValue }
                    if let text = moment.question, !TranscriptStore.normalized(text).isEmpty {
                        let question = SessionQuestion(segmentID: moment.segmentID, text: text, time: self.sessions[i].segments[j].time)
                        if self.sessions[i].addQuestion(question) { newest = question }
                    }
                }
                self.analysisTask = nil; self.scheduleSave(session.id)
                if let newest, self.settings.questionAssistance != .off {
                    if self.isAnswering || self.isSpeaking { self.pendingQuestion = (session.id, newest) }
                    else { self.presentQuestion(newest, sessionID: session.id) }
                }
            } catch {
                guard self.analysisToken == token, !(error is CancellationError) else { return }
                self.analysisTask = nil; self.intelligencePaused = true
                self.error = "Question detection paused: \(error.localizedDescription). Transcription continues."
            }
        }
    }
    func presentQuestion(_ question: SessionQuestion, sessionID: UUID) {
        guard settings.questionAssistance != .off, sessions.contains(where: { $0.id == sessionID }) else { return }
        notice = question; noticeSessionID = sessionID; answer = ""; answerComplete = false
        presentation.beginAnswer(); presentation.reveal(duration: 10)
        if settings.questionAssistance == .suggest || settings.questionAssistance == .automatic {
            requestAnswer(text: question.text, sessionID: sessionID, questionID: question.id, automatic: true, suggestion: settings.questionAssistance == .suggest)
        }
    }
    private func presentPendingQuestion() {
        guard !isAnswering, !isSpeaking, let pendingQuestion else { return }
        self.pendingQuestion = nil
        if activeSessionID == pendingQuestion.sessionID { presentQuestion(pendingQuestion.question, sessionID: pendingQuestion.sessionID) }
    }
    func resumeIntelligence() { intelligencePaused = false; error = nil; lastAnalysisAt = .distantPast }
    private func cancelAnalysis() { analysisToken = UUID(); analysisTask?.cancel(); analysisTask = nil }
    func requestAnswer(text: String? = nil, sessionID: UUID? = nil, questionID: UUID? = nil,
                       task: AITask = .liveQuestion, automatic: Bool = false, suggestion: Bool = false) {
        guard !isStarting, !isStopping, !isShuttingDown else { return }
        let requested = (text ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        let id = sessionID ?? (requested.isEmpty ? (activeSessionID ?? selectedSessionID) : (selectedSessionID ?? activeSessionID))
        let snapshot = sessions.first { $0.id == id }
        let promptQuestion = requested.isEmpty ? (notice?.text ?? "Explain the most recent question or important point in the transcript.") : requested
        guard snapshot != nil || !requested.isEmpty else { return }
        let provider: ProviderConnection
        do { provider = try connection(task) }
        catch { self.error = error.localizedDescription; if !automatic { showLibrary(.settings) }; return }
        cancelAnswer()
        let token = UUID(); responseToken = token
        isAnswering = true; answerComplete = false; answer = ""; answerSessionID = id; error = nil
        if !automatic { question = "" }
        presentation.beginAnswer()
        if automatic || destination != .sessions { presentation.reveal(duration: 30) }
        let questionToUpdate = questionID ?? (requested.isEmpty ? notice?.id : nil)
        answerQuestionID = questionToUpdate
        if !automatic, questionToUpdate == nil { notice = nil; noticeSessionID = nil }
        let background = String(settings.backgroundContext.prefix(4000))
        answerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context: String
                if let snapshot { context = try await self.memoryIndex.context(for: promptQuestion, session: snapshot) }
                else { context = "No captured session context is available." }
                let instruction = SessionIntelligence.grounding + (suggestion
                    ? "\nGive one short suggested answer, at most two sentences. Do not claim the speaker said your suggestion."
                    : "\nAnswer the user's question using relevant context. Be concise for a live question, and give more detail only when the question asks for it. A reference such as 'this curve' may be ambiguous; explain the assumption or say what information is missing.")
                try await ProviderClient().stream(connection: provider, system: instruction,
                    prompt: "Background notes:\n\(background)\n\nRelevant session context:\n\(context)\n\nUser question:\n\(String(promptQuestion.prefix(8000)))",
                    maxTokens: task == .deepAnalysis ? 4096 : 2048) { [weak self] delta in await self?.receiveAnswer(delta, token: token) }
                guard self.responseToken == token, !Task.isCancelled else { return }
                self.isAnswering = false; self.answerComplete = true; self.answerTask = nil
                if let id, let i = self.sessions.firstIndex(where: { $0.id == id }) {
                    if let qid = questionToUpdate, let j = self.sessions[i].questions.firstIndex(where: { $0.id == qid }) {
                        self.sessions[i].questions[j].answer = self.answer
                        if self.notice?.id == qid { self.notice = self.sessions[i].questions[j] }
                    } else { self.sessions[i].notes.append(SessionNote(text: "Question: \(promptQuestion)\n\nAI answer: \(self.answer)")) }
                    self.scheduleSave(id)
                }
                self.presentation.reveal(duration: 9)
                if !suggestion, self.settings.outputMode.usesVoice { self.readAnswer() }
                else { self.presentPendingQuestion() }
            } catch {
                guard self.responseToken == token else { return }
                self.isAnswering = false; self.answerTask = nil
                if error is CancellationError { return }
                self.error = error.localizedDescription
                if automatic { self.intelligencePaused = true }
            }
        }
    }
    private func receiveAnswer(_ delta: String, token: UUID) { if responseToken == token { answer += delta } }
    func answerNotice() {
        guard let notice else { requestAnswer(); return }
        requestAnswer(text: notice.text, sessionID: noticeSessionID, questionID: notice.id)
    }
    func cancelAnswer() {
        responseToken = UUID(); answerTask?.cancel(); answerTask = nil; isAnswering = false
        voice.stop(); isSpeaking = false
        if isListening { capture?.setSuppressed(false) }
    }
    func readAnswer() {
        guard answerComplete, !answer.isEmpty else { return }
        voice.stop(); capture?.setSuppressed(true); isSpeaking = true
        voice.speak(answer, language: settings.locale, rate: settings.voiceRate)
    }
    func stopVoice() { voice.stop(); finishVoice() }
    private func finishVoice() {
        guard isSpeaking else { return }; isSpeaking = false
        if isListening { capture?.setSuppressed(false) }
        presentPendingQuestion()
    }
    func generateSummary(_ id: UUID) {
        guard !isShuttingDown, !summarizing.contains(id), id != activeSessionID, let snapshot = sessions.first(where: { $0.id == id }), !snapshot.segments.isEmpty else { return }
        let connection: ProviderConnection
        do { connection = try self.connection(.summary) }
        catch {
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].summaryError = error.localizedDescription; scheduleSave(id) }
            return
        }
        summarizing.insert(id)
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].summaryError = nil }
        summaryTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.summarizing.remove(id); self.summaryTasks[id] = nil }
            do {
                let summary = try await SessionIntelligence.summarize(snapshot, connection: connection)
                try Task.checkCancellation()
                guard let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[i].summary = summary; self.sessions[i].kind = summary.kind
                if self.sessions[i].title == snapshot.title { self.sessions[i].title = summary.title }
                self.sessions[i].summaryError = nil
            } catch {
                guard !(error is CancellationError), let i = self.sessions.firstIndex(where: { $0.id == id }) else { return }
                self.sessions[i].summaryError = error.localizedDescription
            }
            await self.persist(id)
        }
    }
    func search() {
        searchTask?.cancel(); searchToken = UUID(); let token = searchToken
        let query = searchQuery; let snapshot = sessions; isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.memoryIndex.search(query, sessions: snapshot)
                guard self.searchToken == token, !Task.isCancelled else { return }
                self.searchResults = results; self.isSearching = false
            } catch {
                guard self.searchToken == token else { return }
                self.isSearching = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func askMemory() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        memoryTask?.cancel(); memoryToken = UUID(); let token = memoryToken
        isAskingMemory = true; memoryAnswer = ""; memorySources = []
        let snapshot = sessions
        memoryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.memoryToken == token { self.isAskingMemory = false } }
            do {
                let hits = try await self.memoryIndex.search(query, sessions: snapshot, limit: 10)
                guard self.memoryToken == token, !Task.isCancelled else { return }
                self.searchResults = hits; self.memorySources = hits
                guard !hits.isEmpty else { self.memoryAnswer = "I couldn't find supporting material in your saved sessions. Try a topic, phrase, course name, or a different date range."; return }
                let provider = try self.connection(.memory)
                let evidence = hits.enumerated().map { "[\($0.offset + 1)] \($0.element.sessionTitle) · \($0.element.time.formatted())\n\(String($0.element.text.prefix(2400)))" }.joined(separator: "\n\n")
                try await ProviderClient().stream(connection: provider, system: SessionIntelligence.grounding + "\nAnswer only from the retrieved session excerpts. Cite supporting excerpt numbers as [1], [2], etc. Say when the stored sessions do not establish the answer. Do not claim a list is exhaustive; these are selected search results. Relative dates must remain relative to the source session date unless the calendar date is certain.",
                    prompt: "Today: \(Date().formatted())\nQuestion: \(query)\n\nRetrieved excerpts:\n\(evidence)", maxTokens: 4096) { [weak self] delta in await self?.receiveMemory(delta, token: token) }
            } catch {
                guard self.memoryToken == token, !(error is CancellationError) else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func receiveMemory(_ delta: String, token: UUID) { if memoryToken == token { memoryAnswer += delta } }

    private func refreshKeys() {
        var found: [AIProvider: String] = [:]
        for provider in AIProvider.allCases {
            do { let key = try APIKeyStore.load(account: APIKeyStore.account(provider)); if !key.isEmpty { found[provider] = key } }
            catch { self.error = error.localizedDescription }
        }
        keys = found; keyedProviders = Set(found.keys)
        hasCustomTranscriptionKey = ((try? APIKeyStore.load(account: "custom-transcription-api-key")) ?? "").isEmpty == false
    }
    func saveProviderKey() {
        do {
            try APIKeyStore.save(keyDraft, account: APIKeyStore.account(selectedProvider))
            keys[selectedProvider] = try ProviderNetwork.key(keyDraft); keyedProviders.insert(selectedProvider)
            keyDraft = ""; providerStatus = "Saved in Keychain. Test the connection to refresh available models."
            if let i = settings.providers.firstIndex(where: { $0.provider == selectedProvider }) { settings.providers[i].verifiedAt = nil }
            resumeIntelligence()
        } catch { providerStatus = error.localizedDescription }
    }
    func removeProviderKey() {
        guard !busyListening else { return }
        cancelAnalysis(); cancelAnswer(); memoryTask?.cancel(); pendingQuestion = nil
        summaryTasks.values.forEach { $0.cancel() }
        do {
            try APIKeyStore.remove(account: APIKeyStore.account(selectedProvider)); keys.removeValue(forKey: selectedProvider); keyedProviders.remove(selectedProvider)
            keyDraft = ""; providerStatus = "Key removed."
            if let i = settings.providers.firstIndex(where: { $0.provider == selectedProvider }) { settings.providers[i].verifiedAt = nil }
        } catch { providerStatus = error.localizedDescription }
    }
    func refreshModels() async {
        guard !providerBusy, let config = settings.providers.first(where: { $0.provider == selectedProvider }) else { return }
        providerBusy = true; providerStatus = "Checking connection…"
        let provider = selectedProvider; let originalKey = keys[provider] ?? ""
        defer { providerBusy = false }
        do {
            let models = try await ProviderClient().getModels(configuration: config, key: originalKey)
            guard let i = settings.providers.firstIndex(where: { $0.provider == provider }),
                  (keys[provider] ?? "") == originalKey, settings.providers[i].baseURL == config.baseURL else { return }
            settings.providers[i].models = models; settings.providers[i].verifiedAt = Date()
            if selectedProvider == provider { providerStatus = "Connection verified. Choose a model below." }
        } catch { if selectedProvider == provider { providerStatus = error.localizedDescription } }
    }
    func transcriptionConnection() throws -> (TranscriptionConfiguration, String) {
        var config = settings.transcription; config.provider = resolvedTranscriptionService
        if settings.onDeviceOnly && config.provider != .apple && config.provider != .localWhisper { throw AssistantError("On-device only is enabled. Choose Apple Speech or Local Whisper, or turn off on-device only before using a cloud transcription provider.") }
        switch config.provider {
        case .groq, .openai:
            let provider: AIProvider = config.provider == .groq ? .groq : .openai
            guard let key = keys[provider], !key.isEmpty else { throw AssistantError("Save a \(provider.title) API key in AI Providers before using it for transcription.") }
            return (config, key)
        case .custom: return (config, try APIKeyStore.load(account: "custom-transcription-api-key"))
        default: return (config, "")
        }
    }
    func saveTranscriptionKey() {
        guard !busyListening else { return }
        do { try APIKeyStore.save(transcriptionKeyDraft, account: "custom-transcription-api-key"); transcriptionKeyDraft = ""; hasCustomTranscriptionKey = true; transcriptionStatus = "Saved in Keychain." }
        catch { transcriptionStatus = error.localizedDescription }
    }
    func removeTranscriptionKey() {
        guard !busyListening else { return }
        do { try APIKeyStore.remove(account: "custom-transcription-api-key"); transcriptionKeyDraft = ""; hasCustomTranscriptionKey = false; transcriptionStatus = "Key removed." }
        catch { transcriptionStatus = error.localizedDescription }
    }
    func refreshTranscriptionModels() async {
        do {
            let (config, key) = try transcriptionConnection()
            if config.provider == .apple { transcriptionStatus = "Apple Speech uses the selected language on this Mac."; return }
            transcriptionStatus = "Checking transcription provider…"
            if config.provider == .localWhisper { try await WhisperTranscriptionProvider().validateApiKey(configuration: config, key: key) }
            let models = try await WhisperTranscriptionProvider().getModels(configuration: config, key: key)
            guard config.provider == resolvedTranscriptionService else { return }
            transcriptionModels = models
            transcriptionStatus = config.provider == .localWhisper ? "Local Whisper server responded. Its loaded model is managed by the server." : "Connection verified. Select a transcription model."
        } catch { transcriptionStatus = error.localizedDescription }
    }
    func refreshApplications() async {
        guard !loadingApplications else { return }
        loadingApplications = true; defer { loadingApplications = false }
        do { applications = try await MeetingCapture.applications() }
        catch { self.error = error.localizedDescription }
    }
    func openRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(needsRecordingPermission ? "Privacy_ScreenCapture" : "Privacy_Microphone")") { NSWorkspace.shared.open(url) }
    }
}
