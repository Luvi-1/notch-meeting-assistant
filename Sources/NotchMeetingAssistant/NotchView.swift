import SwiftUI
import Speech
import NotchCore

@MainActor
struct NotchView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var editingQuestion: Bool
    @State private var showFullTranscript = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                notchBar
                if model.presentation.phase == .preview {
                    preview
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                } else if model.expanded {
                    VStack(spacing: 12) {
                        if let message = model.error { errorBanner(message) }
                        if model.showSettings { SettingsView(model: model) }
                        else { meetingView }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            // Use the real, animated window size so the rounded silhouette never snaps ahead of it.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(.black)
            .clipShape(NotchShape(detached: model.detachedNotch))
            .overlay(NotchShape(detached: model.detachedNotch).stroke(.white.opacity(0.08), lineWidth: 1))
            .contentShape(NotchShape(detached: model.detachedNotch))
            .onHover { model.hover($0) }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: model.presentation.phase)
        .onExitCommand { editingQuestion = false; model.collapse() }
        .onChange(of: editingQuestion) { _, focused in model.setEditing(focused) }
        .onChange(of: model.presentation.phase) { _, phase in
            if phase == .compact { editingQuestion = false }
        }
    }

    private var notchBar: some View {
        HStack(spacing: 0) {
            Button { model.openNotch() } label: {
                HStack(spacing: 7) {
                    activityMark
                    if model.presentation.phase != .compact || model.detachedNotch {
                        Text("Notch").font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Open meeting assistant. \(model.status)")
            Color.clear.frame(width: model.cutoutWidth)
            HStack(spacing: 8) {
                if model.expanded {
                    iconButton(model.presentation.pinned ? "pin.fill" : "pin", label: model.presentation.pinned ? "Unpin panel" : "Keep panel open") { model.togglePin() }
                    iconButton("slider.horizontal.3", label: "Settings") { model.showSettings.toggle() }
                    iconButton("chevron.up", label: "Collapse to notch") { editingQuestion = false; model.collapse() }
                } else if model.isListening || model.isStarting {
                    iconButton("stop.fill", label: "Stop meeting") { Task { await model.stop() } }
                } else {
                    iconButton("chevron.down", label: "Open meeting assistant") { model.openNotch() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: model.cutoutHeight)
    }

    @ViewBuilder private var activityMark: some View {
        if model.isAnswering {
            ProgressView().controlSize(.mini).frame(width: 15, height: 15)
        } else {
            Image(systemName: model.error != nil ? "exclamationmark.circle" : (model.isSpeaking ? "speaker.wave.2.fill" : "waveform"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(model.isListening || model.isSpeaking || model.error != nil ? 1 : 0.55))
                .symbolEffect(.pulse, options: .repeating, isActive: model.isListening && !reduceMotion)
                .frame(width: 15, height: 15)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.error != nil ? "Needs your attention" : (model.isAnswering ? "Answering" : "Your answer"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(model.settings.outputMode.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let message = model.error {
                Text(message).font(.system(size: 12)).lineLimit(3).foregroundStyle(.white.opacity(0.8))
                if model.needsRecordingPermission {
                    Button("Open Privacy Settings") { model.openRecordingSettings() }.font(.system(size: 11, weight: .medium))
                }
            } else {
                Text(model.settings.outputMode.showsText ? model.answer : (model.isSpeaking ? "Reading your answer…" : "Spoken answer ready."))
                    .font(.system(size: 15, weight: .medium)).lineSpacing(3).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open answer") { model.openNotch() }.font(.system(size: 10, weight: .medium))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var meetingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meeting").font(.system(size: 22, weight: .semibold))
                Spacer()
                Text(model.providerLabel).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 150, alignment: .trailing)
            }
            HStack(spacing: 18) {
                Picker("Answer mode", selection: $model.settings.answerMode) {
                    Text("Auto").tag(AnswerMode.automatic)
                    Text("Manual").tag(AnswerMode.manual)
                }
                .accessibilityLabel("Automatic or manual answers")
                Picker("Answer output", selection: $model.settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityLabel("Text, voice, or both")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    transcriptSection
                    answerSection
                }
            }
            composer
            sessionControls
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting…", text: $model.question)
                .font(.system(size: 13)).textFieldStyle(.plain)
                .focused($editingQuestion)
                .onSubmit { editingQuestion = false; model.requestAnswer() }
                .accessibilityLabel("Question for meeting assistant")
            Button {
                editingQuestion = false
                if model.isAnswering { model.cancelAnswer() } else { model.requestAnswer() }
            } label: {
                Image(systemName: model.isAnswering ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .semibold)).frame(width: 27, height: 27)
                    .foregroundStyle(.black).background(.white, in: Circle())
                    .opacity(model.isAnswering || model.canAnswer ? 1 : 0.35)
            }
            .buttonStyle(.plain).disabled(!model.isAnswering && !model.canAnswer)
            .help(model.isAnswering ? "Cancel answer" : "Answer now")
            .accessibilityLabel(model.isAnswering ? "Cancel answer" : "Answer now")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button { showFullTranscript.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("Transcript")
                        Image(systemName: showFullTranscript ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .accessibilityLabel(showFullTranscript ? "Show compact transcript" : "Expand transcript")
                Spacer()
                if !model.transcript.lines.isEmpty {
                    Button("Clear") { model.clearTranscript() }.buttonStyle(.plain).font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        if model.transcript.lines.isEmpty {
                            Text(model.isListening ? "Listening for speech…" : "Start a meeting to see the conversation.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.transcript.lines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.source).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading).padding(.top, 2)
                                Text(line.text).textSelection(.enabled).foregroundStyle(.white.opacity(0.78))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("transcript-end")
                    }
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(height: showFullTranscript ? 126 : 54)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: model.transcript.lines) { _, _ in proxy.scrollTo("transcript-end", anchor: .bottom) }
            }
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(model.isAnswering ? "Answering" : (!model.answer.isEmpty && !model.answerComplete ? "Partial answer" : "Answer"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if model.isSpeaking {
                    Button("Stop voice") { model.stopVoice() }.buttonStyle(.plain).font(.system(size: 10))
                } else if model.answerComplete && model.settings.outputMode.usesVoice {
                    iconButton("speaker.wave.2", label: "Play answer again") { model.readAnswer() }
                }
                if !model.answer.isEmpty { iconButton("doc.on.doc", label: "Copy answer") { model.copyAnswer() } }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.settings.outputMode.showsText {
                            Text(model.answer.isEmpty ? answerPlaceholder : model.answer)
                                .font(.system(size: 15, weight: .medium)).lineSpacing(4)
                                .foregroundStyle(.white.opacity(model.answer.isEmpty ? 0.48 : 0.95))
                                .textSelection(.enabled)
                        } else {
                            Label(model.isSpeaking ? "Reading your answer…" : (model.isAnswering ? "Preparing your answer…" : "Answers play through your Mac."),
                                  systemImage: "speaker.wave.2")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("answer-end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(height: 124)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: model.answer) { _, _ in proxy.scrollTo("answer-end", anchor: .bottom) }
            }
        }
    }

    private var answerPlaceholder: String {
        if model.isAnswering { return "Thinking through the question…" }
        return model.settings.answerMode == .automatic
            ? "Your next answer appears here after a question and a short pause."
            : "Ask below, or answer the latest meeting question."
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.isListening && !model.isStarting {
                Toggle("Everyone in this meeting agrees to transcription.", isOn: $model.hasConsent)
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(.white.opacity(model.isListening ? 1 : 0.35)).frame(width: 5, height: 5)
                        Text(model.status).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    if !model.isListening && !model.isStarting {
                        Text("Text to OpenAI. Audio may be processed by Apple.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if model.isListening || model.isStarting {
                    Button(model.isStarting ? "Cancel start" : "Stop meeting") { Task { await model.stop() } }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
                } else {
                    Button("Start meeting") { editingQuestion = false; Task { await model.start() } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .tint(.white).foregroundStyle(.black).disabled(!model.hasConsent)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if model.needsRecordingPermission {
                    Button("Open Privacy Settings") { model.openRecordingSettings() }.buttonStyle(.plain).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
        .font(.system(size: 11)).padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NotchShape: Shape {
    var detached = false
    func path(in r: CGRect) -> Path {
        if detached { return RoundedRectangle(cornerRadius: min(22, r.height / 2), style: .continuous).path(in: r) }
        var p = Path()
        let corner = min(24.0, r.height / 2)
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: r.width, y: 0))
        p.addQuadCurve(to: CGPoint(x: r.width - 8, y: 10), control: CGPoint(x: r.width - 8, y: 0))
        p.addLine(to: CGPoint(x: r.width - 8, y: r.height - corner))
        p.addQuadCurve(to: CGPoint(x: r.width - 8 - corner, y: r.height), control: CGPoint(x: r.width - 8, y: r.height))
        p.addLine(to: CGPoint(x: 8 + corner, y: r.height))
        p.addQuadCurve(to: CGPoint(x: 8, y: r.height - corner), control: CGPoint(x: 8, y: r.height))
        p.addLine(to: CGPoint(x: 8, y: 10))
        p.addQuadCurve(to: .zero, control: CGPoint(x: 8, y: 0))
        p.closeSubpath()
        return p
    }
}

@MainActor
private struct SettingsView: View {
    @ObservedObject var model: MeetingModel
    private var languages: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { languageName($0.identifier) < languageName($1.identifier) }
    }
    private func languageName(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Done") { model.showSettings = false }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    providerSettings
                    Divider()
                    audioSettings
                    Divider()
                    answerSettings
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Answers").font(.headline)
                Spacer()
                Button("Use GPT-6 Astra") {
                    model.settings.model = AnswerClient.astraModel
                    model.settings.ultrafast = true
                }.font(.caption)
            }
            SecureField("OpenAI API key", text: $model.keyDraft).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save key") { model.saveKey() }
                if model.hasKey { Button("Remove key") { model.removeKey() } }
                Spacer()
                Text(model.keyStatus).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Model ID", text: $model.settings.model).textFieldStyle(.roundedBorder)
            Toggle("Ultrafast", isOn: Binding(get: { model.settings.ultrafast == true }, set: { model.settings.ultrafast = $0 }))
                .disabled(model.settings.model != AnswerClient.astraModel)
            Text("Ultrafast uses a higher-priced API tier. Your key stays in Keychain; recent meeting text is sent to OpenAI for answers. API credits are separate from ChatGPT.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var audioSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting audio").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Audio source", selection: $model.settings.applicationID) {
                    Text("All system audio").tag("")
                    if !model.settings.applicationID.isEmpty && !model.applications.contains(where: { $0.id == model.settings.applicationID }) {
                        Text(model.settings.applicationID).tag(model.settings.applicationID)
                    }
                    ForEach(model.applications) { Text($0.name).tag($0.id) }
                }
                Button(model.loadingApplications ? "Loading apps…" : "Refresh running apps") { Task { await model.refreshApplications() } }
                    .disabled(model.loadingApplications)
                Toggle("Include my microphone", isOn: $model.settings.includeMicrophone)
                Picker("Speech language", selection: $model.settings.locale) {
                    ForEach(languages, id: \.identifier) { locale in Text(languageName(locale.identifier)).tag(locale.identifier) }
                }
                Toggle("On-device transcription only", isOn: $model.settings.onDeviceOnly)
            }
            .disabled(model.isListening || model.isStarting)
            Button("Open recording permissions") { model.openRecordingSettings() }
            Text(model.isListening || model.isStarting ? "Stop the meeting to change audio settings." :
                 "Allow Screen & System Audio Recording in macOS, then reopen the app. Without on-device mode, Apple may process audio remotely. A browser source includes all of that browser's audio.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var answerSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timing & voice").font(.headline)
            HStack {
                Text("Pause before automatic answer")
                Spacer()
                Text(String(format: "%.1f s", model.settings.autoDelay)).monospacedDigit()
            }.font(.caption)
            Slider(value: $model.settings.autoDelay, in: 0.7...4, step: 0.1)
                .accessibilityLabel("Pause before automatic answer")
            HStack { Text("Voice speed"); Spacer(); Text("Slower → Faster").foregroundStyle(.secondary) }.font(.caption)
            Slider(value: $model.settings.voiceRate, in: 0.35...0.65).accessibilityLabel("Voice speed")
            Text("Meeting background (optional)").font(.caption)
            TextEditor(text: $model.meetingContext).font(.system(size: 12))
                .frame(height: 75).scrollContentBackground(.hidden).padding(8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Optional meeting background")
            Text("Use headphones for voice answers. Transcription pauses during playback to prevent feedback; speech during playback is not captured. No audio recording is saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
