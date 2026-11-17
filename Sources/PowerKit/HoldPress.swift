import Foundation

/// A press with two meanings: let go soon, it is a press; held for `seconds`, it is a hold (and the let go that follows is nothing).
/// A let go off the button is neither. The clock is given, so a test can be the clock.
public final class HoldPress {

    /// `schedule` runs the closure after the time and returns a way to call it off.
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    public var onPress: (() -> Void)?
    public var onHold: (() -> Void)?

    private let seconds: TimeInterval
    private let schedule: Schedule
    private var cancel: (() -> Void)?
    private var isDown = false
    private var fired = false

    public init(seconds: TimeInterval, schedule: @escaping Schedule) { self.seconds = seconds; self.schedule = schedule }

    public func pressDown() {
        guard !isDown else { return }
        isDown = true; fired = false
        cancel = schedule(seconds) { [weak self] in self?.fire() }
    }

    private func fire() {
        guard isDown, !fired else { return }
        fired = true; cancel = nil
        onHold?()
    }

    public func release(inside: Bool) {
        guard isDown else { return }
        isDown = false
        cancel?(); cancel = nil
        let wasHold = fired
        fired = false
        if !wasHold && inside { onPress?() }
    }

    /// The button went away mid-press: nothing fires.
    public func abandon() {
        isDown = false; fired = false
        cancel?(); cancel = nil
    }
}
