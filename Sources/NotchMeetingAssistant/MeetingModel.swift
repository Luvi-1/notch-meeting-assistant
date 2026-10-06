import AppKit
import Combine
import ScreenCaptureKit
import NotchCore

// The notch and the library share a single session owner.
enum LibrarySection: String, CaseIterable, Identifiable {
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

@MainActor
final class MeetingModel: ObservableObject {
    @Published var settings = UserSettings.load() {
        didSet {
            settings.save()
            if oldValue.assistance != settings.assistance, !settings.assistance.generates, answeringAutomatically { cancelAnswer() }
            if oldValue.outputMode != settings.outputMode, !settings.outputMode.usesVoice { stopVoice() }
            for provider in settings.providers where oldValue.providers.first(where: { $0.id == provider.id }) != provider {
                verifiedProviders.remove(provider.id)
            }
        }
    }
    @Published private(set) var presentation = NotchPresentation()
    @Published var hasConsent = false
    @Published var question = ""
    @Published var error: String?
    @Published private(set) var needsRecordingPermission = false
    @Published private(set) var isStarting = false
    @Published private(set) var isListening = false
    @Published private(set) var isStopping = false
    @Published private(set) var isAnswering = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var answer = ""
    @Published private(set) var answerComplete = false
    @Published private(set) var answerQuestion = ""
    @Published private(set) var latestQuestion = ""
    @Published private(set) var latestQuestionID: String?
    @Published private(set) var audioLevel = 0.0
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var loadingLibrary = true
    @Published var section: LibrarySection = .home
    @Published var selectedSessionID: UUID?
    @Published var selectedSegmentID: UUID?
    @Published var searchQuery = "" { didSet { scheduleSearch() } }
    @Published private(set) var searchResults: [MemoryEvidence] = []
    @Published private(set) var semanticSearch = false
    @Published private(set) var searching = false
    @Published private(set) var memoryAnswer = ""
    @Published private(set) var memorySources: [MemoryEvidence] = []
    @Published private(set) var askingMemory = false
    @Published private(set) var intelligenceStatus = ""
    @Published private(set) var savedKeys = Set<String>()
    @Published private(set) var verifiedProviders = Set<String>()
    @Published private(set) var modelCatalogs: [String: [String]] = [:]
    @Published private(set) var providerStatus: [String: String] = [:]
    @Published private(set) var busyProviders = Set<String>()
    @Published private(set) var transcriptionModels: [String] = []
    @Published private(set) var transcriptionStatus = ""
    @Published private(set) var checkingTranscription = false
    @Published var applications: [MeetingApplication] = []
    @Published private(set) var loadingApplications = false
    @Published var cutoutWidth: CGFloat = 185
    @Published var cutoutHeight: CGFloat = 34
    @Published var panelWidth: CGFloat = 325
    @Published var panelHeight: CGFloat = 34
    @Published var detachedNotch = false
    var onOpenLibrary: (() -> Void)?
    var onStarted: (() -> Void)?

    private let archive: SessionArchive
    private let index = MemoryIndex()
    private var capture: MeetingCapture?
    private let voice = VoiceOutput()
    private var timer: Timer?
    private var dirty = Set<UUID>()
    private var lastSave = Date.distantPast
    private var saveInProgress = false
    private var sessionToken = UUID()
    private var gate = AutoAnswerGate()
    private var analyzed: [UUID: String] = [:]
    private var analysisTask: Task<Void, Never>?
    private var analysisBlocked = false
    private var answerTask: Task<Void, Never>?
    private var answerToken = UUID()
    private var answerSessionID: UUID?
    private var answeringAutomatically = false
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchToken = UUID()
    private var memoryTask: Task<Void, Never>?
    private var memoryToken = UUID()

    var expanded: Bool { presentation.phase == .expanded }
    var busyCapture: Bool { isStarting || isListening || isStopping }
    var activeSession: SessionRecord? { sessions.first { $0.id == activeSessionID } }
    var selectedSession: SessionRecord? { sessions.first { $0.id == selectedSessionID } }
    var canAnswer: Bool { !isStarting && !isStopping && !isAnswering && (!question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(activeSession ?? selectedSession)?.segments.isEmpty == true) }
    var hasAI: Bool { (try? client(for: .quick)) != nil }
    var status: String {
        if isStarting { return "Starting…" }
        if isStopping { return "Saving final speech…" }
        if isSpeaking { return isListening ? "Speaking · listening paused" : "Speaking" }
        if isListening { return "Listening" }
        if isAnswering { return "Answering" }
        return "Ready when you are"
    }
    var audioDisclosure: String {
        let config = settings.transcription
        switch config.resolvedKind {
        case .apple: return settings.onDeviceOnly ? "Audio stays on this Mac. AI assistance sends selected text to your configured provider." : "Apple may process speech. AI assistance sends selected text to your configured provider."
        case .localWhisper: return "Audio goes to your local Whisper server. AI assistance sends selected text to your configured provider."
        default: return "Audio goes to \(config.kind.rawValue) for transcription. Selected text goes to your configured AI providers."
        }
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        archive = SessionArchive(directory: support.appendingPathComponent("NotchMeetingAssistant/Sessions", isDirectory: true))
        voice.onFinished = { [weak self] in self?.finishVoice() }
        refreshKeyPresence()
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.archive.load()
                self.sessions = loaded.sessions
                // A session interrupted by a crash remains reviewable and is never resumed invisibly.
                for id in self.sessions.filter({ $0.endedAt == nil }).map(\.id) {
                    self.edit(id) { $0.endedAt = $0.segments.last?.time ?? $0.startedAt; $0.summaryStatus = "Interrupted session · transcript recovered" }
                }
                if !loaded.warnings.isEmpty { self.error = loaded.warnings.joined(separator: "\n") }
            } catch { self.error = "Could not open the session library: \(error.localizedDescription)" }
            self.loadingLibrary = false
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    func openNotch() { presentation.open() }
    func hover(_ inside: Bool) { presentation.hover(inside) }
    func setEditing(_ value: Bool) { presentation.setEditing(value) }
    func togglePin() { presentation.setPinned(!presentation.pinned) }
    func collapse() { presentation.dismiss() }
    func openLibrary(_ destination: LibrarySection = .home) {
        section = destination; collapse(); onOpenLibrary?()
    }
    func openSession(_ id: UUID, segmentID: UUID? = nil) {
        selectedSessionID = id; selectedSegmentID = segmentID
        edit(id) { $0.lastReviewedAt = Date() }
        openLibrary(.sessions)
    }
    func follow(_ evidence: MemoryEvidence) { openSession(evidence.sessionID, segmentID: evidence.segmentID) }
    private func tick() {
        var next = presentation; next.tick()
        if next != presentation { presentation = next }
        if !dirty.isEmpty, !saveInProgress, Date().timeIntervalSince(lastSave) > 2 {
            lastSave = Date(); Task { await self.flushSaves() }
        }
        guard isListening, !analysisBlocked, analysisTask == nil, !isSpeaking,
              gate.ready(delay: settings.autoDelay, listening: true, mode: .automatic, busy: false, speaking: false) else { return }
        analyzeLatest()
    }
    private func edit(_ id: UUID, _ change: (inout SessionRecord) -> Void) {
        guard let position = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[position]); sessions[position].touch(); dirty.insert(id)
    }
    func flushSaves() async {
        guard !saveInProgress else { return }
        saveInProgress = true
        let pending = dirty; dirty.subtract(pending)
        for id in pending {
            guard let record = sessions.first(where: { $0.id == id }) else { continue }
            do { try await archive.save(record) }
            catch { dirty.insert(id); error = "Your latest session changes could not be saved: \(error.localizedDescription)" }
        }
        saveInProgress = false
    }

    func start() async {
        guard !busyCapture, !loadingLibrary else { return }
        guard hasConsent else { error = "Confirm that you have permission from everyone being transcribed."; openNotch(); return }
        cancelAnswer(); analysisTask?.cancel(); analysisTask = nil
        error = nil; needsRecordingPermission = false; isStarting = true
        answer = ""; latestQuestion = ""; latestQuestionID = nil; answerComplete = false
        gate = AutoAnswerGate(); analyzed = [:]; analysisBlocked = false
        let record = SessionRecord(); let token = UUID(); sessionToken = token
        sessions.insert(record, at: 0); activeSessionID = record.id; selectedSessionID = record.id; dirty.insert(record.id)
        let input = MeetingCapture(); capture = input
        input.onSegment = { [weak self] id, source, text, time in
            guard let self, self.sessionToken == token, self.busyCapture else { return }
            guard let position = self.sessions.firstIndex(where: { $0.id == record.id }) else { return }
            if self.sessions[position].ingest(id: id, source: source, text: text, at: time) {
                self.dirty.insert(record.id); self.gate.changed()
            }
        }
        input.onLevel = { [weak self] level in
            guard let self, self.sessionToken == token else { return }
            if abs(self.audioLevel - level) > 0.04 { self.audioLevel = level }
        }
        input.onFailure = { [weak self] message in
            guard let self, self.sessionToken == token else { return }
            self.showError(message)
            Task { await self.stop(showReview: false) }
        }
        do {
            try await input.start(options: settings)
            guard sessionToken == token, isStarting else { await input.stop(flush: false); return }
            isStarting = false; isListening = true
            intelligenceStatus = hasAI ? "Understanding the conversation" : "Transcribing · connect an AI provider for assistance"
            collapse(); onStarted?()
            await flushSaves()
        } catch {
            guard sessionToken == token else { return }
            isStarting = false; await input.stop(flush: false); capture = nil
            edit(record.id) { $0.endedAt = Date(); $0.summaryStatus = "Listening did not start" }
            activeSessionID = nil
            let failure = error as NSError
            needsRecordingPermission = failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue
            showError(needsRecordingPermission ? "Allow Screen & System Audio Recording in Privacy & Security, then reopen the app. Microphone-only listening does not need this permission." : error.localizedDescription)
            await flushSaves()
        }
    }
    func stop(showReview: Bool = true, summarize: Bool = true) async {
        guard !isStopping, busyCapture else { return }
        isStopping = true; isListening = false; isStarting = false
        analysisTask?.cancel(); analysisTask = nil; cancelAnswer()
        let id = activeSessionID
        let input = capture; capture = nil
        // Keep the session token valid while the final transcription chunks drain.
        await input?.stop()
        sessionToken = UUID(); audioLevel = 0; isStopping = false; hasConsent = false; activeSessionID = nil
        if let id {
            edit(id) { $0.endedAt = Date() }
            await flushSaves()
            if summarize && settings.automaticSummary { generateSummary(id) }
            if showReview { openSession(id) }
        }
    }
    func prepareToQuit() async {
        await stop(showReview: false, summarize: false)
        analysisTask?.cancel(); cancelAnswer(); memoryTask?.cancel(); searchTask?.cancel()
        for (id, task) in summaryTasks { task.cancel(); edit(id) { $0.summaryStatus = "Summary interrupted · generate again" } }
        summaryTasks.removeAll()
        // Persist a final immutable snapshot even if a scheduled autosave was already underway.
        for session in sessions where dirty.contains(session.id) {
            do { try await archive.save(session) } catch { error = error.localizedDescription }
        }
    }

    private func client(for job: AIJob) throws -> ConfiguredLLMProvider {
        var configured = savedKeys
        for provider in settings.providers where provider.kind == .custom {
            if let url = try? provider.endpoint(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "") { configured.insert(provider.id) }
        }
        let route = settings.routes[job.rawValue] ?? ModelRoute()
        let provider = try ModelRoute.resolve(job: job, route: route, providers: settings.providers, configured: configured)
        return ConfiguredLLMProvider(configuration: provider, key: try APIKeyStore.load(provider.id))
    }
    private func analyzeLatest() {
        guard let session = activeSession else { return }
        let revision = gate.revision
        let changed = session.segments.filter { analyzed[$0.id] != $0.text }
        guard !changed.isEmpty else { gate.consume(revision); return }
        let provider: ConfiguredLLMProvider
        do { provider = try client(for: .quick) }
        catch { intelligenceStatus = "Connect an AI provider for question assistance"; gate.consume(revision); return }
        let selected = Array(changed.prefix(6))
        let ids = Set(selected.map(\.id)); let token = sessionToken
        let rows = selected.map { "ID: \($0.id)\nSource: \($0.source)\n\($0.text)" }.joined(separator: "\n\n")
        let context = "Current topic: \(session.topic)\nPrevious context:\n" + String(session.fullTranscript.suffix(5000))
        gate.consume(revision)
        analysisTask = Task { [weak self] in
            do {
                let response = try await provider.complete(system: ContextSelection.untrusted + "\n" + ContextSelection.classificationPrompt,
                                                           prompt: context + "\n\nNEW segments to classify:\n" + rows, maxTokens: 3000)
                let analysis = try SessionAnalysis.decode(response)
                guard let self, self.sessionToken == token, self.isListening, !Task.isCancelled else { return }
                var questions: [SessionMoment] = []
                self.edit(session.id) { record in questions = record.apply(analysis, allowedIDs: ids, detectQuestions: self.settings.assistance.detects).filter { $0.category == .question } }
                for segment in selected { self.analyzed[segment.id] = segment.text }
                self.analysisTask = nil
                self.intelligenceStatus = self.sessions.first(where: { $0.id == session.id })?.topic ?? "Listening"
                if changed.count > selected.count { self.gate.changed() }
                if let question = questions.last {
                    self.latestQuestion = question.quote; self.latestQuestionID = question.id
                    self.presentation.beginAnswer(); self.presentation.reveal(duration: 9)
                    if self.settings.assistance.generates && (!self.isAnswering || self.answeringAutomatically) {
                        self.cancelAnswer()
                        self.requestAnswer(text: question.quote, sessionID: session.id, automatic: true)
                    }
                }
            } catch {
                guard let self, self.sessionToken == token, !Task.isCancelled else { return }
                self.analysisTask = nil; self.analysisBlocked = true
                self.intelligenceStatus = "Assistance paused · retry in Settings"
                self.showError("Question assistance paused: \(error.localizedDescription) Transcription continues.")
            }
        }
    }
    func retryAssistance() { analysisBlocked = false; gate.changed(); intelligenceStatus = "Assistance enabled" }

    func requestAnswer(text: String? = nil, sessionID: UUID? = nil, automatic: Bool = false, job: AIJob = .live) {
        guard !isStarting, !isStopping else { return }
        let prompt = (text ?? (question.isEmpty ? latestQuestion : question)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record = sessions.first(where: { $0.id == (sessionID ?? activeSessionID ?? selectedSessionID) }), !record.segments.isEmpty || !prompt.isEmpty else { return }
        let provider: ConfiguredLLMProvider
        do { provider = try client(for: job) }
        catch { showError(error.localizedDescription); if !automatic { openLibrary(.settings) }; return }
        cancelAnswer(); let token = UUID(); answerToken = token
        let actualQuestion = prompt.isEmpty ? "Explain the most recent question or important concept." : prompt
        answerQuestion = actualQuestion; answerSessionID = record.id; answer = ""; answerComplete = false
        isAnswering = true; answeringAutomatically = automatic; question = ""
        if !automatic { presentation.beginAnswer(); presentation.reveal(duration: 15) }
        let shouldSpeak = automatic ? settings.assistance.speaks(output: settings.outputMode) : settings.outputMode.usesVoice
        answerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let evidence = await self.index.search(query: actualQuestion, sessions: [record], limit: 6).results
                try Task.checkCancellation()
                let context = ContextSelection.live(session: record, relevant: evidence)
                let instruction = "Help the user understand the current lecture, study session, interview or conversation. Answer in the speaker's language in 2 to 4 concise sentences. Use prior context and say when information is missing."
                try await provider.stream(system: ContextSelection.untrusted + "\n" + instruction,
                                          prompt: context + "\n\nUser request:\n" + String(actualQuestion.prefix(6000)), maxTokens: 2048) { [weak self] delta in
                    await self?.receiveAnswer(delta, token: token)
                }
                guard self.answerToken == token, !Task.isCancelled else { return }
                self.isAnswering = false; self.answeringAutomatically = false; self.answerComplete = true; self.answerTask = nil
                self.presentation.reveal(duration: 9)
                if shouldSpeak { self.readAnswer() }
            } catch {
                guard self.answerToken == token, !Task.isCancelled else { return }
                self.isAnswering = false; self.answeringAutomatically = false; self.answerTask = nil
                self.showError(error.localizedDescription)
            }
        }
    }
    private func receiveAnswer(_ delta: String, token: UUID) {
        guard answerToken == token else { return }
        answer += delta
        // Do not reopen or extend the notch for each streaming token.
    }
    func cancelAnswer() {
        answerToken = UUID(); answerTask?.cancel(); answerTask = nil
        isAnswering = false; answeringAutomatically = false; stopVoice()
    }
    func saveAnswer() {
        guard let id = answerSessionID, answerComplete, !answer.isEmpty else { return }
        let question = answerQuestion, text = answer
        edit(id) { record in
            if !record.answers.contains(where: { $0.question == question && $0.answer == text }) { record.answers.append(SavedAnswer(question: question, answer: text)) }
        }
        saveQuestion()
    }
    func saveQuestion() {
        guard let id = activeSessionID ?? answerSessionID ?? selectedSessionID else { return }
        edit(id) { record in
            if let moment = record.moments.first(where: { $0.id == latestQuestionID }), let p = record.segments.firstIndex(where: { $0.id == moment.segmentID }) { record.segments[p].bookmarked = true }
        }
    }
    func readAnswer() {
        guard answerComplete, !answer.isEmpty else { return }
        stopVoice()
        do { try capture?.setSuppressed(true); isSpeaking = true; voice.speak(answer, language: settings.locale, rate: settings.voiceRate) }
        catch { showError(error.localizedDescription) }
    }
    func stopVoice() { voice.stop(); finishVoice() }
    private func finishVoice() {
        guard isSpeaking else { return }; isSpeaking = false
        do { try capture?.setSuppressed(false) } catch { showError(error.localizedDescription) }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func copyAnswer() { copy(answer) }
    func showError(_ message: String) { error = message; presentation.beginAnswer(); presentation.reveal(duration: 12) }
    func openRecordingSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }

    func bookmark(sessionID: UUID, segmentID: UUID) {
        edit(sessionID) { if let p = $0.segments.firstIndex(where: { $0.id == segmentID }) { $0.segments[p].bookmarked.toggle() } }
    }
    func updateNote(sessionID: UUID, segmentID: UUID, text: String) {
        edit(sessionID) { if let p = $0.segments.firstIndex(where: { $0.id == segmentID }) { $0.segments[p].note = text } }
    }
    func addNote(sessionID: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        edit(sessionID) { $0.notes.append(SessionNote(text: text)) }
    }
    func renameSession(_ id: UUID, title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        edit(id) { $0.title = String(title.prefix(160)) }
    }
    func deleteSession(_ id: UUID) async {
        guard id != activeSessionID else { showError("Stop listening before deleting this session."); return }
        summaryTasks[id]?.cancel(); summaryTasks[id] = nil
        do {
            try await archive.remove(id: id); sessions.removeAll { $0.id == id }; dirty.remove(id)
            if selectedSessionID == id { selectedSessionID = nil }
            searchResults.removeAll { $0.sessionID == id }; memorySources.removeAll { $0.sessionID == id }; memoryAnswer = ""
        } catch { showError(error.localizedDescription) }
    }
    func exportSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Session-\(session.startedAt.formatted(.iso8601.year().month().day())).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try session.markdown.write(to: url, atomically: true, encoding: .utf8) }
        catch { showError(error.localizedDescription) }
    }
    func generateSummary(_ id: UUID) {
        guard summaryTasks[id] == nil, let record = sessions.first(where: { $0.id == id }), !record.segments.isEmpty else { return }
        let provider: ConfiguredLLMProvider
        do { provider = try client(for: .summary) }
        catch { edit(id) { $0.summaryStatus = "Connect a summary provider, then choose Generate summary" }; return }
        edit(id) { $0.summaryStatus = "Generating summary…" }
        summaryTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = record.segments.map { "[\($0.id)] \($0.source) at \($0.time.formatted()): \($0.text)" }
                var material = ContextSelection.chunks(rows)
                if material.count > 1 {
                    var notes: [String] = []
                    for (position, chunk) in material.enumerated() {
                        try Task.checkCancellation()
                        self.edit(id) { $0.summaryStatus = "Reviewing transcript \(position + 1) of \(material.count)…" }
                        notes.append(try await provider.complete(system: ContextSelection.untrusted + "\nExtract source-grounded study or discussion notes. Preserve questions, explanations, examples, formulas, assignments, exam mentions, exact deadlines, decisions, owners and source IDs. Do not add facts. Keep at most 600 words.", prompt: chunk, maxTokens: 1800))
                    }
                    material = notes
                    for _ in 0..<5 where material.joined().count > 24_000 {
                        var reduced: [String] = []
                        for group in ContextSelection.chunks(material, limit: 20_000) {
                            reduced.append(try await provider.complete(system: ContextSelection.untrusted + "\nConsolidate these notes into at most 500 words. Preserve source IDs, questions, exam material, decisions, assignments, owners, formulas and exact deadlines. Do not invent missing information.", prompt: group, maxTokens: 1500))
                        }
                        material = reduced
                    }
                    guard material.joined().count <= 40_000 else { throw AssistantError("This session is too large to summarize in one pass. The complete transcript remains saved.") }
                }
                let notes = record.notes.map(\.text).joined(separator: "\n")
                let summary = try await provider.complete(system: ContextSelection.untrusted + "\n" + ContextSelection.summaryPrompt,
                                                          prompt: "Session date: \(record.startedAt.formatted())\n\n" + material.joined(separator: "\n\n") + "\n\nUser notes:\n" + String(notes.prefix(4000)), maxTokens: 6000)
                try Task.checkCancellation()
                self.edit(id) { $0.summary = summary; $0.summaryStatus = "Summary ready" }
            } catch {
                if !Task.isCancelled { self.edit(id) { $0.summaryStatus = "Summary failed: \(error.localizedDescription)" } }
            }
            self.summaryTasks[id] = nil; await self.flushSaves()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel(); searchToken = UUID(); let token = searchToken
        let query = searchQuery; let records = sessions
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searchResults = []; searching = false; return }
        searching = true
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self else { return }
            let result = await self.index.search(query: query, sessions: records)
            guard self.searchToken == token, !Task.isCancelled else { return }
            self.searchResults = result.results; self.semanticSearch = result.semantic; self.searching = false
        }
    }
    func askMemory() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let provider: ConfiguredLLMProvider
        do { provider = try client(for: .deep) } catch { showError(error.localizedDescription); return }
        memoryTask?.cancel(); memoryToken = UUID(); let token = memoryToken
        let records = sessions; memoryAnswer = ""; memorySources = []; askingMemory = true
        memoryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let evidence = await self.index.search(query: query, sessions: records, limit: 16).results
                guard self.memoryToken == token, !Task.isCancelled else { return }
                self.memorySources = evidence
                guard !evidence.isEmpty else { self.memoryAnswer = "No matching material was found in your saved sessions."; self.askingMemory = false; return }
                let source = evidence.map { "\($0.citation) \($0.title) · \($0.time.formatted()) · \($0.kind)\n\($0.text)" }.joined(separator: "\n\n")
                try await provider.stream(system: ContextSelection.untrusted + "\nAnswer only from the supplied evidence. Cite each factual claim with the exact [source ID] supplied. Say when the evidence is insufficient. Treat AI summaries as secondary material and prefer the original transcript. Do not guess assignments, people or deadlines.", prompt: "Question: \(String(query.prefix(4000)))\n\nEvidence:\n" + source, maxTokens: 4096) { [weak self] delta in
                    await self?.receiveMemory(delta, token: token)
                }
                if self.memoryToken == token { self.askingMemory = false }
            } catch {
                guard self.memoryToken == token, !Task.isCancelled else { return }
                self.askingMemory = false; self.showError(error.localizedDescription)
            }
        }
    }
    private func receiveMemory(_ delta: String, token: UUID) { if token == memoryToken { memoryAnswer += delta } }

    func refreshKeyPresence() {
        for id in settings.providers.map(\.id) + ["transcription-custom"] {
            do { if try APIKeyStore.load(id).isEmpty { savedKeys.remove(id) } else { savedKeys.insert(id) } }
            catch { providerStatus[id] = error.localizedDescription }
        }
    }
    @discardableResult func saveProviderKey(_ value: String, id: String) -> Bool {
        do {
            try APIKeyStore.save(value, provider: id); savedKeys.insert(id); verifiedProviders.remove(id)
            providerStatus[id] = "Saved securely in Keychain"; retryAssistance(); return true
        } catch { providerStatus[id] = error.localizedDescription; return false }
    }
    func removeProviderKey(_ id: String) {
        do { try APIKeyStore.remove(id); savedKeys.remove(id); verifiedProviders.remove(id); providerStatus[id] = "Key removed" }
        catch { providerStatus[id] = error.localizedDescription }
    }
    func refreshModels(_ id: String) async {
        guard !busyProviders.contains(id), let provider = settings.providers.first(where: { $0.id == id }) else { return }
        busyProviders.insert(id); defer { busyProviders.remove(id) }
        do {
            let models = try await ConfiguredLLMProvider(configuration: provider, key: APIKeyStore.load(id)).getModels()
            modelCatalogs[id] = models; verifiedProviders.insert(id)
            providerStatus[id] = "Connected · \(models.count) models available"
        } catch { verifiedProviders.remove(id); providerStatus[id] = error.localizedDescription }
    }
    func addCustomProvider() {
        var provider = ProviderConfiguration(kind: .custom, id: UUID().uuidString)
        provider.name = "Custom endpoint \(settings.providers.filter { $0.kind == .custom }.count + 1)"
        settings.providers.append(provider)
    }
    func refreshTranscriptionModels() async {
        guard !checkingTranscription else { return }
        checkingTranscription = true; defer { checkingTranscription = false }
        let config = settings.transcription
        if config.resolvedKind == .apple { transcriptionModels = ["Apple Speech"]; transcriptionStatus = "Native Apple Speech"; return }
        do {
            let key = config.kind.keyID.isEmpty ? "" : try APIKeyStore.load(config.kind.keyID)
            let provider = WhisperProvider(configuration: config, key: key)
            if config.resolvedKind == .localWhisper { try await provider.validateApiKey() }
            transcriptionModels = try await provider.getModels(); transcriptionStatus = "Transcription provider available"
        } catch { transcriptionStatus = error.localizedDescription }
    }
    func refreshApplications() async {
        guard !loadingApplications else { return }; loadingApplications = true; defer { loadingApplications = false }
        do { applications = try await MeetingCapture.applications() } catch { showError(error.localizedDescription) }
    }
}
