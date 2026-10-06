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
    private var library: NSWindow?
    private var statusItem: NSStatusItem?
    private var stateObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var targetFrame = NSRect.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []; panel.contentView = host; self.panel = panel
        model.openLibraryAction = { [weak self] in self?.openLibrary() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Notch")
        let menu = NSMenu()
        addItem("Open Notch", action: #selector(openHome), to: menu, key: "o")
        addItem("Start Listening", action: #selector(startListening), to: menu)
        addItem("Answer question", action: #selector(answerNow), to: menu)
        addItem("Stop Listening", action: #selector(stopListening), to: menu)
        menu.addItem(.separator())
        addItem("Ask your memory", action: #selector(openSearch), to: menu)
        addItem("Settings…", action: #selector(showSettings), to: menu, key: ",")
        menu.addItem(.separator())
        addItem("Quit Notch", action: #selector(quit), to: menu, key: "q")
        item.menu = menu; statusItem = item
        stateObserver = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updatePanel() } }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.updatePanel(animate: false) } }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.model.stop() } }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.model.collapse() }
        }
        updatePanel(animate: false); panel.orderFrontRegardless()
        if !UserDefaults.standard.bool(forKey: "companion-onboarding-shown") {
            UserDefaults.standard.set(true, forKey: "companion-onboarding-shown"); openLibrary()
        }
    }
    private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    private func openLibrary() {
        if library == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 730),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Notch"; window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 800, height: 570)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: LibraryView(model: model))
            window.center(); library = window
        }
        library?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func updatePanel(animate: Bool = true) {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let inset = screen.safeAreaInsets.top
        let detached = inset == 0
        let cutout: CGFloat
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { cutout = max(120, right.minX - left.maxX) }
        else { cutout = 0 }
        let barHeight = max(34, inset)
        let width: CGFloat
        let wantedHeight: CGFloat
        switch model.presentation.phase {
        case .compact: width = detached ? 206 : cutout + 164; wantedHeight = barHeight
        case .preview: width = max(640, cutout + 260); wantedHeight = barHeight + 92
        case .expanded: width = max(360, cutout + 164); wantedHeight = barHeight + 164
        }
        let fittedWidth = min(width, screen.frame.width - 24)
        let height = min(wantedHeight, screen.frame.height - 36)
        let frame = NSRect(x: screen.frame.midX - fittedWidth / 2, y: screen.frame.maxY - height - (detached ? 8 : 0), width: fittedWidth, height: height)
        if model.cutoutWidth != cutout { model.cutoutWidth = cutout }
        if model.cutoutHeight != barHeight { model.cutoutHeight = barHeight }
        if model.detachedNotch != detached { model.detachedNotch = detached }
        if targetFrame != frame {
            let shouldAnimate = animate && targetFrame != .zero && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            targetFrame = frame; model.panelWidth = fittedWidth; model.panelHeight = height
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.25, 1)
                    panel.animator().setFrame(frame, display: true)
                }
            } else { panel.setFrame(frame, display: true) }
        }
        statusItem?.button?.toolTip = "Notch · \(model.status)"
        statusItem?.button?.image = NSImage(systemSymbolName: model.isListening ? "waveform.circle.fill" : "waveform", accessibilityDescription: model.status)
    }
    @objc private func openHome() { model.showLibrary(.home) }
    @objc private func startListening() {
        if model.hasConsent { Task { await model.start() } }
        else { model.showLibrary(.home) }
    }
    @objc private func openSearch() { model.showLibrary(.search) }
    @objc private func showSettings() { model.showLibrary(.settings) }
    @objc private func answerNow() { model.answerNotice() }
    @objc private func stopListening() { Task { await model.stop() } }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            let saved = await model.shutdown()
            if saved, let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            NSApp.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
