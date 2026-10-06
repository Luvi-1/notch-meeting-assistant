import SwiftUI
import NotchCore

/// A glanceable command surface. Reading and editing belong in the companion window.
@MainActor
struct NotchView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedQuestionFingerprint = ""

    private var hasPreview: Bool { model.presentation.phase != .compact }
    private var busy: Bool { model.isListening || model.isStarting || model.isStopping }
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
            .contextMenu {
                Button("Open Notch") { openSession() }
                Button(model.presentation.pinned ? "Unpin preview" : "Keep preview visible") { model.togglePin() }
                Button("Settings") { model.openMain(.settings) }
                if busy {
                    Button(model.isStopping ? "Saving…" : "Stop listening") { Task { await finishListeningSession(model) } }
                        .disabled(model.isStopping)
                }
                if hasPreview { Button("Collapse") { model.collapse() } }
            }
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
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.83))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityLabel("Listening companion. \(model.status). Show controls.")

            // The physical camera housing always has its own unobstructed region.
            Color.clear.frame(width: model.cutoutWidth)

            HStack(spacing: 10) {
                if busy {
                    Text(model.isStopping ? "Saving…" : model.elapsedLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .accessibilityLabel("Session duration \(model.elapsedLabel)")
                } else if !hasPreview {
                    iconButton("arrow.up.right", label: "Open Notch") { model.openMain() }
                }
                if hasPreview {
                    if model.presentation.pinned {
                        iconButton("pin.fill", label: "Unpin preview") { model.togglePin() }
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
            ProgressView().controlSize(.mini).frame(width: 15, height: 15)
        } else {
            Image(systemName: model.error != nil ? "exclamationmark.circle" : (model.isSpeaking ? "speaker.wave.2" : "waveform"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(model.isListening || model.error != nil ? 0.9 : 0.45))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: model.isListening && !reduceMotion)
                .frame(width: 15, height: 15)
        }
    }

    @ViewBuilder private var glance: some View {
        if let error = model.error {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 19, weight: .light)).foregroundStyle(.white.opacity(0.6))
                VStack(alignment: .leading, spacing: 6) {
                    caption("Needs your attention")
                    Text(error).font(.system(size: 12)).lineLimit(2).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 8)
                Button("Settings") { model.openMain(.settings) }.buttonStyle(NotchActionStyle())
                iconButton("xmark", label: "Dismiss error") { model.error = nil; model.collapse() }
            }
            .padding(.horizontal, 24).padding(.top, 10)
        } else if let question = model.currentQuestion, busy || answeringHere {
            questionGlance(question)
        } else {
            controlsGlance
        }
    }

    private func questionGlance(_ question: SessionMoment) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: "questionmark").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75)).frame(width: 29, height: 29)
                .background(.white.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                caption(question.speaker.isEmpty ? "Question detected" : "Question · \(question.speaker)")
                Text(question.text).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(model.notchAnswer.isEmpty ? 2 : 1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !model.notchAnswer.isEmpty && model.settings.outputMode.showsText {
                    Text(model.notchAnswer).font(.system(size: 11)).foregroundStyle(.white.opacity(0.52)).lineLimit(2)
                        .accessibilityLabel("Suggested answer. \(model.notchAnswer)")
                }
            }
            HStack(spacing: 5) {
                Button(answeringHere ? "Thinking…" : "Answer") { model.answerCurrentQuestion() }
                    .buttonStyle(NotchActionStyle()).disabled(answeringHere || model.isStopping)
                let fingerprint = question.id.uuidString + model.notchAnswer
                iconButton(savedQuestionFingerprint == fingerprint ? "bookmark.fill" : "bookmark", label: savedQuestionFingerprint == fingerprint ? "Question saved" : "Save question and answer") {
                    model.saveCurrentQuestion()
                    savedQuestionFingerprint = fingerprint
                }
                .disabled(savedQuestionFingerprint == fingerprint)
                iconButton("arrow.up.right", label: "Expand question in session") { openSession() }
            }
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var controlsGlance: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.isStopping ? "Saving the last words." : (busy ? "Stay with the conversation." : "Ready when you are."))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.86))
                caption(busy ? "\(model.contextLabel) · \(model.transcript.lines.count) passages" : "A little help with everything you hear.")
            }
            Spacer(minLength: 10)
            if model.isStopping {
                Button("Finish now") { model.cancelFinishing() }.buttonStyle(NotchActionStyle())
                    .help("Save received transcript and cancel pending transcription")
            } else if busy {
                Button("Open session") { openSession() }.buttonStyle(NotchActionStyle())
                iconButton("stop.fill", label: model.isStarting ? "Cancel starting" : "Stop listening") {
                    Task { await finishListeningSession(model) }
                }
            } else {
                Button {
                    Task { await model.start() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform").font(.system(size: 11))
                        Text("Start Listening")
                    }
                }
                .buttonStyle(NotchActionStyle())
                iconButton("arrow.up.right", label: "Open Notch") { model.openMain() }
                iconButton("slider.horizontal.3", label: "Settings") { model.openMain(.settings) }
            }
        }
        .padding(.horizontal, 25).padding(.top, 15)
    }

    private func openSession() {
        model.openMain(model.activeSessionID == nil && model.selectedSessionID == nil ? .home : .sessions,
                       sessionID: model.activeSessionID ?? model.selectedSessionID)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55)).frame(width: 24, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct NotchActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.black.opacity(0.9))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(configuration.isPressed ? 0.76 : 0.94), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
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
