import SwiftUI
import AppKit
import NotchCore

enum CompanionPalette {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let wash = Color.primary.opacity(0.045)
}

struct CompanionPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.25), in: Capsule())
            .contentShape(Capsule())
    }
}

@MainActor
struct CompanionWindow: View {
    @ObservedObject var model: MeetingModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                if let error = model.error { errorBanner(error) }
                destination
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CompanionPalette.canvas)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(CompanionPalette.canvas)
        .tint(.primary)
        .sheet(item: $model.configuringProvider) { provider in
            ProviderConfigurationView(model: model, provider: provider)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.openMain(.home) } label: {
                HStack(spacing: 11) {
                    Image(systemName: "waveform").font(.system(size: 20, weight: .medium))
                    Text("Notch").font(.system(size: 21, weight: .semibold)).tracking(-0.7)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 38)
            navItem(.home, title: "Home", symbol: "house", key: "1")
            navItem(.sessions, title: "Sessions", symbol: "rectangle.stack", key: "2")
            navItem(.notes, title: "Notes", symbol: "square.and.pencil", key: "3")
            navItem(.search, title: "Search", symbol: "magnifyingglass", key: "k")
            Spacer(minLength: 28)
            if model.isListening || model.isStarting || model.isStopping {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 9) {
                        Image(systemName: "waveform").font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.isStopping ? "Saving…" : (model.isStarting ? "Starting…" : "Listening"))
                                .font(.system(size: 12, weight: .medium))
                            Text(model.elapsedLabel)
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await finishListeningSession(model) } } label: {
                            Image(systemName: "stop.fill").font(.system(size: 9)).frame(width: 25, height: 25)
                        }
                        .buttonStyle(.plain).help("Stop listening").accessibilityLabel("Stop listening").disabled(model.isStopping)
                    }
                    if model.isStopping {
                        Button("Finish now") { model.cancelFinishing() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            .help("Save received transcript and cancel pending transcription")
                    } else if let sessionID = model.activeSessionID {
                        Button("Open live session") { model.openMain(.sessions, sessionID: sessionID) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 18)
            }
            navItem(.settings, title: "Settings", symbol: "slider.horizontal.3", key: ",")
            Text("A little less to remember.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 16)
        }
        .padding(.horizontal, 17).padding(.top, 57).padding(.bottom, 25)
        .frame(width: 202)
        .background(CompanionPalette.sidebar)
    }

    private func navItem(_ destination: CompanionDestination, title: String, symbol: String, key: KeyEquivalent) -> some View {
        Button {
            if destination == .sessions { model.selectedSessionID = nil; model.highlightedTranscriptID = nil }
            model.openMain(destination)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(width: 20)
                Text(title).font(.system(size: 12.5, weight: model.destination == destination ? .semibold : .regular))
                Spacer()
                if destination == .search {
                    Text("⌘K").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(model.destination == destination ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(model.destination == destination ? CompanionPalette.wash : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .padding(.bottom, 3)
        .accessibilityAddTraits(model.destination == destination ? .isSelected : [])
    }

    @ViewBuilder private var destination: some View {
        switch model.destination {
        case .home:
            CompanionHomeView(model: model)
        case .sessions:
            if let id = model.selectedSessionID, model.sessions.contains(where: { $0.id == id }) {
                SessionDetailView(model: model, sessionID: id).id(id)
            } else {
                SessionLibraryView(model: model)
            }
        case .notes:
            CompanionNotesView(model: model)
        case .search:
            CompanionSearchView(model: model)
        case .settings:
            ProviderSettingsView(model: model)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(model.needsRecordingPermission ? "Open Privacy Settings" : "Open Settings") {
                    if model.needsRecordingPermission { model.openRecordingSettings() }
                    else { model.openMain(.settings) }
                }.buttonStyle(.plain).fontWeight(.semibold)
            }
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss error")
        }
        .font(.system(size: 12))
        .padding(18).padding(.top, 27)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.wash)
    }
}

@MainActor
private struct CompanionHomeView: View {
    @ObservedObject var model: MeetingModel
    private var recent: [ListeningSession] { Array(model.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(4)) }
    private var reviewSession: ListeningSession? {
        model.sessions.sorted { $0.startedAt > $1.startedAt }.first {
            $0.endedAt != nil && (!$0.moments.isEmpty || !$0.notes.isEmpty)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Eyebrow(text: Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    Spacer()
                    Button { model.openMain(.search) } label: {
                        Label("Ask your memory", systemImage: "magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.bottom, 35)

                Text(model.isListening ? "Stay in the moment." : "Ready when you are.")
                    .font(.system(size: 35, weight: .semibold)).tracking(-1.2)
                Text("Lectures, conversations, and everything in between.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 10)

                listeningControl.padding(.top, 30).padding(.bottom, 43)

                HStack {
                    Text("Recent sessions").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if !recent.isEmpty {
                        Button("View all") {
                            model.selectedSessionID = nil
                            model.openMain(.sessions)
                        }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 13)

                if recent.isEmpty {
                    EmptyCompanionState(symbol: "waveform", title: "Your first session starts here.",
                                        message: "Start listening and your transcript, questions, and important moments will have a home.")
                        .padding(.vertical, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(recent) { session in
                            SessionListRow(session: session, isActive: model.activeSessionID == session.id && (model.isListening || model.isStarting || model.isStopping)) {
                                model.openMain(.sessions, sessionID: session.id)
                            }
                        }
                    }
                }

                if let session = reviewSession {
                    VStack(alignment: .leading, spacing: 15) {
                        Eyebrow(text: "Continue reviewing")
                        Button { model.openMain(.sessions, sessionID: session.id) } label: {
                            HStack(alignment: .center, spacing: 14) {
                                Image(systemName: "book").font(.system(size: 20, weight: .light))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                                    Text("\(session.moments.count) moments · \(session.notes.count) saved notes")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right").font(.system(size: 13))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 33)
                }
            }
            .padding(.horizontal, 46).padding(.top, 54).padding(.bottom, 42)
            .frame(maxWidth: 940, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var listeningControl: some View {
        VStack(alignment: .leading, spacing: 13) {
            if model.isListening || model.isStarting || model.isStopping {
                HStack(spacing: 16) {
                    Button { Task { await finishListeningSession(model) } } label: {
                        Label(model.isStopping ? "Saving…" : (model.isStarting ? "Cancel Starting" : "Stop Listening"), systemImage: "stop.fill")
                    }
                    .buttonStyle(CompanionPrimaryButtonStyle()).disabled(model.isStopping)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isStopping ? "Saving the last words…" : (model.isStarting ? "Requesting access…" : model.contextLabel)).font(.system(size: 12, weight: .medium))
                        Text(model.elapsedLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if model.isStopping {
                    Button("Finish now") { model.cancelFinishing() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        .help("Save received transcript and cancel pending transcription")
                } else if let id = model.activeSessionID {
                    Button("Open live transcript") { model.openMain(.sessions, sessionID: id) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Button { Task { await model.start() } } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "waveform").font(.system(size: 15, weight: .medium))
                        Text("Start Listening")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).padding(.leading, 9)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(CompanionPrimaryButtonStyle()).disabled(!model.hasConsent)
                Toggle("Everyone here agrees to transcription", isOn: $model.hasConsent)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Text(audioDisclosure).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audioDisclosure: String {
        switch model.settings.transcription.provider {
        case .auto, .apple:
            return "Audio uses Apple Speech. AI features use your configured providers."
        case .localWhisper:
            return "Audio uses your local Whisper server. AI features use your configured providers."
        default:
            return "Audio is sent to \(model.settings.transcription.provider.displayName). AI features use your configured providers."
        }
    }
}

@MainActor
private struct SessionLibraryView: View {
    @ObservedObject var model: MeetingModel
    @State private var filter = ""
    private var sessions: [ListeningSession] {
        model.sessions.sorted { $0.startedAt > $1.startedAt }.filter {
            filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.kind.rawValue.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                CompanionPageHeader(eyebrow: "Your memory", title: "Sessions", subtitle: "Everything you heard, ready to come back to.")
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a session", text: $filter).textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear session filter")
                    }
                }
                .font(.system(size: 13)).padding(12)
                .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 9))
                if sessions.isEmpty {
                    EmptyCompanionState(symbol: "rectangle.stack", title: filter.isEmpty ? "A place for your conversations." : "No matching sessions.",
                                        message: filter.isEmpty ? "Start listening from Home. Sessions are organized automatically as they take shape." : "Try a different title, or use Search to look inside your sessions.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(sessions) { session in
                            SessionListRow(session: session, isActive: model.activeSessionID == session.id && (model.isListening || model.isStarting || model.isStopping)) {
                                model.highlightedTranscriptID = nil
                                model.openMain(.sessions, sessionID: session.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 46).padding(.top, 52).padding(.bottom, 40)
        }
    }
}

private struct SessionListRow: View {
    let session: ListeningSession
    let isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: sessionSymbol(session.kind))
                    .font(.system(size: 17, weight: .light)).frame(width: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(isActive ? "Listening now" : sessionKindLabel(session.kind))
                        Text("·")
                        Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "waveform").font(.system(size: 13))
                } else {
                    Text(sessionDuration(session)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).padding(.leading, 9)
                }
            }
            .padding(.vertical, 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.5) }
    }
}

@MainActor
private struct SessionDetailView: View {
    @ObservedObject var model: MeetingModel
    let sessionID: UUID
    @State private var tab: DetailTab = .summary
    @State private var noteDraft: TranscriptNoteDraft?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary", transcript = "Full Transcript", moments = "Moments"
        var id: String { rawValue }
    }
    private var session: ListeningSession? { model.sessions.first { $0.id == sessionID } }
    private var isLive: Bool { model.activeSessionID == sessionID && (model.isListening || model.isStarting || model.isStopping) }
    private var lines: [TranscriptLine] { session?.transcript ?? (isLive ? model.transcript.lines : []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                header(session).padding(.horizontal, 38).padding(.top, 43).padding(.bottom, 20)
                HStack {
                    Picker("Session view", selection: $tab) {
                        ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 320)
                    Spacer()
                    if model.summarizingSessionIDs.contains(sessionID) {
                        ProgressView().controlSize(.mini)
                        Text("Writing summary…").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if isLive {
                        Label(model.isStopping ? "Saving…" : "Live", systemImage: "waveform").font(.system(size: 11, weight: .medium))
                    } else if session.summary == nil || session.summary?.usedFallback == true {
                        Button("Regenerate summary") { model.generateSummary(for: sessionID) }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 38).padding(.bottom, 20)
                Group {
                    switch tab {
                    case .summary: summaryContent(session)
                    case .transcript:
                        TranscriptReader(model: model, session: session, lines: lines, isLive: isLive) { line in
                            noteDraft = TranscriptNoteDraft(sessionID: sessionID, transcriptID: line.id, text: line.text)
                        }
                    case .moments: momentsContent(session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                answerAndComposer(session)
            }
        }
        .onAppear { updateTabForSelection() }
        .onChange(of: isLive) { _, live in if !live { tab = .summary } }
        .onChange(of: model.highlightedTranscriptID) { _, id in if id != nil { tab = .transcript } }
        .sheet(item: $noteDraft) { draft in
            TranscriptNoteEditor(model: model, draft: draft)
        }
    }

    private func updateTabForSelection() {
        if model.highlightedTranscriptID != nil || isLive { tab = .transcript }
    }

    private func header(_ session: ListeningSession) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Button {
                model.selectedSessionID = nil
                model.highlightedTranscriptID = nil
            } label: {
                Label("All sessions", systemImage: "chevron.left").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(session.title).font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 7) {
                        Text(sessionKindLabel(session.kind))
                        Text("·")
                        Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        if !isLive { Text("·"); Text(sessionDuration(session)) }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isLive {
                    Button { Task { await finishListeningSession(model) } } label: {
                        Label(model.isStopping ? "Saving…" : "Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).disabled(model.isStopping)
                    if model.isStopping {
                        Button("Finish now") { model.cancelFinishing() }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("Save received transcript and cancel pending transcription")
                    }
                }
            }
        }
    }

    private func summaryContent(_ session: ListeningSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 29) {
                if let summary = session.summary {
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: session.kind == .automatic ? "Session summary" : "\(session.kind.rawValue) summary")
                        Text(summary.overview).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                        SummarySources(ids: summary.overviewSourceTranscriptIDs, lines: lines, onSelect: showSource)
                        if summary.usedFallback {
                            Label("Organized from transcript highlights", systemImage: "text.alignleft")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(summary.sections.filter { !$0.content.isEmpty }) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title).font(.system(size: 15, weight: .semibold))
                            ForEach(Array(section.content.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 10) {
                                    if section.content.count > 1 {
                                        Circle().fill(Color.primary.opacity(0.4)).frame(width: 3, height: 3).padding(.top, 9)
                                    }
                                    Text(item).font(.system(size: 13)).lineSpacing(5)
                                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }
                            }
                            SummarySources(ids: section.sourceTranscriptIDs, lines: lines, onSelect: showSource)
                        }
                    }
                } else {
                    EmptyCompanionState(symbol: isLive ? "waveform" : "text.alignleft",
                                        title: isLive ? "Your notes are taking shape." : "Your transcript is ready.",
                                        message: isLive ? "A structured summary appears when you finish. Important moments are being collected as you listen." : "Open the full transcript or review the important moments from this session.")
                    if !session.moments.isEmpty {
                        Text("Important moments").font(.system(size: 15, weight: .semibold))
                        ForEach(Array(session.moments.prefix(8))) { moment in momentRow(moment) }
                    }
                }
                if !session.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your notes").font(.system(size: 15, weight: .semibold))
                        ForEach(session.notes) { note in
                            VStack(alignment: .leading, spacing: 7) {
                                if note.isBookmark {
                                    Label("Bookmark", systemImage: "bookmark.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(note.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                if let id = note.transcriptID {
                                    Button("View in transcript") { showSource(id) }
                                        .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
            .padding(.horizontal, 40).padding(.top, 5).padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func momentsContent(_ session: ListeningSession) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if session.moments.isEmpty {
                    EmptyCompanionState(symbol: "bookmark", title: "The moments that matter.",
                                        message: "Questions, explanations, assignments, decisions, and exam mentions are collected here automatically.")
                } else {
                    ForEach(session.moments) { moment in momentRow(moment) }
                }
            }
            .padding(.horizontal, 40).padding(.top, 6).padding(.bottom, 30)
        }
    }

    private func momentRow(_ moment: SessionMoment) -> some View {
        Button { showSource(moment.transcriptID) } label: {
            HStack(alignment: .top, spacing: 16) {
                Text(moment.time, format: .dateTime.hour().minute())
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading).padding(.top, 4)
                VStack(alignment: .leading, spacing: 8) {
                    MomentBadge(category: moment.category)
                    Text(moment.text).font(.system(size: 13)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let answer = moment.answer, !answer.isEmpty {
                        Text(answer).font(.system(size: 12)).lineSpacing(4).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 5)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func answerAndComposer(_ session: ListeningSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.displayedAnswerSessionID == sessionID && (!model.answer.isEmpty || model.isAnswering) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Text(model.isAnswering ? "Thinking…" : "Answer").font(.system(size: 11, weight: .semibold))
                        if model.isAnswering { ProgressView().controlSize(.mini) }
                        Spacer()
                        if !model.answer.isEmpty {
                            Button("Save") { model.saveNote(model.answer, sessionID: sessionID) }
                            Button("Copy") { model.copyText(model.answer) }
                        }
                        if model.isSpeaking {
                            Button("Stop voice") { model.stopVoice() }
                        } else if model.answerComplete {
                            Button { model.readAnswer() } label: { Image(systemName: "speaker.wave.2") }
                                .help("Read answer aloud").accessibilityLabel("Read answer aloud")
                        }
                    }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                    if !model.answer.isEmpty {
                        ScrollView {
                            Text(sessionAnswerText(model.answer, lines: lines)).font(.system(size: 13)).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                .environment(\.openURL, OpenURLAction { url in
                                    guard url.scheme == "notch-source", let host = url.host, let id = UUID(uuidString: host),
                                          lines.contains(where: { $0.id == id }) else { return .discarded }
                                    showSource(id)
                                    return .handled
                                })
                        }
                        .frame(maxHeight: 135)
                    }
                }
            }
            if !model.intelligenceStatus.isEmpty {
                Text(model.intelligenceStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled).help(model.intelligenceStatus)
            }
            HStack(spacing: 10) {
                TextField("Ask about this session…", text: $model.question)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { if !model.isAnswering { model.requestAnswer() } }
                    .accessibilityLabel("Ask about this session")
                Button {
                    if model.isAnswering { model.cancelAnswer() }
                    else { model.requestAnswer() }
                } label: {
                    Image(systemName: model.isAnswering ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .semibold)).frame(width: 27, height: 27)
                }
                .buttonStyle(.plain).disabled(!model.isAnswering && !model.canAnswer)
                .accessibilityLabel(model.isAnswering ? "Cancel answer" : "Ask question")
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 7)
            .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 11))
        }
        .padding(.horizontal, 38).padding(.vertical, 18)
        .background(CompanionPalette.canvas)
    }

    private func showSource(_ id: UUID) { model.highlightedTranscriptID = id; tab = .transcript }
}

@MainActor
private struct TranscriptReader: View {
    @ObservedObject var model: MeetingModel
    let session: ListeningSession
    let lines: [TranscriptLine]
    let isLive: Bool
    var createNote: (TranscriptLine) -> Void
    @State private var followLive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLive {
                HStack {
                    Text("Speech appears as it is recognized").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Follow live", isOn: $followLive).toggleStyle(.checkbox).font(.system(size: 10))
                }
                .padding(.horizontal, 40).padding(.bottom, 13)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if lines.isEmpty {
                            EmptyCompanionState(symbol: "waveform", title: isLive ? "Listening for speech…" : "No transcript captured.",
                                                message: isLive ? "You can keep this window closed. Your session continues at the notch." : "Check your audio source in Settings before your next session.")
                        }
                        ForEach(lines) { line in
                            TranscriptPassage(model: model, line: line, session: session,
                                              highlighted: model.highlightedTranscriptID == line.id) { createNote(line) }
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("live-transcript-end")
                    }
                    .padding(.horizontal, 28).padding(.bottom, 24)
                }
                .onAppear {
                    if let id = model.highlightedTranscriptID { followLive = false; proxy.scrollTo(id, anchor: .center) }
                    else if isLive && followLive { proxy.scrollTo("live-transcript-end", anchor: .bottom) }
                }
                .onChange(of: model.highlightedTranscriptID) { _, id in
                    if let id { followLive = false; proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: lines) { _, _ in
                    if isLive && followLive { proxy.scrollTo("live-transcript-end", anchor: .bottom) }
                }
                .onChange(of: followLive) { _, follow in
                    if follow { model.highlightedTranscriptID = nil; proxy.scrollTo("live-transcript-end", anchor: .bottom) }
                }
            }
        }
    }
}

@MainActor
private struct TranscriptPassage: View {
    @ObservedObject var model: MeetingModel
    let line: TranscriptLine
    let session: ListeningSession
    let highlighted: Bool
    var createNote: () -> Void
    @State private var hovered = false

    private var categories: [MomentCategory] {
        var seen = Set<String>()
        return session.moments.filter { $0.transcriptID == line.id }.map(\.category)
            .filter { seen.insert($0.rawValue).inserted }
    }
    private var bookmarked: Bool { session.notes.contains { $0.transcriptID == line.id && $0.isBookmark } }

    var body: some View {
        HStack(alignment: .top, spacing: 17) {
            VStack(alignment: .leading, spacing: 10) {
                Text(line.time, format: .dateTime.hour().minute())
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                if categories.contains(.question) {
                    Image(systemName: "questionmark.bubble").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if categories.contains(.exam) || categories.contains(.important) {
                    Image(systemName: "asterisk").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 60, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Text(line.source.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.secondary).lineLimit(1)
                    if bookmarked {
                        Image(systemName: "bookmark.fill").font(.system(size: 9)).help("Bookmarked")
                    }
                    Spacer()
                    Menu { passageActions } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 26, height: 18)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .opacity(hovered || highlighted ? 1 : 0.4)
                    .help("Passage actions").accessibilityLabel("Actions for this transcript passage")
                }
                Text(line.text).font(.system(size: 13)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                if !categories.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(Array(categories.prefix(3)), id: \.rawValue) { category in MomentBadge(category: category) }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 15)
        .background(highlighted ? Color.primary.opacity(0.065) : (hovered ? Color.primary.opacity(0.025) : .clear),
                    in: RoundedRectangle(cornerRadius: 9))
        .onHover { hovered = $0 }
        .contextMenu { passageActions }
    }

    @ViewBuilder private var passageActions: some View {
        Button("Ask AI about this", systemImage: "text.bubble") { model.askAbout(line, action: "Ask", sessionID: session.id) }
        Button(bookmarked ? "Remove Bookmark" : "Bookmark", systemImage: bookmarked ? "bookmark.slash" : "bookmark") {
            model.toggleBookmark(line, sessionID: session.id)
        }
        Button("Copy", systemImage: "doc.on.doc") { model.copyText(line.text) }
        Button("Create Note", systemImage: "square.and.pencil", action: createNote)
        Divider()
        Button("Explain", systemImage: "lightbulb") { model.askAbout(line, action: "Explain", sessionID: session.id) }
        Button("Summarize", systemImage: "text.alignleft") { model.askAbout(line, action: "Summarize", sessionID: session.id) }
    }
}

private struct MomentBadge: View {
    let category: MomentCategory
    var body: some View {
        Label(category.rawValue, systemImage: momentSymbol(category))
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct SummarySources: View {
    let ids: [UUID]
    let lines: [TranscriptLine]
    var onSelect: (UUID) -> Void

    var body: some View {
        if !ids.isEmpty {
            Menu {
                ForEach(ids, id: \.self) { id in
                    if let line = lines.first(where: { $0.id == id }) {
                        Button("\(line.time.formatted(date: .omitted, time: .shortened)) · \(String(line.text.prefix(80)))") { onSelect(id) }
                    }
                }
            } label: {
                Label(ids.count == 1 ? "View source" : "View \(ids.count) sources", systemImage: "text.quote")
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct CompanionNotesView: View {
    @ObservedObject var model: MeetingModel
    @State private var sessionID: UUID?
    private struct NoteItem: Identifiable {
        let session: ListeningSession
        let note: SessionNote
        var id: UUID { note.id }
    }
    private var notes: [NoteItem] {
        model.sessions.flatMap { session in session.notes.map { NoteItem(session: session, note: $0) } }
            .sorted { $0.note.time > $1.note.time }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                CompanionPageHeader(eyebrow: "Keep it close", title: "Notes", subtitle: "Your thoughts, bookmarks, and things worth keeping.")
                VStack(alignment: .leading, spacing: 12) {
                    TextEditor(text: $model.noteDraft)
                        .font(.system(size: 13)).scrollContentBackground(.hidden)
                        .padding(9).frame(height: 100)
                        .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .topLeading) {
                            if model.noteDraft.isEmpty {
                                Text("A thought worth keeping…").font(.system(size: 13)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 14).padding(.top, 17).allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("New note")
                    HStack {
                        if !model.sessions.isEmpty {
                            Picker("Attach to", selection: $sessionID) {
                                Text("Current or most recent session").tag(Optional<UUID>.none)
                                ForEach(model.sessions.sorted { $0.startedAt > $1.startedAt }) {
                                    Text($0.title).tag(Optional($0.id))
                                }
                            }
                            .labelsHidden().frame(maxWidth: 320).controlSize(.small)
                            .accessibilityLabel("Session for new note")
                        }
                        Spacer()
                        Button("Save Note") {
                            model.saveNote(model.noteDraft, sessionID: sessionID)
                            model.noteDraft = ""
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(model.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if notes.isEmpty {
                    EmptyCompanionState(symbol: "square.and.pencil", title: "Keep the thought. Keep the context.",
                                        message: "Write a note here or bookmark a passage in any transcript. Saved notes stay connected to their session.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(notes) { item in
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Label(item.note.isBookmark ? "Bookmark" : "Note",
                                          systemImage: item.note.isBookmark ? "bookmark.fill" : "square.and.pencil")
                                    Spacer()
                                    Text(item.note.time, format: .dateTime.month(.abbreviated).day().hour().minute())
                                }
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(item.note.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                Button {
                                    model.highlightedTranscriptID = item.note.transcriptID
                                    model.openMain(.sessions, sessionID: item.session.id)
                                } label: {
                                    Label(item.session.title, systemImage: "arrow.up.right")
                                        .font(.system(size: 11)).lineLimit(1)
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 21)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.5) }
                        }
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.horizontal, 46).padding(.top, 52).padding(.bottom, 40)
        }
    }
}

@MainActor
private struct CompanionSearchView: View {
    @ObservedObject var model: MeetingModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                CompanionPageHeader(eyebrow: "Bring it back", title: "Ask your memory", subtitle: "Find the idea, even when you do not remember the exact words.")
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .bottom, spacing: 12) {
                        TextField("What would you like to remember?", text: $model.memoryQuestion, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...3)
                            .onSubmit { askMemory() }
                        Button { askMemory() } label: {
                            if model.memoryIsAnswering {
                                ProgressView().controlSize(.small).frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 18, height: 18)
                            }
                        }
                        .buttonStyle(CompanionPrimaryButtonStyle())
                        .disabled(model.memoryIsAnswering || model.memoryQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Ask your memory")
                    }
                    .padding(.leading, 17).padding(.trailing, 7).padding(.vertical, 7)
                    .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 15))
                    if model.memoryAnswer.isEmpty && !model.memoryIsAnswering {
                        HStack(spacing: 15) {
                            memoryPrompt("What assignments are due?")
                            memoryPrompt("What should I review this week?")
                        }
                    }
                    if model.memoryIsAnswering {
                        Label("Looking through your sessions…", systemImage: "text.magnifyingglass")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !model.memoryAnswer.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(memoryAnswerText(model.memoryAnswer, sources: model.memorySources))
                                .font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                                .environment(\.openURL, OpenURLAction { url in
                                    guard url.scheme == "notch-memory-source", let host = url.host, let number = Int(host),
                                          number > 0, number <= model.memorySources.count else { return .discarded }
                                    model.selectSearchResult(model.memorySources[number - 1])
                                    return .handled
                                })
                            Button("Copy answer") { model.copyText(model.memoryAnswer) }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                            if !model.memorySources.isEmpty {
                                Eyebrow(text: "Sources").padding(.top, 9)
                                ForEach(Array(model.memorySources.enumerated()), id: \.element.id) { index, source in
                                    Button { model.selectSearchResult(source) } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            Text("[\(index + 1)]").font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .frame(width: 28, alignment: .leading)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(source.sessionTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                                Text(source.excerpt).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            Spacer(minLength: 0)
                                            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 5)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 9)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Search everything").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if !model.searchQuery.isEmpty {
                            Text(model.searchUsesSemantic ? "Semantic + text" : "Text search")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search transcripts, questions, notes…", text: $model.searchQuery)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .onSubmit { model.searchMemory() }
                        if !model.searchQuery.isEmpty {
                            Button { model.searchQuery = ""; model.searchMemory() } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                        }
                    }
                    .font(.system(size: 13)).padding(13)
                    .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 9))
                    if model.searchResults.isEmpty {
                        EmptyCompanionState(symbol: "magnifyingglass",
                                            title: model.searchQuery.isEmpty ? "It is all here when you need it." : "No matching passages.",
                                            message: model.searchQuery.isEmpty ? "Search for a topic, a question, an assignment, or a remembered phrase across every session." : "Try another topic or a few different words. Only saved session content is searched.")
                    } else {
                        Text("\(model.searchResults.count) matching passages").font(.system(size: 10)).foregroundStyle(.tertiary)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.searchResults) { result in
                                Button { model.selectSearchResult(result) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 7) {
                                            Text(result.sessionTitle).fontWeight(.medium).lineLimit(1)
                                            Text("·")
                                            Text(result.kind)
                                            Spacer()
                                            Text(result.time, format: .dateTime.month(.abbreviated).day())
                                            Image(systemName: "arrow.up.right").padding(.leading, 5)
                                        }
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        Text(result.excerpt).font(.system(size: 13)).lineSpacing(4).lineLimit(4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 18).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.5) }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 46).padding(.top, 52).padding(.bottom, 40)
        }
        .onAppear { searchFocused = true }
    }

    private func memoryPrompt(_ text: String) -> some View {
        Button { model.memoryQuestion = text; askMemory() } label: {
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.buttonStyle(.plain)
    }

    private func askMemory() {
        guard !model.memoryIsAnswering, !model.memoryQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await model.askMemory() }
    }
}

private struct TranscriptNoteDraft: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let transcriptID: UUID
    var text: String
}

@MainActor
private struct TranscriptNoteEditor: View {
    @ObservedObject var model: MeetingModel
    let draft: TranscriptNoteDraft
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text("Create a note").font(.system(size: 23, weight: .semibold)).tracking(-0.5)
            Text("This note stays connected to the original passage.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden)
                .padding(9).frame(height: 180)
                .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Note text")
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Note") {
                    model.saveNote(text, sessionID: draft.sessionID, transcriptID: draft.transcriptID)
                    dismiss()
                }
                .buttonStyle(CompanionPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 470)
        .background(CompanionPalette.canvas)
        .onAppear { text = draft.text }
    }
}

struct CompanionPageHeader: View {
    var eyebrow: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Eyebrow(text: eyebrow)
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.9).padding(.top, 6)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
        }
    }
}

struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.tertiary)
    }
}

struct EmptyCompanionState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(.secondary).padding(.bottom, 5)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                .frame(maxWidth: 410, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 30)
    }
}

private func sessionSymbol(_ kind: SessionKind) -> String {
    switch kind {
    case .lecture: return "graduationcap"
    case .meeting: return "person.2"
    case .study: return "book"
    case .interview: return "person.crop.rectangle"
    case .presentation: return "rectangle.on.rectangle"
    case .brainstorming: return "lightbulb"
    case .automatic, .conversation: return "bubble.left.and.bubble.right"
    }
}

private func sessionKindLabel(_ kind: SessionKind) -> String { kind == .automatic ? "Listening session" : kind.rawValue }

private func sessionDuration(_ session: ListeningSession) -> String {
    guard let endedAt = session.endedAt else { return "In progress" }
    let seconds = max(0, Int(endedAt.timeIntervalSince(session.startedAt)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
}

private func momentSymbol(_ category: MomentCategory) -> String {
    switch category {
    case .important: return "asterisk"
    case .exam: return "checklist"
    case .assignment: return "doc.text"
    case .definition: return "text.book.closed"
    case .formula: return "function"
    case .example: return "square.on.square"
    case .question: return "questionmark.bubble"
    case .explanation: return "lightbulb"
    case .deadline: return "calendar"
    case .decision: return "checkmark.circle"
    case .action: return "arrow.right.circle"
    case .topic: return "number"
    }
}

/// Only citations that resolve to retained transcript evidence become navigable links.
private func sessionAnswerText(_ text: String, lines: [TranscriptLine]) -> AttributedString {
    let sources = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    return linkedAnswerText(text, pattern: #"\[([A-Fa-f0-9-]{36})\]"#) { reference in
        guard let id = UUID(uuidString: reference), let line = sources[id] else { return nil }
        return "[\(line.time.formatted(date: .omitted, time: .shortened))](notch-source://\(id.uuidString))"
    }
}

private func memoryAnswerText(_ text: String, sources: [MemorySearchResult]) -> AttributedString {
    linkedAnswerText(text, pattern: #"\[([0-9]+)\]"#) { reference in
        guard let index = Int(reference), index > 0, index <= sources.count else { return nil }
        return "[\(index)](notch-memory-source://\(index))"
    }
}

private func linkedAnswerText(_ text: String, pattern: String, replacement: (String) -> String?) -> AttributedString {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return AttributedString(text) }
    var markdown = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let reference = Range(match.range(at: 1), in: text), let value = replacement(String(text[reference])),
              let range = Range(match.range, in: markdown) else { continue }
        markdown.replaceSubrange(range, with: value)
    }
    return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

/// Explicit Stop opens the review page; sleep and application shutdown call the model directly.
@MainActor
func finishListeningSession(_ model: MeetingModel) async {
    let sessionID = model.activeSessionID
    await model.stop()
    guard !model.isStopping else { return }
    model.highlightedTranscriptID = nil
    if let sessionID, model.sessions.contains(where: { $0.id == sessionID }) {
        model.openMain(.sessions, sessionID: sessionID)
    }
}
