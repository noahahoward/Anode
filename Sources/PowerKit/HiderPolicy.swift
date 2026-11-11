import Foundation

// ── When the menu bar hider may act (Menu Bar Hider) ────────────────────────

public enum HiderRefusal: Equatable {
    case disabled, noAccessibility, layoutUnreadable, fullScreen, settling, itemsNotOnThisScreen
}

public enum HiderDecision: Equatable {
    case collapsed
    case standDown(HiderRefusal)
}

public enum HiderPolicy {

    /// Seconds after a Space or display change in which nothing is covered: the layout is still moving.
    public static let settleSeconds: TimeInterval = 1

    /// The first refusal that applies, in the order of the enum; otherwise collapsed.
    public static func decide(enabled: Bool, accessibilityTrusted: Bool, layoutReadable: Bool, fullScreen: Bool,
                              secondsSinceSpaceOrDisplayChange: TimeInterval, itemsOnThisScreen: Bool) -> HiderDecision {
        if !enabled { return .standDown(.disabled) }
        if !accessibilityTrusted { return .standDown(.noAccessibility) }
        if !layoutReadable { return .standDown(.layoutUnreadable) }
        if fullScreen { return .standDown(.fullScreen) }
        if secondsSinceSpaceOrDisplayChange < settleSeconds { return .standDown(.settling) }
        if !itemsOnThisScreen { return .standDown(.itemsNotOnThisScreen) }
        return .collapsed
    }
}

/// Whether the pill is open, and when it closes itself. The chevron, the shortcut and "Show icons" all toggle this; the
/// bar itself stays collapsed either way.
public struct PillState: Equatable {
    public private(set) var isOpen = false
    public private(set) var closeAt: Date?

    public init() {}

    /// Open it (closing itself after `autoClose` seconds, 0 meaning never) or, if open, close it.
    public mutating func toggle(now: Date, autoClose: Int) {
        if isOpen {
            close()
        } else {
            isOpen = true
            closeAt = autoClose > 0 ? now.addingTimeInterval(TimeInterval(autoClose)) : nil
        }
    }

    public mutating func close() {
        isOpen = false
        closeAt = nil
    }

    public mutating func tick(now: Date) {
        if isOpen, let closeAt, now >= closeAt { close() }
    }

    /// The pill was placed for a screen that has changed.
    public mutating func screenParametersChanged() { close() }
}
