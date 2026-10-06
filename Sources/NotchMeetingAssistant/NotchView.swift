import SwiftUI
import NotchCore

/// The notch is a glanceable surface. Reading, settings and editing live in a separate window.
@MainActor
struct NotchView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedQuestionFingerprint = ""

    private var hasPreview: Bool { model.presentation.phase != .compact }
    private var answeringHere: Bool {
        model.isAnswering && model.displayedAnswerSessionID == model.activeSessionID && model.answerMomentID == model.currentQuestion?.id
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                listeningBar
                if hasPreview {
                    glance
                        .frame(height: 86, alignment: .top)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -3)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(.black)
            .clipShape(NotchSilhouette(detached: model.detachedNotch))
            .contentShape(NotchSilhouette(detached: model.detachedNotch))
            .onHover { model.hover($0) }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.91), value: model.presentation.phase)
        .onExitCommand { model.collapse() }
    }

    private var listeningBar: some View {
        HStack(spacing: 0) {
            Button { model.openNotch() } label: {
                HStack(spacing: 8) {
                    activityMark
                    if model.detachedNotch || hasPreview {
                        Text(model.isStopping ? "Saving…" : (model.isListening ? "Listening" : (model.isStarting ? "Starting" : "Notch")))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Listening companion. \(model.status). Show controls.")

            // Never place content behind the physical camera housing.
            Color.clear.frame(width: model.cutoutWidth)

            HStack(spacing: 9) {
                if model.isListening || model.isStarting || model.isStopping {
                    Text(model.isStopping ? "Saving…" : model.elapsedLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityLabel("Session duration \(model.elapsedLabel)")
                    if hasPreview {
                        iconButton("stop.fill", label: "Stop listening") { Task { await finishListeningSession(model) } }
                            .disabled(model.isStopping)
                    }
                } else {
                    iconButton("arrow.up.forward", label: "Open Notch") { model.openMain() }
                }
                if hasPreview {
                    iconButton(model.presentation.pinned ? "pin.fill" : "pin", label: model.presentation.pinned ? "Unpin preview" : "Keep preview visible") {
                        model.togglePin()
                    }
                    iconButton("chevron.up", label: "Collapse notch") { model.collapse() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, model.detachedNotch ? 15 : 20)
        .frame(height: model.cutoutHeight)
    }

    @ViewBuilder private var activityMark: some View {
        if model.isStarting || model.isStopping || answeringHere {
            ProgressView().controlSize(.mini).frame(width: 16, height: 16)
        } else {
            Image(systemName: model.error != nil ? "exclamationmark.circle" : (model.isSpeaking ? "speaker.wave.2" : "waveform"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(model.isListening || model.error != nil ? 1 : 0.5))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: model.isListening && !reduceMotion)
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder private var glance: some View {
        if let error = model.error {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    caption("Needs your attention")
                    Spacer()
                    Button("Settings") { model.openMain(.settings) }
                    Button("Dismiss") { model.error = nil; model.collapse() }
                }
                Text(error).font(.system(size: 12)).lineLimit(2).foregroundStyle(.white.opacity(0.85))
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.top, 8)
        } else if let question = model.currentQuestion {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    caption("Question detected")
                    if !question.speaker.isEmpty {
                        Text(question.speaker).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(answeringHere ? "Thinking…" : "Answer") { model.answerCurrentQuestion() }
                        .disabled(answeringHere || model.isStopping)
                    let fingerprint = question.id.uuidString + model.notchAnswer
                    Button(savedQuestionFingerprint == fingerprint ? "Saved" : "Save") {
                        model.saveCurrentQuestion()
                        savedQuestionFingerprint = fingerprint
                    }
                    .disabled(savedQuestionFingerprint == fingerprint)
                    Button("Expand") { openSession() }
                }
                .font(.system(size: 10, weight: .medium))
                Text(question.text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(model.notchAnswer.isEmpty ? 2 : 1)
                    .truncationMode(.tail)
                if !model.notchAnswer.isEmpty && model.settings.outputMode.showsText {
                    Text(model.notchAnswer)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .accessibilityLabel("Suggested answer. \(model.notchAnswer)")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.top, 5).padding(.bottom, 8)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    caption(model.isListening ? "\(model.contextLabel) · \(model.transcript.lines.count) passages" : "Ready when you are")
                    Spacer()
                    Button(model.isListening ? "Open session" : "Open Notch") { openSession() }
                        .font(.system(size: 10, weight: .medium))
                }
                Text(model.isListening ? "Stay with the conversation. Questions will appear here." : "A quiet companion for everything you hear.")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.8))
                if model.isListening {
                    Text(model.isStopping ? "Saving the last words…" : "Transcribing · Important moments are saved quietly")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.top, 7)
        }
    }

    private func openSession() {
        model.openMain(model.activeSessionID == nil && model.selectedSessionID == nil ? .home : .sessions,
                       sessionID: model.activeSessionID ?? model.selectedSessionID)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 25).contentShape(Rectangle())
        }
        .help(label).accessibilityLabel(label)
    }
}

private struct NotchSilhouette: Shape {
    var detached: Bool

    func path(in rect: CGRect) -> Path {
        if detached {
            return RoundedRectangle(cornerRadius: min(23, rect.height / 2), style: .continuous).path(in: rect)
        }
        let radius = min(22.0, rect.height / 2)
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.width - 8, y: 9), control: CGPoint(x: rect.width - 8, y: 0))
        path.addLine(to: CGPoint(x: rect.width - 8, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: rect.width - 8 - radius, y: rect.height), control: CGPoint(x: rect.width - 8, y: rect.height))
        path.addLine(to: CGPoint(x: 8 + radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: 8, y: rect.height - radius), control: CGPoint(x: 8, y: rect.height))
        path.addLine(to: CGPoint(x: 8, y: 9))
        path.addQuadCurve(to: .zero, control: CGPoint(x: 8, y: 0))
        path.closeSubpath()
        return path
    }
}
