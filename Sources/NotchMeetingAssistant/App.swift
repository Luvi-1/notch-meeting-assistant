import AppKit
import SwiftUI
import Combine
import QuartzCore
import NotchCore

@main
struct NotchMeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = MeetingModel()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private var stateObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var targetFrame = NSRect.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.delegate = self
        let host = NSHostingView(rootView: NotchView(model: model))
        // Window geometry belongs to updatePanel, not the content's temporary intrinsic size.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting assistant")
        let menu = NSMenu()
        addItem("Show meeting assistant", action: #selector(showPanel), to: menu)
        addItem("Answer now", action: #selector(answerNow), to: menu)
        addItem("Stop meeting", action: #selector(stopMeeting), to: menu)
        menu.addItem(.separator())
        addItem("Settings…", action: #selector(showSettings), to: menu)
        addItem("Collapse", action: #selector(collapsePanel), to: menu)
        menu.addItem(.separator())
        addItem("Quit", action: #selector(quit), to: menu, key: "q")
        item.menu = menu
        statusItem = item
        stateObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePanel() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePanel(animate: false) }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.stop() }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.presentation.pinned, !self.model.showSettings else { return }
                self.model.collapse()
            }
        }
        updatePanel(animate: false)
        panel.orderFrontRegardless()
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func updatePanel(animate: Bool = true) {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let inset = screen.safeAreaInsets.top
        let detached = inset == 0
        let cutout: CGFloat
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            cutout = max(120, right.minX - left.maxX)
        } else { cutout = 0 }
        let barHeight = max(34, inset)
        let width: CGFloat
        let wantedHeight: CGFloat
        switch model.presentation.phase {
        case .compact:
            width = detached ? 164 : cutout + 92
            wantedHeight = barHeight
        case .preview:
            width = max(420, cutout + 92)
            wantedHeight = barHeight + 132
        case .expanded:
            width = max(490, cutout + 120)
            wantedHeight = barHeight + (model.showSettings ? 510 : 438) + (model.error == nil ? 0 : 72)
        }
        let fittedWidth = min(width, screen.frame.width - 24)
        let height = min(wantedHeight, screen.frame.height - 36)
        let frame = NSRect(x: screen.frame.midX - fittedWidth / 2,
                           y: screen.frame.maxY - height - (detached ? 8 : 0),
                           width: fittedWidth, height: height)
        if model.cutoutWidth != cutout { model.cutoutWidth = cutout }
        if model.cutoutHeight != barHeight { model.cutoutHeight = barHeight }
        if model.detachedNotch != detached { model.detachedNotch = detached }
        // Compare the destination, not an in-flight frame: transcript tokens must not restart animations.
        if targetFrame != frame {
            let shouldAnimate = animate && targetFrame != .zero && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            targetFrame = frame
            model.panelWidth = fittedWidth
            model.panelHeight = height
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.25, 1)
                    panel.animator().setFrame(frame, display: true)
                }
            } else { panel.setFrame(frame, display: true) }
        }
        statusItem?.button?.toolTip = "Notch Meeting Assistant · \(model.status)"
        statusItem?.button?.image = NSImage(systemSymbolName: model.isListening ? "waveform.circle.fill" : "waveform",
                                           accessibilityDescription: model.status)
    }

    @objc private func showPanel() {
        model.openNotch()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        model.showSettings = true
        showPanel()
    }

    @objc private func collapsePanel() { model.collapse() }
    @objc private func answerNow() { model.requestAnswer() }
    @objc private func stopMeeting() { Task { await model.stop() } }
    @objc private func quit() { NSApp.terminate(nil) }

    func windowDidResignKey(_ notification: Notification) { model.setEditing(false) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        Task {
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
