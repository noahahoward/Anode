import Foundation

/// Every word the root helper answers a refused discharge with, in one place.
///
/// The app tells these apart by their exact text — some pass by themselves
/// (going to sleep, switched a moment ago), some last (a reconnect owed, no
/// sleep notices) — so the server sends these constants and the app compares
/// against the same ones rather than against a copy that can drift. A test
/// pins each one's words and the case that sends it.
///
/// A refused cut's message may carry the failed undo after it ("…; the
/// charger did NOT reconnect …"); the two cut constants are its start.
public enum ChargeRefusal {

    /// A helper built without charge control.
    public static let noChargeControl = "this helper has no charge control"

    /// The system would not register the helper for sleep notices, so nothing
    /// would reconnect the charger before the Mac sleeps. Lasts the helper's
    /// whole life.
    public static let noSleepNotices = "this Mac cannot warn the helper before it sleeps"

    /// Between a will-sleep and the next wake. Passes at the wake.
    public static let goingToSleep = "the Mac is going to sleep"

    /// A reconnect failed and is still owed. Lasts until the helper reads the
    /// charger connected.
    public static let reconnectOwed = "the charger may still be cut off from an earlier failure"

    /// The target is outside what root accepts. Said in the app's own words for the control (a drain), because the
    /// section shows it.
    public static let targetOutOfRange = "refused: the level to drain to must be "
        + "\(FanHelperServer.dischargeTargetRange.lowerBound)–"
        + "\(FanHelperServer.dischargeTargetRange.upperBound)%"

    /// The battery level cannot be read, so nothing could watch the floor.
    public static let batteryUnreadable = "refused: the battery level cannot be read"

    /// The cable is out: there is no charger to cut.
    public static let noCharger = "refused: no charger is connected"

    /// The battery is at or below `percent` — the target, or the floor when
    /// that is higher — so the discharge would end on its first check.
    public static func atOrBelow(_ percent: Int) -> String {
        "refused: the battery is already at or below \(percent)%"
    }

    /// Less than `FanHelperServer.cutSpacing` since the last attempt to cut
    /// the charger. Passes by itself.
    public static let switchedRecently = "the charger was switched a moment ago; try again shortly"

    /// The SMC said no to the cut, and the charger does not read as Anode's
    /// cut (exactly 0x08).
    public static let cutRefused = "the SMC would not cut the charger"

    /// The SMC said yes to the cut, and the charger does not read as Anode's
    /// cut (exactly 0x08): connected, unreadable, or some other value, which
    /// the undo writes back to 0x00.
    public static let cutNotKept = "the SMC took the cut and the charger does not read as cut"
}
