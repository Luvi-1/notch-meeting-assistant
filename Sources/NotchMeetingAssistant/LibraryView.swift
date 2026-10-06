import SwiftUI
import NotchCore

@MainActor
struct LibraryView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.colorScheme) private var colorScheme
    private var navigationInk: Color { colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.8) }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 21, weight: .medium))
                    Text("Notch").font(.system(size: 23, weight: .semibold))
                }.padding(.horizontal, 18).padding(.top, 24)
                List(selection: Binding<MeetingModel.Destination?>(get: { model.destination }, set: { if let value = $0 { model.destination = value } })) {
                    ForEach(MeetingModel.Destination.allCases.filter { $0 != .settings }) { destination in
                        navigationRow(destination).tag(destination)
                    }
                    Section { navigationRow(.settings).tag(MeetingModel.Destination.settings) }
                }.listStyle(.sidebar)
                if model.busyListening {
                    Button { model.showCurrentSession() } label: {
                        HStack(spacing: 9) {
                            WaveformMark(level: model.audioLevel, active: model.isListening && !model.isSpeaking)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.status).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(model.elapsed).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(15)
                    }.buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 225)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).textSelection(.enabled)
                            HStack(spacing: 14) {
                                if model.needsRecordingPermission { Button("Open Privacy Settings") { model.openRecordingSettings() } }
                                if model.intelligencePaused { Button("Resume AI assistance") { model.resumeIntelligence() } }
                            }.buttonStyle(.link)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss issue")
                    }
                    .font(.system(size: 12)).padding(16).background(Color.primary.opacity(0.045))
                }
                Group {
                    switch model.destination {
                    case .home: home
                    case .sessions: sessions
                    case .notes: notes
                    case .search: search
                    case .settings: ProviderSettingsView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.destination == .home ? "" : model.destination.rawValue)
            .toolbar {
                if model.busyListening {
                    ToolbarItem(placement: .primaryAction) {
                        Button(model.isStopping ? "Finishing…" : "Stop Listening", systemImage: "stop.fill") { Task { await model.stop() } }
                            .disabled(model.isStopping)
                    }
                }
            }
        }
        .tint(.primary)
        .frame(minWidth: 780, minHeight: 540)
    }
    private func navigationRow(_ destination: MeetingModel.Destination) -> some View {
        HStack(spacing: 9) {
            Image(systemName: destination.symbol).frame(width: 17).foregroundStyle(navigationInk)
            Text(destination.rawValue).foregroundStyle(navigationInk)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13)).padding(.vertical, 7).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
                    Text(model.isListening ? "Stay in the conversation." : "Make room to listen.")
                        .font(.system(size: 34, weight: .semibold)).tracking(-1.1)
                    Text("A lecture. A conversation. A thought worth keeping.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }.padding(.top, 22)
                VStack(alignment: .leading, spacing: 14) {
                    if model.busyListening {
                        HStack(spacing: 18) {
                            WaveformMark(level: model.audioLevel, active: model.isListening && !model.isSpeaking).scaleEffect(1.5).frame(width: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.status).font(.system(size: 20, weight: .medium))
                                Text(model.elapsed).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open live transcript") { model.showCurrentSession() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }.padding(.vertical, 12)
                    } else {
                        Button { Task { await model.start() } } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "waveform").font(.system(size: 17))
                                Text(model.isLoadingSessions ? "Opening library…" : "Start Listening").font(.system(size: 16, weight: .medium))
                                Image(systemName: "arrow.up.right").font(.system(size: 13))
                            }
                            .padding(.horizontal, 27).padding(.vertical, 19)
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .background(Color.primary, in: Capsule())
                        }
                        .buttonStyle(.plain).disabled(!model.hasConsent || model.isLoadingSessions)
                        .opacity(model.hasConsent && !model.isLoadingSessions ? 1 : 0.55)
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        Toggle("I have permission from the people being transcribed.", isOn: $model.hasConsent)
                            .toggleStyle(.checkbox).font(.system(size: 11))
                    }
                    Text(model.dataFlowLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(model.aiDataFlowLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if model.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your attention stays here.").font(.system(size: 16, weight: .medium))
                        Text("Listening settles into the notch. Questions surface briefly. Your notes and the full session are here when you return.")
                            .font(.system(size: 13)).lineSpacing(5).foregroundStyle(.secondary).frame(maxWidth: 440, alignment: .leading)
                        Button("Set up AI providers", systemImage: "arrow.right") { model.destination = .settings }
                            .buttonStyle(.link).font(.system(size: 12)).padding(.top, 4)
                    }.padding(.top, 20)
                } else {
                    VStack(alignment: .leading, spacing: 15) {
                        sectionHeader("Recent sessions", action: "View all") { model.destination = .sessions }
                        ForEach(model.sessions.prefix(5)) { session in sessionRow(session) }
                    }
                    if let review = model.sessions.first(where: { $0.endedAt != nil && ($0.summary != nil || !$0.notes.isEmpty) }) {
                        Button { model.viewSession(review.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("CONTINUE REVIEWING").font(.system(size: 9, weight: .medium)).tracking(1.3).foregroundStyle(.secondary)
                                    Text(review.title).font(.system(size: 16, weight: .medium))
                                }
                                Spacer(); Image(systemName: "arrow.up.right")
                            }.padding(.vertical, 18)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.horizontal, 42).padding(.bottom, 35).frame(maxWidth: 830, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private var sessions: some View {
        Group {
            if let session = model.selectedSession {
                SessionDetailView(model: model, session: session).id(session.id)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text("Everything worth returning to.").font(.system(size: 27, weight: .semibold)).tracking(-0.7).padding(.vertical, 14)
                        if model.sessions.isEmpty { emptyState("Your first session starts here.", detail: "Start listening from Home. Transcripts, questions and summaries will be saved together.") }
                        ForEach(model.sessions) { session in sessionRow(session) }
                    }.padding(32)
                }
            }
        }
    }
    private var notes: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 23) {
                Text("Keep the useful parts.").font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                let marked = model.sessions.filter { !$0.notes.isEmpty || $0.segments.contains(where: \.bookmarked) || $0.questions.contains(where: \.saved) }
                if marked.isEmpty { emptyState("Nothing bookmarked yet.", detail: "Save a question from the notch, or bookmark a transcript passage and add your own note.") }
                ForEach(marked) { session in
                    VStack(alignment: .leading, spacing: 15) {
                        Button(session.title) { model.viewSession(session.id) }.font(.system(size: 13, weight: .semibold)).buttonStyle(.plain)
                        ForEach(session.notes) { note in
                            Button { model.viewSession(session.id, segmentID: note.segmentID) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(note.text).font(.system(size: 13)).lineSpacing(4).lineLimit(8)
                                    Text(note.time.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).contextMenu { Button("Copy note") { model.copy(note.text) } }
                        }
                        ForEach(session.segments.filter(\.bookmarked)) { segment in
                            Button { model.viewSession(session.id, segmentID: segment.id) } label: {
                                Label(segment.text, systemImage: "bookmark.fill").font(.system(size: 13)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                    Divider().opacity(0.5)
                }
            }.padding(36).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private var search: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask your memory.").font(.system(size: 31, weight: .semibold)).tracking(-0.8)
                    Text("Find a moment, connect your notes, or return to an explanation.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("What did we discuss about…", text: $model.searchQuery).textFieldStyle(.plain)
                        .onSubmit { model.askMemory() }.accessibilityLabel("Ask across saved sessions")
                    if model.isSearching || model.isAskingMemory { ProgressView().controlSize(.small) }
                    Button("Find") { model.search() }.disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Ask", systemImage: "arrow.up") { model.askMemory() }
                        .disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isAskingMemory)
                }.padding(14).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                Text(model.semanticSearchAvailable ? "Search combines on-device semantic matching, where available for the query language, with exact words. Ask uses your selected AI provider and links back to the evidence." : "On-device semantic embeddings are unavailable for this Mac's current model resources. Exact-word search works; Ask uses the retrieved excerpts.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if !model.memoryAnswer.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(.init(model.memoryAnswer)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        ForEach(Array(model.memorySources.enumerated()), id: \.element.id) { entry in
                            Button { model.viewSession(entry.element.sessionID, segmentID: entry.element.segmentID) } label: {
                                Text("[\(entry.offset + 1)] \(entry.element.sessionTitle) · \(entry.element.time.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    Divider().opacity(0.4)
                }
                if model.searchResults.isEmpty && !model.searchQuery.isEmpty && !model.isSearching && model.memoryAnswer.isEmpty {
                    Text("Search your saved sessions by topic, phrase, course, or date.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.searchResults) { hit in
                        Button { model.viewSession(hit.sessionID, segmentID: hit.segmentID) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(hit.sessionTitle).font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Text(hit.time.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(hit.text).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).lineLimit(4)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(36).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func sessionRow(_ session: ListeningSession) -> some View {
        Button { model.viewSession(session.id) } label: {
            HStack(spacing: 16) {
                Image(systemName: session.kind == "Lecture" || session.kind == "Study Session" ? "book.closed" : "waveform")
                    .font(.system(size: 18, weight: .light)).foregroundStyle(.secondary).frame(width: 27)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                        Text(session.id == model.activeSessionID ? "Listening" : session.kind)
                        if session.recovered { Text("· Recovered") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.summarizing.contains(session.id) { ProgressView().controlSize(.small) }
                else { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func sectionHeader(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer(); Button(action, action: perform).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 17, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            Button("Go to Home") { model.destination = .home }.buttonStyle(.link).padding(.top, 5)
        }.padding(.vertical, 35)
    }
}

@MainActor
private struct SessionDetailView: View {
    @ObservedObject var model: MeetingModel
    let session: ListeningSession
    @State private var page = "Overview"
    @State private var note = ""
    @State private var confirmDelete = false
    @State private var rename = false
    @State private var title = ""
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { model.selectedSessionID = nil; model.selectedSegmentID = nil } label: { Label("All sessions", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Rename") { title = session.title; rename = true }
                        Button("Export Markdown") { model.exportSession(session.id) }
                        Button("Copy full transcript") { model.copy(session.markdown) }
                        Button("Generate summary") { model.generateSummary(session.id) }.disabled(model.summarizing.contains(session.id) || session.id == model.activeSessionID)
                        Divider()
                        Button("Delete session", role: .destructive) { confirmDelete = true }.disabled(session.id == model.activeSessionID)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Session actions")
                }
                Text(session.title).font(.system(size: 27, weight: .semibold)).tracking(-0.7).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·"); Text(session.id == model.activeSessionID ? "Listening · \(model.elapsed)" : session.kind)
                    if session.recovered { Text("· Recovered after an interrupted session") }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Session section", selection: $page) {
                    ForEach(["Overview", "Transcript", "Questions", "Notes"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            }.padding(.horizontal, 32).padding(.top, 23).padding(.bottom, 18)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 23) {
                        if page == "Overview" { overview }
                        if page == "Transcript" {
                            Text("Speaker names appear only when supplied by the provider or added by you. Audio source labels are not speaker identities.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            if session.segments.isEmpty { Text("Listening for speech…").foregroundStyle(.secondary) }
                            ForEach(session.segments) { segment in
                                TranscriptRow(model: model, sessionID: session.id, segment: segment).id(segment.id)
                            }
                        }
                        if page == "Questions" {
                            if session.questions.isEmpty { Text("Questions will appear here as they are detected.").foregroundStyle(.secondary) }
                            ForEach(session.questions) { question in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(question.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                        if question.saved { Image(systemName: "bookmark.fill").font(.system(size: 9)) }
                                        Spacer()
                                        Button("Go to source") { model.selectedSegmentID = question.segmentID; page = "Transcript" }.buttonStyle(.link).font(.system(size: 10))
                                    }
                                    Text(question.text).font(.system(size: 16, weight: .medium)).textSelection(.enabled)
                                    if !question.answer.isEmpty {
                                        Text("AI SUGGESTION").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                                        Text(.init(question.answer)).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                    } else {
                                        Button("Suggest an answer") { model.requestAnswer(text: question.text, sessionID: session.id, questionID: question.id) }
                                            .buttonStyle(.link).font(.system(size: 11))
                                    }
                                }.padding(.vertical, 7)
                            }
                        }
                        if page == "Notes" {
                            if session.notes.isEmpty { Text("Add a thought, or create a note from any transcript passage.").foregroundStyle(.secondary) }
                            ForEach(session.notes) { note in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(note.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(note.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                    if let id = note.segmentID { Button("Go to source") { model.selectedSegmentID = id; page = "Transcript" }.buttonStyle(.link).font(.system(size: 10)) }
                                }
                            }
                            HStack {
                                TextField("Add your own note…", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                                Button("Save") { model.addNote(note, sessionID: session.id); note = "" }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        if model.answerSessionID == session.id && (!model.answer.isEmpty || model.isAnswering) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(model.isAnswering ? "Answering…" : (model.answerComplete ? "AI answer" : "Partial AI answer")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    Spacer()
                                    if model.isAnswering { Button("Cancel") { model.cancelAnswer() }.buttonStyle(.link) }
                                    if model.isSpeaking { Button("Stop voice") { model.stopVoice() }.buttonStyle(.link) }
                                    else if model.answerComplete { Button("Read aloud") { model.readAnswer() }.buttonStyle(.link) }
                                    Button { model.copy(model.answer) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).accessibilityLabel("Copy AI answer")
                                }.font(.system(size: 10))
                                Text(.init(model.answer)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                            }.padding(.vertical, 16)
                        }
                        Color.clear.frame(height: 1).id("session-bottom")
                    }.padding(.horizontal, 34).padding(.vertical, 12)
                }
                .onChange(of: model.selectedSegmentID) { _, id in
                    guard let id else { return }; page = "Transcript"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: page) { _, value in
                    if value == "Transcript", let id = model.selectedSegmentID { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(id, anchor: .top) } }
                }
                .onAppear {
                    if let id = model.selectedSegmentID { page = "Transcript"; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(id, anchor: .top) } }
                    else if session.id == model.activeSessionID { page = "Transcript" }
                }
            }
            HStack(spacing: 12) {
                TextField("Ask about this session…", text: $model.question).textFieldStyle(.plain)
                    .onSubmit { model.requestAnswer(sessionID: session.id, task: .deepAnalysis) }
                Button { model.requestAnswer(sessionID: session.id, task: .deepAnalysis) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 25)) }
                    .buttonStyle(.plain).disabled(!model.canAnswer).accessibilityLabel("Ask about this session")
            }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15)).padding(22)
        }
        .confirmationDialog("Delete this session and its saved transcript, notes, and summary?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) { Task { await model.deleteSession(session.id) } }
        }
        .alert("Rename session", isPresented: $rename) {
            TextField("Title", text: $title)
            Button("Save") { model.renameSession(session.id, title: title) }
            Button("Cancel", role: .cancel) {}
        }
    }
    @ViewBuilder private var overview: some View {
        if model.summarizing.contains(session.id) {
            HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Organizing the session…").foregroundStyle(.secondary) }.padding(.vertical, 25)
        } else if let summary = session.summary {
            Text(summary.overview).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
            ForEach(summary.sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.title).font(.system(size: 16, weight: .semibold))
                    Text(.init(section.body)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    if !section.sources.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(Array(section.sources.prefix(4)), id: \.self) { id in
                                if let segment = session.segments.first(where: { $0.id == id }) {
                                    Button(segment.time.formatted(date: .omitted, time: .shortened)) { model.selectedSegmentID = id; page = "Transcript" }
                                        .buttonStyle(.link).font(.system(size: 10))
                                }
                            }
                        }
                    }
                }.padding(.vertical, 5)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(session.id == model.activeSessionID ? "The summary comes together when you finish listening." : "Your session is ready to review.")
                    .font(.system(size: 17, weight: .medium))
                if let issue = session.summaryError { Text(issue).font(.system(size: 12)).foregroundStyle(.secondary) }
                Text("The full transcript is available in the Transcript tab. Questions, bookmarks, and your own notes stay connected to it.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                if session.id != model.activeSessionID { Button("Generate structured summary") { model.generateSummary(session.id) }.buttonStyle(.bordered).buttonBorderShape(.capsule) }
                if !session.topic.isEmpty { Text("CURRENT TOPIC").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(.secondary); Text(session.topic).font(.system(size: 15)) }
            }.padding(.vertical, 17)
        }
    }
}

@MainActor
private struct TranscriptRow: View {
    @ObservedObject var model: MeetingModel
    let sessionID: UUID
    let segment: SessionSegment
    @State private var showNote = false
    @State private var note = ""
    @State private var showSpeaker = false
    @State private var speaker = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(segment.time.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                Text(segment.speakerLabel.uppercased()).tracking(0.6).lineLimit(1)
                Spacer()
                if segment.bookmarked { Image(systemName: "bookmark.fill").accessibilityLabel("Bookmarked") }
                Menu {
                    Button("Ask AI about this") { model.question = "About this passage: \(segment.text)\n\n" }
                    Button("Explain") { model.requestAnswer(text: "Explain this passage simply, using the session context: \(segment.text)", sessionID: sessionID, task: .deepAnalysis) }
                    Button("Summarize") { model.requestAnswer(text: "Summarize this passage in two sentences: \(segment.text)", sessionID: sessionID, task: .quickCommand) }
                    Button(segment.bookmarked ? "Remove bookmark" : "Bookmark") { model.bookmark(segment.id, sessionID: sessionID) }
                    Button("Copy") { model.copy(segment.text) }
                    Button("Create a note") { note = ""; showNote = true }
                    Button("Label this speaker") { speaker = segment.speaker ?? ""; showSpeaker = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18).accessibilityLabel("Passage actions")
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            if !segment.categories.isEmpty {
                Text(segment.categories.map(\.rawValue).joined(separator: " · "))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(segment.text).font(.system(size: 14, weight: segment.categories.contains(.question) ? .medium : .regular))
                .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if showNote {
                HStack {
                    TextField("Your note…", text: $note, axis: .vertical).textFieldStyle(.roundedBorder)
                    Button("Save") { model.addNote(note, sessionID: sessionID, segmentID: segment.id); showNote = false }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { showNote = false }
                }.font(.system(size: 11))
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, segment.id == model.selectedSegmentID ? 12 : 0)
        .overlay(alignment: .leading) { if segment.id == model.selectedSegmentID { Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 2) } }
        .contextMenu {
            Button("Explain this passage") { model.requestAnswer(text: "Explain: \(segment.text)", sessionID: sessionID, task: .deepAnalysis) }
            Button("Copy") { model.copy(segment.text) }
            Button(segment.bookmarked ? "Remove bookmark" : "Bookmark") { model.bookmark(segment.id, sessionID: sessionID) }
            Button("Create a note") { showNote = true }
        }
        .alert("Label this speaker", isPresented: $showSpeaker) {
            TextField("For example, Professor or Alex", text: $speaker)
            Button("Save") { model.labelSpeaker(segment.id, sessionID: sessionID, name: speaker) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This label applies to this passage. Audio source labels do not identify a person.") }
    }
}
