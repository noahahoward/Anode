import Foundation

// ── Anode's own side of Ultra Low Power Mode ────────────────────────────────
//
// While the mode is on Anode stops measuring, and none of its features may call into a process the mode has stopped: a call
// into a stopped process (an accessibility question, a window raise) waits until it times out. Every file that needs to know
// asks here, so "the mode is on" and "this process is stopped" are each decided in one place and a call site is one line.
//
// With no controller (the app makes one when it starts, and drops it when it quits) or with the mode off, every answer is the
// one the app gave before the mode existed. Main thread only, like the controller.

enum UltraQuiet {

    /// The mode is on: Anode has stopped measuring. Not while it is only being asked for (`.confirming`), and not after it
    /// ends.
    static var isOn: Bool { UltraLowPowerController.current?.state == .on }

    /// The mode has `pid` stopped right now: it is not to be asked anything.
    static func isFrozen(pid: pid_t) -> Bool { UltraLowPowerController.current?.isFrozen(pid: pid) ?? false }

    /// The owner picked this app's window or icon: if the mode has it stopped, it is let go first, so what follows is a call
    /// into a running process.
    static func activated(pid: pid_t) { UltraLowPowerController.current?.appActivated(pid: pid) }
}
