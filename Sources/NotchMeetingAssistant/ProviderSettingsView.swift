import SwiftUI
import Speech
import NotchCore

enum CompanionSettingsTab: String, CaseIterable, Identifiable {
    case general = "General", transcription = "Transcription", providers = "AI providers", tasks = "Task models"
    var id: String { rawValue }
}

/// Configuration stays compact; saved credentials never return to a text field.
@MainActor
struct ProviderSettingsView: View {
    @ObservedObject var model: MeetingModel
    @State private var selectedTab: CompanionSettingsTab
    @State private var transcriptionKeyDraft = ""

    init(model: MeetingModel, initialTab: CompanionSettingsTab = .general) {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
    }

    private var audioIsBusy: Bool { model.isListening || model.isStarting || model.isStopping }
    private var usesAppleSpeech: Bool { model.settings.transcription.provider == .auto || model.settings.transcription.provider == .apple }
    private var transcriptionProvider: Binding<TranscriptionProviderID> {
        Binding { model.settings.transcription.provider } set: { model.setTranscriptionProvider($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CompanionPageHeader(eyebrow: "Preferences", title: "Settings",
                                    subtitle: "A few details that make Notch yours.")
                tabs
                Group {
                    switch selectedTab {
                    case .general:
                        audioSettings
                        settingsDivider
                        assistanceSettings
                    case .transcription: transcriptionSettings
                    case .providers: providerSettings
                    case .tasks: taskSettings
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
        }
        .background(CompanionPalette.canvas)
        .onChange(of: selectedTab) { _, _ in transcriptionKeyDraft = "" }
        .onDisappear { transcriptionKeyDraft = "" }
    }

    private var tabs: some View {
        HStack(spacing: 5) {
            ForEach(CompanionSettingsTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selectedTab == tab ? .medium : .regular))
                        .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(selectedTab == tab ? CompanionPalette.raised : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 11))
    }

    private var audioSettings: some View {
        SettingsSection(title: "Audio sources", detail: "Listen to the room, your Mac, or both.") {
            VStack(spacing: 0) {
                Toggle("Microphone", isOn: $model.settings.includeMicrophone)
                    .toggleStyle(.switch).controlSize(.small).frame(minHeight: 38)
                settingsDivider
                Toggle("System audio", isOn: $model.settings.captureSystemAudio)
                    .toggleStyle(.switch).controlSize(.small).frame(minHeight: 38)
                if model.settings.captureSystemAudio {
                    settingsDivider
                    SettingsValueRow("Audio from") {
                        Picker("Audio from", selection: $model.settings.applicationID) {
                            Text("All applications").tag("")
                            ForEach(model.applications) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        Button { Task { await model.refreshApplications() } } label: {
                            if model.loadingApplications { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .buttonStyle(.plain).disabled(model.loadingApplications)
                        .help("Refresh applications").accessibilityLabel("Refresh audio applications")
                    }
                    .task { if model.applications.isEmpty { await model.refreshApplications() } }
                }
            }
            .font(.system(size: 12))
            .disabled(audioIsBusy)
            if audioIsBusy {
                settingsHint("Finish this session to change audio sources.")
            } else if !model.settings.includeMicrophone && !model.settings.captureSystemAudio {
                settingsHint("Choose at least one source to start listening.", symbol: "exclamationmark.circle")
            }
        }
    }

    private var assistanceSettings: some View {
        SettingsSection(title: "Question assistance", detail: "Choose how much help appears while you listen.") {
            SettingsValueRow("When a question comes up") {
                Picker("Question assistance", selection: $model.settings.questionAssistance) {
                    ForEach(QuestionAssistance.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 270)
            }
            Text(assistanceDescription).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            if model.settings.questionAssistance != .off && model.settings.questionAssistance != .detectOnly {
                settingsDivider
                SettingsValueRow("Answer output") {
                    Picker("Answer output", selection: $model.settings.outputMode) {
                        ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 215)
                }
                if model.settings.outputMode.usesVoice {
                    SettingsValueRow("Speaking pace") {
                        Slider(value: $model.settings.voiceRate, in: 0.35...0.65).frame(maxWidth: 185)
                        Text(model.settings.voiceRate < 0.45 ? "Slower" : (model.settings.voiceRate > 0.55 ? "Faster" : "Natural"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 45)
                    }
                }
            }
            SettingsValueRow("Pause before detection") {
                Slider(value: $model.settings.autoDelay, in: 0.7...4, step: 0.1).frame(maxWidth: 185)
                Text(String(format: "%.1fs", model.settings.autoDelay))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 45)
            }
            if !model.intelligenceStatus.isEmpty {
                Text(model.intelligenceStatus).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var assistanceDescription: String {
        switch model.settings.questionAssistance {
        case .off: return "Keep listening and save important moments quietly."
        case .detectOnly: return "Preview the question. Ask for an answer whenever you want one."
        case .suggestedAnswer: return "Preview the question with a short suggested answer."
        case .automaticAnswer: return "Answer detected questions using your selected output."
        }
    }

    private var transcriptionSettings: some View {
        SettingsSection(title: "Speech recognition", detail: "Choose the service that turns audio into a transcript.") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsValueRow("Provider") {
                    Picker("Transcription provider", selection: transcriptionProvider) {
                        ForEach(TranscriptionProviderID.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                }
                settingsDivider
                if usesAppleSpeech {
                    SettingsValueRow("Speech language") {
                        Picker("Speech language", selection: $model.settings.locale) {
                            ForEach(speechLocales, id: \.identifier) { Text(languageName($0.identifier)).tag($0.identifier) }
                        }
                        .labelsHidden().frame(maxWidth: 280)
                    }
                    settingsHint("Auto uses Apple Speech with this language. Whisper providers also support automatic language detection.")
                } else {
                    speechModelSettings
                    if let provider = transcriptionAIProvider {
                        settingsDivider
                        SettingsValueRow("API key") {
                            Label(model.providerHasKey(provider) ? "Saved in Keychain" : "Not connected",
                                  systemImage: model.providerHasKey(provider) ? "checkmark.circle" : "key")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Button(model.providerHasKey(provider) ? "Manage" : "Connect \(provider.displayName)") {
                                model.configuringProvider = provider
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                        settingsHint("Uses your \(provider.displayName) key. Language models for answering are configured separately in AI providers.")
                    }
                    if model.settings.transcription.provider == .localWhisper || model.settings.transcription.provider == .custom {
                        settingsDivider
                        endpointAndKey
                    }
                    settingsDivider
                    Toggle("Automatic language detection", isOn: $model.settings.transcription.autoDetectLanguage)
                        .toggleStyle(.switch).controlSize(.small).frame(minHeight: 36)
                    if !model.settings.transcription.autoDetectLanguage {
                        SettingsValueRow("Language code") {
                            SettingsTextField(placeholder: "en, hi, pa…", text: $model.settings.transcription.language)
                                .frame(maxWidth: 170)
                        }
                    }
                    settingsHint(model.settings.transcription.provider == .localWhisper
                                 ? "Short audio clips are transcribed by your local Whisper server."
                                 : "Short audio clips are sent to this provider. The transcript updates as each clip completes.")
                }
                settingsDivider
                Toggle("Keep speech recognition on this Mac", isOn: $model.settings.onDeviceOnly)
                    .toggleStyle(.switch).controlSize(.small).frame(minHeight: 36)
                settingsHint(model.settings.onDeviceOnly
                             ? "Requires Apple on-device recognition or Local Whisper. AI answers still use your configured providers."
                             : "Apple Speech may process audio remotely. AI features use selected transcript passages.")
            }
            .font(.system(size: 12))
            .disabled(audioIsBusy)
            if audioIsBusy { settingsHint("Finish this session to change transcription settings.") }
        }
    }

    private var speechModelSettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            SettingsValueRow("Speech model") {
                SettingsTextField(placeholder: defaultSpeechModel.isEmpty ? "Model ID" : defaultSpeechModel,
                                  text: $model.settings.transcription.model, monospaced: true)
                    .frame(maxWidth: 290)
                Menu {
                    if !defaultSpeechModel.isEmpty {
                        Button("Provider default · \(defaultSpeechModel)") { model.settings.transcription.model = "" }
                    }
                    ForEach(model.transcriptionModels) { entry in
                        Button(entry.name) { model.settings.transcription.model = entry.id }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(defaultSpeechModel.isEmpty && model.transcriptionModels.isEmpty)
                .accessibilityLabel("Choose speech model")
            }
            HStack(spacing: 12) {
                if model.settings.transcription.provider == .groq || model.settings.transcription.provider == .openAI {
                    Button("Restore provider defaults") { model.resetTranscriptionConfiguration() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loadingTranscriptionModels { ProgressView().controlSize(.mini) }
                Button("Refresh speech models") { Task { await model.refreshTranscriptionModels() } }
                    .buttonStyle(.plain).disabled(model.loadingTranscriptionModels || !canFetchSpeechModels)
            }
            .font(.system(size: 11))
            if !model.transcriptionModelsStatus.isEmpty {
                Text(model.transcriptionModelsStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var defaultSpeechModel: String {
        TranscriptionConfiguration(provider: model.settings.transcription.provider).resolvedModel
    }
    private var canFetchSpeechModels: Bool {
        if let provider = transcriptionAIProvider { return model.providerHasKey(provider) }
        return true
    }
    private var transcriptionAIProvider: AIProviderID? {
        switch model.settings.transcription.provider {
        case .openAI: return .openAI
        case .groq: return .groq
        default: return nil
        }
    }

    private var endpointAndKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsValueRow("Server URL") {
                SettingsTextField(placeholder: model.settings.transcription.provider == .localWhisper
                                  ? "http://127.0.0.1:8080/v1" : "https://your-server.example/v1",
                                  text: $model.settings.transcription.baseURL, monospaced: true)
                    .frame(maxWidth: 340)
            }
            settingsHint(model.settings.transcription.provider == .localWhisper
                         ? "Use a Whisper-compatible server running on this Mac. A blank URL uses 127.0.0.1:8080/v1."
                         : "Enter the base URL of an OpenAI-compatible audio transcription server.")
            HStack(spacing: 10) {
                SecureField(model.transcriptionHasKey ? "Replace saved API key" : "API key", text: $transcriptionKeyDraft)
                    .textFieldStyle(.plain).privacySensitive().padding(.horizontal, 10).frame(height: 34)
                    .background(CompanionPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Custom transcription API key").onSubmit(saveTranscriptionKey)
                Button("Save") { saveTranscriptionKey() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(transcriptionKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                settingsHint(model.transcriptionHasKey ? "Key saved in macOS Keychain." : "A local server can be used without a key.", symbol: "lock")
                Spacer()
                if model.transcriptionHasKey {
                    Button("Remove key") { model.removeTranscriptionKey(); transcriptionKeyDraft = "" }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if !model.transcriptionKeyStatus.isEmpty {
                Text(model.transcriptionKeyStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func saveTranscriptionKey() {
        guard model.saveTranscriptionKey(transcriptionKeyDraft) else { return }
        transcriptionKeyDraft = ""
    }

    private var providerSettings: some View {
        SettingsSection(title: "Connections", detail: "One key per provider. Choose a language model for answers and analysis.") {
            VStack(spacing: 0) {
                ForEach(AIProviderID.allCases) { provider in
                    Button { model.configuringProvider = provider } label: {
                        HStack(spacing: 13) {
                            ProviderMark(provider: provider)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.displayName).font(.system(size: 13, weight: .medium))
                                Text(providerSubtitle(provider)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 16)
                            Text(providerState(provider)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 13).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if provider != AIProviderID.allCases.last { settingsDivider.padding(.leading, 47) }
                }
            }
            settingsHint("Credentials are saved in macOS Keychain and remain hidden after saving.", symbol: "lock")
        }
    }

    private func providerSubtitle(_ provider: AIProviderID) -> String {
        if model.providerConnected(provider), let configuration = model.settings.providers.first(where: { $0.id == provider }), !configuration.model.isEmpty {
            return configuration.model
        }
        switch provider {
        case .openAI: return "GPT models"
        case .anthropic: return "Claude models"
        case .gemini: return "Gemini models"
        case .openRouter: return "A catalogue of models, one connection"
        case .groq: return "Fast answers and Whisper transcription"
        case .openCode: return "OpenCode's model gateway"
        case .custom: return "Connect your own model endpoint"
        }
    }
    private func providerState(_ provider: AIProviderID) -> String {
        let enabled = model.settings.providers.first(where: { $0.id == provider })?.enabled == true
        if model.providerConnected(provider) { return enabled ? "Configured" : "Off" }
        return "Connect"
    }

    private var taskSettings: some View {
        SettingsSection(title: "The right model for the moment", detail: "Auto chooses from your enabled providers. Set a specific model whenever you prefer.") {
            VStack(spacing: 0) {
                ForEach(AITask.allCases) { task in
                    TaskModelSettingsRow(model: model, task: task).padding(.vertical, 15)
                    if task != AITask.allCases.last { settingsDivider }
                }
            }
        }
    }

    private var speechLocales: [Locale] {
        var locales = SFSpeechRecognizer.supportedLocales()
        if !locales.contains(where: { $0.identifier == model.settings.locale }) { locales.insert(Locale(identifier: model.settings.locale)) }
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
    @State private var replacingKey = false

    private var isBusy: Bool { model.loadingProviderModels.contains(provider) || model.checkingProviders.contains(provider) }
    private var configuration: Binding<ProviderConfiguration> {
        Binding {
            model.settings.providers.first(where: { $0.id == provider }) ?? ProviderConfiguration.defaultConfiguration(for: provider)
        } set: { model.updateProviderConfiguration($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProviderMark(provider: provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName).font(.system(size: 24, weight: .semibold)).tracking(-0.6)
                    Text("Connection settings").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { keyDraft = ""; dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26)
                        .background(CompanionPalette.raised, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close provider settings")
            }
            .padding(24)
            settingsDivider
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Toggle("Use this provider", isOn: configuration.enabled)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    credentials
                    settingsDivider
                    modelConfiguration
                    if provider == .custom {
                        settingsDivider
                        connectionConfiguration
                    }
                    if let status = model.providerStatuses[provider], !status.isEmpty {
                        settingsHint(status).textSelection(.enabled)
                    }
                }
                .padding(24)
            }
            settingsDivider
            HStack(spacing: 14) {
                Button("Restore defaults") { model.resetProvider(provider) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.validateProvider(provider) } } label: {
                    HStack(spacing: 8) {
                        if model.checkingProviders.contains(provider) { ProgressView().controlSize(.mini) }
                        Text("Check connection")
                    }
                }
                .buttonStyle(CompanionPrimaryButtonStyle()).controlSize(.small)
                .disabled(isBusy || !model.providerConnected(provider))
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
        .frame(width: 530, height: provider == .custom ? 670 : 550)
        .background(CompanionPalette.canvas)
        .tint(.primary)
        .onDisappear { keyDraft = ""; replacingKey = false }
    }

    private var credentials: some View {
        SettingsSection(title: "API key", detail: provider == .groq || provider == .openAI
                        ? "This key can also be used for speech transcription." : nil) {
            if model.providerHasKey(provider) && !replacingKey {
                HStack(spacing: 10) {
                    Label("Saved in Keychain", systemImage: "lock.fill")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace") { replacingKey = true }
                    Button("Remove") { model.removeProviderKey(provider); keyDraft = "" }
                }
                .font(.system(size: 11)).buttonStyle(.plain)
            } else {
                HStack(spacing: 10) {
                    SecureField(model.providerHasKey(provider) ? "Paste a replacement key" : "Paste API key", text: $keyDraft)
                        .textFieldStyle(.plain).privacySensitive().padding(.horizontal, 10).frame(height: 36)
                        .background(CompanionPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("\(provider.displayName) API key").onSubmit(saveKey)
                    Button("Save") { saveKey() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.providerHasKey(provider) {
                    Button("Cancel replacement") { keyDraft = ""; replacingKey = false }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if provider == .custom { settingsHint("Localhost servers can be used without a key.") }
        }
    }

    private func saveKey() {
        guard model.saveProviderKey(provider, key: keyDraft) else { return }
        keyDraft = ""
        replacingKey = false
        Task { await model.refreshProviderModels(provider) }
    }

    private var modelConfiguration: some View {
        SettingsSection(title: "Answering model", detail: "The default language model for this connection.") {
            HStack(spacing: 10) {
                SettingsTextField(placeholder: "Model ID", text: configuration.model, monospaced: true)
                if let models = model.providerModels[provider], !models.isEmpty {
                    Menu {
                        ForEach(models) { entry in
                            Button(entry.name) { model.selectProviderModel(entry, for: provider) }
                        }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Choose answering model")
                }
            }
            HStack {
                if model.loadingProviderModels.contains(provider) { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Refresh available models") { Task { await model.refreshProviderModels(provider) } }
                    .font(.system(size: 11)).buttonStyle(.plain)
                    .disabled(isBusy || !model.providerConnected(provider))
            }
            if provider == .groq {
                settingsHint("Choose a language model for answers here. Whisper speech models are selected under Transcription.")
            }
            if provider == .openCode {
                SettingsValueRow("Model protocol") {
                    Picker("OpenCode model protocol", selection: configuration.apiProtocol) {
                        ForEach(LLMAPIProtocol.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().font(.system(size: 11)).frame(maxWidth: 260)
                }
                settingsHint("Catalogue selections set the protocol when provided. Choose it here when a model needs a different protocol.")
            }
            if provider == .openAI {
                DisclosureGroup("API compatibility") {
                    SettingsValueRow("Protocol") {
                        Picker("OpenAI API protocol", selection: configuration.apiProtocol) {
                            Text(LLMAPIProtocol.responses.displayName).tag(LLMAPIProtocol.responses)
                            Text(LLMAPIProtocol.chatCompletions.displayName).tag(LLMAPIProtocol.chatCompletions)
                        }
                        .labelsHidden().frame(maxWidth: 260)
                    }
                }
                .font(.system(size: 11))
            }
            if provider == .openAI && configuration.wrappedValue.model == AnswerClient.astraModel {
                Toggle("Use Ultrafast service tier", isOn: configuration.ultrafast)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                settingsHint("Uses your account's Ultrafast tier when available. Provider pricing applies.")
            }
        }
    }

    private var connectionConfiguration: some View {
        SettingsSection(title: "Server", detail: "Use your endpoint's base URL and supported API protocol.") {
            SettingsTextField(placeholder: "https://api.example.com/v1", text: configuration.baseURL, monospaced: true)
            Picker("API protocol", selection: configuration.apiProtocol) {
                ForEach(LLMAPIProtocol.allCases) { Text($0.displayName).tag($0) }
            }
            .font(.system(size: 12))
        }
    }
}

@MainActor
private struct TaskModelSettingsRow: View {
    @ObservedObject var model: MeetingModel
    let task: AITask
    private var selection: ModelSelection { model.route(for: task) }
    private var provider: Binding<AIProviderID?> {
        Binding { selection.provider } set: { model.setRoute(ModelSelection(provider: $0), for: task) }
    }
    private var modelName: Binding<String> {
        Binding { selection.model } set: {
            var route = selection
            route.model = $0
            model.setRoute(route, for: task)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Text(task.displayName).font(.system(size: 12, weight: .medium)).frame(width: 160, alignment: .leading).padding(.top, 7)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider for \(task.displayName)", selection: provider) {
                    Text("Auto — Recommended").tag(Optional<AIProviderID>.none)
                    ForEach(AIProviderID.allCases) { Text($0.displayName).tag(Optional($0)) }
                }
                .labelsHidden()
                if let selected = selection.provider {
                    HStack(spacing: 10) {
                        SettingsTextField(placeholder: "Use provider's default model", text: modelName, monospaced: true)
                        if let models = model.providerModels[selected], !models.isEmpty {
                            Menu {
                                Button("Use provider default") { modelName.wrappedValue = "" }
                                ForEach(models) { entry in Button(entry.name) { modelName.wrappedValue = entry.id } }
                            } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Choose model for \(task.displayName)")
                        }
                    }
                    if !model.providerConnected(selected) || model.settings.providers.first(where: { $0.id == selected })?.enabled != true {
                        Button("Connect \(selected.displayName)") { model.configuringProvider = selected }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ProviderMark: View {
    let provider: AIProviderID
    var body: some View {
        Group {
            switch provider {
            case .anthropic: Text("A").font(.system(size: 17, weight: .semibold, design: .serif))
            case .groq: Text("g").font(.system(size: 21, weight: .semibold, design: .rounded))
            case .openAI: Image(systemName: "circle.hexagongrid").font(.system(size: 16))
            case .gemini: Image(systemName: "sparkle").font(.system(size: 16))
            case .openRouter: Image(systemName: "arrow.triangle.branch").font(.system(size: 16))
            case .openCode: Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 14))
            case .custom: Image(systemName: "server.rack").font(.system(size: 15))
            }
        }
        .frame(width: 34, height: 34)
        .background(CompanionPalette.raised, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3) }
            }
            content
        }
    }
}

private struct SettingsValueRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 12)).frame(minWidth: 125, alignment: .leading)
            Spacer(minLength: 6)
            content
        }
        .frame(minHeight: 38)
    }
}

private struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 10).frame(height: 34)
            .background(CompanionPalette.raised, in: RoundedRectangle(cornerRadius: 7))
    }
}

private var settingsDivider: some View { Rectangle().fill(CompanionPalette.hairline).frame(height: 1) }

private func settingsHint(_ text: String, symbol: String? = nil) -> some View {
    HStack(alignment: .top, spacing: 7) {
        if let symbol { Image(systemName: symbol).font(.system(size: 10)).padding(.top, 1) }
        Text(text).font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(.secondary)
}
