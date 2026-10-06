import SwiftUI
import AppKit
import NotchCore

@MainActor
struct CompanionWindow: View {
    @ObservedObject var model: MeetingModel

    var body: some View {
        VStack(spacing: 0) {
            commandHeader
            CompanionHairline()
            if let error = model.error { errorBanner(error) }
            destination
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            statusBar
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(CompanionPalette.canvas)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .tint(.white)
        .sheet(item: $model.configuringProvider) { provider in
            ProviderConfigurationView(model: model, provider: provider)
                .preferredColorScheme(.dark)
        }
    }

    private var commandHeader: some View {
        HStack(spacing: 22) {
            Button { model.openMain(.home) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 17, weight: .medium))
                    Text("Notch").font(.system(size: 15, weight: .semibold)).tracking(-0.4)
                }
            }
            .buttonStyle(.plain).padding(.trailing, 10)
            HStack(spacing: 3) {
                navItem(.home, title: "Home", key: "1")
                navItem(.sessions, title: "Sessions", key: "2")
                navItem(.notes, title: "Notes", key: "3")
            }
            Spacer(minLength: 12)
            Button { model.openMain(.search) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                    Text("Search").font(.system(size: 11))
                    ShortcutKeycap(text: "⌘K")
                }
                .foregroundStyle(model.destination == .search ? .white : .white.opacity(0.45))
            }
            .buttonStyle(.plain).keyboardShortcut("k", modifiers: .command)
            Button { model.openMain(.settings) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                    .foregroundStyle(model.destination == .settings ? .white : .white.opacity(0.45))
                    .frame(width: 26, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
            .help("Settings").accessibilityLabel("Settings")
        }
        .padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 17)
    }

    private func navItem(_ destination: CompanionDestination, title: String, key: KeyEquivalent) -> some View {
        Button {
            if destination == .sessions { model.selectedSessionID = nil; model.highlightedTranscriptID = nil }
            model.openMain(destination)
        } label: {
            Text(title).font(.system(size: 11.5, weight: model.destination == destination ? .medium : .regular))
                .foregroundStyle(model.destination == destination ? .white.opacity(0.95) : .white.opacity(0.43))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(model.destination == destination ? Color.white.opacity(0.075) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(model.destination == destination ? .isSelected : [])
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.white.opacity(model.isListening ? 0.85 : 0.28)).frame(width: 4, height: 4)
            Text(model.isStopping ? "Saving the last words…" : (model.isStarting ? "Preparing to listen…" : (model.isListening ? "Listening · \(model.elapsedLabel)" : "Ready")))
                .font(.system(size: 10, weight: .medium))
            if model.isListening || model.isStarting || model.isStopping {
                Button("Open session") { model.openMain(.sessions, sessionID: model.activeSessionID) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 8)
                Spacer()
                if model.isStopping {
                    Button("Finish now") { model.cancelFinishing() }
                        .buttonStyle(.plain).font(.system(size: 10))
                        .help("Save received transcript and cancel pending transcription")
                } else {
                    Button { Task { await finishListeningSession(model) } } label: {
                        Label(model.isStarting ? "Cancel" : "Stop", systemImage: "stop.fill").font(.system(size: 10))
                    }.buttonStyle(.plain)
                }
            } else {
                Spacer()
                ShortcutKeycap(text: "⌘⇧L")
                Text("Start listening").font(.system(size: 10))
            }
        }
        .foregroundStyle(Color.white.opacity(0.38))
        .padding(.horizontal, 28).padding(.vertical, 10)
        .overlay(alignment: .top) { CompanionHairline() }
    }

    @ViewBuilder private var destination: some View {
        switch model.destination {
        case .home: CompanionHomeView(model: model)
        case .sessions:
            if let id = model.selectedSessionID, model.sessions.contains(where: { $0.id == id }) {
                SessionDetailView(model: model, sessionID: id).id(id)
            } else { SessionLibraryView(model: model) }
        case .notes: CompanionNotesView(model: model)
        case .search: CompanionSearchView(model: model)
        case .settings: ProviderSettingsView(model: model)
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
                }.buttonStyle(.plain).fontWeight(.medium)
            }
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss error")
        }
        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 28).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.surface)
    }
}

@MainActor
private struct CompanionHomeView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recent: [ListeningSession] { Array(model.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(2)) }
    private var busy: Bool { model.isListening || model.isStarting || model.isStopping }
    private var reviewSession: ListeningSession? {
        model.sessions.sorted { $0.startedAt > $1.startedAt }.first {
            $0.endedAt != nil && (!$0.moments.isEmpty || !$0.notes.isEmpty)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Eyebrow(text: "Your listening companion")
                    Spacer()
                    Text(Date.now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }
                .padding(.bottom, 23)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(busy ? "Listening, quietly." : "Stay in the moment.")
                            .font(.system(size: 30, weight: .semibold)).tracking(-1)
                        Text(busy ? "Your transcript and important moments are being saved." : "Let Notch keep the details.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.43))
                    }
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 39, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(busy ? 0.8 : 0.2))
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: model.isListening && !reduceMotion)
                        .frame(width: 64)
                }
                .padding(.bottom, 27)

                listeningSurface

                Button { model.openMain(.search) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        Text("Ask your memory").font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                        Spacer()
                        Text("Find a thought, a question, a moment").font(.system(size: 10)).foregroundStyle(.white.opacity(0.26))
                        ShortcutKeycap(text: "⌘K")
                    }
                    .padding(.vertical, 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { CompanionHairline() }

                HStack(spacing: 8) {
                    Text("Recent sessions").font(.system(size: 12, weight: .medium))
                    if !model.sessions.isEmpty {
                        Text("\(model.sessions.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                    }
                    Spacer()
                    if !recent.isEmpty {
                        Button {
                            model.selectedSessionID = nil
                            model.openMain(.sessions)
                        } label: { Label("View all", systemImage: "arrow.up.right").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.top, 25).padding(.bottom, 8)

                if recent.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform.path").font(.system(size: 22, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.18)).frame(width: 36)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A fresh start.").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                            Text("Your conversations will find a home here.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(recent) { session in
                            SessionListRow(session: session, isActive: model.activeSessionID == session.id && busy) {
                                model.openMain(.sessions, sessionID: session.id)
                            }
                        }
                    }
                }

                if let session = reviewSession {
                    Button { model.openMain(.sessions, sessionID: session.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                            Text("Continue reviewing").font(.system(size: 10))
                            Text(session.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.right").font(.system(size: 10))
                        }
                        .foregroundStyle(.white.opacity(0.45)).padding(.vertical, 15).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
            }
            .padding(.horizontal, 40).padding(.top, 30).padding(.bottom, 24)
            .frame(maxWidth: 830, alignment: .leading).frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var listeningSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.white.opacity(busy ? 0.85 : 0.4)).frame(width: 5, height: 5)
                Text(model.isStopping ? "Finishing your session" : (model.isStarting ? "Preparing to listen" : (model.isListening ? model.contextLabel : "Ready to listen")))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                Spacer()
                if busy {
                    Text(model.elapsedLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.38))
                } else {
                    Text("Lecture · Conversation · Anything").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
            CompanionHairline().padding(.horizontal, 20)
            HStack(spacing: 19) {
                Button {
                    Task {
                        if busy { await finishListeningSession(model) }
                        else { await model.start() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: busy ? "stop.fill" : "waveform").font(.system(size: busy ? 9 : 13, weight: .medium))
                        Text(model.isStopping ? "Saving…" : (model.isStarting ? "Cancel Starting" : (model.isListening ? "Stop Listening" : "Start Listening")))
                        if !busy { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).padding(.leading, 12) }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(CompanionPrimaryButtonStyle()).disabled(model.isStopping)
                VStack(alignment: .leading, spacing: 4) {
                    if model.isStopping {
                        Button("Finish now") { model.cancelFinishing() }
                            .buttonStyle(.plain).font(.system(size: 11))
                            .help("Save received transcript and cancel pending transcription")
                    } else if let id = model.activeSessionID, busy {
                        Button("Open live transcript") { model.openMain(.sessions, sessionID: id) }
                            .buttonStyle(.plain).font(.system(size: 11))
                    } else {
                        Text("Every kind of conversation.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    }
                    Text(audioLabel).font(.system(size: 10)).foregroundStyle(.white.opacity(0.44)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !busy { ShortcutKeycap(text: "⌘⇧L") }
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
        }
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(CompanionPalette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 8)
    }

    private var audioLabel: String {
        let inputs = [model.settings.includeMicrophone ? "Microphone" : nil,
                      model.settings.captureSystemAudio ? "System audio" : nil].compactMap { $0 }.joined(separator: " + ")
        let provider = model.settings.transcription.provider == .auto ? "Apple Speech" : model.settings.transcription.provider.displayName
        return inputs.isEmpty ? "Choose an audio input in Settings" : "\(inputs) · \(provider)"
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
                CompanionPageHeader(eyebrow: "Your memory", title: "Sessions", subtitle: "The conversations you can come back to.")
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a session", text: $filter).textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear session filter")
                    }
                }
                .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 11)
                .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CompanionPalette.hairline, lineWidth: 0.5))
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
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 30)
        }
    }
}

private struct SessionListRow: View {
    let session: ListeningSession
    let isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: sessionSymbol(session.kind))
                    .font(.system(size: 15, weight: .light)).frame(width: 27)
                    .foregroundStyle(.white.opacity(0.35))
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.86)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(isActive ? "Listening now" : sessionKindLabel(session.kind))
                        Text("·")
                        Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.34))
                }
                Spacer()
                if isActive {
                    Image(systemName: "waveform").font(.system(size: 13))
                } else {
                    Text(sessionDuration(session)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).padding(.leading, 9)
                }
            }
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { CompanionHairline() }
    }
}

@MainActor
private struct SessionDetailView: View {
    @ObservedObject var model: MeetingModel
    let sessionID: UUID
    @State private var tab: DetailTab = .summary
    @State private var noteDraft: TranscriptNoteDraft?

    private enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary", transcript = "Transcript", moments = "Moments"
        var id: String { rawValue }
    }
    private var session: ListeningSession? { model.sessions.first { $0.id == sessionID } }
    private var isLive: Bool { model.activeSessionID == sessionID && (model.isListening || model.isStarting || model.isStopping) }
    private var lines: [TranscriptLine] { session?.transcript ?? (isLive ? model.transcript.lines : []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                header(session).padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 21)
                HStack(spacing: 23) {
                    ForEach(DetailTab.allCases) { item in
                        Button { tab = item } label: {
                            HStack(spacing: 5) {
                                Text(item.rawValue)
                                if item == .moments && !session.moments.isEmpty {
                                    Text("\(session.moments.count)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.28))
                                }
                            }
                            .font(.system(size: 11, weight: item == tab ? .medium : .regular))
                            .foregroundStyle(.white.opacity(item == tab ? 0.94 : 0.4))
                            .padding(.bottom, 12).contentShape(Rectangle())
                            .overlay(alignment: .bottom) { if item == tab { Color.white.opacity(0.85).frame(height: 1.5) } }
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(item == tab ? .isSelected : [])
                    }
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
                .padding(.horizontal, 32)
                .overlay(alignment: .bottom) { CompanionHairline() }
                .padding(.bottom, 17)
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
        VStack(alignment: .leading, spacing: 15) {
            Button {
                model.selectedSessionID = nil
                model.highlightedTranscriptID = nil
            } label: {
                Label("All sessions", systemImage: "chevron.left").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(session.title).font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 7) {
                        Text(sessionKindLabel(session.kind))
                        Text("·")
                        Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        if !isLive { Text("·"); Text(sessionDuration(session)) }
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
                if isLive {
                    Button { Task { await finishListeningSession(model) } } label: {
                        Label(model.isStopping ? "Saving…" : "Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(CompanionSecondaryButtonStyle()).disabled(model.isStopping)
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
                        Text(summary.overview).font(.system(size: 14)).lineSpacing(6).foregroundStyle(.white.opacity(0.84)).textSelection(.enabled)
                        SummarySources(ids: summary.overviewSourceTranscriptIDs, lines: lines, onSelect: showSource)
                        if summary.usedFallback {
                            Label("Organized from transcript highlights", systemImage: "text.alignleft")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(summary.sections.filter { !$0.content.isEmpty }) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title).font(.system(size: 14, weight: .semibold)).tracking(-0.15)
                            ForEach(Array(section.content.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 10) {
                                    if section.content.count > 1 {
                                        Circle().fill(Color.primary.opacity(0.4)).frame(width: 3, height: 3).padding(.top, 9)
                                    }
                                    Text(item).font(.system(size: 13)).lineSpacing(5).foregroundStyle(.white.opacity(0.72))
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
            .padding(.horizontal, 32).padding(.top, 4).padding(.bottom, 30)
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
            .padding(.horizontal, 32).padding(.top, 6).padding(.bottom, 30)
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
            HStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
                TextField("Ask about this session…", text: $model.question)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { if !model.isAnswering { model.requestAnswer() } }
                    .accessibilityLabel("Ask about this session")
                ShortcutKeycap(text: "⌘↵")
                Button {
                    if model.isAnswering { model.cancelAnswer() }
                    else { model.requestAnswer() }
                } label: {
                    Image(systemName: model.isAnswering ? "stop.fill" : "arrow.up")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .background(.white.opacity(model.canAnswer || model.isAnswering ? 0.95 : 0.24), in: Circle())
                }
                .buttonStyle(.plain).disabled(!model.isAnswering && !model.canAnswer)
                .accessibilityLabel(model.isAnswering ? "Cancel answer" : "Ask question")
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(CompanionPalette.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
            if !model.intelligenceStatus.isEmpty {
                Text(model.intelligenceStatus).font(.system(size: 9)).foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1).textSelection(.enabled).help(model.intelligenceStatus)
            }
        }
        .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 16)
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
                .padding(.horizontal, 32).padding(.bottom, 10)
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
                    .padding(.horizontal, 20).padding(.bottom, 24)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text(line.source).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                Text(line.time, format: .dateTime.hour().minute())
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                if bookmarked {
                    Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).help("Bookmarked")
                }
                Spacer(minLength: 8)
                Menu { passageActions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 23, height: 18)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .opacity(hovered || highlighted ? 0.85 : 0.3)
                .help("Passage actions").accessibilityLabel("Actions for this transcript passage")
            }
            Text(line.text).font(.system(size: 14)).lineSpacing(5)
                .foregroundStyle(.white.opacity(categories.contains(.question) ? 0.95 : 0.76))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if !categories.isEmpty {
                HStack(spacing: 11) {
                    ForEach(Array(categories.prefix(3)), id: \.rawValue) { category in
                        MomentBadge(category: category)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 13)
        .background(highlighted ? Color.white.opacity(0.065) : (hovered ? Color.white.opacity(0.025) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if highlighted { Color.white.opacity(0.5).frame(width: 1.5).padding(.vertical, 13) }
        }
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
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4))
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
            .menuStyle(.borderlessButton).controlSize(.mini).fixedSize().foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct CompanionNotesView: View {
    @ObservedObject var model: MeetingModel
    @State private var sessionID: UUID?
    @State private var creating = false
    @State private var filter: NoteFilter = .all
    @FocusState private var noteFocused: Bool

    private enum NoteFilter: String, CaseIterable, Identifiable {
        case all = "All", notes = "Notes", bookmarks = "Bookmarks"
        var id: String { rawValue }
    }
    private struct NoteItem: Identifiable {
        let session: ListeningSession
        let note: SessionNote
        var id: UUID { note.id }
    }
    private var notes: [NoteItem] {
        model.sessions.flatMap { session in session.notes.map { NoteItem(session: session, note: $0) } }
            .filter { filter == .all || (filter == .bookmarks ? $0.note.isBookmark : !$0.note.isBookmark) }
            .sorted { $0.note.time > $1.note.time }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    CompanionPageHeader(eyebrow: "Keep it close", title: "Notes", subtitle: "Thoughts and passages worth keeping.")
                    Spacer()
                    Button { creating = true; noteFocused = true } label: {
                        Label("New note", systemImage: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(CompanionPrimaryButtonStyle()).keyboardShortcut("n", modifiers: .command)
                }
                HStack(spacing: 21) {
                    ForEach(NoteFilter.allCases) { item in
                        Button { filter = item } label: {
                            Text(item.rawValue).font(.system(size: 11, weight: filter == item ? .medium : .regular))
                                .foregroundStyle(.white.opacity(filter == item ? 0.94 : 0.4))
                                .padding(.bottom, 11).contentShape(Rectangle())
                                .overlay(alignment: .bottom) { if filter == item { Color.white.opacity(0.8).frame(height: 1.5) } }
                        }.buttonStyle(.plain).accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                    Spacer()
                    Text("\(notes.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3)).padding(.bottom, 11)
                }
                .overlay(alignment: .bottom) { CompanionHairline() }
                if creating { noteComposer }
                if notes.isEmpty {
                    EmptyCompanionState(symbol: "bookmark", title: filter == .bookmarks ? "Keep a moment close." : "A space for your thoughts.",
                                        message: filter == .bookmarks ? "Bookmark a passage in a transcript and find it here, with its original context." : "Write something down, save an answer, or keep a passage from a conversation.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notes) { item in noteRow(item) }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 30)
        }
        .onAppear { if !model.noteDraft.isEmpty { creating = true } }
    }

    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $model.noteDraft)
                .font(.system(size: 13)).scrollContentBackground(.hidden).focused($noteFocused)
                .padding(.horizontal, 7).padding(.top, 9).frame(height: 105)
                .overlay(alignment: .topLeading) {
                    if model.noteDraft.isEmpty {
                        Text("A thought worth keeping…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.3))
                            .padding(.horizontal, 12).padding(.top, 17).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("New note")
            HStack(spacing: 12) {
                if !model.sessions.isEmpty {
                    Picker("Attach to", selection: $sessionID) {
                        Text("Current or most recent session").tag(Optional<UUID>.none)
                        ForEach(model.sessions.sorted { $0.startedAt > $1.startedAt }) {
                            Text($0.title).tag(Optional($0.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 290).controlSize(.small)
                    .accessibilityLabel("Session for new note")
                }
                Spacer()
                Button("Close") { creating = false; noteFocused = false }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Save note") {
                    model.saveNote(model.noteDraft, sessionID: sessionID)
                    model.noteDraft = ""
                    creating = false
                }
                .buttonStyle(CompanionPrimaryButtonStyle())
                .disabled(model.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14).padding(.bottom, 13)
        }
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CompanionPalette.hairline, lineWidth: 0.5))
    }

    private func noteRow(_ item: NoteItem) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: item.note.isBookmark ? "bookmark" : "text.alignleft")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.32)).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Text(item.note.isBookmark ? "Bookmark" : "Note")
                    Text("·")
                    Text(item.note.time, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Spacer()
                }
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.34))
                Text(item.note.text).font(.system(size: 13)).lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                Button {
                    model.highlightedTranscriptID = item.note.transcriptID
                    model.openMain(.sessions, sessionID: item.session.id)
                } label: {
                    HStack(spacing: 5) {
                        Text(item.session.title).lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                    }.font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.44))
            }
        }
        .padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { CompanionHairline() }
    }
}

@MainActor
private struct CompanionSearchView: View {
    @ObservedObject var model: MeetingModel
    @State private var mode: MemoryMode = .ask
    @FocusState private var searchFocused: Bool

    private enum MemoryMode: String, CaseIterable, Identifiable {
        case ask = "Ask", search = "Search"
        var id: String { rawValue }
    }
    private var query: Binding<String> {
        Binding(get: { mode == .ask ? model.memoryQuestion : model.searchQuery },
                set: { if mode == .ask { model.memoryQuestion = $0 } else { model.searchQuery = $0 } })
    }
    private var canSubmit: Bool {
        !query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(mode == .ask && model.memoryIsAnswering)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                CompanionPageHeader(eyebrow: "Bring it back", title: "Ask your memory",
                                    subtitle: "A thought, a question, something you almost remember.")
                composer
                if mode == .ask {
                    if model.memoryAnswer.isEmpty && !model.memoryIsAnswering { prompts }
                    if model.memoryIsAnswering {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("Looking through your sessions…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    if !model.memoryAnswer.isEmpty { memoryAnswer }
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 30)
        }
        .onAppear {
            if model.memoryQuestion.isEmpty && !model.searchQuery.isEmpty { mode = .search }
            searchFocused = true
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                ForEach(MemoryMode.allCases) { item in
                    Button { mode = item; searchFocused = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item == .ask ? "text.bubble" : "magnifyingglass").font(.system(size: 10))
                            Text(item.rawValue).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(mode == item ? 0.94 : 0.4))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(mode == item ? CompanionPalette.raised : .clear, in: Capsule())
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(mode == item ? .isSelected : [])
                }
                Spacer()
                Text("All sessions").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 12).padding(.top, 11)
            HStack(alignment: .bottom, spacing: 12) {
                TextField(mode == .ask ? "What would you like to remember?" : "Search transcripts, questions, notes…",
                          text: query, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...3).focused($searchFocused)
                    .onSubmit { submit() }.padding(.vertical, 6)
                    .accessibilityLabel(mode == .ask ? "Ask your memory" : "Search saved sessions")
                if !query.wrappedValue.isEmpty && !(mode == .ask && model.memoryIsAnswering) {
                    Button { query.wrappedValue = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                            .frame(width: 20, height: 30)
                    }.buttonStyle(.plain).accessibilityLabel("Clear query")
                }
                Button { submit() } label: {
                    Group {
                        if mode == .ask && model.memoryIsAnswering {
                            ProgressView().controlSize(.mini).tint(.black)
                        } else {
                            Image(systemName: mode == .ask ? "arrow.up" : "arrow.right").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Color.black.opacity(0.85)).frame(width: 32, height: 32)
                    .background(.white.opacity(canSubmit ? 0.95 : 0.25), in: Circle())
                }
                .buttonStyle(.plain).disabled(!canSubmit)
                .accessibilityLabel(mode == .ask ? "Ask your memory" : "Search")
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 17)
            CompanionHairline().padding(.horizontal, 16)
            HStack(spacing: 5) {
                Image(systemName: "text.quote").font(.system(size: 9))
                Text(mode == .ask ? "Answers stay connected to their sources." : "Transcripts, notes, questions, and saved moments.")
                    .font(.system(size: 10))
                Spacer()
                ShortcutKeycap(text: "⌘↵")
            }
            .foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 18).padding(.vertical, 11)
        }
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CompanionPalette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
    }

    private var prompts: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: model.sessions.isEmpty ? "Your memory starts with a conversation" : "A few things you can ask").padding(.bottom, 12)
            memoryPrompt("What assignments are due?", symbol: "calendar")
            memoryPrompt("What should I review this week?", symbol: "book")
            memoryPrompt("What questions came up in my last session?", symbol: "questionmark.bubble")
        }
        .padding(.top, 7)
    }

    private func memoryPrompt(_ text: String, symbol: String) -> some View {
        Button { model.memoryQuestion = text; submit() } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 20).foregroundStyle(.white.opacity(0.3))
                Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.56))
                Spacer()
                Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(.white.opacity(0.25))
            }
            .padding(.vertical, 13).contentShape(Rectangle())
        }.buttonStyle(.plain).overlay(alignment: .bottom) { CompanionHairline() }
    }

    private var memoryAnswer: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Eyebrow(text: "From your sessions")
                Spacer()
                Button { model.copyText(model.memoryAnswer) } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
            }
            Text(memoryAnswerText(model.memoryAnswer, sources: model.memorySources))
                .font(.system(size: 14)).lineSpacing(6).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "notch-memory-source", let host = url.host, let number = Int(host),
                          number > 0, number <= model.memorySources.count else { return .discarded }
                    model.selectSearchResult(model.memorySources[number - 1])
                    return .handled
                })
            if !model.memorySources.isEmpty {
                CompanionHairline().padding(.top, 6)
                Eyebrow(text: "Sources")
                VStack(spacing: 14) {
                    ForEach(Array(model.memorySources.enumerated()), id: \.element.id) { index, source in
                        Button { model.selectSearchResult(source) } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Text("\(index + 1)").font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.52)).frame(width: 20, height: 20)
                                    .background(CompanionPalette.raised, in: RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.sessionTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                                    Text(source.excerpt).font(.system(size: 11)).foregroundStyle(.white.opacity(0.36)).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 5)
    }

    @ViewBuilder private var searchResults: some View {
        HStack {
            Text(model.searchQuery.isEmpty ? "Search your saved conversations" : "\(model.searchResults.count) matching passages")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            if !model.searchQuery.isEmpty {
                Text(model.searchUsesSemantic ? "Semantic + text" : "Text search").font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            }
        }
        if model.searchResults.isEmpty {
            EmptyCompanionState(symbol: "magnifyingglass", title: model.searchQuery.isEmpty ? "Find your way back." : "No matching passages.",
                                message: model.searchQuery.isEmpty ? "Search for a topic, an assignment, or a few words you remember." : "Try another topic or a few different words.")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.searchResults) { result in
                    Button { model.selectSearchResult(result) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 7) {
                                Text(result.sessionTitle).fontWeight(.medium).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                                Text("·")
                                Text(result.kind)
                                Spacer()
                                Text(result.time, format: .dateTime.month(.abbreviated).day())
                                Image(systemName: "arrow.up.right").font(.system(size: 9)).padding(.leading, 5)
                            }
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                            Text(result.excerpt).font(.system(size: 13)).lineSpacing(5).lineLimit(4)
                                .foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).overlay(alignment: .bottom) { CompanionHairline() }
                }
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        if mode == .ask { Task { await model.askMemory() } }
        else { model.searchMemory() }
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
