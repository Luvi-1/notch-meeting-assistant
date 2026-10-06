import SwiftUI
import NotchCore

@MainActor
struct ProviderSettingsView: View {
    @ObservedObject var model: MeetingModel
    @State private var page = "AI Providers"
    private var configuration: Binding<ProviderConfiguration> {
        Binding(get: { model.settings.providers.first(where: { $0.provider == model.selectedProvider }) ?? ProviderConfiguration(model.selectedProvider) },
                set: { value in if let index = model.settings.providers.firstIndex(where: { $0.provider == value.provider }) { model.settings.providers[index] = value } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Make it yours.").font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                Picker("Settings section", selection: $page) {
                    ForEach(["AI Providers", "Listening", "Task Models", "Preferences"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                switch page {
                case "AI Providers": providers
                case "Listening": listening
                case "Task Models": assignments
                default: preferences
                }
            }.padding(32).frame(maxWidth: 870, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private var providers: some View {
        VStack(alignment: .leading, spacing: 25) {
            Text("Choose where your AI assistance comes from. Your credentials stay in macOS Keychain.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 3) {
                    ForEach(model.settings.providers) { provider in
                        Button { model.selectedProvider = provider.provider } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(provider.provider.title).font(.system(size: 12, weight: .medium))
                                    Spacer(minLength: 0)
                                    if provider.provider == model.selectedProvider { Image(systemName: "chevron.right").font(.system(size: 8)) }
                                }
                                Text(connectionStatus(provider)).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 11).padding(.vertical, 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(provider.provider == model.selectedProvider ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 153)
                VStack(alignment: .leading, spacing: 17) {
                    Text(model.selectedProvider.title).font(.system(size: 19, weight: .semibold))
                    if model.selectedProvider == .custom {
                        labeled("Base URL") { TextField("https://your-provider.example/v1", text: configuration.customBaseURL).textFieldStyle(.roundedBorder) }
                        Text("HTTPS is required for remote servers. A local server on this Mac can use HTTP and does not need an API key.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if model.selectedProvider == .opencode {
                        Text("OpenCode Zen uses its own API key. The API format is chosen from the selected model; an explicit override is available below.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    labeled(model.keyedProviders.contains(model.selectedProvider) ? "Replace saved API key" : "API key") {
                        SecureField(model.keyedProviders.contains(model.selectedProvider) ? "Key saved securely — enter a replacement" : "Paste your API key", text: $model.keyDraft)
                            .textFieldStyle(.roundedBorder).onSubmit { model.saveProviderKey() }
                    }
                    HStack(spacing: 10) {
                        Button("Save key") { model.saveProviderKey() }.disabled(model.keyDraft.isEmpty)
                        if model.keyedProviders.contains(model.selectedProvider) {
                            Button("Remove") { model.removeProviderKey() }.disabled(model.busyListening)
                        }
                        Spacer(minLength: 0)
                    }.font(.system(size: 11))
                    Button(model.providerBusy ? "Checking…" : "Test connection & refresh models") { Task { await model.refreshModels() } }
                        .disabled(model.providerBusy).font(.system(size: 11))
                    if !model.providerStatus.isEmpty { Text(model.providerStatus).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                    labeled("Default model") {
                        Picker("Available models", selection: configuration.model) {
                            Text("Choose a model…").tag("")
                            if !configuration.wrappedValue.model.isEmpty && !configuration.wrappedValue.models.contains(configuration.wrappedValue.model) {
                                Text(configuration.wrappedValue.model).tag(configuration.wrappedValue.model)
                            }
                            ForEach(configuration.wrappedValue.models, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                        TextField("Or enter an exact model ID", text: configuration.model).textFieldStyle(.roundedBorder)
                    }
                    if model.selectedProvider == .custom || model.selectedProvider == .opencode {
                        Picker("API format", selection: configuration.format) { ForEach(APIFormat.allCases) { Text($0.rawValue).tag($0) } }
                            .font(.system(size: 11))
                    }
                    if model.selectedProvider == .openai {
                        Toggle("Ultrafast", isOn: configuration.ultrafast).disabled(configuration.wrappedValue.model != "gpt-6-astra")
                            .font(.system(size: 12))
                        Text("Ultrafast applies to GPT-6 Astra and uses a higher-priced API tier. API usage is separate from a ChatGPT subscription. The app does not silently switch provider or tier after an error.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    if let date = configuration.wrappedValue.verifiedAt {
                        Text("Model catalog checked \(date.formatted(date: .abbreviated, time: .shortened)). Individual model access is confirmed when a request succeeds.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func connectionStatus(_ provider: ProviderConfiguration) -> String {
        if model.keyedProviders.contains(provider.provider) { return provider.verifiedAt == nil ? "Key saved" : "Connection verified" }
        if provider.provider == .custom && model.availableProviders.contains(.custom) { return "Local server configured" }
        return "Not configured"
    }
    private var listening: some View {
        VStack(alignment: .leading, spacing: 26) {
            settingsSection("Audio input", detail: "Use the microphone for a classroom or conversation. System audio captures sound from apps and needs a separate macOS permission.") {
                Toggle("Microphone", isOn: $model.settings.includeMicrophone)
                Toggle("System audio", isOn: $model.settings.captureSystemAudio)
                if model.settings.captureSystemAudio {
                    Picker("Capture from", selection: $model.settings.applicationID) {
                        Text("All system audio").tag("")
                        if !model.settings.applicationID.isEmpty && !model.applications.contains(where: { $0.id == model.settings.applicationID }) {
                            Text(model.settings.applicationID).tag(model.settings.applicationID)
                        }
                        ForEach(model.applications) { Text($0.name).tag($0.id) }
                    }
                    Button(model.loadingApplications ? "Finding apps…" : "Refresh running apps") { Task { await model.refreshApplications() } }
                        .disabled(model.loadingApplications)
                }
            }
            .disabled(model.busyListening)
            settingsSection("Transcription", detail: "Auto uses Groq when its key is saved; otherwise it uses Apple Speech. Whisper providers send short, ordered audio chunks. They are not native realtime streams.") {
                Picker("Provider", selection: $model.settings.transcription.provider) {
                    ForEach(TranscriptionService.allCases) { Text($0.rawValue).tag($0) }
                }.onChange(of: model.settings.transcription.provider) { _, _ in model.settings.transcription.model = "" }
                let provider = model.settings.transcription.provider
                if provider == .localWhisper {
                    TextField("Local Whisper server URL", text: $model.settings.transcription.localURL).textFieldStyle(.roundedBorder)
                    Text("Requires a running whisper.cpp server with a loaded model on this Mac. Notch connects to /inference; it does not install or start a model server. The server controls the model.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                } else if provider == .custom {
                    TextField("Custom base URL, including /v1 when required", text: $model.settings.transcription.customBaseURL).textFieldStyle(.roundedBorder)
                    SecureField(model.hasCustomTranscriptionKey ? "Custom transcription key saved — enter a replacement" : "Custom transcription API key", text: $model.transcriptionKeyDraft).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save key") { model.saveTranscriptionKey() }.disabled(model.transcriptionKeyDraft.isEmpty)
                        if model.hasCustomTranscriptionKey { Button("Remove key") { model.removeTranscriptionKey() } }
                    }
                }
                if provider != .apple && provider != .localWhisper {
                    Picker("Available models", selection: $model.settings.transcription.model) {
                        Text("Provider default").tag("")
                        if !model.settings.transcription.model.isEmpty && !model.transcriptionModels.contains(model.settings.transcription.model) { Text(model.settings.transcription.model).tag(model.settings.transcription.model) }
                        ForEach(model.transcriptionModels, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Exact transcription model ID (optional)", text: $model.settings.transcription.model).textFieldStyle(.roundedBorder)
                    if provider == .groq { Text("Default: whisper-large-v3-turbo").font(.caption).foregroundStyle(.secondary) }
                    if provider == .openai { Text("Default: whisper-1. Diarization is available only with a supported diarization model; speaker IDs remain clip-scoped.").font(.caption).foregroundStyle(.secondary) }
                }
                Button("Check transcription provider") { Task { await model.refreshTranscriptionModels() } }
                if !model.transcriptionStatus.isEmpty { Text(model.transcriptionStatus).font(.system(size: 11)).foregroundStyle(.secondary) }
                Toggle("Automatic language detection", isOn: Binding(get: { model.settings.transcription.language.isEmpty }, set: { model.settings.transcription.language = $0 ? "" : "en" }))
                if !model.settings.transcription.language.isEmpty {
                    TextField("Language code: en, hi, pa…", text: $model.settings.transcription.language).textFieldStyle(.roundedBorder)
                }
                if provider == .apple || (provider == .automatic && !model.keyedProviders.contains(.groq)) {
                    TextField("Apple Speech language / locale", text: $model.settings.locale).textFieldStyle(.roundedBorder)
                    Text("Apple Speech uses this selected locale, rather than automatic language detection. Cloud Whisper and Local Whisper can detect language automatically.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Toggle("On-device transcription only", isOn: $model.settings.onDeviceOnly)
                Text("This restricts transcription to supported on-device Apple Speech or Local Whisper. AI answers can still send selected text to your configured provider.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.disabled(model.busyListening)
            settingsSection("Audio timing", detail: "Shorter chunks reduce the wait but make more transcription requests. Very quiet input can need a lower silence threshold.") {
                HStack { Text("Whisper chunk size"); Spacer(); Text("\(Int(model.settings.transcription.chunkSeconds)) s").monospacedDigit() }
                Slider(value: $model.settings.transcription.chunkSeconds, in: 2...20, step: 1).accessibilityLabel("Whisper audio chunk duration")
                HStack { Text("Silence threshold"); Spacer(); Text(String(format: "%.4f", model.settings.silenceThreshold)).monospacedDigit() }
                Slider(value: $model.settings.silenceThreshold, in: 0...0.01, step: 0.0005).accessibilityLabel("Audio silence threshold")
            }.disabled(model.busyListening)
            if model.busyListening { Text("Stop listening before changing audio or transcription settings.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
    private var assignments: some View {
        VStack(alignment: .leading, spacing: 25) {
            Text("Use a quick model for live help and a different model for reviewing a session. Auto picks among configured providers; it never retries a failed request through another provider.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            ForEach(AITask.allCases) { task in
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.rawValue).font(.system(size: 15, weight: .medium))
                    Picker("Provider", selection: assignment(task).provider) {
                        Text("Auto — Recommended").tag(AIProvider?.none)
                        ForEach(AIProvider.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    if let provider = assignment(task).wrappedValue.provider {
                        let config = model.settings.providers.first { $0.provider == provider }
                        Picker("Model", selection: assignment(task).model) {
                            Text("Provider default").tag("")
                            let selected = assignment(task).wrappedValue.model
                            if !selected.isEmpty && !(config?.models.contains(selected) ?? false) { Text(selected).tag(selected) }
                            ForEach(config?.models ?? [], id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Exact model override (optional)", text: assignment(task).model).textFieldStyle(.roundedBorder)
                    }
                    if let resolved = try? model.settings.configuration(for: task, available: model.availableProviders) {
                        Text("Using \(resolved.provider.title) · \(resolved.model)").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else { Text("Configure a provider and model to enable this task.").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Divider().opacity(0.5)
            }
            Button("Configure transcription models") { page = "Listening" }.buttonStyle(.link)
        }
    }
    private func assignment(_ task: AITask) -> Binding<ModelAssignment> {
        Binding(get: { model.settings.assignments[task.rawValue] ?? ModelAssignment() }, set: { model.settings.assignments[task.rawValue] = $0 })
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 28) {
            settingsSection("Question Assistance", detail: "Detection understands requests and context, including questions without question marks. Definitions, assignments and other important moments are classified quietly.") {
                Picker("Assistance", selection: $model.settings.questionAssistance) { ForEach(QuestionAssistance.allCases) { Text($0.rawValue).tag($0) } }
                Text("Detect only never generates an answer. Suggested answers stay on screen without speaking. Automatic answers follow your output choice below.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("Answer output", selection: $model.settings.outputMode) { ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                HStack { Text("Wait after speech"); Spacer(); Text(String(format: "%.1f s", model.settings.autoDelay)).monospacedDigit() }
                Slider(value: $model.settings.autoDelay, in: 0.7...4, step: 0.1).accessibilityLabel("Question detection pause")
            }
            settingsSection("Saved sessions", detail: "Text, summaries, questions and notes are saved locally. Audio chunks are held in memory only and are not saved as recordings.") {
                Toggle("Save sessions on this Mac", isOn: $model.settings.saveSessions).disabled(model.busyListening)
                Toggle("Generate a summary when listening ends", isOn: $model.settings.generateSummaries)
                Text("Turning off saved sessions affects new sessions. Existing sessions remain until you delete them from their session menu. Saved text is protected by your macOS account's file permissions, not a separate app encryption key.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            settingsSection("Voice", detail: "During spoken playback, transcription pauses to prevent the assistant from answering itself. Speech during that pause is not transcribed.") {
                HStack { Text("Voice speed"); Spacer(); Text("Slower → Faster").foregroundStyle(.secondary) }
                Slider(value: $model.settings.voiceRate, in: 0.35...0.65).accessibilityLabel("Voice speed")
                TextField("Voice language / locale", text: $model.settings.locale).textFieldStyle(.roundedBorder)
            }
            settingsSection("Optional context", detail: "Add a course name, project background or a note that would help interpret the conversation. This text is shared with the selected answer provider.") {
                TextEditor(text: $model.settings.backgroundContext).font(.system(size: 12)).frame(height: 100)
                    .scrollContentBackground(.hidden).padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Background context for answers")
            }
        }
    }
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 11, weight: .medium)); content() }
    }
    private func settingsSection<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            content().font(.system(size: 12))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
