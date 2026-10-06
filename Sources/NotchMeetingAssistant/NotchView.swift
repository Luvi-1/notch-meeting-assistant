import SwiftUI
import NotchCore

@MainActor
struct NotchView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var typing: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                statusBar
                if model.presentation.phase == .preview {
                    questionPreview.transition(.opacity)
                } else if model.expanded {
                    controls.transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(.black)
            .clipShape(NotchSilhouette(detached: model.detachedNotch))
            .overlay(NotchSilhouette(detached: model.detachedNotch).stroke(.white.opacity(0.07), lineWidth: 0.5))
            .contentShape(NotchSilhouette(detached: model.detachedNotch))
            .onHover { model.hover($0) }
        }
        .foregroundStyle(.white).tint(.white).environment(\.colorScheme, .dark)
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: model.presentation.phase)
        .onChange(of: typing) { _, value in model.setEditing(value) }
        .onChange(of: model.presentation.phase) { _, value in if value == .compact { typing = false } }
        .onExitCommand { typing = false; model.collapse() }
    }
    private var statusBar: some View {
        HStack(spacing: 0) {
            Button { model.openNotch() } label: {
                HStack(spacing: 7) {
                    waveform
                    if model.presentation.phase != .compact || model.detachedNotch {
                        Text(model.isListening ? "Listening" : "Notch").font(.system(size: 10, weight: .medium))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.accessibilityLabel("\(model.status). Open listening controls")
            Color.clear.frame(width: model.cutoutWidth)
            HStack(spacing: 10) {
                if let session = model.activeSession {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = Int(max(0, context.date.timeIntervalSince(session.startedAt)))
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
                    }
                }
                if model.busyCapture {
                    icon("stop.fill", "Stop listening") { Task { await model.stop() } }
                } else { icon("chevron.down", "Open listening controls") { model.openNotch() } }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 16).frame(height: model.cutoutHeight)
    }
    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let factor = [0.5, 0.8, 1.0, 0.65, 0.4][index]
                Capsule().fill(.white.opacity(model.isListening ? 0.95 : 0.45))
                    .frame(width: 2, height: model.isListening ? 3 + 12 * model.audioLevel * factor : Double(index % 2 == 0 ? 6 : 10))
            }
        }.frame(width: 18, height: 18)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.audioLevel)
            .accessibilityLabel(model.isListening ? "Microphone activity" : "Not listening")
    }
    private var questionPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = model.error {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    icon("xmark", "Dismiss message") { model.error = nil; model.collapse() }
                }
                Button(model.needsRecordingPermission ? "Open Privacy Settings" : "Open settings") {
                    if model.needsRecordingPermission { model.openRecordingSettings() } else { model.openLibrary(.settings) }
                }.font(.system(size: 10, weight: .semibold))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.latestQuestion.isEmpty ? model.answerQuestion : model.latestQuestion)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.isAnswering { ProgressView().controlSize(.mini) }
                    Button("Answer") { model.requestAnswer(text: model.latestQuestion) }
                        .disabled(model.isAnswering).font(.system(size: 10, weight: .medium))
                    Button("Save") { if model.answerComplete { model.saveAnswer() } else { model.saveQuestion() } }
                        .font(.system(size: 10, weight: .medium))
                    Button("Expand") {
                        if let id = model.activeSessionID ?? model.selectedSessionID { model.openSession(id) }
                        else { model.openLibrary(.sessions) }
                    }.font(.system(size: 10, weight: .medium))
                }
                Text(previewText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 12)
    }
    private var previewText: String {
        if !model.settings.outputMode.showsText { return model.isSpeaking ? "Speaking your answer…" : "Question detected. Choose Answer to hear assistance." }
        if !model.answer.isEmpty && model.answerQuestion == model.latestQuestion { return model.answer }
        if model.isAnswering { return "Considering the conversation…" }
        return "Question detected · tap Answer for help with this moment."
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isListening ? "Stay in the moment." : "A little space to think.")
                        .font(.system(size: 19, weight: .semibold))
                    Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                icon("rectangle.on.rectangle", "Open your library") { model.openLibrary(.home) }
                icon("slider.horizontal.3", "Settings") { model.openLibrary(.settings) }
                icon("chevron.up", "Collapse notch") { typing = false; model.collapse() }
            }
            if let error = model.error {
                HStack {
                    Text(error).font(.system(size: 10)).lineLimit(2)
                    Spacer()
                    icon("xmark", "Dismiss message") { model.error = nil }
                }.foregroundStyle(.secondary)
            }
            if !model.busyCapture {
                Toggle("I have permission to transcribe everyone here.", isOn: $model.hasConsent)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Text(model.audioDisclosure).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
                Button { Task { await model.start() } } label: {
                    Label("Start Listening", systemImage: "waveform").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(.black).background(.white, in: Capsule())
                }.disabled(!model.hasConsent || model.loadingLibrary)
            } else {
                Text(model.intelligenceStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    TextField("Ask about this moment…", text: $model.question).textFieldStyle(.plain).focused($typing)
                        .font(.system(size: 12)).onSubmit { typing = false; model.requestAnswer() }
                    icon(model.isAnswering ? "stop.circle" : "arrow.up.circle.fill", model.isAnswering ? "Cancel answer" : "Ask") {
                        typing = false
                        if model.isAnswering { model.cancelAnswer() } else { model.requestAnswer() }
                    }
                }.padding(11).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Picker("Answer output", selection: $model.settings.outputMode) {
                        ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Spacer()
                    Button(model.isStopping ? "Saving…" : "Stop & review") { Task { await model.stop() } }
                        .font(.system(size: 11, weight: .medium)).disabled(model.isStopping)
                }
            }
        }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 20)
    }
    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 20, height: 22).contentShape(Rectangle()) }
            .help(label).accessibilityLabel(label)
    }
}

private struct NotchSilhouette: Shape {
    var detached: Bool
    func path(in rect: CGRect) -> Path {
        if detached { return RoundedRectangle(cornerRadius: min(22, rect.height / 2), style: .continuous).path(in: rect) }
        return UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 24, bottomTrailingRadius: 24, topTrailingRadius: 8, style: .continuous).path(in: rect)
    }
}
