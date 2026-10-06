import AppKit
import SwiftUI
import Combine
import QuartzCore
import NotchCore

@main
struct NotchMeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.openSettingsFromCommand() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .newItem) {
                    Button("Start or Stop Listening") { delegate.toggleListeningFromCommand() }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                }
            }
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = MeetingModel()
    private var panel: NotchPanel?
    private var companionWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var listeningMenuItem: NSMenuItem?
    private var stateObserver: AnyCancellable?
    private var listeningObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var targetFrame = NSRect.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makeNotchPanel()
        makeCompanionWindow()
        makeMenu()
        model.onOpenMainWindow = { [weak self] in self?.openCompanionWindow() }
        stateObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePanel() }
        }
        listeningObserver = model.$isListening.removeDuplicates().sink { [weak self] listening in
            guard listening else { return }
            DispatchQueue.main.async {
                self?.companionWindow?.orderOut(nil)
                self?.model.collapse()
            }
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
                guard let self, !self.model.presentation.pinned else { return }
                self.model.collapse()
            }
        }
        updatePanel(animate: false)
        panel?.orderFrontRegardless()
        openCompanionWindow()
    }

    private func makeNotchPanel() {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
    }

    private func makeCompanionWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Notch"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(calibratedWhite: 23 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: CompanionWindow(model: model))
        window.center()
        window.setFrameAutosaveName("NotchCompanionWindow")
        companionWindow = window
    }

    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Notch listening companion")
        let menu = NSMenu()
        menu.autoenablesItems = false
        addItem("Open Notch", action: #selector(showCompanion), to: menu)
        listeningMenuItem = addItem("Start Listening", action: #selector(toggleListening), to: menu)
        addItem("Answer current question", action: #selector(answerNow), to: menu)
        menu.addItem(.separator())
        addItem("Search your memory", action: #selector(showSearch), to: menu)
        addItem("Settings…", action: #selector(showSettings), to: menu, key: ",")
        addItem("Collapse notch", action: #selector(collapsePanel), to: menu)
        menu.addItem(.separator())
        addItem("Quit Notch", action: #selector(quit), to: menu, key: "q")
        item.menu = menu
        statusItem = item
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
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
        let compact = model.presentation.phase == .compact
        let width = compact ? (detached ? 196 : cutout + 144) : max(650, cutout + 144)
        // Hover and question previews share one shallow horizontal surface.
        let wantedHeight = barHeight + (compact ? 0 : 86)
        let fittedWidth = min(width, screen.frame.width - 24)
        let height = min(wantedHeight, screen.frame.height - 36)
        let frame = NSRect(x: screen.frame.midX - fittedWidth / 2,
                           y: screen.frame.maxY - height - (detached ? 8 : 0),
                           width: fittedWidth, height: height)
        if model.cutoutWidth != cutout { model.cutoutWidth = cutout }
        if model.cutoutHeight != barHeight { model.cutoutHeight = barHeight }
        if model.detachedNotch != detached { model.detachedNotch = detached }
        // Compare destinations, so streaming tokens cannot restart an in-flight window animation.
        if targetFrame != frame {
            let shouldAnimate = animate && targetFrame != .zero && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            targetFrame = frame
            model.panelWidth = fittedWidth
            model.panelHeight = height
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.34
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.25, 1)
                    panel.animator().setFrame(frame, display: true)
                }
            } else { panel.setFrame(frame, display: true) }
        }
        statusItem?.button?.toolTip = "Notch · \(model.status)"
        statusItem?.button?.image = NSImage(systemSymbolName: model.isListening ? "waveform.circle.fill" : "waveform",
                                           accessibilityDescription: model.status)
        listeningMenuItem?.title = model.isStopping ? "Saving the last words…" : (model.isStarting ? "Cancel Starting" : (model.isListening ? "Stop Listening" : "Start Listening"))
        listeningMenuItem?.isEnabled = !model.isStopping
    }

    private func openCompanionWindow() {
        companionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.collapse()
    }

    func openSettingsFromCommand() { model.openMain(.settings) }
    func toggleListeningFromCommand() { toggleListening() }

    @objc private func showCompanion() { model.openMain() }
    @objc private func showSettings() { model.openMain(.settings) }
    @objc private func showSearch() { model.openMain(.search) }
    @objc private func collapsePanel() { model.collapse() }
    @objc private func answerNow() { model.answerCurrentQuestion() }
    @objc private func toggleListening() {
        if model.isListening || model.isStarting { Task { await finishListeningSession(model) } }
        else { Task { await model.start() } }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === companionWindow { sender.orderOut(nil); return false }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel { model.setEditing(false) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openMain()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        Task {
            await model.finishForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
