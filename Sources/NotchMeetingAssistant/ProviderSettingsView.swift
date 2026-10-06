import SwiftUI
import Speech
import NotchCore

@MainActor
struct ProviderSettingsView: View {
    @ObservedObject var model: MeetingModel
    @State private var page = "AI Providers"
    @State private var providerID = ProviderKind.openai.rawValue
    @State private var keyDraft = ""
    @State private var transcriptionKeyDraft = ""
    private let pages = ["AI Providers", "Transcription", "Models by Task", "Listening"]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Settings").font(.system(size: 28, weight: .semibold))
            HStack(spacing: 20) {
                ForEach(pages, id: \.self) { title in
                    Button { page = title; keyDraft = ""; transcriptionKeyDraft = "" } label: {
                        VStack(spacing: 7) {
                            Text(title).font(.system(size: 12, weight: page == title ? .semibold : .regular))
                                .foregroundStyle(page == title ? Color.primary : .secondary)
                            Rectangle().fill(page == title ? Color.primary : .clear).frame(height: 1)
                        }
                    }.buttonStyle(.plain)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch page {
                    case "AI Providers": providers
                    case "Transcription": transcription
                    case "Models by Task": routes
                    default: listening
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }.padding(38).onChange(of: providerID) { _, _ in keyDraft = "" }
    }
    private var providers: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.settings.providers) { provider in
                    Button { providerID = provider.id } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(provider.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(model.verifiedProviders.contains(provider.id) ? "Connected" : (model.savedKeys.contains(provider.id) ? "Key saved" : "Configure"))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(providerID == provider.id ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Button { model.addCustomProvider(); providerID = model.settings.providers.last?.id ?? providerID } label: {
                    Label("Add endpoint", systemImage: "plus").font(.system(size: 11))
                }.buttonStyle(.plain).padding(12)
            }.frame(width: 160)
            Divider()
            if let position = model.settings.providers.firstIndex(where: { $0.id == providerID }) {
                providerConfiguration(position)
            }
        }
    }
    private func providerConfiguration(_ position: Int) -> some View {
        let provider = model.settings.providers[position]
        return VStack(alignment: .leading, spacing: 17) {
            Text(provider.name).font(.system(size: 22, weight: .semibold))
            if provider.kind == .custom {
                field("Name") { TextField("Provider name", text: $model.settings.providers[position].name).textFieldStyle(.roundedBorder) }
                field("Base URL") { TextField("https://your-provider.example/v1", text: $model.settings.providers[position].baseURL).textFieldStyle(.roundedBorder) }
                Text("Use an HTTPS API endpoint, or a local server on this Mac. Keys and selected session text are sent to this address.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            field(model.savedKeys.contains(provider.id) ? "Replace API key" : "API key") {
                SecureField(model.savedKeys.contains(provider.id) ? "Saved in Keychain · enter a replacement" : "Paste your API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("\(provider.name) API key")
            }
            HStack {
                Button("Save key") { if model.saveProviderKey(keyDraft, id: provider.id) { keyDraft = "" } }.disabled(keyDraft.isEmpty)
                if model.savedKeys.contains(provider.id) { Button("Remove") { model.removeProviderKey(provider.id); keyDraft = "" } }
            }.controlSize(.small)
            Text("Saved keys are never displayed again. They stay in macOS Keychain, outside your session files.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 3)
            field("Default model") { TextField("Model ID", text: $model.settings.providers[position].model).textFieldStyle(.roundedBorder) }
            if let models = model.modelCatalogs[provider.id], !models.isEmpty {
                Picker("Available models", selection: $model.settings.providers[position].model) {
                    if !models.contains(provider.model) { Text(provider.model.isEmpty ? "Choose a model" : provider.model).tag(provider.model) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }.font(.system(size: 11))
            }
            Button(model.busyProviders.contains(provider.id) ? "Checking…" : "Connect & refresh models") { Task { await model.refreshModels(provider.id) } }
                .disabled(model.busyProviders.contains(provider.id)).controlSize(.small)
            if provider.kind == .opencode || provider.kind == .custom {
                Picker("API format", selection: $model.settings.providers[position].dialect) {
                    ForEach(ProviderDialect.allCases) { Text($0.rawValue).tag($0) }
                }.font(.system(size: 11))
            }
            if provider.kind == .opencode {
                Text("Connect an OpenCode Zen API key. Automatic format selection covers GPT, Claude, Gemini, and compatible chat models; select a format explicitly for other Zen endpoints.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if provider.kind == .openai {
                Toggle("Astra Ultrafast", isOn: $model.settings.providers[position].ultrafast)
                    .disabled(provider.model != AnswerClient.astraModel).font(.system(size: 12))
                Text("Applies to gpt-6-astra through OpenAI. This is a higher-priced API tier; API billing is separate from a ChatGPT subscription.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let status = model.providerStatus[provider.id] {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var transcription: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Speech, your way.").font(.system(size: 22, weight: .semibold))
            Text("Choose where audio is transcribed. Listening sources are configured separately.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Group {
                Picker("Transcription provider", selection: $model.settings.transcription.kind) {
                    ForEach(TranscriptionKind.allCases) { Text($0.rawValue).tag($0) }
                }.onChange(of: model.settings.transcription.kind) { _, kind in
                    model.settings.transcription.model = kind.defaultModel
                    transcriptionKeyDraft = ""
                }
                if model.settings.transcription.resolvedKind == .apple {
                    Text("Auto uses Apple Speech with no extra API key. Apple Speech uses the language below; automatic language detection is available with Whisper providers.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("Apple speech language", selection: $model.settings.locale) {
                        ForEach(SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                        }
                    }
                    Toggle("Require on-device Apple recognition", isOn: $model.settings.onDeviceOnly)
                } else {
                    if model.settings.transcription.kind == .localWhisper {
                        field("Local Whisper server") { TextField("http://127.0.0.1:8080", text: $model.settings.transcription.localURL).textFieldStyle(.roundedBorder) }
                        Text("Uses a running whisper.cpp server on this Mac via /inference. The model is managed by that server. This app does not bundle or download Whisper weights.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        if model.settings.transcription.kind == .custom {
                            field("Base URL") { TextField("https://provider.example/v1", text: $model.settings.transcription.baseURL).textFieldStyle(.roundedBorder) }
                        }
                        field("Model") { TextField("Transcription model ID", text: $model.settings.transcription.model).textFieldStyle(.roundedBorder) }
                        if !model.transcriptionModels.isEmpty {
                            Picker("Available models", selection: $model.settings.transcription.model) {
                                if !model.transcriptionModels.contains(model.settings.transcription.model) { Text(model.settings.transcription.model).tag(model.settings.transcription.model) }
                                ForEach(model.transcriptionModels, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        let keyID = model.settings.transcription.kind.keyID
                        field(model.savedKeys.contains(keyID) ? "Replace provider key" : "API key") {
                            SecureField(model.savedKeys.contains(keyID) ? "Saved in Keychain" : "Transcription API key", text: $transcriptionKeyDraft).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button("Save key") { if model.saveProviderKey(transcriptionKeyDraft, id: keyID) { transcriptionKeyDraft = "" } }.disabled(transcriptionKeyDraft.isEmpty)
                            if model.savedKeys.contains(keyID) { Text("Uses the same saved key as \(model.settings.transcription.kind.rawValue).").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }.controlSize(.small)
                    }
                    Toggle("Automatic language detection", isOn: $model.settings.transcription.automaticLanguage)
                    if !model.settings.transcription.automaticLanguage {
                        field("Language code") { TextField("en, hi, pa…", text: $model.settings.transcription.language).textFieldStyle(.roundedBorder) }
                    }
                    HStack { Text("Audio chunk length"); Spacer(); Text(String(format: "%.0f seconds", model.settings.transcription.chunkSeconds)).monospacedDigit() }
                    Slider(value: $model.settings.transcription.chunkSeconds, in: 3...12, step: 1).accessibilityLabel("Transcription chunk length")
                    Text("Whisper updates arrive as short audio chunks finish. Each provider's latency and minimum billing duration apply. Speaker labels appear only when returned by a diarization model; ordinary room audio is labeled Room.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.disabled(model.busyCapture)
            Button(model.checkingTranscription ? "Checking…" : "Check provider & refresh models") { Task { await model.refreshTranscriptionModels() } }
                .disabled(model.checkingTranscription || model.busyCapture)
            Text(model.transcriptionStatus).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            if model.busyCapture { Text("Stop listening to change transcription settings.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.font(.system(size: 12)).frame(maxWidth: 590, alignment: .leading)
    }
    private var routes: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("The right model for the moment.").font(.system(size: 22, weight: .semibold))
            Text("Auto selects from configured providers. A failed request never silently switches provider or starts a paid retry loop.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(AIJob.allCases) { job in
                VStack(alignment: .leading, spacing: 12) {
                    Text(job.rawValue).font(.system(size: 13, weight: .semibold))
                    Picker("Provider", selection: routeBinding(job, keyPath: \.providerID)) {
                        Text("Auto — Recommended").tag("")
                        ForEach(model.settings.providers) { Text($0.name).tag($0.id) }
                    }
                    TextField("Use provider default model", text: routeBinding(job, keyPath: \.model)).textFieldStyle(.roundedBorder)
                    let selected = model.settings.routes[job.rawValue]?.providerID ?? ""
                    if let catalog = model.modelCatalogs[selected], !catalog.isEmpty {
                        Picker("Model catalog", selection: routeBinding(job, keyPath: \.model)) {
                            Text("Provider default").tag("")
                            let current = model.settings.routes[job.rawValue]?.model ?? ""
                            if !current.isEmpty && !catalog.contains(current) { Text(current).tag(current) }
                            ForEach(catalog, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if job == .quick { Text("Also used for silent question and important-moment detection.").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Divider()
            }
            Button("Configure transcription") { page = "Transcription" }.buttonStyle(.plain)
        }.font(.system(size: 12)).frame(maxWidth: 590, alignment: .leading)
    }
    private func routeBinding(_ job: AIJob, keyPath: WritableKeyPath<ModelRoute, String>) -> Binding<String> {
        Binding(get: { (model.settings.routes[job.rawValue] ?? ModelRoute())[keyPath: keyPath] }, set: { value in
            var route = model.settings.routes[job.rawValue] ?? ModelRoute(); route[keyPath: keyPath] = value
            model.settings.routes[job.rawValue] = route
        })
    }
    private var listening: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Quiet by default.").font(.system(size: 22, weight: .semibold))
            Group {
                Picker("Audio source", selection: $model.settings.audioSource) { ForEach(AudioSource.allCases) { Text($0.rawValue).tag($0) } }
                if model.settings.audioSource.usesSystem {
                    Picker("System audio from", selection: $model.settings.applicationID) {
                        Text("All system audio").tag("")
                        if !model.settings.applicationID.isEmpty && !model.applications.contains(where: { $0.id == model.settings.applicationID }) { Text(model.settings.applicationID).tag(model.settings.applicationID) }
                        ForEach(model.applications) { Text($0.name).tag($0.id) }
                    }
                    Button(model.loadingApplications ? "Loading…" : "Refresh running apps") { Task { await model.refreshApplications() } }.disabled(model.loadingApplications)
                    Button("Open screen & audio permissions") { model.openRecordingSettings() }.buttonStyle(.plain)
                }
            }.disabled(model.busyCapture)
            Text("Microphone listens to the room. System audio listens to apps. Combining them can capture the same speaker twice when speakers are audible; headphones reduce that duplication.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Picker("Question Assistance", selection: $model.settings.assistance) { ForEach(QuestionAssistance.allCases) { Text($0.rawValue).tag($0) } }
            Text("Detect only reveals a question. Suggested answers appear quietly as text. Automatic answers also use your selected voice output. You can always ask manually.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Answer output", selection: $model.settings.outputMode) { ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            HStack { Text("Pause before assistance"); Spacer(); Text(String(format: "%.1f seconds", model.settings.autoDelay)).monospacedDigit() }
            Slider(value: $model.settings.autoDelay, in: 0.7...4, step: 0.1).accessibilityLabel("Pause before question assistance")
            HStack { Text("Voice speed"); Spacer(); Text("Slower → Faster").foregroundStyle(.secondary) }
            Slider(value: $model.settings.voiceRate, in: 0.35...0.65).accessibilityLabel("Spoken answer speed")
            Text("Listening pauses while an answer is spoken to prevent feedback. Speech during playback is not captured. Text output keeps listening uninterrupted.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("Create a structured summary after each session", isOn: $model.settings.automaticSummary)
            Button("Retry paused assistance") { model.retryAssistance() }
            Divider()
            Text("Session text, notes, and bookmarks are saved locally in Application Support. Raw audio is not saved. Cloud transcription sends short audio chunks to the provider you select. AI assistance sends selected text to the task's configured provider.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).frame(maxWidth: 590, alignment: .leading)
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); content() }
    }
}
