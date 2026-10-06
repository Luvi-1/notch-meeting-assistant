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
    private var terminating = false
    private let smokeCheck = CommandLine.arguments.contains("--smoke-check") && ProcessInfo.processInfo.environment["CI"] == "true"

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
        menu.addItem(.separator()); add("Settings…", #selector(showSettings), to: menu); add("Quit Notch", #selector(quit), to: menu, key: "q")
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
        if smokeCheck { Task { await runSmokeCheck() } }
        else if !UserDefaults.standard.bool(forKey: "companion-introduced") {
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
        let inset = screen.safeAreaInsets.top, detached = inset == 0
        let cutout: CGFloat
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { cutout = max(120, right.minX - left.maxX) }
        else { cutout = 0 }
        let bar = max(34, inset)
        let width: CGFloat, wantedHeight: CGFloat
        switch model.presentation.phase {
        case .compact: width = detached ? 220 : cutout + 176; wantedHeight = bar
        case .preview: width = max(660, cutout + 180); wantedHeight = bar + 88
        case .expanded: width = max(440, cutout + 180); wantedHeight = bar + (model.error == nil ? 228 : 266)
        }
        let fitted = min(width, screen.frame.width - 24), height = min(wantedHeight, screen.frame.height - 36)
        let frame = NSRect(x: screen.frame.midX - fitted / 2, y: screen.frame.maxY - height - (detached ? 8 : 0), width: fitted, height: height)
        if model.cutoutWidth != cutout { model.cutoutWidth = cutout }
        if model.cutoutHeight != bar { model.cutoutHeight = bar }
        if model.detachedNotch != detached { model.detachedNotch = detached }
        if targetFrame != frame {
            let shouldAnimate = animate && !smokeCheck && targetFrame != .zero && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        guard !terminating else { return .terminateLater }; terminating = true
        Task {
            let saved = await model.prepareToQuit()
            if saved, let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            if !saved { terminating = false; showLibraryWindow() }
            NSApp.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
    /// Runs only when explicitly requested on a CI machine with an empty library. No audio or API calls.
    private func runSmokeCheck() async {
        do {
            for _ in 0..<100 where model.loadingLibrary { try await Task.sleep(nanoseconds: 100_000_000) }
            guard model.libraryAvailable, model.sessions.isEmpty, let output = ProcessInfo.processInfo.environment["NOTCH_SMOKE_OUTPUT"] else {
                throw AssistantError("UI smoke check requires an empty CI library and an output directory.")
            }
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for section in LibrarySection.allCases {
                model.section = section; showLibraryWindow(); try await Task.sleep(nanoseconds: 400_000_000)
                guard let view = library?.contentView, view.bounds.width >= 800, view.bounds.height >= 500 else { throw AssistantError("Library window has invalid dimensions.") }
                try snapshot(view, to: directory.appendingPathComponent(section.rawValue.lowercased() + ".png"))
                print("Rendered native library: \(section.rawValue)")
            }
            model.collapse(); updatePanel(animate: false); try await Task.sleep(nanoseconds: 200_000_000)
            guard let panel, panel.frame.height <= 60 else { throw AssistantError("Idle notch did not collapse.") }
            try snapshot(panel.contentView!, to: directory.appendingPathComponent("notch-compact.png"))
            model.showError("Layout check — no audio is being recorded."); updatePanel(animate: false)
            try await Task.sleep(nanoseconds: 200_000_000)
            guard panel.frame.width >= 600, panel.frame.height <= 160 else { throw AssistantError("Automatic preview did not expand horizontally.") }
            model.hover(true)
            guard model.presentation.phase == .preview else { throw AssistantError("Hover replaced the question preview controls.") }
            try snapshot(panel.contentView!, to: directory.appendingPathComponent("notch-preview.png"))
            model.error = nil; model.openNotch(); updatePanel(animate: false)
            try await Task.sleep(nanoseconds: 200_000_000)
            try snapshot(panel.contentView!, to: directory.appendingPathComponent("notch-controls.png"))
            guard !model.busyCapture, !model.hasConsent else { throw AssistantError("Smoke check unexpectedly started capture.") }
            print("SMOKE_CHECK_PASSED: five native library pages, compact/preview/controls, horizontal geometry, preview hover, and no capture")
            NSApp.terminate(nil)
        } catch { fputs("UI smoke check failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    private func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AssistantError("Could not allocate a view snapshot.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0, let data = bitmap.representation(using: .png, properties: [:]) else { throw AssistantError("Could not render a native view.") }
        try data.write(to: url, options: .atomic)
    }
}
