import AppKit

/// The app's animation driver, and the reason it is a driver rather than a set of
/// `NSAnimationContext` calls.
///
/// ── THE RULE THIS ENFORCES ───────────────────────────────────────────────────
///
/// Nothing animates unless the user is doing something. An app whose premise is
/// not costing what it measures cannot have a heartbeat: idle with the window
/// open must be as quiet as idle with it closed, and closed must be silent.
///
/// That is a property of the DRIVER, not a promise made by each caller. The timer
/// exists only while at least one view is mid-transition, and every transition
/// here is started by a mouse entering, leaving, or clicking. Stop moving the
/// pointer and within ~120 ms there is no timer, no callback and nothing to
/// redraw. There is no animation in this app that runs on its own.
///
/// ── WHY NOT CORE ANIMATION ───────────────────────────────────────────────────
///
/// The views these serve draw themselves with `NSBezierPath` in `draw(_:)` —
/// rows, cards, chevrons, bars. Animating them through CA would mean giving each
/// one a backing layer and an animatable property, which is a larger change to
/// the drawing than the animation is worth, and layer-backing a table's reused row
/// views has costs of its own. A shared 60 Hz tick that exists for a tenth of a
/// second per interaction is cheaper than both, and it is auditable: one timer,
/// one place to look at when asking what this app is doing while nobody touches
/// it.
final class Motion {

    static let shared = Motion()

    /// How long a state change takes. Short enough to feel like the control
    /// responding rather than the app thinking about it — a hover that takes a
    /// quarter of a second reads as lag, not polish.
    static let duration: TimeInterval = 0.12

    private final class Entry {
        weak var view: NSView?
        let advance: (TimeInterval) -> Bool
        init(view: NSView, advance: @escaping (TimeInterval) -> Bool) {
            self.view = view
            self.advance = advance
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var timer: Timer?
    private var last: Date?

    private init() {}

    /// Register a view as moving. Re-registering replaces the previous entry, so a
    /// pointer sweeping across rows does not stack callbacks on any of them.
    ///
    /// `advance` returns false when the view has arrived, which is what removes it
    /// — a view that never finishes would keep the timer alive forever, so
    /// arriving is the caller's responsibility and it is a single comparison.
    func start(_ view: NSView, _ advance: @escaping (TimeInterval) -> Bool) {
        entries[ObjectIdentifier(view)] = Entry(view: view, advance: advance)
        guard timer == nil else { return }
        last = Date()
        // `.common` so a transition does not freeze while a menu is open or a
        // scroll is tracking, which are exactly the moments hover changes.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// True while anything is moving. For tests, and for anyone asking whether
    /// this app is busy when it should not be.
    var isRunning: Bool { timer != nil }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(last ?? now)
        last = now

        for (key, entry) in entries {
            // A view that has gone away takes its animation with it. Weak, because
            // a table's rows are reused and discarded under us and holding one
            // here would keep a dead row alive to finish a fade nobody can see.
            guard let view = entry.view else { entries[key] = nil; continue }
            if entry.advance(dt) {
                view.needsDisplay = true
            } else {
                view.needsDisplay = true   // one last frame, at the resting value
                entries[key] = nil
            }
        }

        // THE WHOLE POINT. No movers, no timer.
        if entries.isEmpty {
            timer?.invalidate()
            timer = nil
            last = nil
        }
    }
}

/// One value easing towards another.
///
/// A struct rather than a class so a view owns it outright — there is no shared
/// state between two animating rows, and nothing to release.
struct Eased {
    /// Where it is now, 0…1.
    private(set) var value: CGFloat = 0
    /// Where it is going.
    private(set) var target: CGFloat = 0

    var isMoving: Bool { abs(value - target) > 0.001 }

    /// Jump straight there, for a view being reused or first shown. A row that
    /// scrolls into view under the pointer should already be hovered, not fade in
    /// as though the pointer had just arrived.
    mutating func set(_ v: CGFloat) { value = v; target = v }

    mutating func aim(_ v: CGFloat) { target = v }

    /// Move towards the target, returning whether there is further to go.
    ///
    /// Exponential rather than linear: it leaves quickly and arrives softly, which
    /// is what makes a 120 ms change read as a response rather than a slide. The
    /// snap at the end keeps a value that is asymptotically approaching from
    /// keeping the timer alive forever.
    mutating func advance(_ dt: TimeInterval) -> Bool {
        guard isMoving else { value = target; return false }
        let k = 1 - pow(0.001, CGFloat(dt) / CGFloat(Motion.duration))
        value += (target - value) * k
        if abs(value - target) <= 0.001 { value = target; return false }
        return true
    }
}
