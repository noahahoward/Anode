import AppKit
import IOKit.ps
import PowerKit

// ── Charge Control (Beta Features) ──────────────────────────────────────────
//
// Holds the battery at the person's charge limit through macOS's own manual charge limit (MCL), and drains it on
// the adapter through the root helper. What to do is decided by `ChargePolicy`, one pure function; this file feeds
// it and applies its answer, and decides nothing itself.
//
// Where an answer goes:
//   * a limit of 80, 85, 90, 95 or 100 → macOS's own client API (`ChargeLimitClient`), no helper needed;
//   * any other limit → the helper's `setChargeLimit`; with no helper, the nearest client value ABOVE it, so the
//     battery is never held lower than asked, and the status says the helper is needed;
//   * a discharge → the helper's `discharge` / `stopDischarge`, over the connection the Fans tab shares
//     (`HelperConnection`).
//
// The helper is a root daemon that launchd starts on demand, and every hello wakes it. So Charge Control greets it
// once when switched on (its startup clears a charger cut a dead helper left behind), talks to it again only when
// it has something to ask, and keeps the connection open only while a discharge lives on it (closing the
// connection ends the cut). Nothing about the helper is said until it has answered, or is known not to be there.
//
// The first time it is switched on, the state of macOS's limit and Optimized Battery Charging is written down
// (`Settings.chargeRestoreRecord`, flushed to disk) BEFORE anything is changed, and switching off puts it back at
// once, after anything still on its way to the helper has landed. So does quitting: the limit is in force only while
// Anode is running, so that an Anode that ever breaks on someone's Mac leaves the battery released, not held. The
// record is cleared by a restore that worked, and the setting and the person's limit are not touched, so the next
// launch switches on again from a cold start. A record still there at launch with Charge Control on therefore means
// the last run ended without a quit (a crash, a kill, the power going), with macOS's limit still in force; that
// launch puts macOS's own settings back at once and switches on again only after `startDelay` (`liftAfterUncleanExit`).
// It writes `Settings.chargeStartPending` first and clears it only once that switch-on has run (or on switching off, a
// clean quit or an uninstall), so an Anode that dies during the delay finds the flag at its next launch and waits
// again: only one that stays up for the whole delay ever holds a limit, however often it crashes before that.
// While on, macOS is read back on the timer and after a wake, and put back if something else changed it.
//
// A charger cut outlives the helper that made it (measured: a killed helper leaves it cut, and the installed daemon
// is not kept alive; only a new connection to its socket starts a fresh helper, whose startup reconnects the
// charger). So a discharge is never taken as ended until a RUNNING helper has answered a stop with yes. The debt is
// written down (`Settings.chargeCutUnconfirmed`, flushed) before a discharge is asked for, and when the net finds a
// cut nobody holds (below), so that switching off or quitting still asks about it. A stop nobody answered, a
// connection reset under a discharge, or the charger switch reading cut for more than 90 s with no discharge running,
// all mean the cut may be left with nobody watching: the connection is opened again at once and the stop asked
// again, then on every tick, with a warning, until a running helper says yes. Two things settle it with no helper:
// the helper's own uninstall finishing (it reconnects the charger, and fails when it cannot), and the charger switch
// reading connected for more than 90 s with no discharge running. That net, and only it, does not run while another
// account is on screen: that account's Anode may be discharging, through a helper whose socket this one cannot open.
//
// The switch is read by the app itself (reading needs no root; only writing does), because what macOS says is not
// proof either way. Measured on Mac17,9, macOS 27.0: with no macOS limit holding the battery, a cut makes macOS say
// the Mac is off the adapter within 1 to 2 s; with a limit below the battery level in force (limit 63, battery 100)
// the switch read cut for 50 s and macOS said "on the adapter" throughout. macOS's word is used only until the switch
// has been read once in this run of the app (a Mac whose switch cannot be read never reads it): the net and the
// settling go by it then, as the weaker evidence. After that a read that fails is no information, and macOS's word
// does not stand in for it: the net neither ends nor goes on, and nothing is settled. See `noteCutLook`,
// `noteConnected`.
//
// While the setting is off nothing exists: no client, no timer, no observer but the one on the switch itself, no
// helper connection and no helper command. The exceptions are what an earlier run left unfinished: a restore record
// is put back once at launch (and before an uninstall), with a client made for that alone; and that debt, which is
// paid at launch through an installed helper, and asked again every 30 s until a running helper answers. While it is
// owed, the section says so (`offWarning`), from the flag alone. The delay after an unclean exit is the same kind of
// thing: Charge Control is on in the setting but holds nothing, so nothing of it exists but one timer and the two
// session observers (so that it does not start into another account's limit), and the debt is paid in the same way
// meanwhile.
//
// Main thread throughout.

/// The root helper as Charge Control sees it. A protocol so the tests can script it; the real one is
/// `ChargeHelperAdapter`.
protocol ChargeHelperLink: AnyObject {
    /// The helper last answered speaking protocol 2 or later, and has not stopped answering since. Learned from its
    /// hello and from its replies; the connection need not be open now.
    var available: Bool { get }
    /// A helper answered, but one too old to know the charge commands.
    var outdated: Bool { get }
    /// Installed as a daemon: a connection starts it, so it can be greeted even when it has not answered.
    var installed: Bool { get }
    /// The helper has answered since `follow`, or is known not to be installed. Until then nothing is said about it.
    var known: Bool { get }
    /// The connection is open and this link is holding it.
    var isOpen: Bool { get }
    /// Goes up whenever the helper may have ended a discharge that Charge Control did not end: its socket closed
    /// or was replaced, or the Fans tab sent "release everything".
    var resets: Int { get }
    /// Call `changed` (on the main thread) when `available`, `outdated`, `known`, `isOpen` or `resets` change. If
    /// the helper is installed, greet it once and let it go.
    func follow(_ changed: @escaping () -> Void)
    /// Stop following, and let go of the connection. It closes only if nothing else in the app holds it.
    func letGo()
    /// Keep the connection open, because a discharge lives on it; or let it go once nothing is on its way.
    func keepOpen(_ open: Bool)
    /// Look again for a helper that has not answered: the section was shown. Installs and uninstalls are noticed
    /// without this.
    func recheck()
    /// Check that the connection kept open is still there, and reopen it if it is not. Only while kept open.
    func refresh()
    /// Opens the connection if this link is not holding it, or if the one it holds is known to be gone (a command
    /// found it gone), and lets it go after the answer unless it is kept open. `done` is called on the main thread.
    /// A helper that is gone answers ok:false with `HelperConnection.stoppedAnswering`; there is no "no answer".
    func send(_ c: FanCommand, _ done: @escaping (FanReply) -> Void)
    /// `send`, answered before it returns, or nil after `timeout`. Greets over the connection first, opening a new
    /// one if the old one does not answer (for an installed helper that starts a fresh one). Blocks the caller.
    func sendWaiting(_ c: FanCommand, timeout: TimeInterval) -> FanReply?
    /// Wait until everything already sent has been exchanged with the helper (the answers may still be on their way
    /// to the main thread). False after `timeout`. Blocks the caller.
    func drain(timeout: TimeInterval) -> Bool
}

/// What the Beta Features section shows.
enum ChargeStatus: Equatable {
    case off
    /// Charge Control cannot run on this Mac, and why.
    case unavailable(String)
    /// What was asked for needs the helper, which is missing or too old; the sentence says which.
    case needsHelper(String)
    /// The helper is there and would not do what was asked, for a reason that does not pass by itself; the sentence
    /// says what and why. It is not asked again until the person presses again or the decision changes.
    case refused(String)
    /// Running, with the decision in force.
    case active(ChargeDecision)
    /// Something may be wrong with the charger that Charge Control is still trying to put right; the sentence says
    /// what, and what the person can do.
    case warning(String)
    /// Charge Control is on but has not started: the sentence says why, and when it will.
    case waiting(String)
}

final class ChargeController {

    /// The running controller, for the Beta Features section to read.
    static weak var current: ChargeController?

    static let unavailableText = "Needs macOS 26.4 or later on Apple silicon"
    static let unreadableText = "macOS did not report its charge settings, so Charge Control changed nothing"
    static let noBatteryText = "Anode could not read the battery"
    static let limitNeedsHelperText = "Limits other than 80, 85, 90, 95 or 100% need the Anode helper"
    static let dischargeNeedsHelperText = "Discharge needs the Anode helper"
    static let helperOutdatedText = "The Anode helper needs updating to control charging"

    /// A discharge's end has not been confirmed by a running helper, and Charge Control is still asking.
    static let cutWarningText = "The charger may still be switched off. Reconnecting\u{2026}"
    /// The same with no helper installed as a daemon: nothing will start a fresh one, and an unplug does not undo
    /// the cut. The way out is what the Fans tab offers: start the helper (its startup switches the charger back
    /// on), or its uninstall, which does the same.
    static let cutWarningNoHelperText = "The charger may still be switched off, and unplugging it will not switch it "
        + "back on. Start the Anode helper again from the Fans tab (Copy Start Command), or run AnodeHelper "
        + "--uninstall with sudo, to switch it back on."

    /// The same while Charge Control is off, with no helper installed: nothing while off can find out whether the
    /// charger is connected, so the line also says what clears it.
    static let cutWarningOffText = "The charger may still be switched off, and unplugging it will not switch it "
        + "back on. Start the Anode helper again from the Fans tab (Copy Start Command): it switches the charger "
        + "back on as it starts. This line goes once Charge Control is on and finds the charger connected."

    /// The same while Charge Control waits to start after an unclean exit, with no helper installed: the setting is on,
    /// so the line cannot say it goes once Charge Control is on. It goes once Charge Control has started and finds the
    /// charger connected.
    static let cutWarningWaitingText = "The charger may still be switched off, and unplugging it will not switch it "
        + "back on. Start the Anode helper again from the Fans tab (Copy Start Command): it switches the charger "
        + "back on as it starts. This line goes once Charge Control has started again and finds the charger connected."

    /// A hold only the helper can set, named by the feature that wanted it: with the person's limit at 80, "limits
    /// other than 80" would be no help. macOS holds the nearest value it takes above it meanwhile, so the Mac charges
    /// on to that; the sentence says so.
    static func limitNeedsHelperText(for d: ChargeDecision) -> String {
        let p = d.osLimit, on = nearestClientValue(atOrAbove: d.osLimit)
        switch d.reason {
        case .heat: return "Pausing for heat at \(p)% needs the Anode helper; it charges on to \(on)%"
        case .sleeping: return "Holding \(p)% while the Mac sleeps needs the Anode helper; it charges on to \(on)%"
        case .sailing: return "Sailing at \(p)% needs the Anode helper; it charges on to \(on)%"
        case .limit, .topUp, .discharging, .discharged: return limitNeedsHelperText
        }
    }

    /// What the battery card is told Charge Control holds: the limit in force when the controller knows it (a hold
    /// or Top Up included), else the person's own; nil while off, and while the delay after an unclean exit holds
    /// nothing. Safe from any thread.
    static func limitForMonitor(settings: Settings, inForce: ChargeLimitInForce) -> Int? {
        guard settings.chargeControlEnabled, !inForce.lifted else { return nil }
        return inForce.value ?? settings.chargeLimit
    }

    /// The launch argument `uninstall.sh` runs the app with: put macOS's own charge settings back, with no window,
    /// and exit 0 if nothing of Charge Control's is left in force, 1 if something may be.
    static let restoreArgument = "--restore-charge-settings"

    /// What that argument does. The same as the Uninstall button's `restoreForUninstall`, on a controller that
    /// starts nothing (Charge Control is never switched on to be switched off, whatever the setting says): the
    /// record put back, the debt of an unconfirmed discharge asked about (waited for; only waited commands work
    /// with no run loop, and they open the connection themselves), the setting turned off, and all of it flushed.
    /// True when no record and no debt are left.
    static func restoreForUninstall(settings: Settings,
                                    makeClient: @escaping () -> ChargeLimitClient? = { PowerUIChargeClient() },
                                    helper: ChargeHelperLink,
                                    log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) }) -> Bool {
        let c = ChargeController(settings: settings, makeClient: makeClient, helper: helper, battery: { nil },
                                 chargerSwitch: { nil }, log: log, workspace: NotificationCenter(),
                                 limitInForce: ChargeLimitInForce(), startDelay: Self.startDelay, observing: false)
        c.restoreForUninstall()
        settings.flush()
        let left = settings.chargeRestoreRecord != nil || settings.chargeCutUnconfirmed
        log(left ? "uninstalling: something of Charge Control's may still be in force"
                 : "uninstalling: macOS's own charge settings are back")
        return !left
    }

    static func dischargeRefusedText(_ why: String) -> String {
        "The Anode helper would not discharge: \(plainWords(why))"
    }
    static func limitRefusedText(_ limit: Int, _ why: String) -> String {
        "The Anode helper did not set the limit to \(limit)%: \(plainWords(why))"
    }

    /// The helper's reasons are written for its log, and some name the part of the Mac it writes to. Shown in the
    /// section, they are said plainly; the log keeps them as they came.
    static func plainWords(_ why: String) -> String {
        var s = why
        if s.hasPrefix("refused: ") { s.removeFirst("refused: ".count) }
        return s.replacingOccurrences(of: "the SMC", with: "the Mac").replacingOccurrences(of: "SMC", with: "the Mac")
    }

    /// How often the battery is looked at while on. Charging moves about 1% a minute at most, and every change
    /// that matters sooner (a plug, a setting, a sleep) has its own trigger.
    static let tickInterval: TimeInterval = 30
    /// The longest anything waits for the helper: going to sleep, switching off, uninstalling.
    static let stopTimeout: TimeInterval = 2
    /// The helper's refusals of a discharge that pass by themselves, so the next tick asks again: the Mac going to
    /// sleep (not an error, and not logged), and the charger switched a moment ago (the helper spaces its cuts
    /// `FanHelperServer.cutSpacing` apart; a reconnect is never held back). Every other refusal is shown, and not
    /// asked again until the person presses again or the decision changes. The sentences are the helper's own
    /// `ChargeRefusal` constants, never a copy.
    static let transientDischargeRefusals: Set<String> = [
        ChargeRefusal.goingToSleep,
        ChargeRefusal.switchedRecently,
    ]

    /// The limit that is no limit. macOS turns its own limit switch off when it is set (see `checkDrift`).
    static let noLimit = 100

    /// How long after a discharge ends with the cable in that macOS may still show "not charging". Measured on
    /// this Mac: about a minute before charging resumes; this leaves room.
    static let chargerReconnectTime: TimeInterval = 90

    /// How long a launch that found the last run did not quit cleanly waits before Charge Control holds a limit again:
    /// macOS's own settings are put back at once, and if Anode breaks again within this the battery stays released.
    /// `liftedText` says "a minute".
    static let startDelay: TimeInterval = 60

    /// The line in the section while that delay runs.
    static let liftedText = "Starting again in a minute. Charge Control waits before holding a limit when Anode "
        + "did not close normally last time."

    /// The policy's last answer.
    private(set) var lastDecision: ChargeDecision?
    private(set) var status: ChargeStatus = .off
    /// The person pressed Discharge and it has not finished, been cancelled, or been ended by an unplug or a sleep.
    private(set) var isDischargeRequested = false
    /// The person pressed Top Up and has not unplugged or cancelled it.
    private(set) var isTopUpRequested = false
    /// The charge the last tick saw; nil while off.
    private(set) var batteryPercent: Int?
    /// Whether the cable was in at the last tick: on the adapter, or cut off from it by Anode's own discharge
    /// (macOS may then report the Mac on battery, but the adapter is still there). False while off.
    private(set) var isCablePresent = false
    /// The discharge the helper said yes to and has not said it stopped: what is running, not what was asked for.
    var dischargeInForce: Int? { appliedDischarge }

    private let settings: Settings
    private let makeClient: () -> ChargeLimitClient?
    private let helper: ChargeHelperLink
    private let battery: () -> Battery.State?
    /// The byte the Mac's own charger switch holds (`AdapterCutKey`): 0x00 connected, 0x08 Anode's cut. nil when it
    /// cannot be read, or this Mac has none; what that means depends on whether it has been read before in this run
    /// (`switchEverRead`). Reading it needs no root and no helper; see `systemChargerSwitch` for the real one and
    /// `chargerSwitchThisTick` for when it is read.
    private let chargerSwitch: () -> UInt8?
    private let log: (String) -> Void
    /// NSWorkspace's notification center: sleep, wake and account switches. A parameter for the tests.
    private let workspace: NotificationCenter
    /// What `limitForMonitor` reads from the monitor's queue; see `ChargeLimitInForce`.
    private let limitInForce: ChargeLimitInForce
    /// This account is the one on screen. The limit is the whole Mac's and each account has its own Anode, so only
    /// the one on screen holds it; see `sessionResigned`.
    private var sessionActive = true
    /// While going to sleep, a limit only the helper can set is waited for, until this, rather than sent and left.
    private var waitUntil: Date?

    private var client: ChargeLimitClient?
    private var memory = ChargeMemory()
    private var sleeping = false
    /// Bumped on every switch-on, so an answer from the helper that belongs to an earlier one is ignored.
    private var session = 0

    // What is in force, as far as this controller knows. Applied values are booked only when macOS or the helper
    // said yes, so a refusal is tried again on a later tick.
    private var appliedLimit: Int? {
        didSet { if appliedLimit != oldValue { limitInForce.set(appliedLimit) } }
    }
    private var limitInFlight = false
    /// Bumped when a waited limit overtakes one still on its way, so the late answer books nothing.
    private var limitEpoch = 0
    /// A limit the helper refused, and why. Not sent again until the decision's limit changes, the Mac wakes, macOS
    /// is found changed, or the section looks again; meanwhile the nearest value macOS takes above it holds.
    private var refusedLimit: (value: Int, why: String)?
    private var appliedDischarge: Int? {
        didSet {
            guard appliedDischarge != oldValue else { return }
            // A discharge that ends with the cable in hands the battery back to the charger, which takes macOS a
            // minute; one that ends because the cable was pulled hands it back to nothing.
            if appliedDischarge != nil {
                dischargeEndedAt = nil
            } else if oldValue != nil {
                dischargeEndedAt = isCablePresent ? Date() : nil
            }
            changed()
        }
    }
    /// When a discharge last ended with the cable in; see `chargerReconnectTimeLeft`.
    private var dischargeEndedAt: Date?
    /// A discharge or a stop is on its way to the helper.
    private var dischargeInFlight = false
    /// Bumped when a discharge in flight is overtaken (going to sleep stops it), so its late answer is ignored.
    private var dischargeEpoch = 0
    /// A discharge the helper refused for a reason that does not pass by itself, and the reason. Not asked for
    /// again until the person presses again or the decision changes.
    private var blockedDischarge: (target: Int, why: String)?
    private var seenResets = 0
    private var lastRefusal: String?
    /// The last "changed outside Charge Control" line, so the same news is logged once.
    private var lastDrift: String?

    // The charger cut, as far as anyone has confirmed it. See the note at the top of the file.

    /// The debt: a discharge was asked for, or the net found a cut nobody holds (`noteCutLook`), and nothing has shown
    /// the charger connected since (a running helper's yes to a stop, the helper's own uninstall, or the charger
    /// switch itself; see `noteConnected`). Mirrors `Settings.chargeCutUnconfirmed`, which is written (and flushed)
    /// before the discharge goes out, or the stop for the cut the net found.
    private var cutOwed = false {
        // The section shows it while off too (`offWarning`), and nothing else would tell it.
        didSet { if cutOwed != oldValue { changed() } }
    }
    /// A stop goes out before anything else, whatever the policy wants and whether or not the helper has answered:
    /// the debt was found at launch, or the connection was reset under a discharge.
    private var stopDue = false
    /// A stop was not answered yes (the helper is gone, or could not reconnect the charger): the cut may be left
    /// with nobody watching. The warning shows, and the stop is asked again once a tick until a running helper says
    /// yes, the helper's uninstall finishes (`helperUninstalled`), or the charger shows as connected for long
    /// enough (`noteConnected`).
    private var cutLost = false
    /// The charger has looked cut (`noteCutLook`: the switch reading cut, or macOS's word where that is all there
    /// is), with no discharge in force, for longer than the end of a discharge takes: the look of a cut nobody
    /// holds. Treated like `cutLost` while it lasts; a stop it asks that is not answered yes sets `cutLost`, which
    /// outlasts the look and is settled the same ways.
    private var cutSeen = false
    /// When that look began; nil while the charger does not look cut, or a discharge is in force.
    private var cutLookSince: Date?
    /// A running helper said the charger is connected during this stretch of that look: not asked again until it
    /// ends, or a charger macOS reports oddly would wake the helper every tick.
    private var cutLookAnswered = false
    /// Since when the charger has shown as connected, with something to settle and no discharge in force; nil
    /// otherwise. See `noteConnected`.
    private var connectedSince: Date?
    /// What the charger switch read in which tick; see `chargerSwitchThisTick`.
    private var switchRead: (tick: Int, value: UInt8?)?
    /// The switch has been read at least once in this run of the app. From then on a read that fails is no
    /// information (see `noteCutLook`, `noteConnected`); before it, a read that fails means this Mac's switch cannot
    /// be read, and macOS's word is what there is. Not forgotten when Charge Control is switched off: it is about the
    /// Mac and the run, not the switch-on.
    private var switchEverRead = false
    /// A switch that had been read could not be read, and that was logged: once, until it reads again.
    private var switchLost = false
    /// Counts the discharges sent: a stop's yes settles the debt only if no discharge went out after the stop.
    private var dischargeSeq = 0
    /// A stop's answer said the charger switch holds a value Anode never writes, and that has been logged: once.
    private var saidNotAnodesValue = false
    /// Counts calls to `tick`. A stop for a lost cut goes out at most once a tick, so a helper that keeps not
    /// answering is asked every tick, not in a loop on its own answers.
    private var tickSerial = 0
    private var lostStopTick = -1
    /// While switching off, quitting or uninstalling, the helper's news does not start a tick.
    private var switchingOff = false

    // Looking again for a helper that did not answer (a cold start slower than its hello), while something needs it.

    /// When to look next; nil while nothing needs the helper, or it has answered.
    private var lookDueAt: Date?
    private var lookCount = 0
    /// 30 s after the first miss, then 60 s, 120 s, and every five minutes after that.
    static let lookAgainAfter: [TimeInterval] = [30, 60, 120, 300]

    // While off, the debt is asked about on a timer of its own, which exists only while there is one.
    private var offRetryTimer: Timer?
    private var offStopInFlight = false
    private var lastOffFailure: String?

    // After a launch that found the last run did not quit cleanly (`liftAfterUncleanExit`): macOS's own settings are
    // back and Charge Control is on in the setting but holds nothing, until this time.
    private let startAfter: TimeInterval
    private var startsAt: Date? {
        didSet {
            guard (startsAt == nil) != (oldValue == nil) else { return }
            // The battery card is not told a limit is held while it is lifted (`limitForMonitor`).
            limitInForce.setLifted(startsAt != nil)
            changed()
        }
    }
    private var startTimer: Timer?
    /// Another account came on screen during the delay, so `sessionActive` is false until it goes (the controller is
    /// not running, so the observers that normally say so are not installed: these two are).
    private var startObservers: [NSObjectProtocol] = []
    /// The delay ran out while another account was on screen: this account starts when it is back.
    private var delayOver = false

    /// Charge Control is on in the setting but has not started: it is waiting out the delay after an unclean exit,
    /// and holds nothing.
    var isWaitingToStart: Bool { startsAt != nil }

    /// A tick asked for while one runs (the helper link can answer inside it) runs again after it, not inside it.
    private var ticking = false
    private var tickAgain = false

    // Triggers. Only `enabledToken` exists while off.
    private var enabledToken: AnyObject?
    private var keyTokens: [AnyObject] = []
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    private var running: Bool { client != nil }

    /// Everything that wants to hear about changes; see `observeChanges`. Held weakly: the listener holds the token.
    private var observers: [WeakObservation] = []

    private final class Observation {
        let call: () -> Void
        init(_ call: @escaping () -> Void) { self.call = call }
    }

    private struct WeakObservation {
        weak var value: Observation?
    }

    convenience init(settings: Settings, makeClient: @escaping () -> ChargeLimitClient? = { PowerUIChargeClient() },
                     helper: ChargeHelperLink, battery: @escaping () -> Battery.State? = { Battery.state() },
                     chargerSwitch: @escaping () -> UInt8? = ChargeController.systemChargerSwitch(),
                     log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) },
                     workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                     limitInForce: ChargeLimitInForce = ChargeLimitInForce(),
                     startDelay: TimeInterval = ChargeController.startDelay) {
        self.init(settings: settings, makeClient: makeClient, helper: helper, battery: battery,
                  chargerSwitch: chargerSwitch, log: log, workspace: workspace, limitInForce: limitInForce,
                  startDelay: startDelay, observing: true)
    }

    /// The Mac's own charger switch, read as the person and not through the helper: only writing it needs root
    /// (measured on Mac17,9, macOS 27.0: an unprivileged process reads it). The helper's own reader and key name
    /// (`SystemChargeHardware.adapterCutValue`), so there is one of each; nothing here can write. The connection to
    /// the SMC is opened at the first read, which is never while Charge Control is off.
    ///
    /// A read that fails is followed, at the next read, by a new connection. `SystemChargeHardware()` cannot fail: an
    /// SMC that would not open is kept inside it as "no connection" for good (`SMC.init?` is nil then), and a
    /// connection that has died is never opened again by itself. So the one that failed is dropped, and the next read
    /// opens one (one open at most per read, and the controller reads once a tick at most). `open` is a parameter for
    /// the tests, which must not reach the real SMC.
    static func systemChargerSwitch(open: @escaping () -> ChargeHardware = { SystemChargeHardware() })
        -> () -> UInt8? {
        var hardware: ChargeHardware?
        var lastReadFailed = false
        return {
            if hardware == nil || lastReadFailed { hardware = open() }
            let value = hardware?.adapterCutValue()
            lastReadFailed = value == nil
            return value
        }
    }

    /// `observing` false: a controller that watches nothing and starts nothing, for the uninstall's restore with no
    /// window (`restoreForUninstall(settings:...)`), which must not switch Charge Control on to switch it off.
    private init(settings: Settings, makeClient: @escaping () -> ChargeLimitClient?, helper: ChargeHelperLink,
                 battery: @escaping () -> Battery.State?, chargerSwitch: @escaping () -> UInt8?,
                 log: @escaping (String) -> Void, workspace: NotificationCenter, limitInForce: ChargeLimitInForce,
                 startDelay: TimeInterval, observing: Bool) {
        self.settings = settings
        self.makeClient = makeClient
        self.helper = helper
        self.battery = battery
        self.chargerSwitch = chargerSwitch
        self.log = log
        self.workspace = workspace
        self.limitInForce = limitInForce
        self.startAfter = startDelay
        cutOwed = settings.chargeCutUnconfirmed
        guard observing else { return }
        enabledToken = settings.observe(Settings.Key.chargeControlEnabled) { [weak self] in self?.applyEnabled() }
        // On at launch with the record still there: the last run did not quit. Only a launch takes this route; a
        // person switching on by hand later does not.
        if settings.chargeControlEnabled, liftAfterUncleanExit() {
            // Nothing else starts until the delay is over.
        } else {
            applyEnabled()
        }
        if !settings.chargeControlEnabled {
            // Off at launch, a record left over means macOS may still hold a limit Anode set while the switch shows
            // off (a switch-off macOS partly refused, or the setting turned off while Anode was closed). Put back
            // once.
            putBackLeftoverRecord(when: "at launch")
            // And a discharge whose end no running helper confirmed may have left the charger cut.
            retryOwedStopWhileOff()
        }
    }

    deinit {
        removeTriggers()
        offRetryTimer?.invalidate()
        startTimer?.invalidate()
        for o in startObservers { workspace.removeObserver(o) }
        // The connection is shared: a claim left behind would keep it open for good.
        if running { helper.letGo() }
    }

    // ── Listening ───────────────────────────────────────────────────────────

    /// Call `f` (on the main thread) whenever something the section shows may have changed: `status`, the two press
    /// flags, `dischargeInForce`, `batteryPercent` or `isCablePresent`. Any number of listeners; each keeps hearing
    /// for as long as it keeps the token returned, and none can take another's place.
    func observeChanges(_ f: @escaping () -> Void) -> AnyObject {
        let o = Observation(f)
        observers.append(WeakObservation(value: o))
        return o
    }

    private func changed() {
        observers.removeAll { $0.value == nil }
        // A copy: a listener may start or stop listening while it is called.
        for o in observers { o.value?.call() }
    }

    /// How much longer macOS may show "not charging" after a discharge ended with the cable in, before it charges
    /// again; nil when it should not (no discharge ended lately, the cable is out, a discharge runs).
    func chargerReconnectTimeLeft(now: Date = Date()) -> TimeInterval? {
        guard let ended = dischargeEndedAt, isCablePresent, appliedDischarge == nil else { return nil }
        let left = Self.chargerReconnectTime - now.timeIntervalSince(ended)
        return left > 0 ? left : nil
    }

    // ── On and off ──────────────────────────────────────────────────────────

    private func applyEnabled() {
        if settings.chargeControlEnabled { enable() } else { disable() }
    }

    private func enable() {
        // Not while the delay after an unclean exit runs: that ends in `startNow`, or is cancelled by switching off.
        guard !running, startsAt == nil else { return }
        guard let c = makeClient() else {
            log("unavailable: the macOS charge limit client is missing on this Mac")
            return setStatus(.unavailable(Self.unavailableText))
        }
        // The way back is written down before anything is changed, and flushed: macOS keeps these settings if Anode
        // dies, so the record has to survive a crash in the next few lines. A record still there is the state before
        // Charge Control ever ran (at launch it is not: see `liftAfterUncleanExit`; here it is one a refused
        // switch-off or restore left), and stays. So does one that cannot be read: the state found now may be one
        // Charge Control made, and switching off puts back macOS's defaults instead.
        if let text = settings.chargeRestoreRecord {
            if Self.decodeRecord(text) == nil {
                log("the record of macOS's own settings could not be read; it is kept, and switching off will put "
                    + "back macOS's defaults")
            }
        } else {
            guard let found = c.read(), let json = Self.encodeRecord(found) else {
                log("unavailable: macOS did not report its charge settings; nothing was changed")
                return setStatus(.unavailable(Self.unreadableText))
            }
            settings.chargeRestoreRecord = json
            settings.flush()
            log("recorded macOS's own settings: limit \(found.mclLimit) \(found.mclEnabled ? "on" : "off"), "
                + "Optimized Battery Charging \(found.optimizedChargingEnabled ? "on" : "off")")
        }
        client = c
        session += 1
        endOffRetry()
        // A debt left from before (a quit, a crash, a switch-off the helper did not answer) is paid first.
        cutOwed = settings.chargeCutUnconfirmed
        stopDue = cutOwed
        if cutOwed { log("a discharge's end was never confirmed; asking the helper to reconnect the charger") }
        // Two controllers on one charger would fight; Optimized Battery Charging comes back on when this goes off.
        if !c.setOptimizedCharging(false) { log("macOS would not turn Optimized Battery Charging off") }
        if !c.setLimitEnabled(true) { log("macOS would not turn its charge limit on") }
        log("on")
        installTriggers()
        seenResets = helper.resets
        helper.follow { [weak self] in self?.helperChanged() }
        tick()
    }

    private func disable() {
        // Off during the delay after an unclean exit cancels it, and no start is pending any more. Nothing of Charge
        // Control's is in force then unless the lift was refused (`liftAfterUncleanExit`): the record is then still
        // there, and the dead run's limit with it, so it is put back as for any record left over while off.
        let wasWaiting = startsAt != nil
        endStartWait()
        setStartPending(false)
        if wasWaiting { putBackLeftoverRecord(when: "as the delay was cancelled") }
        if running, let c = client {
            switchingOff = true
            restore(client: c)
            stop()
            switchingOff = false
            log("off")
            // A stop the helper did not answer leaves the debt, which is asked about while off too.
            retryOwedStopWhileOff()
        }
        setStatus(.off)
    }

    /// Put macOS back as the record says: the limit, the limit's switch and Optimized Battery Charging, after a
    /// running discharge is stopped and after everything already on its way to the helper has landed (a limit it
    /// is still setting would otherwise land after this and stay, with nothing left to undo it). The helper's parts
    /// are waited for on this thread, `stopTimeout` at most for all of them together: a helper that has stopped
    /// answering must not hold the main thread once for each.
    ///
    /// The record is cleared only when every step is known to have worked. Otherwise it is kept and that is logged,
    /// so the next switch-off, quit or launch tries again from the true original rather than from what is left.
    ///
    /// Used for switching off, quitting and uninstalling, and at a launch that finds the last run did not quit
    /// (`liftAfterUncleanExit`); `why` names which, in the line about a discharge stopped on the way.
    private func restore(client c: ChargeLimitClient, leaving why: String = "switching off") {
        let deadline = Date().addingTimeInterval(Self.stopTimeout)
        // A stop goes behind everything already sent on the same link, so its answer also says those have landed.
        let settled: Bool
        if appliedDischarge != nil || dischargeInFlight || cutOwed {
            let r = waitedStop(timeout: Self.timeLeft(deadline))
            log("discharge stopped (\(why)): \(r?.message ?? "no answer within \(Int(Self.stopTimeout)) s")")
            settled = r != nil
        } else {
            settled = helper.drain(timeout: Self.timeLeft(deadline))
        }
        if !settled {
            log("the helper had not finished what it was asked within \(Int(Self.stopTimeout)) s; it may land after "
                + "this")
        }
        let record: NativeChargeState
        if let found = recordToRestore() {
            record = found
        } else {
            // Lost while on (removed by hand, say): Charge Control's settings are not left in force for that.
            log("no record of macOS's own settings to put back; putting back macOS's defaults: no limit, "
                + "Optimized Battery Charging on")
            record = Self.defaultRecord
        }
        var ok = restoreLimit(record.mclLimit, client: c, deadline: deadline) && settled
        ok = c.setLimitEnabled(record.mclEnabled) && ok
        ok = c.setOptimizedCharging(record.optimizedChargingEnabled) && ok
        if ok {
            settings.chargeRestoreRecord = nil
            settings.flush()
            log("put back macOS's own settings: limit \(record.mclLimit) \(record.mclEnabled ? "on" : "off"), "
                + "Optimized Battery Charging \(record.optimizedChargingEnabled ? "on" : "off")")
        } else {
            log("putting back macOS's own settings is not known to have worked; the record is kept")
        }
    }

    /// The recorded limit itself, or false. Only the helper can put back one macOS does not take by itself; an
    /// installed one is greeted for it even when nothing has talked to it this run (Charge Control off, or this is
    /// the uninstall): the waited command opens the connection first. When the value cannot land, the nearest one
    /// macOS takes at or above it is set, so the Mac can still charge at least that far, and false keeps the record
    /// for the next launch to try again. The helper is waited for until `deadline`, the restore's own.
    private func restoreLimit(_ limit: Int, client c: ChargeLimitClient, deadline: Date) -> Bool {
        if NativeChargeLimit.isClientSettable(limit) { return c.setLimit(limit) }
        let nearest = Self.nearestClientValue(atOrAbove: limit)
        let why: String
        if helper.available || helper.installed {
            let r = helper.sendWaiting(.setChargeLimit(limit), timeout: Self.timeLeft(deadline))
            if r?.ok == true { return true }
            why = "the helper did not put the limit back to \(limit): " + (r?.message ?? "no answer in time")
        } else {
            why = "limit \(limit) needs the helper to put back, and none is installed"
        }
        log("\(why); set \(nearest) for now, and the record is kept to try again at the next launch")
        _ = c.setLimit(nearest)
        return false
    }

    /// Forget everything this switch-on built. Leaves macOS as it is.
    private func stop() {
        removeTriggers()
        helper.letGo()
        client = nil
        memory = ChargeMemory()
        sleeping = false
        lastDecision = nil
        appliedLimit = nil
        limitInFlight = false
        refusedLimit = nil
        appliedDischarge = nil
        dischargeInFlight = false
        blockedDischarge = nil
        isDischargeRequested = false
        isTopUpRequested = false
        batteryPercent = nil
        isCablePresent = false
        dischargeEndedAt = nil
        lastRefusal = nil
        lastDrift = nil
        // The debt itself (`cutOwed`) is on disk and outlives this; what was being done about it does not.
        stopDue = false
        cutLost = false
        cutSeen = false
        cutLookSince = nil
        cutLookAnswered = false
        connectedSince = nil
        switchRead = nil
        lookDueAt = nil
        lookCount = 0
    }

    /// The app is quitting: Charge Control's limit is in force only while Anode is running, so macOS's own settings
    /// are put back, as switching off puts them back (`restore`): a running discharge is stopped and its end waited
    /// for, so nothing drains with nobody watching, then the limit, the limit's switch and Optimized Battery Charging
    /// go back from the record, and the record is cleared once that is known to have worked. The setting and the
    /// person's own limit and options are left alone: the next launch switches on again from a cold start. A put-back
    /// macOS or the helper refused leaves the record, and the next launch then lifts the limit
    /// (`liftAfterUncleanExit`). Then the helper link is let go. All the waiting together is `stopTimeout` at most.
    ///
    /// Not when the record has gone (something else, an uninstall, has put macOS back since), and not while another
    /// account is on screen: the limit in force is that account's Anode's, not this one's. A discharge is still
    /// stopped then.
    func shutdown() {
        enabledToken = nil
        endOffRetry()
        // A quit during the delay is a clean one: nothing is pending, and macOS's own settings are in force, unless
        // the lift was refused: the record is then still there, and is put back now (not while another account is on
        // screen: the limit in force is its Anode's).
        let wasWaiting = startsAt != nil, onScreen = sessionActive
        endStartWait()
        setStartPending(false)
        if wasWaiting, onScreen { putBackLeftoverRecord(when: "as Anode quit", leaving: "quitting") }
        guard running, let c = client else { return }
        switchingOff = true
        defer { switchingOff = false }
        if sessionActive, settings.chargeRestoreRecord != nil {
            restore(client: c, leaving: "quitting")
        } else if appliedDischarge != nil || dischargeInFlight || cutOwed {
            let r = waitedStop(timeout: Self.stopTimeout)
            log("discharge stopped (quitting): \(r?.message ?? "no answer in time")")
        } else if limitInFlight {
            _ = helper.drain(timeout: Self.stopTimeout)
        }
        stop()
    }

    /// What is left of a wait that must end by `deadline`; never nothing, so a late step still gets a moment.
    private static func timeLeft(_ deadline: Date) -> TimeInterval {
        max(0.1, deadline.timeIntervalSinceNow)
    }

    /// Anode is being uninstalled: put macOS back now, waiting for the helper, and switch Charge Control off.
    ///
    /// Also while off, if a record is left over (a switch-off macOS partly refused, or the setting turned off while
    /// Anode was closed): once Anode is gone nothing could ever undo that hold.
    func restoreForUninstall() {
        // Nothing is pending once Charge Control is switched off and macOS put back; the headless restore has no
        // observer to do that when the setting goes off.
        setStartPending(false)
        if running, let c = client {
            switchingOff = true
            restore(client: c)
            stop()
            switchingOff = false
            log("off (uninstalling)")
        } else if !putBackLeftoverRecord(when: "before uninstalling"), cutOwed {
            // Once Anode is gone nothing would ever pay the debt, so it is asked about now, and waited for. (A
            // restore asks about it itself.)
            let r = waitedStop(timeout: Self.stopTimeout)
            log("discharge stopped (before uninstalling): "
                + "\(r?.message ?? "no answer within \(Int(Self.stopTimeout)) s")")
        }
        endOffRetry()
        setStatus(.off)
        settings.chargeControlEnabled = false
    }

    /// While off: put back a record that is left over, with a client made for that alone and let go at once (the
    /// only times a client exists while off: at launch, and before an uninstall). Nothing else starts: no timer, no
    /// observer, no helper connection. `restore` logs how it went; a refusal keeps the record. False when there was
    /// nothing to put back, or no client to do it with.
    @discardableResult
    private func putBackLeftoverRecord(when: String, leaving: String = "switching off") -> Bool {
        guard !running, settings.chargeRestoreRecord != nil, let c = makeClient() else { return false }
        log("a record of macOS's own settings was left over while off; putting it back \(when)")
        restore(client: c, leaving: leaving)
        return true
    }

    // ── After an unclean exit ───────────────────────────────────────────────

    /// At launch, with Charge Control on in the setting: a record still there means the last run did not quit (a
    /// quit puts macOS back and clears it), and macOS's limit may still be in force with nobody holding it. Put
    /// macOS's own settings back at once, with a client made for that alone and let go, as for a record left over
    /// while off. Then switch on again only after `startAfter`, so that an Anode that breaks again within it leaves
    /// the battery released: the sentence in the section says so (`liftedText`), and the setting and the person's
    /// limit are not touched. True when it did this, false when there is nothing to lift (no record, no start
    /// pending) or no client to do it with (the ordinary switch-on then reports that).
    ///
    /// A start still pending (`Settings.chargeStartPending`) takes the same route with no record: the last run was
    /// itself waiting out this delay and died before it ended, which cleared the record but not the pending start.
    /// There is nothing to put back then, and the full delay is waited again. The flag is written, and flushed,
    /// before anything is put back, so that no crash between the record going and the wait starting can leave neither;
    /// it stays until the switch-on after the delay has run (`startNow`), or Charge Control is switched off, quits
    /// cleanly or is uninstalled.
    ///
    /// A discharge's end never confirmed is dealt with first and as before: `restore` waits for a stop ahead of
    /// anything else, and what it could not settle is asked again on the off-retry's timer until a running helper
    /// answers (with no record there is no restore, and the retry asks at once). The delay holds back the limit and
    /// new discharges, never the reconnecting of a charger. A restore macOS refused keeps the record; the switch-on
    /// that follows leaves it as it is.
    private func liftAfterUncleanExit() -> Bool {
        let recorded = settings.chargeRestoreRecord != nil
        guard recorded || settings.chargeStartPending else { return false }
        // Something to put back needs a client; with nothing, the wait is all there is.
        let c = recorded ? makeClient() : nil
        if recorded, c == nil { return false }
        setStartPending(true)
        if let c {
            log("Anode did not quit cleanly last time (the record of macOS's own settings was still there); putting "
                + "them back now, and Charge Control starts again in \(Int(startAfter)) s")
            restore(client: c)
        } else {
            log("a start was still pending from last time (Anode stopped before the delay ended); nothing to put "
                + "back, and Charge Control starts again in \(Int(startAfter)) s")
        }
        waitToStart()
        retryOwedStopWhileOff()
        return true
    }

    /// One timer, once, on the main run loop (as the tick and the off-retry are); the controller does not run until it
    /// fires, and `resumeIfDue` is the same step for the tests. Meanwhile the two session notifications are heard, so
    /// that it does not start into another account's limit (see `startNow`).
    private func waitToStart() {
        let due = Date().addingTimeInterval(startAfter)
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in self?.startNow() }
        t.tolerance = min(5, startAfter / 10)
        RunLoop.main.add(t, forMode: .common)
        startTimer = t
        startObservers = [
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                                  queue: .main) { [weak self] _ in self?.sessionActive = false },
            workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                                  queue: .main) { [weak self] _ in self?.sessionBecameActiveWhileWaiting() },
        ]
        startsAt = due
        setStatus(.waiting(Self.liftedText))
    }

    /// The delay is over, if `now` says so: switch on as from a cold start. Internal so the tests can be the clock.
    func resumeIfDue(now: Date = Date()) {
        guard let due = startsAt, now >= due else { return }
        startNow()
    }

    /// Not while another account is on screen: macOS's limit is the whole Mac's and what it says now is that
    /// account's, which switching on would write down as macOS's own and then fight over. The start waits for this
    /// account to be back (`sessionBecameActiveWhileWaiting`).
    private func startNow() {
        guard startsAt != nil else { return }
        guard sessionActive else {
            if !delayOver { log("the delay after an unclean exit is over, but another account is on screen; "
                                + "switching on when this one is back") }
            delayOver = true
            return
        }
        endStartWait()
        log("the delay after an unclean exit is over; switching on")
        enable()
        // Only now: Anode has stayed up for the whole delay and the ordinary switch-on has run.
        setStartPending(false)
    }

    /// Written down, and flushed, before what depends on it happens, like the record and the debt.
    private func setStartPending(_ pending: Bool) {
        guard settings.chargeStartPending != pending else { return }
        settings.chargeStartPending = pending
        settings.flush()
    }

    private func sessionBecameActiveWhileWaiting() {
        sessionActive = true
        if delayOver { startNow() }
    }

    /// The delay is over or cancelled. This account is taken to be on screen again: it is whoever switches Charge
    /// Control on next, or the one that has just started.
    private func endStartWait() {
        startTimer?.invalidate()
        startTimer = nil
        for o in startObservers { workspace.removeObserver(o) }
        startObservers = []
        delayOver = false
        if startsAt != nil { sessionActive = true }
        startsAt = nil
    }

    /// A stop, waited for, after a hello over the connection (a new one if the old one does not answer: for an
    /// installed helper that starts a fresh one, whose startup reconnects the charger). A yes settles the debt.
    private func waitedStop(timeout: TimeInterval) -> FanReply? {
        let seq = dischargeSeq
        let r = helper.sendWaiting(.stopDischarge, timeout: timeout)
        if let r, r.ok { chargerConfirmed(stopSentAt: seq, message: r.message) }
        return r
    }

    /// While off: a discharge's end that no running helper confirmed (a switch-off it did not answer, or a quit
    /// or crash before it did) may have left the charger cut. Ask an installed helper to reconnect it, at launch
    /// and then every 30 s, until one answers yes. Nothing else starts, and with no debt nothing at all exists.
    ///
    /// Internal so the tests can be the timer.
    func retryOwedStopWhileOff() {
        guard !running, cutOwed, helper.installed else { return endOffRetry() }
        if offRetryTimer == nil {
            let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                self?.retryOwedStopWhileOff()
            }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            offRetryTimer = t
            // The line while off says so now (`offWarning`).
            changed()
        }
        guard !offStopInFlight else { return }
        offStopInFlight = true
        let seq = dischargeSeq
        helper.send(.stopDischarge) { [weak self] r in
            guard let self else { return }
            self.offStopInFlight = false
            // Switched on meanwhile: the controller's own stop has this now.
            guard !self.running else { return }
            if r.ok {
                self.chargerConfirmed(stopSentAt: seq, message: r.message)
                if !Self.isNotAnodesValue(r.message) { self.log("the charger is connected: \(r.message)") }
                self.endOffRetry()
            } else if r.message != self.lastOffFailure {
                self.lastOffFailure = r.message
                self.log("a discharge's end is still not confirmed: \(r.message); asking again every "
                         + "\(Int(Self.tickInterval)) s")
            }
        }
    }

    private func endOffRetry() {
        let ended = offRetryTimer != nil
        offRetryTimer?.invalidate()
        offRetryTimer = nil
        lastOffFailure = nil
        // The line while off stops saying "Reconnecting…" (`offWarning`).
        if ended { changed() }
    }

    // ── The debt ────────────────────────────────────────────────────────────

    /// Written down, and flushed, before anything that can cut the charger goes out.
    private func oweCut() {
        guard !cutOwed else { return }
        cutOwed = true
        settings.chargeCutUnconfirmed = true
        settings.flush()
    }

    /// A running helper answered a stop with yes: the charger is connected (or was never cut, or holds a value Anode
    /// never writes, which is not Anode's cut). Settles the debt, unless a discharge went out after that stop.
    private func chargerConfirmed(stopSentAt seq: Int, message: String) {
        let foreign = Self.isNotAnodesValue(message)
        if foreign, !saidNotAnodesValue {
            saidNotAnodesValue = true
            log("\(message): it is not Anode's cut, so Charge Control leaves it as it is")
        }
        guard seq == dischargeSeq else { return }
        let wasLost = (cutLost || cutSeen) && !foreign
        stopDue = false
        cutLost = false
        if cutSeen || cutLookSince != nil { cutLookAnswered = true }
        cutSeen = false
        if cutOwed || settings.chargeCutUnconfirmed {
            cutOwed = false
            settings.chargeCutUnconfirmed = false
            settings.flush()
        }
        if wasLost { log("a running helper says the charger is connected") }
    }

    /// The helper's ok to a stop that found the charger switch holding a value Anode never writes, and left it.
    static func isNotAnodesValue(_ message: String) -> Bool {
        message.hasPrefix(ChargeRelease.notAnodesValue)
    }

    /// The helper's own uninstall finished (the Fans tab's button). It reconnects the charger itself, and fails when
    /// it cannot (`FanElevation.uninstallEnd`), so the debt is settled, on or off: with no helper left, no stop could
    /// ever be answered, and the warning would otherwise stay for good. Called before the shared connection opens
    /// again.
    func helperUninstalled() {
        settleWithoutTheHelper("the helper's uninstall reconnected the charger")
    }

    /// The charger is known to be connected by something other than a helper's yes to a stop
    /// (`chargerConfirmed`): the helper's own uninstall, or the charger switch itself (`noteConnected`). The debt, a
    /// lost cut and the net are all dropped, and whatever is still on its way is overtaken, so its late answer (from
    /// a helper that is gone) cannot bring the warning back. While off, the retry ends.
    private func settleWithoutTheHelper(_ why: String) {
        let had = somethingToSettle
        dischargeEpoch += 1
        dischargeInFlight = false
        appliedDischarge = nil
        stopDue = false
        cutLost = false
        cutSeen = false
        cutLookSince = nil
        cutLookAnswered = false
        if cutOwed || settings.chargeCutUnconfirmed {
            cutOwed = false
            settings.chargeCutUnconfirmed = false
            settings.flush()
        }
        endOffRetry()
        if had { log(why) }
        settle()
    }

    /// What the section shows under the switch while Charge Control is off: nothing, unless a discharge's end was
    /// never confirmed. Then the charger may still be cut, and the line says so: "Reconnecting…" while an installed
    /// helper is being asked (`retryOwedStopWhileOff`), otherwise how to get it back. Makes nothing: no client,
    /// timer or helper traffic is added for it.
    var offWarning: String? {
        guard !running, cutOwed else { return nil }
        if offRetryTimer != nil { return Self.cutWarningText }
        return isWaitingToStart ? Self.cutWarningWaitingText : Self.cutWarningOffText
    }

    /// A stop was not answered yes: by a helper that is gone (or a link that heard nothing), or by one that could
    /// not reconnect the charger. The cut may be left with nobody watching: warn, keep the connection, and ask
    /// again at once (the link opens a new connection for it), then once a tick.
    private func stopNotConfirmed(_ why: String) {
        appliedDischarge = nil
        stopDue = true
        let news = !cutLost
        cutLost = true
        settle()
        guard news, running else { return }
        log("the charger may still be cut off, and nothing is watching it: \(why); asking the helper again")
        stopDischarge(why: "asking again")
    }

    // ── Triggers ────────────────────────────────────────────────────────────

    private func installTriggers() {
        let keys = [Settings.Key.chargeLimit, Settings.Key.chargeSailingEnabled, Settings.Key.chargeSailingGap,
                    Settings.Key.chargeHeatProtectionEnabled, Settings.Key.chargeMaxTemperatureC,
                    Settings.Key.chargeStopWhenSleeping, Settings.Key.chargeAutomaticDischarge]
        keyTokens = keys.map { settings.observe($0) { [weak self] in self?.tick() } }

        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.periodicTick()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ws = workspace
        workspaceObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.willSleep()
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.didWake()
            },
            ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                           queue: .main) { [weak self] _ in
                self?.sessionResigned()
            },
            ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                           queue: .main) { [weak self] _ in
                self?.sessionBecameActive()
            },
        ]

        // Plugging in or unplugging. The context is unretained, so the source is always removed before this
        // object goes (`removeTriggers`, also from deinit).
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<ChargeController>.fromOpaque(ctx).takeUnretainedValue().tick()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
    }

    private func removeTriggers() {
        keyTokens = []
        timer?.invalidate()
        timer = nil
        for o in workspaceObservers { workspace.removeObserver(o) }
        workspaceObservers = []
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }
    }

    /// The 30 s timer. Internal so the tests can be the timer.
    ///
    /// It talks to the helper only while a discharge lives on the connection, to notice a helper that went away
    /// under it, or while something needs a helper that has not answered (see `lookAgainIfDue`). Otherwise the
    /// daemon is left asleep: a limit it set stays set without it.
    func periodicTick(now: Date = Date()) {
        guard running else { return }
        if appliedDischarge != nil { helper.refresh() }
        // Another account on screen holds the limit: its changes are not drift.
        if sessionActive { checkDrift() }
        tick(now: now)
        lookAgainIfDue(now: now)
    }

    /// Something needs the helper (a limit only it can set, not in force; or a discharge) and an installed one has
    /// not answered: its cold start was slower than its hello, say. Looked for again 30 s, 60 s and 120 s apart,
    /// then every five minutes. An outdated helper has answered, and is not woken to say so again.
    private var helperMissedWhileNeeded: Bool {
        guard let d = lastDecision, helper.known, !helper.available, !helper.outdated, helper.installed else {
            return false
        }
        let limitWaits = !NativeChargeLimit.isClientSettable(d.osLimit) && appliedLimit != d.osLimit
        return limitWaits || d.dischargeTo != nil
    }

    private func noteHelperNeed(now: Date) {
        if !helperMissedWhileNeeded {
            lookDueAt = nil
            lookCount = 0
        } else if lookDueAt == nil {
            lookDueAt = now.addingTimeInterval(Self.lookAgainAfter[0])
        }
    }

    private func lookAgainIfDue(now: Date) {
        // The timer's tolerance: a tick 30 s on may come a few seconds early.
        guard running, sessionActive, helperMissedWhileNeeded, let due = lookDueAt,
              now >= due.addingTimeInterval(-5) else { return }
        lookCount += 1
        lookDueAt = now.addingTimeInterval(Self.lookAgainAfter[min(lookCount, Self.lookAgainAfter.count - 1)])
        helper.recheck()
    }

    /// Read macOS back. If the limit's switch, the limit or Optimized Battery Charging is not what this controller
    /// put in force (the person changed it in System Settings, or something else did), say so once, forget what
    /// was believed, and put all three back; the tick that follows sets the limit. Once per call, on the timer and
    /// after a wake, so a Mac that keeps refusing is asked again 30 s later, never in a loop.
    ///
    /// The switch reading off is not a change when 100 is what this controller put in force and 100 is what macOS
    /// reads: macOS turns the switch off by itself once the limit is set to 100 (measured on Mac17,9, macOS 27.0:
    /// "off, 100" read back seconds after 100 was set; taken for drift, 100 was set again every 30 s for as long as
    /// the limit, or Top Up, was 100). Off with anything below 100 in force is still a change, as is any other limit.
    private func checkDrift() {
        guard let c = client, let found = c.read() else { return }
        var changed: [String] = []
        let offByItself = appliedLimit == Self.noLimit && found.mclLimit == Self.noLimit
        if !found.mclEnabled, !offByItself { changed.append("the limit was turned off") }
        if found.optimizedChargingEnabled { changed.append("Optimized Battery Charging was turned on") }
        if let mine = appliedLimit, !limitInFlight, found.mclLimit != mine {
            changed.append("the limit is \(found.mclLimit), not \(mine)")
        }
        guard !changed.isEmpty else {
            lastDrift = nil
            return
        }
        // The same news every 30 s is one line, not one a tick.
        let line = "macOS's charge settings changed outside Charge Control: " + changed.joined(separator: "; ")
            + "; putting them back"
        let news = line != lastDrift
        if news { log(line) }
        lastDrift = line
        appliedLimit = nil
        refusedLimit = nil
        if !c.setOptimizedCharging(false), news { log("macOS would not turn Optimized Battery Charging off") }
        if !c.setLimitEnabled(true), news { log("macOS would not turn its charge limit on") }
    }

    /// The helper link came, went, answered, or was reset under a discharge.
    ///
    /// A reset under a discharge (or while its end is unconfirmed) does not end it: the helper that held the cut
    /// may have died with the charger cut, or a live one may have reconnected it; nobody can tell which. So a stop
    /// goes out before anything else, and a discharge still wanted is asked for again after its yes.
    private func helperChanged() {
        guard running, !switchingOff else { return }
        if helper.resets != seenResets {
            seenResets = helper.resets
            if appliedDischarge != nil || cutOwed {
                if appliedDischarge != nil {
                    log("the helper's connection was reset under the discharge; stopping it before anything else")
                }
                appliedDischarge = nil
                stopDue = true
            }
        }
        tick()
    }

    /// The Beta Features section was shown: look again for a helper that has not answered (installed from a
    /// terminal, say). A helper that is there is not woken for this.
    ///
    /// While off, the same for the debt: a helper installed since it arose (or since the retry ended) is asked
    /// now, and then every 30 s, as one installed at launch is. Nothing without a debt and an installed helper, and
    /// nothing more while the retry is already asking.
    func recheckHelper() {
        guard running else {
            if offRetryTimer == nil { retryOwedStopWhileOff() }
            return
        }
        refusedLimit = nil
        helper.recheck()
    }

    // ── The person ──────────────────────────────────────────────────────────

    /// Discharge to the limit on the adapter; pressed again, cancel. Cancels Top Up, which would otherwise outrank it.
    func pressDischarge() {
        guard running else { return }
        isDischargeRequested.toggle()
        if isDischargeRequested { isTopUpRequested = false }
        // Pressing again is asking again, whatever the helper said last time.
        blockedDischarge = nil
        log(isDischargeRequested ? "Discharge pressed" : "Discharge cancelled")
        tick()
        changed()
    }

    /// Charge to 100% until unplugged; pressed again, cancel. Cancels a manual discharge.
    func pressTopUp() {
        guard running else { return }
        isTopUpRequested.toggle()
        if isTopUpRequested { isDischargeRequested = false }
        log(isTopUpRequested ? "Top Up pressed" : "Top Up cancelled")
        tick()
        changed()
    }

    // ── Sleep ───────────────────────────────────────────────────────────────

    /// The Mac is going to sleep. A running discharge is stopped, and the helper's answer awaited, before this
    /// returns, whatever Stop Charging when Sleeping says: nothing watches the floor while the Mac sleeps. A manual
    /// discharge ends here and does not come back; an automatic one comes back by itself after the wake, through the
    /// policy. Then the sleeping decision is applied, a limit only the helper can set waited for too: it must be in
    /// force before the Mac sleeps, not on its way. All of it within `stopTimeout`.
    func willSleep() {
        guard running else { return }
        let deadline = Date().addingTimeInterval(Self.stopTimeout)
        sleeping = true
        stopAndWait(for: "sleep", deadline: deadline)
        if isDischargeRequested {
            isDischargeRequested = false
            log("manual discharge ended by sleep")
            changed()
        }
        waitUntil = deadline
        tick()
        waitUntil = nil
    }

    func didWake() {
        guard running else { return }
        sleeping = false
        // The person may have changed macOS's settings while the Mac slept.
        if sessionActive { checkDrift() }
        // Asserted again after every sleep, whatever the books say.
        appliedLimit = nil
        refusedLimit = nil
        tick()
    }

    /// A discharge this controller holds (or may hold) is stopped and the answer waited for: what comes next has
    /// nobody watching the floor. Not answered yes, the cut may outlive it: asked again on every tick.
    private func stopAndWait(for why: String, deadline: Date) {
        guard appliedDischarge != nil || dischargeInFlight || cutOwed else { return }
        let r = waitedStop(timeout: Self.timeLeft(deadline))
        log("discharge stopped for \(why): \(r?.message ?? "no answer in time")")
        dischargeEpoch += 1
        dischargeInFlight = false
        appliedDischarge = nil
        if r?.ok != true {
            stopDue = true
            cutLost = true
        }
    }

    // ── Two accounts ────────────────────────────────────────────────────────

    /// Another account came on screen. macOS's limit is the whole Mac's, and each account has its own Anode and
    /// settings: two of them asserting their own would put each other's back every 30 s. So only the account on
    /// screen holds it. This one stops a discharge it started (waited for, as for sleep: nobody here watches it),
    /// ends a manual one, and applies nothing and reads nothing back until it is on screen again. A stop it owes is
    /// still asked: that is putting right, not holding. The net does not run while away (the other account's Anode
    /// may be discharging, through a helper whose socket this one cannot open), and what it was doing is dropped.
    func sessionResigned() {
        guard running, sessionActive else { return }
        sessionActive = false
        log("another account is on screen; the charger is left to it until this one is back")
        stopAndWait(for: "another account", deadline: Date().addingTimeInterval(Self.stopTimeout))
        cutSeen = false
        cutLookSince = nil
        cutLookAnswered = false
        // Every lost cut is owed: a discharge is owed before it is asked for, and the net owes what it finds, so a
        // debt this Anode has written down is still asked about while away (that is putting right, not holding),
        // warning and all. This holds only a lost cut with no debt behind it, which nothing makes now; it is kept so
        // that one could never outlive the debt it belongs to.
        if !cutOwed {
            cutLost = false
            stopDue = false
        }
        if isDischargeRequested {
            isDischargeRequested = false
            log("manual discharge ended: another account is on screen")
            changed()
        }
        tick()
    }

    /// This account is on screen again: macOS is read back (the other account's Anode may have changed it) and the
    /// limit asserted again, whatever the books say.
    func sessionBecameActive() {
        guard running, !sessionActive else { return }
        sessionActive = true
        log("this account is on screen again")
        checkDrift()
        appliedLimit = nil
        refusedLimit = nil
        tick()
    }

    // ── Deciding ────────────────────────────────────────────────────────────

    /// Ask the policy, and apply what changed.
    func tick(now: Date = Date()) {
        guard running, !switchingOff else { return }
        // The helper link may answer synchronously inside a tick (opening the connection, letting it go); that
        // news is acted on by one more pass afterwards, never by a tick inside this one.
        if ticking {
            tickAgain = true
            return
        }
        ticking = true
        tickSerial += 1
        defer { ticking = false }
        var passes = 0
        repeat {
            tickAgain = false
            tickOnce(now: now)
            passes += 1
        } while tickAgain && running && passes < 4
    }

    private func tickOnce(now: Date) {
        guard let b = battery() else { return setStatus(.unavailable(Self.noBatteryText)) }
        // Anode's own charger cut can make macOS report the Mac off the adapter while the cable is in (measured with
        // no macOS limit holding the battery); the adapter's details still describe a charger then, and stop
        // describing one when the cable is really pulled.
        let onAC = b.onAC || b.adapterPresent
        // What the section reads, from the same reading the decision is made from, so the two always agree.
        var announce = false
        if b.percent != batteryPercent || onAC != isCablePresent {
            batteryPercent = b.percent
            isCablePresent = onAC
            if !onAC { dischargeEndedAt = nil }
            announce = true
        }
        let inputs = ChargeInputs(percent: b.percent, onAC: onAC,
                                  temperatureC: b.temperature_C.flatMap { $0.isFinite ? $0 : nil },
                                  sleeping: sleeping, topUp: isTopUpRequested,
                                  manualDischarge: isDischargeRequested, now: now)
        let decision = ChargePolicy.decide(settings.chargeSettingsSnapshot(), inputs, &memory)
        if decision.endTopUp && isTopUpRequested { isTopUpRequested = false; announce = true }
        if decision.endManualDischarge && isDischargeRequested {
            isDischargeRequested = false
            announce = true
            log(onAC ? "manual discharge finished" : "manual discharge ended: unplugged")
        }
        lastDecision = decision
        // The net is this account's alone: while another is on screen, its Anode may be discharging through a
        // helper this one cannot even reach. It looks only with a charger on the cable: with the cable out nothing
        // is cut off from anything, and the Mac is on its battery, where every read costs.
        let netLooks = sessionActive && onAC && appliedDischarge == nil
        noteCutLook(looked: netLooks, switchReads: netLooks ? chargerSwitchThisTick() : nil,
                    macOSLook: sessionActive && !b.onAC && b.adapterPresent, now: now)
        // macOS's own flag, not `onAC` above: the adapter's details say yes all through a cut.
        noteConnected(externalConnected: b.onAC, now: now)
        apply(decision)
        // Sailing and heat memory belong to one connection to the adapter.
        if !onAC { memory = ChargeMemory() }
        settle()
        noteHelperNeed(now: now)
        if announce { changed() }
    }

    /// The charger switch, read at most once a tick: by the net and by the debt, whichever asks first, and by neither
    /// when neither needs it (a discharge in force; the cable out with nothing owed; another account on screen with
    /// nothing owed; off). Two calls into the SMC, well under a millisecond, no helper, no timer of its own. A later
    /// pass of the same tick gets the first pass's reading: an answer that came back inside the tick may have
    /// changed the switch, and the next tick sees that.
    ///
    /// Also where it is noticed that a switch which had been read cannot be read now, and that it can again: one line
    /// each time, in the charge log, and nothing for the ticks in between.
    private func chargerSwitchThisTick() -> UInt8? {
        if let read = switchRead, read.tick == tickSerial { return read.value }
        let value = chargerSwitch()
        switchRead = (tickSerial, value)
        if value != nil {
            if switchLost {
                switchLost = false
                log("the charger switch can be read again")
            }
            switchEverRead = true
        } else if switchEverRead, !switchLost {
            switchLost = true
            log("the charger switch can no longer be read; until it can, a cut left behind is not looked for, and a "
                + "debt is not settled by it or by macOS's word")
        }
        return value
    }

    /// Something only "the charger is connected" can settle: the debt, a lost cut, the net, or a stop that is due.
    private var somethingToSettle: Bool {
        cutOwed || cutLost || cutSeen || stopDue || settings.chargeCutUnconfirmed
    }

    /// The safety net under the bookkeeping: the charger looking cut with no discharge in force. A cut is expected
    /// for a minute or so after one ends; longer than `chargerReconnectTime`, with none on its way either, it is
    /// taken for a cut nobody holds: the helper is asked to reconnect it and the warning shows, until a running
    /// helper says the charger is connected (then not again for the same stretch) or the look ends.
    ///
    /// What looks cut:
    ///   * the charger switch reading cut (`AdapterCutKey.cut`), whatever macOS says. Measured on Mac17,9, macOS
    ///     27.0: with a macOS limit below the battery level in force (limit 63, battery 100) the switch read cut for
    ///     50 s and macOS said "on the adapter" throughout, so macOS's word alone would never see that cut;
    ///   * macOS reporting the Mac off the adapter while the adapter is there (`macOSLook`), which is what a cut
    ///     looks like with no limit holding the battery (measured: within 1 to 2 s of the cut). This is the route
    ///     for a Mac whose switch has never been read in this run. It is not believed against a switch that reads
    ///     connected: there is then nothing to reconnect, and the helper is not woken to say so.
    ///
    /// `looked` is whether the switch was asked at all this tick (`read` is nil when it was not). A read that fails
    /// is no information once the switch has been read in this run: the look neither ends nor goes on, `cutLookSince`
    /// and `cutSeen` stay as they were, and nothing fires on it. (Before that, a read that fails means this Mac's
    /// switch cannot be read, and macOS's word is all there is.) A cut read as cut, cut, failed, cut would otherwise
    /// start its 90 s again, and one failing every third tick would never be found.
    private func noteCutLook(looked: Bool, switchReads read: UInt8?, macOSLook: Bool, now: Date) {
        if looked, read == nil, switchEverRead { return }
        let switchCut = read == AdapterCutKey.cut
        let looksCut = switchCut || (macOSLook && read != AdapterCutKey.connected)
        guard looksCut, appliedDischarge == nil else {
            cutLookSince = nil
            cutLookAnswered = false
            cutSeen = false
            return
        }
        let since = cutLookSince ?? now
        cutLookSince = since
        guard !dischargeInFlight, !cutLookAnswered, !cutSeen,
              now.timeIntervalSince(since) > Self.chargerReconnectTime else { return }
        cutSeen = true
        // A cut the net finds is a debt like any other: written down before the helper is asked (`applyDischarge`,
        // later in this tick), so a switch-off or a quit while it is unsettled still asks the helper, and the line
        // while off still says so. The look itself is only in memory, and ends with the look.
        oweCut()
        let what = switchCut ? "the charger switch has read cut" : "macOS has said the Mac is off the adapter"
        log("\(what), with the adapter there and no discharge running, for over \(Int(Self.chargerReconnectTime)) s: "
            + "the charger may have been left cut; asking the helper to reconnect it")
    }

    /// Evidence the charger IS connected, which needs no helper, held for longer than `chargerReconnectTime` with no
    /// discharge in force or on its way: the debt, a lost cut and the net are then settled. Without this, a warning
    /// no helper can answer (none installed, one that stopped answering) would stay for good. Looked for only while
    /// there is something to settle. A discharge sent starts the count again; a stop does not.
    ///
    /// The evidence is the charger switch reading connected (`AdapterCutKey.connected`). Any other reading, Anode's
    /// cut or a value it never writes, is not: the debt is never settled here while the switch reads anything else,
    /// whatever macOS says.
    ///
    /// A read that fails depends on whether the switch has ever been read in this run:
    ///   * it has: the failed read is no information. It does not start the count, end it or add to it
    ///     (`connectedSince` stays as it was), and nothing is settled on it, nor on macOS's word in its place.
    ///   * it has not: this Mac's switch cannot be read, and macOS's word is taken instead, the Mac on the adapter
    ///     (ExternalConnected) for as long. That is the weaker evidence, and no proof. Measured on Mac17,9, macOS
    ///     27.0: with no macOS limit holding the battery a cut makes ExternalConnected read No within 1 to 2 s, but
    ///     with a limit below the battery level in force (limit 63, battery 100) it stayed Yes through 50 s of the
    ///     switch reading cut. It is kept because the other choice on such a Mac is a warning that never goes.
    private func noteConnected(externalConnected: Bool, now: Date) {
        guard appliedDischarge == nil, somethingToSettle else {
            connectedSince = nil
            return
        }
        let read = chargerSwitchThisTick()
        let connected: Bool
        if let read {
            connected = read == AdapterCutKey.connected
        } else if switchEverRead {
            return
        } else {
            connected = externalConnected
        }
        guard connected else {
            connectedSince = nil
            return
        }
        let since = connectedSince ?? now
        connectedSince = since
        guard now.timeIntervalSince(since) > Self.chargerReconnectTime, !dischargeInFlight else { return }
        let what = read != nil ? "the charger switch has read connected" : "macOS has said the Mac is on the adapter"
        settleWithoutTheHelper("\(what) for over \(Int(Self.chargerReconnectTime)) s with no discharge running: the "
                               + "charger is connected")
    }

    /// Apply `lastDecision` again after an answer came back, in case it changed while the request was on its way.
    private func reapply() {
        guard running, let d = lastDecision else { return }
        apply(d)
        settle()
    }

    private func apply(_ d: ChargeDecision) {
        // Another account on screen holds the limit; only a stop that is owed still goes out.
        if sessionActive { applyLimit(d) }
        applyDischarge(d)
    }

    /// After applying: the status, and whether the helper connection is still needed.
    private func settle() {
        guard running else { return }
        updateStatus()
        helper.keepOpen(linkNeeded)
    }

    /// A discharge lives on the connection (closing it ends the cut), from the moment one is wanted until it has
    /// stopped; and while a stop is owed, it is held for the stop. Nothing else keeps it open.
    private var linkNeeded: Bool {
        if appliedDischarge != nil || dischargeInFlight || stopDue || cutLost || cutSeen { return true }
        guard let target = lastDecision?.dischargeTo, !sleeping, sessionActive, helper.available else { return false }
        return blockedDischarge?.target != target
    }

    // ── The limit ───────────────────────────────────────────────────────────

    private func applyLimit(_ d: ChargeDecision) {
        let want = d.osLimit
        if let r = refusedLimit, r.value != want { refusedLimit = nil }
        guard appliedLimit != want, let c = client else { return }
        // One on its way is waited for, except going to sleep, when this one must land first (see below).
        if limitInFlight && waitUntil == nil { return }
        if NativeChargeLimit.isClientSettable(want) {
            setClientLimit(want, client: c, reason: d.reason)
        } else if helper.available, refusedLimit == nil {
            let from = appliedLimit
            if let deadline = waitUntil {
                // Going to sleep: in force before sleep is allowed. Queued behind anything still on its way, whose
                // late answer then books nothing.
                limitEpoch += 1
                limitInFlight = false
                let r = helper.sendWaiting(.setChargeLimit(want), timeout: Self.timeLeft(deadline))
                limitAnswered(r, want: want, from: from, reason: d.reason)
                return
            }
            limitInFlight = true
            let mine = session, epoch = limitEpoch
            helper.send(.setChargeLimit(want)) { [weak self] r in
                guard let self, self.session == mine, self.limitEpoch == epoch else { return }
                self.limitInFlight = false
                guard self.running else { return }
                self.limitAnswered(r, want: want, from: from, reason: d.reason)
                self.reapply()
            }
        } else {
            // Never lower than asked: the nearest value the client takes at or above it. Not before the helper has
            // answered (or is known missing): at launch its hello is a moment away, and the limit would otherwise go
            // up and come back down every time the app starts.
            guard helper.known else { return }
            let nearest = Self.nearestClientValue(atOrAbove: want)
            guard appliedLimit != nearest else { return }
            setClientLimit(nearest, client: c, reason: d.reason, wanted: want)
        }
    }

    /// The helper's answer to a limit: booked on a yes. Otherwise not sent again on every tick: a helper that
    /// stopped answering is unavailable now, and one that refused is not asked for this value again until
    /// something changes. Either way the nearest value macOS takes above it holds meanwhile. nil (no answer in
    /// time, going to sleep) books nothing and refuses nothing.
    private func limitAnswered(_ r: FanReply?, want: Int, from: Int?, reason: ChargeReason) {
        guard let r else { return log("the helper did not answer the limit \(want) in time") }
        if r.ok {
            appliedLimit = want
            log("\(Self.limitChange(from, want)) (\(reason.rawValue))")
        } else {
            log("the helper did not set the limit to \(want): \(r.message)")
            if r.message != HelperConnection.stoppedAnswering { refusedLimit = (want, r.message) }
        }
    }

    private func setClientLimit(_ value: Int, client c: ChargeLimitClient, reason: ChargeReason, wanted: Int? = nil) {
        guard NativeChargeLimit.isClientSettable(value) else { return }
        let from = appliedLimit
        if c.setLimit(value) {
            appliedLimit = value
            let note = wanted.map { "; \($0) needs the helper" } ?? ""
            log("\(Self.limitChange(from, value)) (\(reason.rawValue)\(note))")
        } else {
            log("macOS refused the limit \(value)")
        }
    }

    private static func limitChange(_ from: Int?, _ to: Int) -> String {
        from.map { "limit \($0) -> \(to)" } ?? "limit set to \(to)"
    }

    // ── Discharge ───────────────────────────────────────────────────────────

    private func applyDischarge(_ d: ChargeDecision) {
        guard !dischargeInFlight else { return }
        let want = d.dischargeTo
        // A refusal that does not pass by itself holds until the decision changes.
        if let b = blockedDischarge, b.target != want { blockedDischarge = nil }

        // A stop that is owed goes first, whatever the policy wants, and whether or not the helper has answered
        // lately: a helper that stopped answering is exactly the one that must be reached. A lost cut is asked
        // about once a tick.
        if stopDue || cutLost || cutSeen {
            if (cutLost || cutSeen) && lostStopTick == tickSerial { return }
            return stopDischarge(why: d.reason.rawValue)
        }
        guard let target = want else {
            // Not wanted: a discharge in force is stopped, and so is one whose end no running helper confirmed (a
            // refused or unanswered request may have cut the charger all the same).
            if appliedDischarge != nil || cutOwed { stopDischarge(why: d.reason.rawValue) }
            return
        }
        guard target != appliedDischarge, helper.available, sessionActive else { return }
        // Nothing watches the floor while the Mac sleeps, and the helper would refuse anyway.
        guard !sleeping, blockedDischarge == nil else { return }
        // A discharge lives on an open connection. Opening one answers through `helperChanged`, which ticks again;
        // a connection the Fans tab already holds is open at once.
        if !helper.isOpen { helper.keepOpen(true) }
        guard helper.isOpen else { return }
        startDischarge(to: target)
    }

    private func startDischarge(to target: Int) {
        let from = appliedDischarge
        // A discharge running, or one whose end no running helper has confirmed, is stopped first: the charger is
        // reconnected, and that confirmed, before it is cut again (the helper would otherwise cut over whatever it
        // holds). The link's queue keeps the two in order.
        let stopFirst = cutOwed
        dischargeInFlight = true
        // Whatever macOS said before this goes out says nothing about what it does.
        connectedSince = nil
        // The debt is on disk before anything that can cut the charger goes out.
        oweCut()
        dischargeSeq += 1
        let mine = session, epoch = dischargeEpoch, resetsAtSend = helper.resets
        if stopFirst {
            helper.send(.stopDischarge) { [log] r in
                if !r.ok { log("stopping the old discharge first: \(r.message)") }
            }
        }
        helper.send(.discharge(toPercent: target)) { [weak self] r in
            guard let self, self.session == mine, self.dischargeEpoch == epoch else { return }
            self.dischargeInFlight = false
            guard self.running else { return }
            if r.ok {
                self.lastRefusal = nil
                if self.helper.resets == resetsAtSend {
                    self.appliedDischarge = target
                    self.log(from.map { "discharge \($0) -> \(target)" } ?? "discharge to \(target) started")
                } else {
                    // The connection was reset after this went out: the helper that cut may be gone, or may have
                    // reconnected the charger. Neither running nor ended as far as anyone knows, so a stop goes
                    // out before anything else.
                    self.appliedDischarge = nil
                    self.seenResets = self.helper.resets
                    self.stopDue = true
                    self.log("the helper's connection was reset as the discharge to \(target) started; stopping it "
                             + "before anything else")
                }
                self.reapply()
            } else if r.message == HelperConnection.stoppedAnswering {
                // Not a refusal: the helper went away with this on its way, and may have cut the charger first.
                self.stopNotConfirmed("the helper stopped answering as the discharge to \(target) went out")
            } else {
                // A refusal starts nothing, and a stop sent first ended whatever ran.
                self.appliedDischarge = nil
                let why = r.message
                if !Self.transientDischargeRefusals.contains(why) {
                    // Shown, and asked again only when the person presses again or the decision changes.
                    self.blockedDischarge = (target, why)
                }
                if why != self.lastRefusal {
                    self.lastRefusal = why
                    if why != ChargeRefusal.goingToSleep { self.log("discharge to \(target) refused: \(why)") }
                }
                self.settle()
            }
        }
    }

    /// Ask the helper to reconnect the charger. Only a yes from a running helper ends a discharge (or settles a
    /// debt); anything else is `stopNotConfirmed`.
    private func stopDischarge(why: String) {
        let from = appliedDischarge
        let lost = cutLost || cutSeen
        dischargeInFlight = true
        lostStopTick = tickSerial
        let mine = session, epoch = dischargeEpoch, seq = dischargeSeq
        helper.send(.stopDischarge) { [weak self] r in
            guard let self, self.session == mine, self.dischargeEpoch == epoch else { return }
            self.dischargeInFlight = false
            guard self.running else { return }
            if r.ok {
                self.appliedDischarge = nil
                self.chargerConfirmed(stopSentAt: seq, message: r.message)
                if let from {
                    self.log("discharge to \(from) stopped (\(why))")
                } else if !lost, !Self.isNotAnodesValue(r.message) {
                    self.log("the charger is connected (\(why)): \(r.message)")
                }
                self.reapply()
            } else {
                self.stopNotConfirmed(r.message)
            }
        }
    }

    // ── Status ──────────────────────────────────────────────────────────────

    private func updateStatus() {
        guard running, let d = lastDecision else { return }
        // First: the charger may be cut with nobody watching it.
        if cutLost || cutSeen {
            return setStatus(.warning(helper.installed ? Self.cutWarningText : Self.cutWarningNoHelperText))
        }
        let missing = helper.outdated ? Self.helperOutdatedText : nil
        let limitNotInForce = !NativeChargeLimit.isClientSettable(d.osLimit) && appliedLimit != d.osLimit
        if limitNotInForce, let r = refusedLimit, r.value == d.osLimit, helper.available {
            setStatus(.refused(Self.limitRefusedText(r.value, r.why)))
        } else if limitNotInForce, !helper.available {
            // Nothing is said about the helper until it has answered, or is known not to be installed.
            guard helper.known else { return }
            setStatus(.needsHelper(missing ?? Self.limitNeedsHelperText(for: d)))
        } else if let target = d.dischargeTo, let b = blockedDischarge, b.target == target {
            setStatus(.refused(Self.dischargeRefusedText(b.why)))
        } else if d.dischargeTo != nil, !helper.available {
            guard helper.known else { return }
            setStatus(.needsHelper(missing ?? Self.dischargeNeedsHelperText))
        } else {
            setStatus(.active(d))
        }
    }

    private func setStatus(_ s: ChargeStatus) {
        guard s != status else { return }
        status = s
        changed()
    }

    // ── Pure pieces ─────────────────────────────────────────────────────────

    /// What is put back for a record that cannot be read: macOS's own defaults.
    static let defaultRecord = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true)

    /// The state to put back: the record; macOS's defaults for a record that cannot be read; nil for none.
    private func recordToRestore() -> NativeChargeState? {
        guard let text = settings.chargeRestoreRecord else { return nil }
        if let record = Self.decodeRecord(text) { return record }
        log("the record of macOS's own settings could not be read; putting back macOS's defaults: no limit, "
            + "Optimized Battery Charging on")
        return Self.defaultRecord
    }

    static func encodeRecord(_ s: NativeChargeState) -> String? {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// nil for no record, and for a string that is not one (see `recordToRestore`).
    static func decodeRecord(_ text: String?) -> NativeChargeState? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(NativeChargeState.self, from: Data(text.utf8))
    }

    /// The nearest limit the client takes that is at or above `percent`: the safe direction, since the battery is
    /// then never held lower than asked.
    static func nearestClientValue(atOrAbove percent: Int) -> Int {
        NativeChargeLimit.clientValues.first { $0 >= percent } ?? 100
    }
}

/// `ChargeHelperLink` over the connection Charge Control shares with the Fans tab.
///
/// The helper is a root daemon launchd starts on demand, so every hello wakes it. This link greets it once when
/// followed (its startup clears a charger cut a dead helper left behind), then holds a claim on the shared
/// connection only while a command is on its way or a discharge lives on it, and lets go after. What the helper
/// speaks is remembered from its last answer, so the connection need not stay open to know.
final class ChargeHelperAdapter: ChargeHelperLink {

    private let connection: HelperConnection
    private let isInstalled: () -> Bool
    private var token: AnyObject?
    private var changed: (() -> Void)?
    /// The protocol the helper last said it speaks; nil before it has answered, and after it stopped answering.
    private var version: Int?
    private(set) var known = false
    /// This link has a claim on the shared connection.
    private var claimed = false
    private var wantOpen = false
    private var inFlight = 0
    /// Connects asked for and not answered yet.
    private var connecting = 0
    /// A command found the connection gone (the link has closed its socket), and nothing has opened one since:
    /// the connection's own status may still say connected until its check comes back.
    private var lost = false
    private var wasSuspended = false

    init(connection: HelperConnection = .shared, isInstalled: @escaping () -> Bool = { FanDaemon.isInstalled() }) {
        self.connection = connection
        self.isInstalled = isInstalled
    }

    var available: Bool { (version ?? 0) >= 2 }
    var installed: Bool { isInstalled() }
    var outdated: Bool { version.map { $0 < 2 } ?? false }
    var isOpen: Bool { claimed && connection.isConnected }
    var resets: Int { connection.resets }

    func follow(_ changed: @escaping () -> Void) {
        self.changed = changed
        token = connection.watch { [weak self] in self?.connectionChanged() }
        wasSuspended = connection.suspended
        look()
    }

    func letGo() {
        token = nil
        changed = nil
        wantOpen = false
        version = nil
        known = false
        lost = false
        if claimed {
            claimed = false
            connection.release(.charge)
        }
    }

    func keepOpen(_ open: Bool) {
        guard token != nil else { return }
        wantOpen = open
        if open { claim() } else { settle() }
    }

    func recheck() {
        guard token != nil, !claimed else { return }
        // A helper that answered is not woken to say so again; an uninstall since is a file check away.
        if available, isInstalled() { return }
        look()
    }

    func refresh() {
        guard token != nil, wantOpen, claimed else { return }
        // A hello over the open socket; a new one only if it stopped answering, which counts as a reset.
        connect()
    }

    func send(_ c: FanCommand, _ done: @escaping (FanReply) -> Void) {
        inFlight += 1
        claim(reopenIfGone: true)
        connection.send(c) { [weak self] reply in
            self?.inFlight -= 1
            self?.learn(reply)
            done(reply)
            self?.settle()
        }
    }

    func sendWaiting(_ c: FanCommand, timeout: TimeInterval) -> FanReply? {
        inFlight += 1
        // Waited-for commands are the ones that cannot be asked twice (going to sleep, switching off, quitting,
        // uninstalling): greet first, so a socket that died under the app is replaced before the command goes,
        // rather than found dead by it.
        claim(reopenIfGone: true, greetFirst: true)
        let reply = connection.sendWaiting(c, timeout: timeout)
        inFlight -= 1
        if let reply { learn(reply) } else { lost = true }
        settle()
        return reply
    }

    func drain(timeout: TimeInterval) -> Bool {
        connection.drain(timeout: timeout)
    }

    // ── Inside ──────────────────────────────────────────────────────────────

    /// Greet the helper if it can be there, and let go after. One that is not installed is not connected to at
    /// all, unless another part of the app is already talking to one (started by hand from the Fans tab).
    private func look() {
        guard isInstalled() || connection.isConnected else {
            let news = version != nil || !known
            version = nil
            known = true
            if news { changed?() }
            return
        }
        claimed = true
        connect()
    }

    /// Open the connection for this link if it is not holding it already. For a command
    /// (`reopenIfGone`), also when the one it holds is known to be gone, or (`greetFirst`) always greet over it:
    /// the connect is idempotent, a hello over an open socket that answers, and a new socket only if it does not
    /// (which starts a fresh installed helper). Commands sent after this queue behind it on the link's serial queue.
    private func claim(reopenIfGone: Bool = false, greetFirst: Bool = false) {
        guard claimed else {
            claimed = true
            return connect()
        }
        guard reopenIfGone, connecting == 0 else { return }
        if greetFirst || lost || !connection.isConnected { connect() }
    }

    /// Greet over the shared connection, opening it if nobody has. Counted as in flight until answered, so the
    /// claim is not let go under it (which would close the socket and make the answer a stale one).
    private func connect() {
        inFlight += 1
        connecting += 1
        lost = false
        connection.connect(for: .charge) { [weak self] status in
            guard let self else { return }
            self.inFlight -= 1
            self.connecting -= 1
            self.learn(status)
            self.settle()
        }
    }

    /// Let go once nothing needs the connection: no command on its way, no discharge on it.
    private func settle() {
        guard claimed, !wantOpen, inFlight == 0 else { return }
        claimed = false
        connection.release(.charge)
    }

    private func learn(_ status: FanControlLink.Status) {
        let was = (version, known)
        switch status {
        case .connected(_, let v): version = v ?? 1
        case .notRunning, .refused: version = nil
        case .disconnected: return   // about a socket closed since; says nothing about the helper
        }
        known = true
        if was.0 != version || was.1 != known { changed?() }
    }

    /// A reply says the helper is there, except "stopped answering", which says it is gone (and the link has
    /// closed its socket: the next command opens a new one).
    private func learn(_ reply: FanReply) {
        guard !reply.ok, reply.message == HelperConnection.stoppedAnswering else { return }
        version = nil
        known = true
        lost = true
    }

    private func connectionChanged() {
        // Another part of the app greeting the helper (the Fans tab) learns what it speaks as well as this link would.
        if case .connected(_, let v) = connection.status {
            version = v ?? 1
            known = true
        }
        let resumed = wasSuspended && !connection.suspended
        wasSuspended = connection.suspended
        changed?()
        // An install or an uninstall has just finished: look again.
        if resumed, token != nil { look() }
    }
}

/// The limit Charge Control has in force, for code on another thread to read: the battery card is drawn from the
/// monitor's sampling queue, and the controller is main-thread only. This one value is all that crosses.
final class ChargeLimitInForce: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    private var liftedFlag = false

    init() {}

    /// Charge Control is on but is not holding a limit: the delay after an unclean exit.
    var lifted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return liftedFlag
    }

    func setLifted(_ v: Bool) {
        lock.lock()
        liftedFlag = v
        lock.unlock()
    }

    /// nil while Charge Control is off, or before macOS or the helper has said yes to a limit.
    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ v: Int?) {
        lock.lock()
        stored = v
        lock.unlock()
    }
}
