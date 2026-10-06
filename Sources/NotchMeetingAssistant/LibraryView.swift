import SwiftUI
import NotchCore

@MainActor
struct LibraryView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 21, weight: .medium))
                    Text("Notch").font(.system(size: 23, weight: .semibold))
                }.padding(.horizontal, 22).padding(.top, 38)
                VStack(spacing: 5) {
                    ForEach(LibrarySection.allCases.filter { $0 != .settings }) { section in navItem(section) }
                }.padding(.horizontal, 12)
                Spacer()
                if model.busyCapture {
                    Button { if let id = model.activeSessionID { model.openSession(id) } } label: {
                        Label(model.status, systemImage: "waveform.circle.fill").font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.buttonStyle(.plain).padding(.horizontal, 12)
                }
                navItem(.settings).padding(.horizontal, 12).padding(.bottom, 18)
            }.navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                        Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss message")
                    }.padding(16).background(Color.primary.opacity(0.045))
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.navigationSplitViewStyle(.balanced)
            .tint(.primary)
            .frame(minWidth: 840, minHeight: 580)
    }
    private func navItem(_ section: LibrarySection) -> some View {
        Button { model.section = section } label: {
            Label(section.rawValue, systemImage: section.symbol)
                .font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(model.section == section ? Color.primary.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var content: some View {
        switch model.section {
        case .home: home
        case .sessions: sessions
        case .notes: notes
        case .search: search
        case .settings: ProviderSettingsView(model: model)
        }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("YOUR LISTENING COMPANION").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Text("Make room for\nwhat matters.").font(.system(size: 42, weight: .semibold)).tracking(-1.4).lineSpacing(-3)
                    Text("Lectures, conversations, and the ideas in between.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Button { Task { if model.busyCapture { await model.stop() } else { await model.start() } } } label: {
                        Label(model.busyCapture ? "Stop & Review" : "Start Listening", systemImage: model.busyCapture ? "stop.fill" : "waveform")
                            .font(.system(size: 15, weight: .semibold)).padding(.horizontal, 27).padding(.vertical, 15)
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .background(Color.primary, in: Capsule())
                    }.buttonStyle(.plain).disabled(model.loadingLibrary || model.isStopping || (!model.busyCapture && !model.hasConsent))
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                    if !model.busyCapture {
                        Toggle("I have permission to transcribe everyone here.", isOn: $model.hasConsent).toggleStyle(.checkbox).font(.system(size: 11))
                        Text(model.audioDisclosure).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: 540, alignment: .leading)
                    } else { Text("Listening quietly in your notch.").font(.callout).foregroundStyle(.secondary) }
                }
                if let reviewing = model.sessions.filter({ $0.lastReviewedAt != nil }).max(by: { ($0.lastReviewedAt ?? .distantPast) < ($1.lastReviewedAt ?? .distantPast) }) {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Continue reviewing")
                        sessionRow(reviewing)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { sectionLabel("Recent sessions"); Spacer(); Button("View all") { model.section = .sessions }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary) }
                    if model.loadingLibrary { ProgressView().controlSize(.small) }
                    else if model.sessions.isEmpty { Text("Your first session starts here.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 12) }
                    else { ForEach(model.sessions.prefix(5)) { session in sessionRow(session); Divider().opacity(0.55) } }
                }
            }.padding(.horizontal, 50).padding(.vertical, 50).frame(maxWidth: 860, alignment: .leading)
        }
    }
    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
    private func sessionRow(_ session: SessionRecord) -> some View {
        Button { model.openSession(session.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: session.kind == .lecture ? "book.closed" : "waveform").font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 27)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text("\(session.kind.rawValue) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(session.moments.filter { $0.category == .question }.count) questions").font(.system(size: 10)).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var sessions: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sessions").font(.system(size: 25, weight: .semibold)).padding(.horizontal, 20).padding(.top, 30)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.sessions) { session in
                            Button { model.selectedSessionID = session.id; model.selectedSegmentID = nil } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    if session.id == model.activeSessionID { Text("Listening now").font(.system(size: 10, weight: .medium)) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(session.id == model.selectedSessionID ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10)
                }
            }.frame(width: 205)
            Divider()
            if let session = model.selectedSession {
                SessionDetailView(model: model, sessionID: session.id).id(session.id)
            } else { empty("A place for every idea.", detail: "Choose a session to review its questions, notes, and transcript.", symbol: "rectangle.stack") }
        }
    }
    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Notes & saved moments").font(.system(size: 28, weight: .semibold))
                ForEach(model.sessions) { session in
                    let saved = session.segments.filter { $0.bookmarked || !$0.note.isEmpty }
                    if !saved.isEmpty || !session.notes.isEmpty || !session.answers.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Button(session.title) { model.openSession(session.id) }.font(.system(size: 13, weight: .semibold)).buttonStyle(.plain)
                            ForEach(saved) { segment in
                                Button { model.openSession(session.id, segmentID: segment.id) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: segment.bookmarked ? "bookmark.fill" : "note.text").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(segment.text).font(.system(size: 13)).lineLimit(3)
                                            if !segment.note.isEmpty { Text(segment.note).font(.system(size: 12)).foregroundStyle(.secondary) }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            ForEach(session.notes) { Text($0.text).font(.system(size: 13)).textSelection(.enabled) }
                            ForEach(session.answers) { answer in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(answer.question).font(.system(size: 13, weight: .semibold))
                                    Text(answer.answer).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            Divider()
                        }
                    }
                }
                if !model.sessions.contains(where: { !$0.notes.isEmpty || !$0.answers.isEmpty || $0.segments.contains(where: { $0.bookmarked || !$0.note.isEmpty }) }) {
                    empty("Keep the useful parts.", detail: "Save a question or add a note to any transcript passage.", symbol: "bookmark")
                }
            }.padding(38).frame(maxWidth: 900, alignment: .leading)
        }
    }
    private var search: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Ask your memory").font(.system(size: 30, weight: .semibold))
            Text("A thought from last week. A deadline. Something worth finding again.").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("What did we discuss about elasticity?", text: $model.searchQuery).textFieldStyle(.plain).onSubmit { model.askMemory() }
                    .accessibilityLabel("Search saved sessions and ask your memory")
                if model.searching { ProgressView().controlSize(.small) }
                Button(model.askingMemory ? "Answering…" : "Ask") { model.askMemory() }.disabled(model.askingMemory || model.searchQuery.isEmpty)
            }.padding(14).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !model.memoryAnswer.isEmpty {
                        StructuredText(text: model.memoryAnswer)
                        if !model.memorySources.isEmpty {
                            Text("Answer sources").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(model.memorySources) { evidenceRow($0, citation: true) }
                        }
                        Divider().padding(.vertical, 6)
                    }
                    HStack {
                        Text("Results").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(model.semanticSearch ? "Semantic + text search" : "Text search").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    ForEach(model.searchResults) { evidenceRow($0, citation: false) }
                    if model.searchResults.isEmpty && !model.searching {
                        Text(model.searchQuery.isEmpty ? "Search transcripts, questions, summaries, assignments, and saved notes." : "No matching material found.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
        }.padding(38)
    }
    private func evidenceRow(_ evidence: MemoryEvidence, citation: Bool) -> some View {
        Button { model.follow(evidence) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(evidence.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(evidence.kind).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(evidence.text).font(.system(size: 13)).lineLimit(citation ? 2 : 4).frame(maxWidth: .infinity, alignment: .leading)
                Text(citation ? evidence.citation : evidence.time.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10, design: citation ? .monospaced : .default)).foregroundStyle(.secondary)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 18, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(35)
    }
}

@MainActor
private struct SessionDetailView: View {
    @ObservedObject var model: MeetingModel
    let sessionID: UUID
    @State private var tab = "Review"
    @State private var note = ""
    @State private var noteSegment: SessionSegment?
    @State private var deleting = false
    @State private var followLive = true
    private var record: SessionRecord? { model.sessions.first { $0.id == sessionID } }
    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        TextField("Session title", text: Binding(get: { self.record?.title ?? "" }, set: { model.renameSession(sessionID, title: $0) }))
                            .textFieldStyle(.plain).font(.system(size: 24, weight: .semibold))
                        Menu {
                            Button("Export Markdown…") { model.exportSession(sessionID) }
                            Button("Copy transcript") { model.copy(record.fullTranscript) }
                            Button("Generate summary") { model.generateSummary(sessionID) }
                            Divider()
                            Button("Delete session…", role: .destructive) { deleting = true }.disabled(sessionID == model.activeSessionID)
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 25)
                    }
                    Text("\(record.kind.rawValue) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Picker("Session view", selection: $tab) {
                    Text("Review").tag("Review"); Text("Transcript").tag("Transcript"); Text("Notes").tag("Notes")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 330)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if tab == "Review" { review(record) }
                            else if tab == "Transcript" { transcript(record) }
                            else { notes(record) }
                            Color.clear.frame(height: 1).id("end")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                    .onChange(of: model.selectedSegmentID) { _, id in
                        if let id { tab = "Transcript"; followLive = false; DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: record.revision) { _, _ in
                        if followLive && sessionID == model.activeSessionID && tab == "Transcript" { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onAppear {
                        if let id = model.selectedSegmentID { tab = "Transcript"; followLive = false; DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
                if sessionID == model.activeSessionID && tab == "Transcript" {
                    Toggle("Follow live transcript", isOn: $followLive).toggleStyle(.checkbox).font(.system(size: 11))
                }
                if !model.answer.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Latest assistance").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            if model.isAnswering { ProgressView().controlSize(.mini) }
                            Button("Save") { model.saveAnswer() }.disabled(!model.answerComplete)
                            Button("Copy") { model.copyAnswer() }
                            if model.answerComplete { Button(model.isSpeaking ? "Stop voice" : "Read aloud") { if model.isSpeaking { model.stopVoice() } else { model.readAnswer() } } }
                        }.font(.system(size: 10)).buttonStyle(.plain)
                        Text(model.answerQuestion).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        ScrollView { Text(model.answer).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                    }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 12) {
                    TextField("Ask about this session…", text: $model.question).textFieldStyle(.plain)
                        .onSubmit { model.requestAnswer(sessionID: sessionID, job: .deep) }
                    Button { if model.isAnswering { model.cancelAnswer() } else { model.requestAnswer(sessionID: sessionID, job: .deep) } } label: {
                        Image(systemName: model.isAnswering ? "stop.circle" : "arrow.up.circle.fill").font(.system(size: 23))
                    }.buttonStyle(.plain).help(model.isAnswering ? "Cancel answer" : "Ask about this session")
                }.padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            }.padding(28)
                .sheet(item: $noteSegment) { segment in SegmentNoteEditor(model: model, sessionID: sessionID, segment: segment) }
                .confirmationDialog("Delete this session and its saved notes?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete session", role: .destructive) { Task { await model.deleteSession(sessionID) } }
                }
        }
    }
    @ViewBuilder private func review(_ record: SessionRecord) -> some View {
        if record.summary.isEmpty {
            HStack {
                Text(record.summaryStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Generate summary") { model.generateSummary(sessionID) }.font(.system(size: 11))
            }
            if !record.moments.isEmpty {
                ForEach(MomentCategory.allCases) { category in
                    let moments = record.moments.filter { $0.category == category }
                    if !moments.isEmpty {
                        Text(category.rawValue).font(.system(size: 15, weight: .semibold))
                        ForEach(moments) { moment in
                            Button { tab = "Transcript"; model.selectedSegmentID = moment.segmentID } label: {
                                Text(moment.quote).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text(sessionID == model.activeSessionID ? "Important moments will collect here while you listen." : "Your full transcript is saved. A configured AI provider can create a structured review.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 15)
            }
        } else { StructuredText(text: record.summary) }
    }
    @ViewBuilder private func transcript(_ record: SessionRecord) -> some View {
        if record.segments.isEmpty { Text("Listening for speech…").foregroundStyle(.secondary) }
        ForEach(record.segments) { segment in
            let categories = Array(Set(record.moments.filter { $0.segmentID == segment.id }.map(\.category))).sorted { $0.rawValue < $1.rawValue }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(segment.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Text(segment.source.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    Spacer()
                    if segment.bookmarked { Image(systemName: "bookmark.fill").font(.system(size: 10)) }
                    Menu {
                        Button("Ask AI about this") { model.question = "About this passage: \(segment.text)\n" }
                        Button("Explain") { model.requestAnswer(text: "Explain this passage using the conversation context: \(segment.text)", sessionID: sessionID, job: .deep) }
                        Button("Summarize") { model.requestAnswer(text: "Summarize this passage briefly: \(segment.text)", sessionID: sessionID, job: .quick) }
                        Button(segment.bookmarked ? "Remove bookmark" : "Bookmark") { model.bookmark(sessionID: sessionID, segmentID: segment.id) }
                        Button("Create / edit note") { noteSegment = segment }
                        Button("Copy") { model.copy(segment.text) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                }
                Text(segment.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !categories.isEmpty {
                    Text(categories.map(\.rawValue).joined(separator: "  ·  ")).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                if !segment.note.isEmpty { Text(segment.note).font(.system(size: 11)).italic().foregroundStyle(.secondary) }
            }.padding(12).background(model.selectedSegmentID == segment.id ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8)).id(segment.id)
                .contextMenu {
                    Button("Bookmark") { model.bookmark(sessionID: sessionID, segmentID: segment.id) }
                    Button("Create note") { noteSegment = segment }
                    Button("Copy passage") { model.copy(segment.text) }
                }
        }
    }
    @ViewBuilder private func notes(_ record: SessionRecord) -> some View {
        ForEach(record.notes) { note in
            VStack(alignment: .leading, spacing: 6) {
                Text(note.time.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(note.text).font(.system(size: 13)).textSelection(.enabled)
            }
        }
        ForEach(record.segments.filter { !$0.note.isEmpty }) { segment in
            VStack(alignment: .leading, spacing: 6) {
                Text(segment.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Text(segment.note).font(.system(size: 13)).textSelection(.enabled)
            }
        }
        TextEditor(text: $note).font(.system(size: 13)).frame(minHeight: 120).padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Write a session note")
        Button("Add note") { model.addNote(sessionID: sessionID, text: note); note = "" }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        ForEach(record.answers) { answer in
            VStack(alignment: .leading, spacing: 7) {
                Text(answer.question).font(.system(size: 13, weight: .semibold))
                Text(answer.answer).font(.system(size: 13)).textSelection(.enabled)
            }
        }
    }
}

@MainActor
private struct SegmentNoteEditor: View {
    @ObservedObject var model: MeetingModel
    let sessionID: UUID
    let segment: SessionSegment
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A note for this moment").font(.title2).fontWeight(.semibold)
            Text(segment.text).font(.callout).foregroundStyle(.secondary).lineLimit(5)
            TextEditor(text: $text).frame(height: 180).font(.body).accessibilityLabel("Note")
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save note") { model.updateNote(sessionID: sessionID, segmentID: segment.id, text: text); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(25).frame(width: 480).onAppear { text = segment.note }
    }
}

struct StructuredText: View {
    let text: String
    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                if line.hasPrefix("# ") {
                    Text(String(line.dropFirst(2))).font(.system(size: 23, weight: .semibold)).padding(.top, 10)
                } else if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3))).font(.system(size: 16, weight: .semibold)).padding(.top, 14)
                } else if line.hasPrefix("### ") {
                    Text(String(line.dropFirst(4))).font(.system(size: 14, weight: .semibold)).padding(.top, 8)
                } else if line.isEmpty { Spacer().frame(height: 3) }
                else { Text(.init(line)).font(.system(size: 13)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.textSelection(.enabled)
    }
}
