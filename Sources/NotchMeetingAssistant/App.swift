import AppKit
import SwiftUI
import Combine

@main
struct NotchMeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MeetingModel()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private var stateObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

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
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        self.panel = panel
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting assistant")
        let menu = NSMenu()
        addItem("Show meeting assistant", action: #selector(showPanel), to: menu)
        addItem("Answer now", action: #selector(answerNow), to: menu)
        addItem("Stop meeting", action: #selector(stopMeeting), to: menu)
        menu.addItem(.separator())
        addItem("Settings…", action: #selector(showSettings), to: menu)
        menu.addItem(.separator())
        addItem("Quit", action: #selector(quit), to: menu, key: "q")
        item.menu = menu
        statusItem = item
        stateObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePanel() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePanel() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.stop() }
        }
        updatePanel()
        panel.orderFrontRegardless()
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func updatePanel() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let inset = screen.safeAreaInsets.top
        let cutout: CGFloat
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            cutout = max(120, right.minX - left.maxX)
        } else { cutout = 130 }
        let barHeight = max(32, inset)
        let width = model.expanded ? min(620, screen.frame.width - 20) : cutout + 124
        let wantedHeight: CGFloat = model.expanded ? (model.showSettings ? 680 : (model.error == nil ? 620 : 675)) : barHeight
        let height = min(wantedHeight, screen.frame.height - 24)
        if model.cutoutWidth != cutout { model.cutoutWidth = cutout }
        if model.cutoutHeight != barHeight { model.cutoutHeight = barHeight }
        if model.panelWidth != width { model.panelWidth = width }
        if model.panelHeight != height { model.panelHeight = height }
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        statusItem?.button?.toolTip = "Notch Meeting Assistant · \(model.status)"
        statusItem?.button?.image = NSImage(systemSymbolName: model.isListening ? "waveform.circle.fill" : "waveform",
                                           accessibilityDescription: model.status)
    }

    @objc private func showPanel() {
        model.expanded = true
        panel?.orderFrontRegardless()
        panel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        model.showSettings = true
        showPanel()
    }

    @objc private func answerNow() { model.requestAnswer() }
    @objc private func stopMeeting() { Task { await model.stop() } }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
