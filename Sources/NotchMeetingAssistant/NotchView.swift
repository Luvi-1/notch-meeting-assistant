import SwiftUI
import Speech
import NotchCore

@MainActor
struct NotchView: View {
    @ObservedObject var model: MeetingModel

    var body: some View {
        VStack(spacing: 0) {
            notchBar
            if model.expanded {
                VStack(spacing: 14) {
                    if let message = model.error { errorBanner(message) }
                    if model.showSettings {
                        SettingsView(model: model)
                    } else {
                        meetingView
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .frame(width: model.panelWidth, height: model.panelHeight, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape())
        .overlay(NotchShape().stroke(Color.white.opacity(0.09), lineWidth: 1))
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
    }

    private var notchBar: some View {
        HStack(spacing: 0) {
            Button { model.expanded = true } label: {
                HStack(spacing: 7) {
                    Circle().fill(model.isListening ? Color.green : Color.white.opacity(0.45))
                        .frame(width: 6, height: 6)
                    if model.expanded {
                        Text("NOTCH").font(.system(size: 9, weight: .semibold)).tracking(2)
                    } else {
                        Image(systemName: "waveform").font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open meeting assistant. \(model.status)")
            Color.clear.frame(width: model.cutoutWidth)
            HStack(spacing: 12) {
                if model.expanded {
                    Button { model.showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .help("Settings").accessibilityLabel("Settings")
                    Button { model.expanded = false } label: { Image(systemName: "chevron.up") }
                        .help("Collapse to notch").accessibilityLabel("Collapse to notch")
                } else if model.isListening || model.isStarting {
                    Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill") }
                        .help("Stop meeting").accessibilityLabel("Stop meeting")
                } else {
                    Button { model.expanded = true } label: { Image(systemName: "chevron.down") }
                        .help("Expand").accessibilityLabel("Expand meeting assistant")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: model.cutoutHeight)
    }

    private var meetingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meeting assistant").font(.system(size: 23, weight: .semibold))
                Spacer()
                Text(model.settings.answerMode == .automatic ? "AFTER A PAUSE" : "ON YOUR SIGNAL")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 24) {
                Picker("Answer mode", selection: $model.settings.answerMode) {
                    ForEach(AnswerMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Answer output", selection: $model.settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transcriptSection
                    answerSection
                    HStack(spacing: 10) {
                        TextField("Ask about this meeting…", text: $model.question)
                            .textFieldStyle(.plain)
                            .onSubmit { model.requestAnswer() }
                            .padding(10)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityLabel("Question for meeting assistant")
                        if model.isAnswering {
                            Button("Cancel") { model.cancelAnswer() }.buttonStyle(.bordered)
                        } else {
                            Button("Answer now") { model.requestAnswer() }
                                .buttonStyle(.bordered)
                                .disabled(!model.canAnswer)
                                .keyboardShortcut(.return, modifiers: .command)
                        }
                    }
                }
            }
            sessionControls
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption("LIVE TRANSCRIPT")
                Spacer()
                if !model.transcript.lines.isEmpty {
                    Button("Clear") { model.clearTranscript() }
                        .font(.system(size: 11)).buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        if model.transcript.lines.isEmpty {
                            Text(model.isListening ? "Listening for speech…" : "Your meeting transcript will appear here.")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        ForEach(model.transcript.lines) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(line.source.uppercased())
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(width: 52, alignment: .leading)
                                    .padding(.top, 3)
                                Text(line.text).textSelection(.enabled)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("transcript-end")
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(height: 106)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: model.transcript.lines) { _, _ in proxy.scrollTo("transcript-end", anchor: .bottom) }
            }
        }
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption(model.isAnswering ? "ANSWERING" : (model.answer.isEmpty || model.answerComplete ? "YOUR ANSWER" : "PARTIAL ANSWER"))
                if model.isAnswering { ProgressView().controlSize(.mini) }
                Spacer()
                if model.isSpeaking {
                    Button("Stop voice") { model.stopVoice() }.buttonStyle(.plain).font(.system(size: 11))
                } else if model.answerComplete && model.settings.outputMode.usesVoice {
                    Button("Play again") { model.readAnswer() }.buttonStyle(.plain).font(.system(size: 11))
                }
                if !model.answer.isEmpty {
                    Button { model.copyAnswer() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy answer").accessibilityLabel("Copy answer")
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.settings.outputMode.showsText {
                            Text(model.answer.isEmpty ? answerPlaceholder : model.answer)
                                .font(.system(size: 16, weight: .medium))
                                .lineSpacing(5)
                                .foregroundStyle(.white.opacity(model.answer.isEmpty ? 0.4 : 0.95))
                                .textSelection(.enabled)
                        } else {
                            Image(systemName: model.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                                .font(.system(size: 24)).padding(.bottom, 5)
                            Text(model.isAnswering ? "Preparing a spoken answer…" :
                                 (model.isSpeaking ? "Reading your answer…" :
                                  (model.answerComplete ? "Spoken answer ready." : "Answers will play through your Mac.")))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Color.clear.frame(height: 1).id("answer-end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .frame(height: 158)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: model.answer) { _, _ in proxy.scrollTo("answer-end", anchor: .bottom) }
            }
        }
    }

    private var answerPlaceholder: String {
        if model.isAnswering { return "Thinking through the meeting…" }
        return model.settings.answerMode == .automatic
            ? "An answer appears here after a new question and a short pause."
            : "Press Answer now, or type a question below."
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(.white.opacity(0.07))
            if !model.isListening && !model.isStarting {
                Toggle("Everyone in this meeting agrees to transcription.", isOn: $model.hasConsent)
                    .toggleStyle(.checkbox).font(.system(size: 11))
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(model.status, systemImage: model.isSpeaking ? "speaker.wave.2" : "waveform")
                        .font(.system(size: 12, weight: .medium))
                    if !model.isListening && !model.isStarting {
                        Text("Meeting text → OpenAI. Audio may be processed by Apple.")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                Spacer()
                if model.isListening || model.isStarting {
                    Button(model.isStarting ? "Cancel start" : "Stop meeting") { Task { await model.stop() } }
                        .buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button("Start meeting") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                        .controlSize(.large).disabled(!model.hasConsent)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1).foregroundStyle(.white.opacity(0.45))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle")
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
        .font(.system(size: 11)).padding(11)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct NotchShape: Shape {
    func path(in r: CGRect) -> Path {
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
                Text("Settings").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Done") { model.showSettings = false }.buttonStyle(.bordered)
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
            Text("Answer provider").font(.headline)
            SecureField("OpenAI API key", text: $model.keyDraft).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save key") { model.saveKey() }
                if model.hasKey { Button("Remove key") { model.removeKey() } }
                Spacer()
                Text(model.keyStatus).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Model ID", text: $model.settings.model).textFieldStyle(.roundedBorder)
            Text("Your key stays in macOS Keychain. Recent transcript text is sent to OpenAI when an answer is requested. API usage is billed to your API account.")
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
                    ForEach(languages, id: \.identifier) { locale in
                        Text(languageName(locale.identifier)).tag(locale.identifier)
                    }
                }
                Toggle("On-device transcription only", isOn: $model.settings.onDeviceOnly)
            }
            .disabled(model.isListening || model.isStarting)
            Text(model.isListening || model.isStarting ? "Stop the meeting to change audio settings." :
                 "Start requests macOS recording permissions. Without on-device mode, Apple may process audio remotely. Selecting a browser captures audio from that browser, not an individual tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var answerSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Answers").font(.headline)
            HStack {
                Text("Pause before automatic answer")
                Spacer()
                Text(String(format: "%.1f s", model.settings.autoDelay)).monospacedDigit()
            }.font(.caption)
            Slider(value: $model.settings.autoDelay, in: 0.7...4, step: 0.1)
                .accessibilityLabel("Pause before automatic answer")
            HStack { Text("Voice speed"); Spacer(); Text("Slower → Faster").foregroundStyle(.secondary) }.font(.caption)
            Slider(value: $model.settings.voiceRate, in: 0.35...0.65)
                .accessibilityLabel("Voice speed")
            Text("Meeting background (optional)").font(.caption)
            TextEditor(text: $model.meetingContext).font(.system(size: 12))
                .frame(height: 80).scrollContentBackground(.hidden).padding(8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Optional meeting background")
            Text("Use headphones for voice answers. Transcription pauses during playback to prevent feedback; conversation during playback is not captured. Nothing is saved as an audio recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
