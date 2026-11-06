import Foundation
import CoreGraphics

// ── What the keyboard cleaner lets through ──────────────────────────────────
//
// While the cleaner is up, every event is swallowed, with two exceptions:
//
//  - the exit combination, which ends the session (and is itself consumed);
//  - the RELEASE of a key that was already down when the session began. The start shortcut's own keys are still
//    held at that moment; if their release were swallowed, the system would be told a key went down and never
//    came up. A modifier is released with a flags-changed event rather than a key-up, so both count.
//
// Pure, no AppKit: decided per event so it is testable without a tap. It is called from the tap's thread only
// (`EventTapThread`), never concurrently, so it keeps its state without a lock.

struct CleanerEvent {
    enum Kind { case keyDown, keyUp, flagsChanged, other }
    let kind: Kind
    let key: Int
    let flags: CGEventFlags
}

enum CleanerVerdict: Equatable {
    case swallow
    case pass
    /// The exit combination: end the session, and swallow this event too.
    case exit
}

final class CleanerInputFilter {
    private let exit: Shortcut
    private var heldAtStart: Set<Int>

    init(exit: Shortcut, keysDownAtStart: Set<Int>) {
        self.exit = exit
        self.heldAtStart = keysDownAtStart
    }

    func verdict(for event: CleanerEvent) -> CleanerVerdict {
        switch event.kind {
        case .keyDown:
            return exit.matches(key: event.key, flags: event.flags) ? .exit : .swallow
        case .keyUp, .flagsChanged:
            // The first release of a key that was held at the start goes through; everything after is swallowed.
            return heldAtStart.remove(event.key) != nil ? .pass : .swallow
        case .other:
            return .swallow
        }
    }
}
