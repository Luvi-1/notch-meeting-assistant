import SwiftUI
import NotchCore

@MainActor
struct NotchView: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if model.presentation.phase == .preview { questionPreview.transition(.opacity) }
                else if model.expanded { controls.transition(.opacity) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(.black)
            .clipShape(NotchShape(detached: model.detachedNotch))
            .overlay(NotchShape(detached: model.detachedNotch).stroke(.white.opacity(0.06), lineWidth: 0.5))
            .contentShape(NotchShape(detached: model.detachedNotch))
            .onHover { model.hover($0) }
        }
        .foregroundStyle(.white).tint(.white).environment(\.colorScheme, .dark)
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.presentation.phase)
        .onExitCommand { model.collapse() }
    }
    private var header: some View {
        HStack(spacing: 0) {
            Button { model.openNotch() } label: {
                HStack(spacing: 7) {
                    WaveformMark(level: model.audioLevel, active: model.isListening, reduceMotion: reduceMotion)
                    if model.presentation.phase != .compact || model.detachedNotch { Text(model.isListening ? "Listening" : "Notch").font(.system(size: 10, weight: .medium)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.accessibilityLabel("Open listening controls. \(model.status)")
            Color.clear.frame(width: model.cutoutWidth)
            HStack(spacing: 10) {
                if model.busyListening {
                    Text(model.elapsed).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                    Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").font(.system(size: 8)).frame(width: 18, height: 24) }
                        .disabled(model.isStopping).accessibilityLabel("Stop Listening")
                } else {
                    Button { model.showLibrary() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).frame(width: 20, height: 24) }
                        .accessibilityLabel("Open Notch library")
                }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 16).frame(height: model.cutoutHeight)
    }
    private var questionPreview: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle").font(.system(size: 11))
                    Text(model.notice == nil ? "Your answer" : "Question detected").font(.system(size: 10, weight: .medium))
                    if model.isAnswering { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                }.foregroundStyle(.white.opacity(0.5))
                Text(model.notice?.text ?? model.previewAnswer).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !model.previewAnswer.isEmpty, model.notice != nil {
                    Text(model.settings.outputMode.showsText || model.settings.questionAssistance == .suggest ? model.previewAnswer : "Spoken answer ready")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                Button { model.answerNotice() } label: { Image(systemName: "arrow.turn.down.right").font(.system(size: 13)) }
                    .disabled(model.isAnswering).help("Answer").accessibilityLabel("Answer question")
                Button { model.saveNotice() } label: { Image(systemName: model.notice?.saved == true ? "bookmark.fill" : "bookmark").font(.system(size: 13)) }
                    .disabled(model.notice == nil).help("Save").accessibilityLabel("Save question")
                Button { model.showCurrentSession() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)) }
                    .help("Expand").accessibilityLabel("Expand in session window")
            }.foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 23).padding(.top, 7).padding(.bottom, 17).frame(maxHeight: .infinity, alignment: .top)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.status).font(.system(size: 17, weight: .medium))
                Spacer()
                Button { model.showLibrary(.settings) } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Settings")
            }
            Text(model.isListening ? (model.activeSession?.topic.isEmpty == false ? model.activeSession!.topic : "Questions appear here. Everything else stays quietly in your session.") : "Lectures, conversations, and everything in between.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            HStack(spacing: 14) {
                if model.busyListening {
                    Button("Open session") { model.showCurrentSession() }; Spacer()
                    Button(model.isStopping ? "Finishing…" : "Stop Listening") { Task { await model.stop() } }.disabled(model.isStopping)
                } else {
                    Button("Open library") { model.showLibrary() }; Spacer()
                    Button("Start Listening") {
                        if model.hasConsent { Task { await model.start() } }
                        else { model.showLibrary(.home) }
                    }
                }
            }.font(.system(size: 11, weight: .medium))
            if model.error != nil { Button("Review an issue") { model.showLibrary() }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)) }
        }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
    }
}

struct WaveformMark: View {
    let level: Double
    let active: Bool
    var reduceMotion = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in Capsule().fill(.primary.opacity(active ? 0.9 : 0.45)).frame(width: 2, height: height(index)) }
        }
        .frame(width: 19, height: 17).animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityLabel(active ? "Audio input activity" : "Not listening")
    }
    private func height(_ index: Int) -> CGFloat {
        guard active else { return [4, 8, 12, 8, 4][index] }
        if reduceMotion { return 9 }
        return 3 + CGFloat(min(1, max(0, level))) * [7, 11, 15, 10, 6][index]
    }
}

struct NotchShape: Shape {
    var detached = false
    func path(in r: CGRect) -> Path {
        if detached { return RoundedRectangle(cornerRadius: min(22, r.height / 2), style: .continuous).path(in: r) }
        let corner = min(23.0, r.height / 2)
        var p = Path()
        p.move(to: .zero); p.addLine(to: CGPoint(x: r.width, y: 0))
        p.addQuadCurve(to: CGPoint(x: r.width - 8, y: 8), control: CGPoint(x: r.width - 8, y: 0))
        p.addLine(to: CGPoint(x: r.width - 8, y: r.height - corner))
        p.addQuadCurve(to: CGPoint(x: r.width - 8 - corner, y: r.height), control: CGPoint(x: r.width - 8, y: r.height))
        p.addLine(to: CGPoint(x: 8 + corner, y: r.height))
        p.addQuadCurve(to: CGPoint(x: 8, y: r.height - corner), control: CGPoint(x: 8, y: r.height))
        p.addLine(to: CGPoint(x: 8, y: 8)); p.addQuadCurve(to: .zero, control: CGPoint(x: 8, y: 0)); p.closeSubpath()
        return p
    }
}
