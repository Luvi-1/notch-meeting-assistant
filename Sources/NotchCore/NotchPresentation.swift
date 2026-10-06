import Foundation

public enum NotchPhase: Equatable { case compact, preview, expanded }

/// Time is supplied by the caller so hover and dismissal remain deterministic.
public struct NotchPresentation: Equatable {
    public private(set) var phase: NotchPhase = .compact
    public private(set) var pinned = false
    private var hovered = false
    private var editing = false
    private var settingsOpen = false
    private var hoverBlocked = false
    private var revealAllowed = true
    private var closeAfter: Date?
    public init() {}
    private var heldOpen: Bool { hovered || pinned || editing || settingsOpen }
    public mutating func hover(_ inside: Bool, at now: Date = Date()) {
        hovered = inside
        if inside {
            guard !hoverBlocked else { return }
            // Keep Answer, Save and Expand under the pointer instead of replacing them on hover.
            if phase == .preview { closeAfter = nil } else { open() }
        } else { hoverBlocked = false; scheduleClose(at: now) }
    }
    public mutating func open() { phase = .expanded; closeAfter = nil; hoverBlocked = false }
    public mutating func setPinned(_ value: Bool, at now: Date = Date()) {
        pinned = value; if value { open() } else { scheduleClose(at: now) }
    }
    public mutating func setEditing(_ value: Bool, at now: Date = Date()) {
        editing = value; if value { open() } else { scheduleClose(at: now) }
    }
    public mutating func setSettings(_ value: Bool, at now: Date = Date()) {
        settingsOpen = value; if value { open() } else { scheduleClose(at: now) }
    }
    public mutating func beginAnswer() { revealAllowed = true }
    public mutating func reveal(at now: Date = Date(), duration: Double = 8) {
        guard revealAllowed else { return }
        if phase != .expanded { phase = .preview }
        if !heldOpen { closeAfter = now.addingTimeInterval(duration) }
    }
    public mutating func dismiss() {
        phase = .compact; pinned = false; editing = false; settingsOpen = false
        closeAfter = nil; hoverBlocked = hovered; revealAllowed = false
    }
    public mutating func tick(at now: Date = Date()) {
        guard !heldOpen, let closeAfter, now >= closeAfter else { return }
        phase = .compact; self.closeAfter = nil
    }
    private mutating func scheduleClose(at now: Date) {
        guard !heldOpen, phase != .compact else { return }; closeAfter = now.addingTimeInterval(0.7)
    }
}
