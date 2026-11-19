import CoreGraphics

/// Where macOS's panel has to go so that its Adaptive Audio slider lies exactly under the one Anode's menu draws. macOS's slider can only
/// be moved by a real drag on it (measured: no Accessibility value or action, and events sent to Control Center do nothing), so while
/// the pointer is on Anode's slider, macOS's own is put under it and Anode's menu lets the pointer through there. Both draw the slider's
/// end icons at the same place in the row, so putting the left icons on each other puts the whole slider in place.
public enum AdaptiveSliderAlignment {

    /// How far to move macOS's panel (top-left global points).
    public static func offset(macLeftIcon: CGRect, anodeLeftIcon: CGRect) -> CGVector {
        CGVector(dx: anodeLeftIcon.minX - macLeftIcon.minX, dy: anodeLeftIcon.minY - macLeftIcon.minY)
    }

    /// Close enough that the two cannot be told apart (a window is placed on whole points; the icons sit on half points).
    public static func inPlace(macLeftIcon: CGRect, anodeLeftIcon: CGRect) -> Bool {
        abs(macLeftIcon.minX - anodeLeftIcon.minX) <= 0.75 && abs(macLeftIcon.minY - anodeLeftIcon.minY) <= 0.75
    }
}

/// When macOS's panel is put under Anode's slider and when it is put away. Measured: a click anywhere outside macOS's panel closes it,
/// so it is out only while the pointer is on the slider (or the button is down, a drag that strays off the row), and goes as soon as
/// neither is so, or macOS closes it itself, or the menu closes.
public struct AdaptiveSliderArming: Equatable {

    public enum State: Equatable { case idle, arming, armed, failed }
    public enum Action: Equatable { case none, arm, showHole, disarm }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func pointerEntered() -> Action {
        guard state == .idle else { return .none }
        state = .arming
        return .arm
    }

    /// macOS's panel is in place under the slider (`ok`), or could not be put there. Not tried again in this opening of the menu
    /// when it could not: the pointer wandering on and off the row would open and close macOS's panel each time.
    public mutating func armFinished(ok: Bool, pointerInside: Bool) -> Action {
        guard state == .arming else { return ok ? .disarm : .none }
        guard ok else { state = .failed; return .none }
        guard pointerInside else { state = .idle; return .disarm }
        state = .armed
        return .showHole
    }

    /// Looked at often while it is out.
    public mutating func tick(pointerInside: Bool, buttonDown: Bool, panelOpen: Bool) -> Action {
        guard state == .armed else { return .none }
        if !panelOpen || (!pointerInside && !buttonDown) { state = .idle; return .disarm }
        return .none
    }

    /// The menu is closing, or something else of macOS's panel is wanted (a press of another row).
    public mutating func menuClosing() -> Action {
        guard state == .armed || state == .arming else { return .none }
        state = .idle
        return .disarm
    }

    /// A press that reached Anode's own drawing of the slider (it was not in place): it opens macOS's own menu only when putting it in
    /// place failed, or was never tried; while it is on its way the press waits for it.
    public var handsOverOnPress: Bool { state == .failed || state == .idle }
}
