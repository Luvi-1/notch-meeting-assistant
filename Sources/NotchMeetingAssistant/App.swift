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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.animationBehavior = .none; panel.delegate = self
        let host = NSHostingView(rootView: NotchView(model: model)); host.sizingOptions = []; panel.contentView = host
        self.panel = panel
        model.onOpenLibrary = { [weak self] in self?.showLibraryWindow() }
        model.onStarted = { [weak self] in self?.library?.orderOut(nil) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Notch listening companion")
        let menu = NSMenu()
        add("Open Notch", #selector(showLibrary), to: menu)
        add("Listening controls", #selector(showPanel), to: menu)
        add("Answer now", #selector(answerNow), to: menu)
        add("Stop listening", #selector(stopListening), to: menu)
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings), to: menu)
        add("Quit Notch", #selector(quit), to: menu, key: "q")
        item.menu = menu; statusItem = item
        stateObserver = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updatePanel() } }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePanel(animate: false) }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.stop(showReview: false) }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in guard let self, !self.model.presentation.pinned else { return }; self.model.collapse() }
        }
        updatePanel(animate: false); panel.orderFrontRegardless()
        if !UserDefaults.standard.bool(forKey: "companion-introduced") {
            showLibraryWindow(); UserDefaults.standard.set(true, forKey: "companion-introduced")
        }
    }
    private func add(_ title: String, _ action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    private func showLibraryWindow() {
        if library == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Notch"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 840, height: 580); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LibraryView(model: model)); window.center(); library = window
        }
        library?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func updatePanel(animate: Bool = true) {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let inset = screen.safeAreaInsets.top; let detached = inset == 0
        let cutout: CGFloat
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { cutout = max(120, right.minX - left.maxX) }
        else { cutout = 0 }
        let bar = max(34, inset)
        let width: CGFloat, wantedHeight: CGFloat
        switch model.presentation.phase {
        case .compact: width = detached ? 220 : cutout + 144; wantedHeight = bar
        case .preview: width = max(660, cutout + 180); wantedHeight = bar + 88
        case .expanded: width = max(440, cutout + 180); wantedHeight = bar + (model.error == nil ? 228 : 266)
        }
        let fitted = min(width, screen.frame.width - 24); let height = min(wantedHeight, screen.frame.height - 36)
        let frame = NSRect(x: screen.frame.midX - fitted / 2, y: screen.frame.maxY - height - (detached ? 8 : 0), width: fitted, height: height)
        if model.cutoutWidth != cutout { model.cutoutWidth = cutout }
        if model.cutoutHeight != bar { model.cutoutHeight = bar }
        if model.detachedNotch != detached { model.detachedNotch = detached }
        if targetFrame != frame {
            let shouldAnimate = animate && targetFrame != .zero && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            targetFrame = frame; model.panelWidth = fitted; model.panelHeight = height
            if shouldAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3; context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.25, 1)
                    panel.animator().setFrame(frame, display: true)
                }
            } else { panel.setFrame(frame, display: true) }
        }
        statusItem?.button?.toolTip = "Notch · \(model.status)"
        statusItem?.button?.image = NSImage(systemSymbolName: model.isListening ? "waveform.circle.fill" : "waveform", accessibilityDescription: model.status)
    }
    @objc private func showLibrary() { model.openLibrary(.home) }
    @objc private func showPanel() { model.openNotch(); panel?.orderFrontRegardless(); panel?.makeKey() }
    @objc private func showSettings() { model.openLibrary(.settings) }
    @objc private func answerNow() { model.requestAnswer() }
    @objc private func stopListening() { Task { await model.stop() } }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowDidResignKey(_ notification: Notification) { model.setEditing(false) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        Task { await model.prepareToQuit(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
