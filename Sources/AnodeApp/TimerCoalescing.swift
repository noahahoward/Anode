import Foundation

// ── Timer coalescing ────────────────────────────────────────────────────────
//
// macOS merges wake-ups only for timers that say how late they may fire: a timer with no `tolerance` wakes the CPU on
// its own, to the millisecond. Every repeating timer that can run while the app sits idle sets one, through this, so
// the system can fire several together on one wake-up.

extension Timer {

    /// Sets how late the system may fire this timer so it can be merged with other wake-ups, and returns the timer
    /// (so it can end a `Timer.scheduledTimer(...)` expression). The tolerance is a share of the interval, never a
    /// rule: pick it so a late tick changes nothing the person can see.
    @discardableResult
    func coalescing(tolerance: TimeInterval) -> Timer {
        self.tolerance = tolerance
        return self
    }
}
