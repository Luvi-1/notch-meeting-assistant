import SwiftUI
import Speech
import NotchCore

/// Native settings keep credentials out of view state after saving and provider logic out of views.
@MainActor
struct ProviderSettingsView: View {
    @ObservedObject var model: MeetingModel
    @State private var transcriptionKeyDraft = ""

    private var audioIsBusy: Bool { model.isListening || model.isStarting || model.isStopping }
    private var usesAppleSpeech: Bool { model.settings.transcription.provider == .auto || model.settings.transcription.provider == .apple }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                CompanionPageHeader(eyebrow: "Make it yours", title: "Settings",
                                    subtitle: "Choose how Notch listens, helps, and remembers.")
                audioSettings
                sectionDivider
                assistanceSettings
                sectionDivider
                transcriptionSettings
                sectionDivider
                providerSettings
                sectionDivider
                taskSettings
            }
            .padding(.horizontal, 46).padding(.top, 52).padding(.bottom, 45)
        }
        .onDisappear { transcriptionKeyDraft = "" }
    }

    private var sectionDivider: some View { Rectangle().fill(Color.primary.opacity(0.075)).frame(height: 0.5) }

    private var audioSettings: some View {
        SettingsSection(title: "Listening", detail: "Start immediately. The session type is understood from the conversation.") {
            VStack(alignment: .leading, spacing: 17) {
                Toggle("Microphone", isOn: $model.settings.includeMicrophone)
                    .toggleStyle(.switch).controlSize(.small)
                Toggle("System audio", isOn: $model.settings.captureSystemAudio)
                    .toggleStyle(.switch).controlSize(.small)
                if model.settings.captureSystemAudio {
                    HStack(spacing: 12) {
                        Picker("Audio from", selection: $model.settings.applicationID) {
                            Text("All applications").tag("")
                            ForEach(model.applications) { app in Text(app.name).tag(app.id) }
                        }
                        Button {
                            Task { await model.refreshApplications() }
                        } label: {
                            if model.loadingApplications { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .buttonStyle(.plain).disabled(model.loadingApplications)
                        .help("Refresh applications").accessibilityLabel("Refresh audio applications")
                    }
                    .task { if model.applications.isEmpty { await model.refreshApplications() } }
                }
                Text("The microphone hears the room. System audio captures sound playing on your Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                Text("Labels identify audio inputs unless the transcription model supplies speakers.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(3)
                if !model.settings.includeMicrophone && !model.settings.captureSystemAudio {
                    Label("Choose at least one audio source.", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .disabled(audioIsBusy)
            if audioIsBusy {
                Text("Finish this session to change audio settings.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var assistanceSettings: some View {
        SettingsSection(title: "Question Assistance", detail: "Only questions surface at the notch. Other important moments are saved quietly.") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Assistance", selection: $model.settings.questionAssistance) {
                    ForEach(QuestionAssistance.allCases) { Text($0.displayName).tag($0) }
                }
                Text(assistanceDescription).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                if model.settings.questionAssistance != .off && model.settings.questionAssistance != .detectOnly {
                    HStack {
                        Text("Answer output")
                        Spacer()
                        Picker("Answer output", selection: $model.settings.outputMode) {
                            ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    }
                }
                if model.settings.outputMode.usesVoice {
                    HStack(spacing: 18) {
                        Text("Speaking pace")
                        Slider(value: $model.settings.voiceRate, in: 0.35...0.65)
                        Text(model.settings.voiceRate < 0.45 ? "Slower" : (model.settings.voiceRate > 0.55 ? "Faster" : "Natural"))
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 44)
                    }
                }
                HStack(spacing: 18) {
                    Text("Pause before detection")
                    Slider(value: $model.settings.autoDelay, in: 0.7...4, step: 0.1)
                    Text(String(format: "%.1fs", model.settings.autoDelay))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 38)
                }
                if !model.intelligenceStatus.isEmpty {
                    Text(model.intelligenceStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
        }
    }

    private var assistanceDescription: String {
        switch model.settings.questionAssistance {
        case .off: return "Keep listening without question previews or automatic answers."
        case .detectOnly: return "Show the question at the notch. Request an answer when you want one."
        case .suggestedAnswer: return "Show the question with a short suggested answer. Expand whenever you need more."
        case .automaticAnswer: return "Generate a full answer to detected questions using the selected output."
        }
    }

    private var transcriptionSettings: some View {
        SettingsSection(title: "Transcription", detail: "Audio goes only to the speech provider you select.") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Provider", selection: $model.settings.transcription.provider) {
                    ForEach(TranscriptionProviderID.allCases) { provider in
                        Text(provider == .auto ? "Auto — Recommended" : provider.displayName).tag(provider)
                    }
                }
                if usesAppleSpeech {
                    Text("Auto uses Apple Speech. Adding an AI key does not change where your audio is transcribed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    Picker("Speech language", selection: $model.settings.locale) {
                        ForEach(speechLocales, id: \.identifier) { locale in
                            Text(languageName(locale.identifier)).tag(locale.identifier)
                        }
                    }
                    Text("Apple Speech uses this language setting. Automatic language detection is available with Whisper providers.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 15) {
                        Text("Model").frame(width: 66, alignment: .leading)
                        TextField("Default for this provider", text: $model.settings.transcription.model)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        transcriptionModelMenu
                    }
                    if let keyProvider = transcriptionAIProvider {
                        HStack {
                            Label(model.providerHasKey(keyProvider) ? "API key saved" : "API key needed",
                                  systemImage: model.providerHasKey(keyProvider) ? "key.fill" : "key")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(model.providerConnected(keyProvider) ? "Manage key" : "Add API key") { model.configuringProvider = keyProvider }
                        }
                        .font(.system(size: 11))
                    }
                    HStack {
                        if !model.transcriptionModelsStatus.isEmpty {
                            Text(model.transcriptionModelsStatus).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Fetch models") { Task { await model.refreshTranscriptionModels() } }
                            .font(.system(size: 11))
                    }
                    if model.settings.transcription.provider == .localWhisper || model.settings.transcription.provider == .custom {
                        endpointAndKey
                    }
                    Toggle("Automatic language detection", isOn: $model.settings.transcription.autoDetectLanguage)
                        .toggleStyle(.switch).controlSize(.small)
                    if !model.settings.transcription.autoDetectLanguage {
                        HStack(spacing: 15) {
                            Text("Language code").frame(width: 100, alignment: .leading)
                            TextField("en, hi, pa…", text: $model.settings.transcription.language)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        }
                    }
                    Text(model.settings.transcription.provider == .localWhisper
                         ? "Audio is transcribed in short chunks by your local Whisper server."
                         : "Audio is sent in short chunks to this provider. Transcript updates follow each completed chunk.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                }
                Toggle("Keep speech recognition on this Mac", isOn: $model.settings.onDeviceOnly)
                    .toggleStyle(.switch).controlSize(.small)
                Text(model.settings.onDeviceOnly
                     ? "Requires Apple on-device recognition or a local Whisper server. AI features still use your configured providers."
                     : "Apple Speech may process audio remotely. AI features send selected transcript passages to your configured providers.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(3)
            }
            .font(.system(size: 12))
            .disabled(audioIsBusy)
        }
    }

    private var endpointAndKey: some View {
        VStack(alignment: .leading, spacing: 11) {
            LabeledContent("Base URL") {
                TextField(model.settings.transcription.provider == .localWhisper ? "http://127.0.0.1:8080/v1" : "https://your-server.example/v1",
                          text: $model.settings.transcription.baseURL)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            }
            if model.settings.transcription.provider == .localWhisper {
                Text("Requires a running Whisper-compatible server on this Mac. A blank URL uses 127.0.0.1:8080/v1.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                Text("Use the base URL of a server that supports the OpenAI audio transcriptions endpoint.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SecureField(model.transcriptionHasKey ? "Replace saved API key" : "API key (optional for a local server)", text: $transcriptionKeyDraft)
                .textFieldStyle(.roundedBorder).privacySensitive()
                .accessibilityLabel("Transcription API key")
                .onSubmit {
                    guard !transcriptionKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    model.saveTranscriptionKey(transcriptionKeyDraft)
                    transcriptionKeyDraft = ""
                }
            HStack {
                Button("Save key") {
                    model.saveTranscriptionKey(transcriptionKeyDraft)
                    transcriptionKeyDraft = ""
                }
                .disabled(transcriptionKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.transcriptionHasKey {
                    Button("Remove key") { model.removeTranscriptionKey(); transcriptionKeyDraft = "" }
                }
                Spacer()
                if model.transcriptionHasKey { Label("Saved in Keychain", systemImage: "lock").foregroundStyle(.secondary) }
            }
            .font(.system(size: 10))
            if !model.transcriptionKeyStatus.isEmpty {
                Text(model.transcriptionKeyStatus).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var transcriptionModelMenu: some View {
        if !model.transcriptionModels.isEmpty {
            Menu("Choose") {
                ForEach(model.transcriptionModels) { entry in
                    Button(entry.name) { model.settings.transcription.model = entry.id }
                }
            }
            .fixedSize()
        }
    }

    private var transcriptionAIProvider: AIProviderID? {
        switch model.settings.transcription.provider {
        case .openAI: return .openAI
        case .groq: return .groq
        default: return nil
        }
    }

    private var providerSettings: some View {
        SettingsSection(title: "AI Providers", detail: "Connect the models you like. Credentials are stored in macOS Keychain.") {
            VStack(spacing: 0) {
                ForEach(AIProviderID.allCases) { provider in
                    Button { model.configuringProvider = provider } label: {
                        HStack(spacing: 14) {
                            ProviderMark(provider: provider)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(provider.displayName).font(.system(size: 12, weight: .medium))
                                Text(providerSubtitle(provider)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(providerState(provider)).font(.system(size: 10)).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.leading, 9)
                        }
                        .padding(.vertical, 13).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func providerSubtitle(_ id: AIProviderID) -> String {
        let configuration = model.settings.providers.first { $0.id == id }
        if model.providerConnected(id), let name = configuration?.model, !name.isEmpty { return name }
        switch id {
        case .openAI: return "GPT models · Native Responses API"
        case .anthropic: return "Claude models"
        case .gemini: return "Gemini models · Native API"
        case .openRouter: return "Many models through one connection"
        case .groq: return "Fast language models + Whisper transcription"
        case .openCode: return "OpenCode's model gateway"
        case .custom: return "Your endpoint, your model"
        }
    }

    private func providerState(_ id: AIProviderID) -> String {
        let enabled = model.settings.providers.first { $0.id == id }?.enabled == true
        if model.providerConnected(id) { return enabled ? "Connected" : "Disabled" }
        return id == .custom ? "Add provider" : "Set up"
    }

    private var taskSettings: some View {
        SettingsSection(title: "Models for each task", detail: "Auto selects from your enabled, connected providers. A specific choice stays with that provider.") {
            VStack(alignment: .leading, spacing: 21) {
                ForEach(AITask.allCases) { task in TaskModelSettingsRow(model: model, task: task) }
            }
        }
    }

    private var speechLocales: [Locale] {
        var locales = SFSpeechRecognizer.supportedLocales()
        if !locales.contains(where: { $0.identifier == model.settings.locale }) {
            locales.insert(Locale(identifier: model.settings.locale))
        }
        return locales.sorted { languageName($0.identifier) < languageName($1.identifier) }
    }
    private func languageName(_ identifier: String) -> String { Locale.current.localizedString(forIdentifier: identifier) ?? identifier }
}

@MainActor
struct ProviderConfigurationView: View {
    @ObservedObject var model: MeetingModel
    let provider: AIProviderID
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var busy = false

    private var configuration: Binding<ProviderConfiguration> {
        Binding {
            model.settings.providers.first { $0.id == provider } ?? ProviderConfiguration.defaultConfiguration(for: provider)
        } set: { value in
            var settings = model.settings
            if let index = settings.providers.firstIndex(where: { $0.id == provider }) {
                settings.providers[index] = value
            } else {
                settings.providers.append(value)
            }
            model.settings = settings
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 13) {
                ProviderMark(provider: provider)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName).font(.system(size: 24, weight: .semibold)).tracking(-0.6)
                    Text("Provider configuration").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { keyDraft = ""; dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Toggle("Enable this provider", isOn: configuration.enabled)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    credentials
                    modelConfiguration
                    connectionConfiguration
                    if let status = model.providerStatuses[provider], !status.isEmpty {
                        Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button("Reset configuration") { model.resetProvider(provider) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        busy = true
                        await model.validateProvider(provider)
                        busy = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text("Check connection")
                    }
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(busy)
            }
        }
        .padding(29).frame(width: 555, height: 605)
        .background(CompanionPalette.canvas)
        .tint(.primary)
        .onDisappear { keyDraft = "" }
    }

    private var credentials: some View {
        SettingsSection(title: "API key", detail: model.providerHasKey(provider) ? "A credential is saved. Enter a new key only to replace it." : "Save a key to connect your account.") {
            SecureField(model.providerHasKey(provider) ? "Replace saved key" : "Paste API key", text: $keyDraft)
                .textFieldStyle(.roundedBorder).privacySensitive()
                .accessibilityLabel("\(provider.displayName) API key")
                .onSubmit {
                    guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    model.saveProviderKey(provider, key: keyDraft)
                    keyDraft = ""
                }
            HStack {
                Button("Save key") { model.saveProviderKey(provider, key: keyDraft); keyDraft = "" }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.providerHasKey(provider) {
                    Button("Remove key") { model.removeProviderKey(provider); keyDraft = "" }
                }
                Spacer()
                Label("macOS Keychain", systemImage: "lock").foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
            if provider == .custom {
                Text("A server running on localhost can be used without a key.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var modelConfiguration: some View {
        SettingsSection(title: "Default model", detail: "Use a model available to your account, or choose one from the provider.") {
            TextField("Model ID", text: configuration.model)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("Default model identifier")
            HStack {
                if let models = model.providerModels[provider], !models.isEmpty {
                    Menu("Choose model") {
                        ForEach(models) { entry in
                            Button(entry.name) {
                                configuration.wrappedValue.model = entry.id
                                if let apiProtocol = entry.apiProtocol { configuration.wrappedValue.apiProtocol = apiProtocol }
                            }
                        }
                    }
                    .frame(maxWidth: 310, alignment: .leading)
                }
                Spacer()
                Button("Fetch models") {
                    Task {
                        busy = true
                        await model.refreshProviderModels(provider)
                        busy = false
                    }
                }
                .disabled(busy)
            }
            .font(.system(size: 11))
            if provider == .openAI && configuration.wrappedValue.model == AnswerClient.astraModel {
                Toggle("Use Ultrafast service tier", isOn: configuration.ultrafast).font(.system(size: 11))
                Text("Uses your account's Ultrafast tier when available. Provider pricing applies.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionConfiguration: some View {
        SettingsSection(title: "Connection", detail: provider == .openCode ? "OpenCode models can use different API protocols. Match the protocol to the selected model." : nil) {
            LabeledContent("Base URL") {
                TextField("https://api.example.com/v1", text: configuration.baseURL)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            }
            .font(.system(size: 11))
            if provider == .custom || provider == .openCode || provider == .openAI {
                Picker("API protocol", selection: configuration.apiProtocol) {
                    ForEach(LLMAPIProtocol.allCases) { Text($0.displayName).tag($0) }
                }
                .font(.system(size: 11))
            } else {
                LabeledContent("API protocol", value: configuration.wrappedValue.apiProtocol.displayName)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct TaskModelSettingsRow: View {
    @ObservedObject var model: MeetingModel
    let task: AITask

    private var selection: ModelSelection { model.route(for: task) }
    private var provider: Binding<AIProviderID?> {
        Binding { selection.provider } set: { value in model.setRoute(ModelSelection(provider: value), for: task) }
    }
    private var modelName: Binding<String> {
        Binding { selection.model } set: { value in
            var route = selection
            route.model = value
            model.setRoute(route, for: task)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(task.displayName).font(.system(size: 12)).frame(width: 145, alignment: .leading).padding(.top, 5)
            VStack(alignment: .leading, spacing: 9) {
                Picker("Provider for \(task.displayName)", selection: provider) {
                    Text("Auto — Recommended").tag(Optional<AIProviderID>.none)
                    ForEach(AIProviderID.allCases) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }
                .labelsHidden()
                if let id = selection.provider {
                    HStack {
                        TextField("Use provider's default model", text: modelName)
                            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        if let models = model.providerModels[id], !models.isEmpty {
                            Menu {
                                Button("Use provider default") { modelName.wrappedValue = "" }
                                ForEach(models) { entry in
                                    Button(entry.name) { modelName.wrappedValue = entry.id }
                                }
                            } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Choose model for \(task.displayName)")
                        }
                    }
                    if !model.providerConnected(id) || model.settings.providers.first(where: { $0.id == id })?.enabled != true {
                        Button("Connect and enable \(id.displayName)") { model.configuringProvider = id }
                            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ProviderMark: View {
    let provider: AIProviderID

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .regular)).frame(width: 34, height: 34)
            .background(CompanionPalette.wash, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch provider {
        case .openAI: return "circle.hexagongrid"
        case .anthropic: return "a"
        case .gemini: return "sparkle"
        case .openRouter: return "arrow.triangle.branch"
        case .groq: return "bolt"
        case .openCode: return "chevron.left.forwardslash.chevron.right"
        case .custom: return "server.rack"
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                }
            }
            content
        }
    }
}
