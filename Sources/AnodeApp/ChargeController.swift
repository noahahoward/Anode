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
//     battery is never held lower than asked, and the status says the helper is needed. The helper only writes the
//     value, and macOS's limit switch is turned on by setting a limit, never by enabling it (enabling sets the limit to
//     80: see `ChargeLimitClient`), so when the switch reads off, or nothing is known to be in force, the nearest
//     client value at or above the limit is set first and the helper's value follows (`standInForTheHelper`);
//   * a discharge → the helper's `discharge` / `stopDischarge`, over the connection the Fans tab shares
//     (`HelperConnection`).
//
// The helper is a root daemon that launchd starts on demand, and every hello wakes it. So Charge Control greets it
// once when switched on (its startup clears a charger cut a dead helper left behind), talks to it again only when
// it has something to ask, and keeps the connection open only while a discharge lives on it (closing the
// connection ends the cut). Nothing about the helper is said until it has answered, or is known not to be there.
//
// The first time it is switched on, the state of macOS's limit and Optimized Battery Charging is written down
// (`ChargeRecords`: one record for the whole Mac, flushed to disk) BEFORE anything is changed, and switching off puts
// it back at once, after anything still on its way to the helper has landed. So does quitting: the limit is in force
// only while Anode is running, so that an Anode that ever breaks on someone's Mac leaves the battery released, not
// held. The record is cleared by a restore that worked, and the setting and the person's limit are not touched, so
// the next launch switches on again from a cold start.
//
// macOS's limit is one setting for the whole Mac, and every account has its own Anode, so the record is shared and
// lists who holds the limit: switching on adopts a record that is already there (macOS's settings then are another
// Anode's limit, not macOS's own) and joins its holders; putting back removes this account from them, and only the
// last live holder puts anything back. Whether this account is on screen does not matter for that.
//
// A record still there at launch with Charge Control on that lists this account under another process, or lists
// nobody alive, means the last run ended without a quit (a crash, a kill, the power going), with macOS's limit still
// in force; that launch puts macOS's own settings back at once (unless another account's live Anode holds the limit)
// and switches on again only after `startDelay` (`liftAfterUncleanExit`).
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
// paid at launch through an installed helper, and asked again every 30 s until a running helper answers or the charger
// switch reads connected (read before each ask). While it is owed, the section says so (`offWarning`), from the flag
// alone. The delay after an unclean exit is the same kind of
// thing: Charge Control is on in the setting but holds nothing, so nothing of it exists but one timer and the two
// session observers (so that it does not start into another account's limit), and the debt is paid in the same way
// meanwhile. With no helper installed to ask, the one thing done for the debt is a single read of the charger switch
// whenever the section is shown (`settleOwedCutByReadingTheSwitch`): a helper started by hand and stopped has
// reconnected the charger itself, and nothing else would say so. The same read is made whichever helper is installed.
//
// Ready By (a hold until the battery has to charge to be at the limit by a time of day) is one more rule in the policy,
// fed two things here: the next moment the person's time of day names (`nextReadyBy`, worked out with the calendar on
// every look at the battery, so a change of time zone is acted on at once) and how fast this charger charges (learned
// from the battery, `ChargeRateMeter`, kept through `ChargeRateStore`). It needs a helper that speaks protocol 3; with
// none, or an older one, the policy is told there is no moment and the battery charges to the limit as usual.
//
// While the Mac is awake the hold is the same kind of hold as any other, and a one-shot timer raises the limit at the
// start moment. A Mac that sleeps in the middle of a hold cannot raise it: before it sleeps the helper is told the
// moment and the limit (`sendThePlan`, waited for) and wakes the Mac to write it. The plan lives on the helper
// connection, which is held open while it is pending (`linkNeeded`). A wake that is not the moment changes nothing; the
// plan is cancelled (`cancelPlan`) only when the hold it was made for ends: unplugged, Ready By or Charge Control off,
// the time or the limit changed, Charge to Full, another account on screen, the moment come, or quitting. After an
// unclean exit the new run knows nothing of the old plan, and the helper dropped it when the old connection closed.
//
// Main thread throughout.

/// The root helper as Charge Control sees it. A protocol so the tests can script it; the real one is
/// `ChargeHelperAdapter`.
protocol ChargeHelperLink: AnyObject {
    /// The helper last answered speaking protocol 2 or later, and has not stopped answering since. Learned from its
    /// hello and from its replies; the connection need not be open now.
    var available: Bool { get }
    /// The helper last answered speaking protocol 3 or later, which knows the commands that plan a wake for Ready By
    /// (`FanCommand.scheduleChargeLimit`). A helper that speaks 2 closes the connection on a command it does not know,
    /// which ends a discharge and hands the fans back, so those are sent to nothing else.
    var speaksReadyBy: Bool { get }
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

    /// Said only when the Mac really is older than macOS 26.4, or is not Apple silicon (`osFitsChargeControl`).
    static let unavailableText = "Needs macOS 26.4 or later on Apple silicon"
    /// Said when this Mac is new enough and the client still could not be opened (a framework, class or method that is
    /// not what Anode was written for: macOS changed it). The step that failed goes to the charge log.
    static let clientMissingText = "Anode could not reach macOS's charge controls on this version of macOS, so "
        + "Charge Control is unavailable"
    static let unreadableText = "macOS did not report its charge settings, so Charge Control changed nothing"
    static let noBatteryText = "Anode could not read the battery"
    static let limitNeedsHelperText = "Limits other than 80, 85, 90, 95 or 100% need the Anode helper"
    static let drainNeedsHelperText = "Draining to the limit needs the Anode helper"
    static let helperOutdatedText = "The Anode helper needs updating to control charging"
    static let readyByNeedsHelperText = "Ready By needs the Anode helper"
    /// The helper that answered knows the charge commands (protocol 2: limits, drains, holds) but not the ones that plan a
    /// wake: Ready By needs a newer one, and nothing else is wrong with it.
    static let readyByNeedsNewerHelperText = "Ready By needs a newer Anode helper. Press Install Helper\u{2026} to update it."
    /// The record of macOS's own settings is another Anode's to finish at the moment (its lock is held), so switching
    /// on changed nothing.
    static let recordUnreachableText = "Charge Control could not reach the record of macOS's own charge settings, so "
        + "it changed nothing"

    /// A discharge's end has not been confirmed by a running helper, and Charge Control is still asking.
    static let cutWarningText = "The charger may still be switched off. Reconnecting\u{2026}"
    /// A running helper said the charger is connected, and Anode's own reading of the charger switch still says it is
    /// cut, past the time a discharge's end takes. Asked again, at longer and longer intervals.
    static let cutWarningDisputedText = "The charger may still be switched off. The Anode helper says it is connected, "
        + "but Anode's own reading of the charger says it is not; Anode asks the helper again from time to time."
    /// The same once an installed helper has been asked and did not say yes (it refuses this build, cannot start, is too
    /// old): "Reconnecting\u{2026}" would no longer be true. It goes when the charger reads connected.
    static let cutWarningStillAskingText = "The charger may still be switched off. The Anode helper has not switched it "
        + "back on; Anode asks it again every \(Int(tickInterval)) seconds, and this line goes when the charger "
        + "reads connected."
    /// The same with no helper installed as a daemon: nothing will start a fresh one, and an unplug does not undo
    /// the cut. The way out is the section's own Install Helper\u{2026} button, shown with this line
    /// (`cutWarningsThatOfferInstall`): the installed helper starts on the first connection, and its startup switches
    /// the charger back on (`FanHelperServer.clearOrphanedAdapterCut`).
    static let cutWarningNoHelperText = "The charger may still be switched off, and unplugging it will not switch it "
        + "back on. Press Install Helper\u{2026} below: the helper switches the charger back on as it starts."

    /// The same while Charge Control is not running (off, or waiting out the delay after an unclean exit), with no
    /// helper installed: nothing is cutting the charger from here, so the line also says what else clears it. While
    /// not running, the section reads the charger switch once whenever it is shown (`recheckHelper`), and the line goes
    /// when that reads connected; while running, the net does the same after 90 s.
    static let cutWarningOffText = "The charger may still be switched off, and unplugging it will not switch it "
        + "back on. Press Install Helper\u{2026} below: the helper switches the charger back on as it starts. This "
        + "line also goes when Anode finds the charger connected."

    /// A helper was installed after the debt arose, while Charge Control was not running, and nothing has asked it
    /// yet (`recheckHelper` does, when the section is next shown). The button is gone, so no sentence may point at it.
    static let cutWarningInstalledText = "The charger may still be switched off, and unplugging it will not switch it "
        + "back on. The Anode helper is installed now, and Anode will ask it to switch the charger back on."

    /// The cut warnings that point at the section's Install Helper\u{2026} button: the section shows the button
    /// whenever the line it shows is one of these.
    static let cutWarningsThatOfferInstall: Set<String> = [cutWarningNoHelperText, cutWarningOffText]

    /// A hold only the helper can set, named by the feature that wanted it: with the person's limit at 80, "limits
    /// other than 80" would be no help. macOS holds the nearest value it takes above it meanwhile, so the Mac charges
    /// on to that; the sentence says so.
    static func limitNeedsHelperText(for d: ChargeDecision) -> String {
        let p = d.osLimit, on = nearestClientValue(atOrAbove: d.osLimit)
        switch d.reason {
        case .heat: return "Pausing for heat at \(p)% needs the Anode helper; it charges on to \(on)%"
        case .sleeping: return "Holding \(p)% while the Mac sleeps needs the Anode helper; it charges on to \(on)%"
        case .drift: return "Drifting below the limit at \(p)% needs the Anode helper; it charges on to \(on)%"
        case .readyBy: return readyByNeedsHelperText
        case .limit, .fullCharge, .draining, .drained: return limitNeedsHelperText
        }
    }

    /// What the battery card is told Charge Control holds: the limit in force when the controller knows it (a hold
    /// or Charge to Full included), else the person's own; nil while off, and while the delay after an unclean exit
    /// holds nothing. Safe from any thread.
    static func limitForMonitor(settings: Settings, inForce: ChargeLimitInForce) -> Int? {
        guard settings.chargeControlEnabled, !inForce.lifted else { return nil }
        return inForce.value ?? settings.chargeLimit
    }

    /// Why there is no charge client, for the section and for the log.
    struct NoClientReason: Equatable {
        /// This Mac is older than macOS 26.4 or is not Apple silicon, which is what `unavailableText` says.
        var unsupportedMac: Bool
        /// The step of opening the client that failed (`PowerUIChargeClient.lastFailure`), for the log.
        var step: String?
    }

    /// Charge Control's route to macOS's limit exists from macOS 26.4, on Apple silicon.
    static func osFitsChargeControl(_ v: OperatingSystemVersion, appleSilicon: Bool) -> Bool {
        appleSilicon && (v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4))
    }

    /// The real answer: this Mac's version, and the step that failed. `hw.optional.arm64` is 1 on Apple silicon even
    /// for a process running translated.
    static func systemNoClientReason() -> NoClientReason {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let known = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let fits = osFitsChargeControl(version, appleSilicon: known && arm64 == 1)
        return NoClientReason(unsupportedMac: !fits, step: PowerUIChargeClient.lastFailure)
    }

    /// What the helper has said it can do, for the section to compare with what is switched on.
    enum HelperReach: Int, Comparable {
        /// No helper is answering (none installed, or one too old to know the charge commands).
        case none = 0
        /// Protocol 2: limits, drains and holds.
        case charge = 1
        /// Protocol 3: and a plan for Ready By.
        case readyBy = 2

        static func < (a: HelperReach, b: HelperReach) -> Bool { a.rawValue < b.rawValue }
    }

    /// Ready By is switched on, and the helper that answered speaks protocol 2: it does control charging, so the status
    /// stays what the other features make it, and the section adds this one sentence about Ready By
    /// (`readyByNeedsNewerHelperText`).
    var readyByNeedsNewerHelper: Bool {
        running && settings.chargeReadyByEnabled && helper.known && helper.available && !helper.speaksReadyBy
    }
    private var shownReadyByNeedsNewerHelper = false

    /// nil until the helper has answered, or is known not to be installed: nothing is said about it before then.
    var helperReach: HelperReach? {
        guard running, helper.known else { return nil }
        if helper.speaksReadyBy { return .readyBy }
        return helper.available ? .charge : HelperReach.none
    }

    /// The least a helper must do for everything switched on in `settings` to work, or nil when nothing switched on needs
    /// one. Ready By needs a plan, which is protocol 3; a drain, and any hold that may have to rest anywhere but at 80,
    /// 85, 90, 95 or 100%, need protocol 2, and so does a limit of the person's own that macOS does not take by itself.
    static func helperNeeded(by settings: Settings) -> HelperReach? {
        if settings.chargeReadyByEnabled { return .readyBy }
        if settings.chargeDrainAutomatically || settings.chargeDriftEnabled || settings.chargePauseWhenHotEnabled
            || settings.chargeHoldDuringSleep || !NativeChargeLimit.isClientSettable(settings.chargeLimit) {
            return .charge
        }
        return nil
    }

    /// Whether this account is the one on screen, from the session's own dictionary
    /// (`CGSessionCopyCurrentDictionary`): nil when it says nothing, which the controller takes as on screen.
    static func onConsole(fromSession session: [String: Any]?) -> Bool? {
        session?[kCGSessionOnConsoleKey as String] as? Bool
    }

    static func systemOnConsole() -> Bool? {
        onConsole(fromSession: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// The launch argument `uninstall.sh` runs the app with: put macOS's own charge settings back, with no window,
    /// and exit 0 if nothing of Charge Control's is left in force, 1 if something may be.
    static let restoreArgument = "--restore-charge-settings"

    /// What that argument does. The same as the Uninstall button's `restoreForUninstall`, on a controller that
    /// starts nothing (Charge Control is never switched on to be switched off, whatever the setting says): the
    /// record put back, the debt of an unconfirmed discharge asked about (waited for; only waited commands work
    /// with no run loop, and they open the connection themselves), the setting turned off, and all of it flushed.
    /// True when no record and no debt are left (`restoreForUninstallOutcome` tells a limit another account's Anode
    /// holds from one that may be left).
    static func restoreForUninstall(settings: Settings,
                                    records: ChargeRecords? = nil,
                                    makeClient: @escaping () -> ChargeLimitClient? = { PowerUIChargeClient.make() },
                                    helper: ChargeHelperLink,
                                    log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) }) -> Bool {
        restoreForUninstallOutcome(settings: settings, records: records, makeClient: makeClient, helper: helper,
                                   log: log) == .cleared
    }

    /// How the headless restore ended: nothing of Charge Control's is left in force (exit 0); something may be (exit
    /// 1); or the limit is in force and is another account's Anode's to put back, which is left alone (exit 2).
    enum UninstallRestore: Equatable {
        case cleared, mayBeLeft, heldByAnotherAccount

        var exitCode: Int32 {
            switch self {
            case .cleared: return 0
            case .mayBeLeft: return 1
            case .heldByAnotherAccount: return 2
            }
        }
    }

    static func restoreForUninstallOutcome(settings: Settings, records: ChargeRecords? = nil,
                                           makeClient: @escaping () -> ChargeLimitClient? = {
                                               PowerUIChargeClient.make()
                                           },
                                           helper: ChargeHelperLink,
                                           log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) })
        -> UninstallRestore {
        let records = records ?? ChargeRecords(settings: settings)
        let c = ChargeController(settings: settings, records: records, makeClient: makeClient, helper: helper,
                                 battery: { nil }, chargerSwitch: { nil }, log: log, workspace: NotificationCenter(),
                                 limitInForce: ChargeLimitInForce(), startDelay: Self.startDelay, liftedAtLaunch: false,
                                 observing: false)
        c.restoreForUninstall()
        settings.flush()
        let outcome: UninstallRestore
        if settings.chargeCutUnconfirmed {
            outcome = .mayBeLeft
        } else if records.hasRecord {
            outcome = records.heldByAnotherAccount ? .heldByAnotherAccount : .mayBeLeft
        } else {
            outcome = .cleared
        }
        switch outcome {
        case .cleared: log("uninstalling: macOS's own charge settings are back")
        case .mayBeLeft: log("uninstalling: something of Charge Control's may still be in force")
        case .heldByAnotherAccount:
            log("uninstalling: another account's Anode is holding the charge limit, so it is left in force")
        }
        return outcome
    }

    /// The first thing the program does, before `NSApplication` and before anything else of the app is built (see
    /// `main.swift`): if Charge Control is on and the last run did not quit (a restore record is still there, or a
    /// start is still pending), write the pending start down, put macOS's own settings back, and log it. True when it
    /// did. The controller, built much later, is told (`liftedAtLaunch`) and only waits.
    ///
    /// With Charge Control off, a record left over (a switch-off macOS partly refused, or the setting turned off while
    /// Anode was closed) is put back here too, by the same holder rule and for the same reason: left to the
    /// controller, an Anode that crashes before the middle of launch never releases it. There is no wait and no
    /// pending start then: nothing is switched on again. Nothing at all is built when there is no record to put back.
    ///
    /// It is early on purpose. The controller is made in the middle of `applicationDidFinishLaunching`, after the
    /// panes, the sampling monitor, the history database and the menu. A relaunch that crashes in any of them every
    /// time (a state file the dead run left half written) would never reach it, and the limit would stay held by an
    /// Anode that crashes on every launch. So this depends on as little as possible: the settings, the charge client,
    /// the helper link and the charge log. Nothing that reads the history database, the trend file, the menu or a
    /// window. The same restore as everywhere else, with the same bounded waits, a cut debt's stop first.
    ///
    /// For a normal launch (nothing to lift) it does nothing and builds nothing: the client and the helper link are
    /// asked for only when there is work, so `helper` is a closure.
    @discardableResult
    static func liftAtLaunch(settings: Settings = .shared, records: ChargeRecords? = nil,
                             makeClient: @escaping () -> ChargeLimitClient? = { PowerUIChargeClient.make() },
                             helper: () -> ChargeHelperLink = { ChargeHelperAdapter() },
                             log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) }) -> Bool {
        let records = records ?? ChargeRecords(settings: settings)
        let on = settings.chargeControlEnabled
        let work = on ? records.lastRunDidNotRelease() || settings.chargeStartPending
                      : records.leftOverForThisAccount()
        guard work else { return false }
        let c = ChargeController(settings: settings, records: records, makeClient: makeClient, helper: helper(),
                                 battery: { nil }, chargerSwitch: { nil }, log: log, workspace: NotificationCenter(),
                                 limitInForce: ChargeLimitInForce(), startDelay: Self.startDelay,
                                 liftedAtLaunch: false, observing: false)
        return on ? c.liftNow() : c.putBackLeftoverRecord(when: "at the top of the program")
    }

    /// A reason for a limit in the words the charge log uses, which a person reads. The enum's raw values are names in the
    /// code ("fullCharge") and are stored nowhere.
    static func logWords(_ reason: ChargeReason) -> String {
        switch reason {
        case .limit: return "limit"
        case .fullCharge: return "charge to full"
        case .heat: return "pause when hot"
        case .sleeping: return "hold during sleep"
        case .drift: return "drift"
        case .draining: return "draining"
        case .drained: return "drained"
        case .readyBy: return "ready by"
        }
    }

    /// The helper raised the limit at its plan's moment and Charge Control does not want that limit now: the pack is
    /// paused for heat again, or something else outranks the plan. Not a change from outside, and said so.
    static func plannedWriteNotWanted(_ planned: Int, _ d: ChargeDecision) -> String {
        let head = "the helper raised the limit to \(planned)% as planned, but "
        switch d.reason {
        case .heat: return head + "the battery is still paused for heat; holding again"
        case .readyBy where d.readyBy?.isHolding == true:
            return head + "Ready By is still holding the battery at \(d.osLimit)%; holding again"
        default: return head + "Charge Control wants \(d.osLimit)% now (\(logWords(d.reason))); setting that"
        }
    }

    static func drainRefusedText(_ why: String) -> String {
        "The Anode helper would not start the drain: \(plainWords(why))"
    }
    /// A limit macOS takes by itself and refused: not in force, so the status says so instead of "Charging stops at".
    ///
    /// `wanted` is the limit that was asked for (the person's own, when it is the limit that rules), `refused` the value
    /// macOS was given for it (the same, or the nearest it takes at or above: 87 goes to macOS as 90), and `inForce` the
    /// limit of Charge Control's that is in force, if there is one. Saying only "90%" for a limit of 87 named a number
    /// the person never chose and left out what holds the battery.
    static func macOSRefusedLimitText(wanted: Int, refused: Int, inForce: Int?) -> String {
        var s = wanted == refused
            ? "macOS did not take the charge limit of \(wanted)%, so the battery is not held there"
            : "macOS did not take \(refused)%, the nearest charge limit it accepts to \(wanted)%, so the battery is "
              + "not held at \(wanted)%"
        s += inForce.map { "; the limit in force is \($0)%" } ?? "; no limit of Charge Control's is in force"
        return s
    }
    /// macOS shows another limit than the one that was set, three passes running.
    static func notHoldingText(wanted: Int, inForce: Int) -> String {
        "macOS is not holding the charge limit of \(wanted)%: \(inForce)% is in force. Change the limit to try again."
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
    /// How long the restore waits for a helper nobody has greeted (none installed, none answering yet): a socket that is
    /// there answers at once, and one that is not is known at once.
    static let helperProbeTimeout: TimeInterval = 0.5
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
    /// The person pressed Drain to Limit and it has not finished, been cancelled, or been ended by an unplug or a sleep.
    private(set) var isDrainRequested = false
    /// The person pressed Charge to Full and has not unplugged or cancelled it.
    private(set) var isFullChargeRequested = false
    /// The charge the last tick saw; nil while off.
    private(set) var batteryPercent: Int?
    /// Whether the cable was in at the last tick: on the adapter, or cut off from it by Anode's own discharge
    /// (macOS may then report the Mac on battery, but the adapter is still there). False while off.
    private(set) var isCablePresent = false
    /// The battery reported charging at the last tick; false while off.
    private(set) var isCharging = false
    /// The discharge the helper said yes to and has not said it stopped: what is running, not what was asked for.
    var dischargeInForce: Int? { appliedDischarge }

    private let settings: Settings
    /// The record of macOS's own settings, shared by every account's Anode on this Mac (`ChargeRecords`).
    private let records: ChargeRecords
    private let makeClient: () -> ChargeLimitClient?
    /// Asked only when `makeClient` gave nothing. A parameter for the tests.
    private let noClientBecause: () -> NoClientReason
    /// The step that failed has been logged in this run: said once, however often Charge Control is switched on.
    private var saidWhyNoClient = false
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
    /// the one on screen asserts it (which of them holds it for the purpose of putting back is the record's business:
    /// `ChargeRecords`); see `sessionResigned`. Seeded from the session at launch (`onConsole`): an Anode started while
    /// another account is on screen holds nothing until its own account is back.
    private var sessionActive = true
    /// The session's own answer, asked again by the periodic tick while this controller believes another account is on
    /// screen: a seed that was wrong at launch, or a notice that never came, would otherwise leave it passive for good
    /// while the section says the limit is held.
    private let sessionOnConsole: () -> Bool?
    /// macOS's settings have been asserted by this controller (the switch-on turned Optimized Battery Charging off; the
    /// limit goes in by setting it, which is what turns the limit's switch on). Not while another account was on screen
    /// at launch: then the first time this account is on screen it does that, and is not taken to have found someone
    /// else's change.
    private var asserted = false
    /// While going to sleep, a limit only the helper can set is waited for, until this, rather than sent and left.
    private var waitUntil: Date?

    /// The time, and the calendar: parameters so the tests can be both. The calendar is asked every time a moment is
    /// worked out, so a change of time zone is acted on with no more than the next look at the battery.
    private let clock: () -> Date
    private let calendar: () -> Calendar
    /// How fast chargers charge this Mac, as learned so far (`ChargeRate`), and where it is kept. Built from the
    /// settings this controller was given, and never from the shared ones.
    private let rateStore: ChargeRateStore
    private var rates: ChargeRate?
    private var meter = ChargeRateMeter()

    /// What the helper has been told to do while the Mac sleeps, as far as it has said yes.
    struct WakePlan: Equatable {
        /// The moment the battery is to be ready by.
        var by: Date
        /// The limit to raise to.
        var limit: Int
        /// When to raise it, and so when to wake the Mac.
        var raiseAt: Date
    }
    /// The plan the helper holds for this controller, if it has said yes to one and nothing has cancelled it since.
    private(set) var wakePlan: WakePlan?
    /// A plan this controller has asked the helper to forget, and the helper has not said yes to yet. The helper's own
    /// timer can fire before it has processed the cancel, and a write that lands then is that plan working, not
    /// someone else's change (`checkDrift`). Ends with the helper's yes, a new plan, or the connection closing.
    private var cancelledPlan: WakePlan?
    /// The helper's planned write, found in macOS by the drift pass and not yet compared with what the decision wants
    /// (`tickOnce` does that, with the decision made for this moment, and says so when it does not want it).
    private var plannedWriteSeen: WakePlan?
    /// For the sleep that is starting: the helper did not take the plan, so Ready By is not holding (`sendThePlan`). Ends
    /// with the wake, or when Charge Control stops.
    private var readyBySetAside = false
    /// A plan is on its way to the helper, waited for.
    private var planSending = false
    /// When the one-shot timer for the start moment fires, while awake; nil when none is set.
    private(set) var readyByTimerAt: Date?
    private var readyByTimer: Timer?
    /// When the timer that is actually scheduled will fire, for the tests: `readyByTimerAt` is what it was asked for.
    var readyByTimerFireDate: Date? { readyByTimer?.fireDate }

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
    /// The value macOS itself refused (a client value, or the nearest one standing in for a limit only the helper can
    /// set), until a value is taken: the status says so while it is the one wanted and not in force.
    private var macOSRefusedLimit: Int?
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
    /// How many passes in a row found the same difference after it was put back, and, once that is three, the limit
    /// macOS will not hold and what it holds in its place. While set, the limit is not sent again (the same answer
    /// every 30 s for ever helps nobody) and the section says so; it clears when macOS shows the wanted limit, when
    /// what it shows changes, or when the wanted limit changes.
    private var driftRepeats = 0
    private var notHolding: (wanted: Int, inForce: Int)?
    static let driftTries = 3

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
    private var cutLookAnsweredAt: Date?
    private var cutLookAnswered: Bool { cutLookAnsweredAt != nil }
    /// The time of the last tick, which is when a helper's answer is taken to have come (the callbacks have no clock of
    /// their own, and the tests move this one by hand).
    private var lastTickNow = Date()
    /// Once a running helper has said the charger is connected, the switch still reading cut is asked about again, but
    /// not sooner than this after that answer, so a helper that keeps saying so is not woken every tick. Each further
    /// ask waits twice as long (`cutReaskInterval`), up to `cutReaskCap`.
    static let cutReaskAfter: TimeInterval = 300
    static let cutReaskCap: TimeInterval = 3600
    /// How long to wait after the answer before asking again, when the helper has already been asked `reasks` times
    /// again in this stretch: 5, 10, 20, 40 minutes, then an hour.
    static func cutReaskInterval(afterReasks reasks: Int) -> TimeInterval {
        min(cutReaskAfter * pow(2, Double(min(max(reasks, 0), 12))), cutReaskCap)
    }
    /// How many times, in this stretch of the look, the helper has been asked again after saying the charger is
    /// connected; and the wait that was last put in the log, so that a line is written when the wait changes and not
    /// at each ask.
    private var cutReasks = 0
    private var cutReaskLogged: TimeInterval?
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
    /// `liftAtLaunch` already ran in this process: macOS's own settings were put back before the app was built, and
    /// the pending start written. The controller waits without lifting again.
    private let liftedAtLaunch: Bool
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
    /// The system's own word that the time zone or the clock changed, on the default centre.
    private var timeClockObservers: [NSObjectProtocol] = []
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

    convenience init(settings: Settings, records: ChargeRecords? = nil,
                     makeClient: @escaping () -> ChargeLimitClient? = { PowerUIChargeClient.make() },
                     helper: ChargeHelperLink, battery: @escaping () -> Battery.State? = { Battery.state() },
                     chargerSwitch: @escaping () -> UInt8? = ChargeController.systemChargerSwitch(),
                     log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) },
                     workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                     limitInForce: ChargeLimitInForce = ChargeLimitInForce(),
                     startDelay: TimeInterval = ChargeController.startDelay, liftedAtLaunch: Bool = false,
                     noClientBecause: @escaping () -> NoClientReason = ChargeController.systemNoClientReason,
                     onConsole: @escaping () -> Bool? = ChargeController.systemOnConsole,
                     rateStore: ChargeRateStore? = nil,
                     now: @escaping () -> Date = Date.init,
                     calendar: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.init(settings: settings, records: records ?? ChargeRecords(settings: settings), makeClient: makeClient,
                  helper: helper, battery: battery, chargerSwitch: chargerSwitch, log: log, workspace: workspace,
                  limitInForce: limitInForce, startDelay: startDelay, liftedAtLaunch: liftedAtLaunch, observing: true,
                  noClientBecause: noClientBecause, onConsole: onConsole,
                  rateStore: rateStore ?? SettingsChargeRateStore(settings: settings), now: now, calendar: calendar)
    }

    /// The Mac's own charger switch, read as the person and not through the helper: only writing it needs root
    /// (measured on Mac17,9, macOS 27.0: an unprivileged process reads it). The helper's own reader and key name
    /// (`SystemChargeHardware.adapterCutValue`), so there is one of each; nothing here can write. The connection to
    /// the SMC is opened at the first read, which is never while Charge Control is off, except for the one read the
    /// section asks for when a debt is owed (`settleOwedCutByReadingTheSwitch`).
    ///
    /// A read that fails is followed, at the next read, by a new connection. `SystemChargeHardware()` cannot fail: an
    /// SMC that would not open is kept inside it as "no connection" for good (`SMC.init?` is nil then), and a
    /// connection that has died is never opened again by itself. So the one that failed is dropped, and the next read
    /// opens one (one open at most per read, and the controller reads once a tick at most). On a Mac whose switch can
    /// never be read that would be a new SMC connection every tick for as long as Charge Control is on, so after
    /// `reopenFailuresBeforeBackoff` failures in a row nothing is opened or read for `reopenBackoff`; the next read
    /// after that tries again, and each failure then backs off again. A read that works forgets the failures. `open`
    /// and `now` are parameters for the tests, which must not reach the real SMC or wait.
    static func systemChargerSwitch(open: @escaping () -> ChargeHardware = { SystemChargeHardware() },
                                    now: @escaping () -> Date = Date.init)
        -> () -> UInt8? {
        var hardware: ChargeHardware?
        var lastReadFailed = false
        var failuresInARow = 0
        var tryAgainAt = Date.distantPast
        return {
            if hardware == nil || lastReadFailed {
                guard failuresInARow < reopenFailuresBeforeBackoff || now() >= tryAgainAt else { return nil }
                hardware = open()
            }
            let value = hardware?.adapterCutValue()
            lastReadFailed = value == nil
            if value == nil {
                failuresInARow += 1
                if failuresInARow >= reopenFailuresBeforeBackoff {
                    tryAgainAt = now().addingTimeInterval(reopenBackoff)
                }
            } else {
                failuresInARow = 0
            }
            return value
        }
    }

    /// How many reads in a row may fail, each with a new connection, before `systemChargerSwitch` backs off.
    static let reopenFailuresBeforeBackoff = 3
    /// How long it then leaves the SMC alone.
    static let reopenBackoff: TimeInterval = 300

    /// `observing` false: a controller that watches nothing and starts nothing, for the uninstall's restore with no
    /// window (`restoreForUninstall(settings:...)`), which must not switch Charge Control on to switch it off.
    private init(settings: Settings, records: ChargeRecords, makeClient: @escaping () -> ChargeLimitClient?,
                 helper: ChargeHelperLink,
                 battery: @escaping () -> Battery.State?, chargerSwitch: @escaping () -> UInt8?,
                 log: @escaping (String) -> Void, workspace: NotificationCenter, limitInForce: ChargeLimitInForce,
                 startDelay: TimeInterval, liftedAtLaunch: Bool, observing: Bool,
                 noClientBecause: @escaping () -> NoClientReason = ChargeController.systemNoClientReason,
                 onConsole: @escaping () -> Bool? = { nil },
                 rateStore: ChargeRateStore? = nil,
                 now: @escaping () -> Date = Date.init,
                 calendar: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.settings = settings
        self.rateStore = rateStore ?? SettingsChargeRateStore(settings: settings)
        self.clock = now
        self.calendar = calendar
        self.records = records
        self.makeClient = makeClient
        self.noClientBecause = noClientBecause
        self.helper = helper
        self.battery = battery
        self.chargerSwitch = chargerSwitch
        self.log = log
        self.workspace = workspace
        self.limitInForce = limitInForce
        self.startAfter = startDelay
        self.liftedAtLaunch = liftedAtLaunch
        self.sessionOnConsole = onConsole
        cutOwed = settings.chargeCutUnconfirmed
        guard observing else { return }
        // Only a controller that will run asks: the headless restores never act on it.
        sessionActive = onConsole() ?? true
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
            // (Already done at the top of the program when it could be: `liftAtLaunch`; not asked of macOS twice.)
            if !liftedAtLaunch { putBackLeftoverRecord(when: "at launch") }
            // And a discharge whose end no running helper confirmed may have left the charger cut.
            retryOwedStopWhileOff()
        }
    }

    deinit {
        removeTriggers()
        offRetryTimer?.invalidate()
        startTimer?.invalidate()
        readyByTimer?.invalidate()
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
    /// again; nil when it should not (no discharge ended lately, the cable is out, a discharge runs, or the battery
    /// reports charging: it resumed, which was measured at about 55 s, so the fixed 90 s is only the longest it waits).
    func chargerReconnectTimeLeft(now: Date = Date()) -> TimeInterval? {
        guard let ended = dischargeEndedAt, isCablePresent, appliedDischarge == nil, !isCharging else { return nil }
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
            let why = noClientBecause()
            if !saidWhyNoClient {
                saidWhyNoClient = true
                log("unavailable: the macOS charge limit client could not be opened"
                    + (why.unsupportedMac ? " (this Mac is older than macOS 26.4, or is not Apple silicon)" : "")
                    + (why.step.map { ": \($0)" } ?? ""))
            }
            return setStatus(.unavailable(why.unsupportedMac ? Self.unavailableText : Self.clientMissingText))
        }
        // The way back is written down before anything is changed, and flushed: macOS keeps these settings if Anode
        // dies, so the record has to survive a crash in the next few lines. A record that is there already stands, and
        // this Anode becomes one of its holders: it is the state before any Anode changed macOS (at launch after a run
        // that did not quit it is not there: see `liftAfterUncleanExit`; here it is one a refused restore left, or
        // another account's Anode holds the limit now, and what macOS says is that Anode's limit, not macOS's own).
        // So does one that cannot be read: switching off puts back macOS's defaults instead.
        switch records.acquire(read: { c.read() }) {
        case .adopted(let readable):
            if readable {
                log("the record of macOS's own settings that was already there stands")
            } else {
                log("the record of macOS's own settings could not be read; it is kept, and switching off will put "
                    + "back macOS's defaults")
            }
        case .recorded(let found):
            log("recorded macOS's own settings: limit \(found.mclLimit) \(found.mclEnabled ? "on" : "off"), "
                + "Optimized Battery Charging \(found.optimizedChargingEnabled ? "on" : "off")")
        case .macOSUnreadable:
            log("unavailable: macOS did not report its charge settings; nothing was changed")
            return setStatus(.unavailable(Self.unreadableText))
        case .unreachable:
            log("the shared record of macOS's own settings could not be reached (another Anode may be using it); "
                + "nothing was changed")
            return setStatus(.unavailable(Self.recordUnreachableText))
        }
        client = c
        session += 1
        endOffRetry()
        // A debt left from before (a quit, a crash, a switch-off the helper did not answer) is paid first.
        cutOwed = settings.chargeCutUnconfirmed
        stopDue = cutOwed
        if cutOwed { log("a drain's end was never confirmed; asking the helper to reconnect the charger") }
        // Two controllers on one charger would fight; Optimized Battery Charging comes back on when this goes off.
        // Not while another account is on screen: that Anode's limit is in force, and this is not the account that
        // holds it (`assertMacOSSettings` is what the account does once it is back).
        if sessionActive { assertMacOSSettings(c) }
        log("on")
        installTriggers()
        seenResets = helper.resets
        helper.follow { [weak self] in self?.helperChanged() }
        tick()
    }

    private func assertMacOSSettings(_ c: ChargeLimitClient) {
        asserted = true
        if !c.setOptimizedCharging(false) { log("macOS would not turn Optimized Battery Charging off") }
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
    /// The record is cleared only when every step is known to have worked. Otherwise it is kept (with nobody holding
    /// it) and that is logged, so the next switch-off, quit or launch of any account's Anode tries again from the true
    /// original rather than from what is left. And nothing is put back at all while another account's running Anode
    /// holds the limit (`ChargeRecords.release`).
    ///
    /// Used for switching off, quitting and uninstalling, and at a launch that finds the last run did not quit
    /// (`liftAfterUncleanExit`); `why` names which, in the line about a discharge stopped on the way.
    private func restore(client c: ChargeLimitClient, leaving why: String = "switching off", deadline given: Date? = nil) {
        let deadline = given ?? Date().addingTimeInterval(Self.stopTimeout)
        // A plan the helper holds goes first: nothing may raise the limit after this, and the helper's connection may
        // be one the Fans tab is also holding, which would keep the plan alive.
        cancelPlan(because: why, waitingUntil: deadline)
        // A stop goes behind everything already sent on the same link, so its answer also says those have landed.
        let settled: Bool
        if appliedDischarge != nil || dischargeInFlight || cutOwed {
            let r = waitedStop(timeout: Self.timeLeft(deadline))
            log("drain stopped (\(why)): \(r?.message ?? "no answer within \(Int(Self.stopTimeout)) s")")
            settled = r != nil
        } else {
            settled = helper.drain(timeout: Self.timeLeft(deadline))
        }
        if !settled {
            log("the helper had not finished what it was asked within \(Int(Self.stopTimeout)) s; it may land after "
                + "this")
        }
        // This account stops holding the limit. Only the last live holder puts anything back (the shared record is
        // locked while it does, so no other Anode records half-restored settings): another account's Anode that is
        // running holds the limit now, and it is that Anode's to put back.
        let released = records.release { original in
            let record: NativeChargeState
            switch original {
            case .state(let found):
                record = found
            case .unreadableText:
                log("the record of macOS's own settings could not be read; putting back macOS's defaults: no limit, "
                    + "Optimized Battery Charging on")
                record = Self.defaultRecord
            case .none:
                // Lost while on (removed by hand, say): Charge Control's settings are not left in force for that.
                log("no record of macOS's own settings to put back; putting back macOS's defaults: no limit, "
                    + "Optimized Battery Charging on")
                record = Self.defaultRecord
            }
            let limit = restoreLimit(record, client: c, deadline: deadline)
            var ok = limit != .kept && settled
            ok = c.setOptimizedCharging(record.optimizedChargingEnabled) && ok
            let switchText = "\(record.mclEnabled ? "on" : "off")"
            let obcText = "Optimized Battery Charging \(record.optimizedChargingEnabled ? "on" : "off")"
            if ok, case .bestThisMacCanDo(let held) = limit {
                // The recorded limit needs a helper to set, and none is installed to ask: nothing will ever put it
                // back, and keeping the record would make every launch wait out the delay for nothing. The record is
                // cleared, and the line says exactly what was and was not put back.
                log("put back as much of macOS's own settings as this Mac can: limit \(held) \(switchText) (it was "
                    + "\(record.mclLimit), which needs the helper to set, and none is installed), \(obcText)")
            } else if ok {
                log("put back macOS's own settings: limit \(record.mclLimit) \(switchText), \(obcText)")
            } else {
                log("putting back macOS's own settings is not known to have worked; the record is kept")
            }
            return ok
        }
        switch released {
        case .restored:
            break
        case .handedOver:
            log("another account's Anode is holding the charge limit, so nothing is put back; it is that Anode's to "
                + "put back when it quits")
        case .unreadable(let why):
            log("the shared record of macOS's own settings could not be read (\(why)); nothing is put back from it")
        case .unreachable:
            log("the shared record of macOS's own settings could not be reached (another Anode may be using it); "
                + "nothing is put back, and the next launch of any account's Anode lifts the limit")
        }
    }

    /// How putting back the recorded limit ended.
    private enum LimitRestore: Equatable {
        /// The recorded limit itself is in force.
        case restored
        /// The recorded limit is one only the helper can set, and none is installed (not merely slow or silent): the
        /// nearest value macOS takes at or above it is in force, which is the best this Mac can do.
        case bestThisMacCanDo(Int)
        /// Not put back; the record is kept for the next launch to try again.
        case kept
    }

    /// The recorded limit with the recorded switch, or the best this Mac can do. A record with the switch off is put
    /// back by turning it off (which gives "off, 100"); one with the switch on and limit v ends at "on, v" by setting v,
    /// which turns the switch on by itself, and never by enabling it, which would end at 80. Only the helper can put
    /// back one macOS does not take by
    /// itself; an installed one is greeted for it even when nothing has talked to it this run (Charge Control off, or
    /// this is the uninstall): the waited command opens the connection first. When the value cannot land, the nearest
    /// one macOS takes at or above it is set, so the Mac can still charge at least that far. With no helper
    /// that is the end of it (`bestThisMacCanDo`, when it went in): nothing will ever do better, and a record kept for
    /// it would send every launch down the unclean route for ever. With one that did not answer, or refused, the
    /// record is kept for the next launch to try again. The helper is waited for until `deadline`, the restore's own.
    ///
    /// "No helper" is not read off `installed` and `available` alone: at the early lift at launch nothing has connected
    /// yet, so a helper started by hand (no installed daemon) looks absent only because nobody has asked it, and its
    /// record would be cleared with a stand-in left in force and the person's original lost. So its socket is tried
    /// once, as the stop for a cut debt is: the same waited command, bounded to `helperProbeTimeout`. Only when nothing
    /// answers is there no helper; an answer, even a refusal, is one.
    private func restoreLimit(_ record: NativeChargeState, client c: ChargeLimitClient, deadline: Date) -> LimitRestore {
        guard record.mclEnabled else { return c.turnLimitOff() ? .restored : .kept }
        let limit = record.mclLimit
        if NativeChargeLimit.isClientSettable(limit) { return c.setLimit(limit) ? .restored : .kept }
        let nearest = Self.nearestClientValue(atOrAbove: limit)
        var noHelper = !(helper.available || helper.installed)
        // With the switch off the helper's value alone would land with it off: the nearest value above goes first.
        standInForTheHelper(limit, client: c)
        let r = helper.sendWaiting(.setChargeLimit(limit),
                                   timeout: noHelper ? min(Self.timeLeft(deadline), Self.helperProbeTimeout)
                                                     : Self.timeLeft(deadline))
        if r?.ok == true { return .restored }
        let why: String
        if noHelper, r == nil {
            why = "limit \(limit) needs the helper to put back, and none is installed"
        } else {
            noHelper = false
            why = "the helper did not put the limit back to \(limit): " + (r?.message ?? "no answer in time")
        }
        let landed = c.setLimit(nearest)
        if noHelper, landed { return .bestThisMacCanDo(nearest) }
        log("\(why); set \(nearest) for now, and the record is kept to try again at the next launch")
        return .kept
    }

    /// Forget everything this switch-on built. Leaves macOS as it is.
    private func stop() {
        removeTriggers()
        helper.letGo()
        client = nil
        asserted = false
        macOSRefusedLimit = nil
        memory = ChargeMemory()
        sleeping = false
        lastDecision = nil
        appliedLimit = nil
        limitInFlight = false
        refusedLimit = nil
        driftRepeats = 0
        notHolding = nil
        appliedDischarge = nil
        dischargeInFlight = false
        blockedDischarge = nil
        isDrainRequested = false
        isFullChargeRequested = false
        batteryPercent = nil
        isCablePresent = false
        isCharging = false
        dischargeEndedAt = nil
        lastRefusal = nil
        lastDrift = nil
        // A plan the helper holds is cancelled before this (`cancelPlan`); what is forgotten here is this side's book.
        wakePlan = nil
        cancelledPlan = nil
        plannedWriteSeen = nil
        readyBySetAside = false
        planSending = false
        readyByTimer?.invalidate()
        readyByTimer = nil
        readyByTimerAt = nil
        meter = ChargeRateMeter()
        // The debt itself (`cutOwed`) is on disk and outlives this; what was being done about it does not.
        stopDue = false
        cutLost = false
        cutSeen = false
        cutLookSince = nil
        forgetTheAnswer()
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
    /// Not when the record has gone (something else, an uninstall, has put macOS back since). With the shared record,
    /// nothing is put back while another account's Anode is running and holds the limit: it is that Anode's, and
    /// whether this account is on screen does not matter. With a per-account record (the shared file could not be
    /// had) nobody can say whose limit is in force, so nothing is put back while another account is on screen. A
    /// discharge is still stopped then: that is this account's own.
    func shutdown() {
        enabledToken = nil
        endOffRetry()
        // A quit during the delay is a clean one: nothing is pending, and macOS's own settings are in force, unless
        // the lift was refused: the record is then still there, and is put back now, if nobody else holds it.
        let wasWaiting = startsAt != nil, onScreen = sessionActive
        endStartWait()
        setStartPending(false)
        if wasWaiting, onScreen || records.isShared {
            putBackLeftoverRecord(when: "as Anode quit", leaving: "quitting")
        }
        guard running, let c = client else { return }
        switchingOff = true
        defer { switchingOff = false }
        // All the waiting of a quit is one budget: the plan's cancel, a discharge's stop, the limit going back.
        let deadline = Date().addingTimeInterval(Self.stopTimeout)
        cancelPlan(because: "quitting", waitingUntil: deadline)
        // Who holds the limit is known when the record is shared (`restore` puts nothing back while another account's
        // Anode is running and holds it); with a per-account record it is not, and nothing is put back while another
        // account is on screen: the limit in force is probably its Anode's.
        if records.hasRecord, sessionActive || records.isShared {
            restore(client: c, leaving: "quitting", deadline: deadline)
        } else if appliedDischarge != nil || dischargeInFlight || cutOwed {
            let r = waitedStop(timeout: Self.timeLeft(deadline))
            log("drain stopped (quitting): \(r?.message ?? "no answer in time")")
        } else if limitInFlight {
            _ = helper.drain(timeout: Self.timeLeft(deadline))
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
            log("drain stopped (before uninstalling): "
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
        guard !running, records.leftOverForThisAccount(), let c = makeClient() else { return false }
        // "While off" only when the setting is off: before an uninstall, or as a quit during the delay, it may be on.
        log("a record of macOS's own settings was left over\(settings.chargeControlEnabled ? "" : " while off"); "
            + "putting it back \(when)")
        restore(client: c, leaving: leaving)
        return true
    }

    // ── After an unclean exit ───────────────────────────────────────────────

    /// The lift: a record still there means the last run did not quit (a quit puts macOS back and clears it), and
    /// macOS's limit may still be in force with nobody holding it. Put macOS's own settings back at once, with a
    /// client made for that alone and let go, as for a record left over while off. True when it did this, false when
    /// there is nothing to lift (no record, no start pending) or no client to do it with (the ordinary switch-on then
    /// reports that). It runs at the top of the program (`liftAtLaunch`), and again here if the controller is built
    /// without that having run (the tests; nothing in the app).
    ///
    /// A start still pending (`Settings.chargeStartPending`) takes the same route with no record: the last run was
    /// itself waiting out the delay and died before it ended, which cleared the record but not the pending start.
    /// There is nothing to put back then, and the full delay is waited again. The flag is written, and flushed,
    /// before anything is put back, so that no crash between the record going and the wait starting can leave neither;
    /// it stays until the switch-on after the delay has run (`startNow`), or Charge Control is switched off, quits
    /// cleanly or is uninstalled.
    ///
    /// A discharge's end never confirmed is dealt with first: `restore` waits for a stop ahead of anything else (with
    /// no record there is no restore, and the off-retry asks at once; see `liftAfterUncleanExit`). A restore macOS
    /// refused keeps the record; the switch-on that follows leaves it as it is.
    private func liftNow() -> Bool {
        let recorded = records.hasRecord
        guard records.lastRunDidNotRelease() || settings.chargeStartPending else { return false }
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
        return true
    }

    /// At launch, with Charge Control on in the setting, when the last run did not quit: the lift, then the wait
    /// before switching on again, so that an Anode that breaks again within it leaves the battery released. The
    /// sentence in the section says so (`liftedText`), and the setting and the person's limit are not touched. The lift
    /// has usually been done already, at the top of the program (`liftedAtLaunch`), and is not repeated: this only
    /// waits, and asks about a debt the lift could not settle on the off-retry's timer until a running helper
    /// answers. The delay holds back the limit and new discharges, never the reconnecting of a charger. True when it
    /// waits, false when there is nothing to wait for.
    private func liftAfterUncleanExit() -> Bool {
        if !liftedAtLaunch, !liftNow() { return false }
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
        // The charger switch first, whatever the helper is (see `settleOwedCutByReadingTheSwitch`): a helper that
        // refuses this build, cannot start or is too old would be asked every 30 s for ever, each ask starting the
        // root helper, while the switch reads connected. A read that says so ends it, and nothing is asked.
        if settleOwedCutByReadingTheSwitch() { return }
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
                self.log("a drain's end is still not confirmed: \(r.message); asking again every "
                         + "\(Int(Self.tickInterval)) s")
                // The line while off stops saying "Reconnecting…", which is no longer what is happening
                // (`offWarning`).
                self.changed()
            }
        }
    }

    /// While not running, with a debt: the charger switch, read once, whatever helper is installed. A hand-started
    /// helper that was stopped has reconnected the charger as it went, and an installed one may never say yes (it
    /// refuses this build, cannot start, is too old): nothing else would ever say that the charger is connected, so
    /// the warning (`offWarning`) would stay for good, across launches, and an installed helper would be asked every
    /// 30 s for ever. Not running means nothing of this Anode's can be cutting the charger, so one read that says
    /// connected is enough: the net's 90 s of agreement guards against a discharge ending, and there is none. A switch
    /// that reads cut, a value Anode never writes, or cannot be read settles nothing. Read when the section is shown or
    /// the app comes forward, with no helper to ask, and before each ask of an installed one. True when it settled.
    @discardableResult
    private func settleOwedCutByReadingTheSwitch() -> Bool {
        guard !running, cutOwed, chargerSwitch() == AdapterCutKey.connected else { return false }
        settleWithoutTheHelper("the charger switch reads connected, and nothing of Charge Control's is running to cut "
                               + "it again")
        return true
    }

    /// Whether the debt is being asked about on the timer, for the tests.
    var isAskingAboutTheDebtWhileOff: Bool { offRetryTimer != nil }

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
        if cutSeen || cutLookSince != nil { cutLookAnsweredAt = lastTickNow }
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
        forgetTheAnswer()
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
        // Asked and not answered yes: "Reconnecting…" is not what is happening, and the line says what is.
        if offRetryTimer != nil { return lastOffFailure == nil ? Self.cutWarningText : Self.cutWarningStillAskingText }
        // Nothing is asking: either no helper is installed, or one was installed since and has not been asked yet.
        return helper.installed ? Self.cutWarningInstalledText : Self.cutWarningOffText
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
        let keys = [Settings.Key.chargeLimit, Settings.Key.chargeDriftEnabled, Settings.Key.chargeDriftGap,
                    Settings.Key.chargePauseWhenHotEnabled, Settings.Key.chargeMaxTemperatureC,
                    Settings.Key.chargeHoldDuringSleep, Settings.Key.chargeDrainAutomatically,
                    Settings.Key.chargeReadyByEnabled, Settings.Key.chargeReadyByMinutes]
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

        // The time of day Ready By names is a moment on the calendar: a change of time zone, or of the clock, moves it.
        timeClockObservers = [NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSSystemClockDidChange]
            .map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.tick()
                }
            }

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
        for o in timeClockObservers { NotificationCenter.default.removeObserver(o) }
        timeClockObservers = []
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
    func periodicTick(now given: Date? = nil) {
        guard running else { return }
        let now = given ?? clock()
        // Believed off screen: ask the session again. Only a plain yes counts (a session that says nothing is not
        // proof, and the account that is on screen holds the limit), and then it is what the notice would have done.
        if !sessionActive, sessionOnConsole() == true {
            log("the session says this account is on screen, though no notice of it came")
            sessionBecameActive()
        }
        if appliedDischarge != nil { helper.refresh() }
        // Another account on screen holds the limit: its changes are not drift.
        if sessionActive { checkDrift(now: now) }
        tick(now: now)
        lookAgainIfDue(now: now)
    }

    /// Something needs the helper (a limit only it can set, not in force; a discharge; or Ready By) and an installed one has
    /// not answered: its cold start was slower than its hello, say. Looked for again 30 s, 60 s and 120 s apart,
    /// then every five minutes. An outdated helper has answered, and is not woken to say so again.
    private var helperMissedWhileNeeded: Bool {
        guard let d = lastDecision, helper.known, !helper.available, !helper.outdated, helper.installed else {
            return false
        }
        let limitWaits = !NativeChargeLimit.isClientSettable(d.osLimit) && appliedLimit != d.osLimit
        // Ready By switched on needs a helper too (one that can wake the Mac): without it the hold is silently not in
        // force, and nothing else would look for the helper until the section was next shown.
        return limitWaits || d.dischargeTo != nil || settings.chargeReadyByEnabled
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
    /// was believed, and put it back: Optimized Battery Charging here, and the limit (with its switch) by the tick
    /// that follows, which sets it. The switch is never enabled on its own: that would set the limit to 80. Once per call, on the timer and
    /// after a wake, so a Mac that keeps refusing is asked again 30 s later, never in a loop.
    ///
    /// The switch reading off is not a change when 100 is what this controller put in force and 100 is what macOS
    /// reads: macOS turns the switch off by itself once the limit is set to 100 (measured on Mac17,9, macOS 27.0:
    /// "off, 100" read back seconds after 100 was set; taken for drift, 100 was set again every 30 s for as long as
    /// the limit, or Charge to Full, was 100). Off with anything below 100 in force is still a change, as is any
    /// other limit.
    ///
    /// With a plan pending (the helper holds one for this controller, or was asked to forget it and has not said yes) and
    /// its moment come, the planned limit is the helper's doing, not a change: its timer writes it when the Mac is awake
    /// as much as when it slept, and the pass must not call that outside. What the app does about it is the decision's:
    /// the limit macOS holds is taken as the planned one, and the tick that follows (`tickOnce`) leaves it when the
    /// decision wants it (Ready By charging), and sets the decision's own limit, with a line that says what happened,
    /// when it does not (a pack that is hot again, a hold that is not yet over).
    private func checkDrift(now: Date? = nil) {
        guard let c = client, let found = c.read() else { return }
        let at = now ?? clock()
        if let plan = wakePlan ?? cancelledPlan, let mine = appliedLimit, !limitInFlight, found.mclLimit != mine,
           found.mclLimit == plan.limit, at.addingTimeInterval(FanHelperServer.chargePlanSlack) >= plan.raiseAt {
            plannedWriteSeen = plan
            appliedLimit = plan.limit
        }
        var changed: [String] = []
        let offByItself = appliedLimit == Self.noLimit && found.mclLimit == Self.noLimit
        // A limit only the helper can set, on its way from nothing in force or from 100 (where macOS keeps the switch
        // off): macOS may show the value already landed, and the switch off if the stand-in ahead of it
        // (`standInForTheHelper`) was refused, for a moment before the helper's yes. That is the transition, not
        // someone's change. And with nothing in force (nothing applied yet, or the books cleared by this very pass) a
        // switch that is off is not a change either: nothing was holding it on.
        let helperLimitOnItsWay = limitInFlight && (appliedLimit == nil || appliedLimit == Self.noLimit)
        if appliedLimit != nil, !found.mclEnabled, !offByItself, !helperLimitOnItsWay {
            changed.append("the limit was turned off")
        }
        if found.optimizedChargingEnabled { changed.append("Optimized Battery Charging was turned on") }
        if let mine = appliedLimit, !limitInFlight, found.mclLimit != mine {
            changed.append("the limit is \(found.mclLimit), not \(mine)")
        }
        guard !changed.isEmpty else {
            lastDrift = nil
            driftRepeats = 0
            if notHolding != nil { notHolding = nil; updateStatus() }
            return
        }
        // The same news every 30 s is one line, not one a tick.
        let line = "macOS's charge settings changed outside Charge Control: " + changed.joined(separator: "; ")
            + "; putting them back"
        let news = line != lastDrift
        if news { log(line) }
        lastDrift = line
        // The same difference again after it was put back: macOS is not taking it. Three times, then stop sending and
        // say so, until something changes.
        if news {
            driftRepeats = 0
            notHolding = nil
        } else if let mine = appliedLimit, !limitInFlight, found.mclLimit != mine {
            driftRepeats += 1
            if driftRepeats >= Self.driftTries {
                if notHolding == nil {
                    log("macOS still shows a limit of \(found.mclLimit)%, not \(mine)%, after it was put back "
                        + "\(Self.driftTries) times; not setting it again until the limit changes")
                }
                notHolding = (mine, found.mclLimit)
                updateStatus()
                return
            }
        }
        appliedLimit = nil
        refusedLimit = nil
        // The limit itself is put back by the tick that follows, which sets it (that turns the switch on).
        if !c.setOptimizedCharging(false), news { log("macOS would not turn Optimized Battery Charging off") }
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
            // A plan lives on the connection. A socket that closed or was replaced took it with it; a reset that left
            // the connection open (the Fans tab released everything) did not, and a plan the helper still holds is
            // one that must still be cancelled when the hold ends.
            if wakePlan != nil, !helper.isOpen {
                log("the helper's connection was reset; the plan it held went with it")
                wakePlan = nil
            }
            // And a cancel that was never answered no longer matters: the connection it was for is gone.
            if !helper.isOpen { cancelledPlan = nil }
            if appliedDischarge != nil || cutOwed {
                if appliedDischarge != nil {
                    log("the helper's connection was reset under the drain; stopping it before anything else")
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
            // An installed helper's ask reads the switch first; with the ask already on its timer, or no helper to ask,
            // the section being shown is one more look.
            if helper.installed, offRetryTimer == nil { retryOwedStopWhileOff() } else { settleOwedCutByReadingTheSwitch() }
            return
        }
        refusedLimit = nil
        helper.recheck()
    }

    // ── The person ──────────────────────────────────────────────────────────

    /// Drain to the limit on the adapter; pressed again, cancel. Cancels Charge to Full, which would otherwise outrank
    /// it.
    func pressDrain() {
        guard running else { return }
        isDrainRequested.toggle()
        if isDrainRequested { isFullChargeRequested = false }
        // Pressing again is asking again, whatever the helper said last time.
        blockedDischarge = nil
        log(isDrainRequested ? "Drain to Limit pressed" : "Drain to Limit cancelled")
        tick()
        changed()
    }

    /// Charge to 100% until unplugged; pressed again, cancel. Cancels a manual drain.
    func pressFullCharge() {
        guard running else { return }
        isFullChargeRequested.toggle()
        if isFullChargeRequested { isDrainRequested = false }
        log(isFullChargeRequested ? "Charge to Full pressed" : "Charge to Full cancelled")
        tick()
        changed()
    }

    // ── Sleep ───────────────────────────────────────────────────────────────

    /// The next moment the time of day `minutes` (after local midnight) names, strictly after `now`, on `calendar`.
    ///
    /// Worked out with the calendar each time and never added up in seconds, so that it is right across a change of
    /// time zone and both daylight-saving changes: 7:00 is 7:00 on the wall that morning, whether the night was seven
    /// hours or nine. A time that does not exist that day (2:30 in the hour that was skipped) is the next one that
    /// does; one that happens twice (1:30 in the hour that was repeated) is the first.
    static func nextReadyBy(after now: Date, minutes: Int, calendar: Calendar) -> Date? {
        var time = DateComponents()
        time.hour = minutes / 60
        time.minute = minutes % 60
        time.second = 0
        return calendar.nextDate(after: now, matching: time, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
    }

    /// The one-shot timer for the start moment: look again now. Internal so the tests can be the timer.
    func readyByDue(now: Date? = nil) {
        readyByTimer?.invalidate()
        readyByTimer = nil
        readyByTimerAt = nil
        guard running else { return }
        tick(now: now)
    }

    /// The Mac is going to sleep. A running discharge is stopped, and the helper's answer awaited, before this
    /// returns, whatever Hold Level During Sleep says: nothing watches the floor while the Mac sleeps. A manual
    /// drain ends here and does not come back; an automatic one comes back by itself after the wake, through the
    /// policy. Then the sleeping decision is applied, a limit only the helper can set waited for too: it must be in
    /// force before the Mac sleeps, not on its way. All of it within `stopTimeout`.
    func willSleep(now: Date? = nil) {
        guard running else { return }
        let deadline = Date().addingTimeInterval(Self.stopTimeout)
        sleeping = true
        stopAndWait(for: "sleep", deadline: deadline)
        if isDrainRequested {
            isDrainRequested = false
            log("manual drain ended by sleep")
            changed()
        }
        waitUntil = deadline
        tick(now: now)
        waitUntil = nil
        sendThePlan(deadline: deadline, now: now)
    }

    /// While a hold is in force and the Mac is about to sleep, the helper is told when to wake it and what to raise the
    /// limit to, and the answer is waited for within the sleep's own budget: a plan not in place before the Mac sleeps
    /// is no plan. The connection is asked to stay open first, because the helper keeps a plan only as long as the
    /// connection it came on, and the link lets go after a waited command unless it has been asked not to.
    ///
    /// Sent again before every sleep, whatever was sent before: the helper replaces a plan with the same plan, and one
    /// it has lost (a restart, a reconnect) is then back. Only to a helper that speaks protocol 3: an older one closes
    /// the connection on a command it does not know.
    ///
    /// A plan that is not in place when the Mac is about to sleep is not left as the hold: nothing would raise the limit
    /// until someone woke the Mac after the time, and the battery would sit at the hold level all night. Ready By is set
    /// aside for this sleep (`readyBySetAside`), the decision is made again without it, and what that decides is put
    /// in force before the Mac sleeps, inside the same budget (a limit only the helper can set is waited for, as for
    /// any sleep): the person's own limit, unless another rule decides otherwise (Pause When Hot keeps a hot pack
    /// paused, Hold Level During Sleep holds the level, Drift Below the Limit rests the battery), and the log says
    /// which (`sleepWithoutAPlanText`). On the wake Ready By is back. A plan send that timed out can still land at the helper: that is
    /// harmless, since it only raises to the person's own limit at its moment, and it dies with the connection, which is
    /// let go.
    func sendThePlan(deadline: Date, now: Date?) {
        guard sessionActive, helper.speaksReadyBy else { return }
        let target: (by: Date, limit: Int, raiseAt: Date)
        if lastDecision?.reason == .readyBy, let hold = lastDecision?.readyBy, let at = hold.raiseAt {
            target = (hold.by, hold.raiseTo, at)
        } else if let paused = heatPausePlan(now: now ?? clock()) {
            target = paused
        } else {
            return
        }
        planSending = true
        helper.keepOpen(true)
        let r = helper.sendWaiting(.scheduleChargeLimit(limit: target.limit, at: target.raiseAt),
                                   timeout: Self.timeLeft(deadline))
        planSending = false
        if r?.ok == true {
            wakePlan = WakePlan(by: target.by, limit: target.limit, raiseAt: target.raiseAt)
            cancelledPlan = nil
            log("the helper will wake the Mac and raise the limit to \(target.limit)% at \(Self.logTime(target.raiseAt))")
            settle()
            return
        }
        wakePlan = nil
        log("the helper did not take the plan to raise the limit to \(target.limit)% at "
            + "\(Self.logTime(target.raiseAt)): \(r?.message ?? "no answer in time")")
        // The link is let go first (nothing is pending), then the limit is decided again without Ready By.
        readyBySetAside = true
        settle()
        waitUntil = deadline
        tick(now: now)
        waitUntil = nil
        standInForTheLimitThatCouldNotBeConfirmed()
        log(Self.sleepWithoutAPlanText(wanted: lastDecision, inForce: limitInForceNow()))
        settle()
    }

    /// The limit macOS holds as far as can be known now: read back when it can be, otherwise what was booked.
    private func limitInForceNow() -> Int? { client?.read()?.mclLimit ?? appliedLimit }

    /// Going to sleep with no plan, the decision's limit has been asked of the helper (waited for), and the helper may
    /// have refused or not answered. Whatever the Ready By hold left in force would then stay all night, so the nearest
    /// value macOS takes itself at or above the limit goes in, as `restoreLimit` does: never lower than asked. The wake
    /// asserts everything again (`didWake`), so it is for this sleep only.
    private func standInForTheLimitThatCouldNotBeConfirmed() {
        guard let d = lastDecision, let c = client, appliedLimit != d.osLimit,
              !NativeChargeLimit.isClientSettable(d.osLimit) else { return }
        let nearest = Self.nearestClientValue(atOrAbove: d.osLimit)
        guard appliedLimit != nearest else { return }
        setClientLimit(nearest, client: c, reason: d.reason, wanted: d.osLimit)
    }

    /// What the log says about the sleep that has no plan, from what is in force when the Mac goes to sleep.
    ///
    /// The decision made again without Ready By is not always the person's own limit, so "charging as usual" is said
    /// only for the decision that is the person's own limit (`.limit`). Pause When Hot outranks Ready By: a pack that
    /// was paused for heat stays paused and held at its level until the Mac wakes. Drift Below the Limit, a drain that
    /// is finished or stopped, Charge to Full and Hold Level During Sleep each hold or ask for something else, and each
    /// is said in its own words, built from the decision's reason and the limit read back as in force.
    static func sleepWithoutAPlanText(wanted d: ChargeDecision?, inForce: Int?) -> String {
        let why = "because no wake could be arranged for Ready By"
        guard let d else { return "the Mac sleeps \(why); Ready By is back when the Mac wakes" }
        let want = d.osLimit
        let back = "the limit is asserted again when the Mac wakes"
        // What was asked for, in the words of the decision that asked for it, where it could not be confirmed.
        let asked: String
        switch d.reason {
        case .heat: asked = "the pause for heat at \(want)%"
        case .sleeping: asked = "the hold of \(want)% for the sleep"
        case .drift: asked = "the rest below the limit at \(want)%"
        case .readyBy: asked = "the hold of \(want)% for Ready By"
        case .limit, .fullCharge, .draining, .drained: asked = "the charge limit of \(want)%"
        }
        switch inForce {
        case want?:
            switch d.reason {
            case .limit:
                return "the Mac sleeps with the battery charging as usual, to \(want)%, \(why); it is back when the Mac wakes"
            case .heat:
                return "the Mac sleeps with the battery paused for heat at \(want)% by Pause When Hot, \(why); it stays "
                    + "paused until the Mac wakes"
            case .sleeping:
                return "the Mac sleeps with the battery held at \(want)% by Hold Level During Sleep, \(why); Ready By is "
                    + "back when the Mac wakes"
            case .drift:
                return "the Mac sleeps with the battery drifting below the limit, held at \(want)% by Drift Below the "
                    + "Limit, \(why); Ready By is back when the Mac wakes"
            case .draining:
                return "the Mac sleeps with the limit of \(want)% in force and the drain stopped for the sleep, \(why); "
                    + "Drain Automatically Above the Limit starts it again when the Mac wakes, if the battery is still "
                    + "above the limit"
            case .drained:
                return "the Mac sleeps with the drain down to the limit finished and the limit of \(want)% in force, "
                    + "\(why); Ready By is back when the Mac wakes"
            case .fullCharge:
                return "the Mac sleeps with the battery charging to \(want)% for Charge to Full, \(why); Ready By is "
                    + "back when the Mac wakes"
            case .readyBy:
                return "the Mac sleeps with the battery still held at \(want)% by Ready By, although no wake could be "
                    + "arranged for it; \(back)"
            }
        case let held? where held < want:
            return "the Mac sleeps with \(held)% still in force, not \(want)%: neither the helper nor macOS set \(want)% "
                + "before the Mac sleeps, so the battery will not charge past \(held)% until it wakes; \(back)"
        case let above?:
            return "\(asked) could not be confirmed in force before the Mac sleeps; \(above)% is in "
                + "force instead, the nearest limit macOS takes itself at or above it, so the battery may charge up to "
                + "\(above)% meanwhile; \(back)"
        case nil:
            return "\(asked) could not be confirmed in force before the Mac sleeps; \(back)"
        }
    }

    /// How long a pack paused for heat is given, asleep, to cool before the limit is raised for Ready By.
    static let heatCoolingTime: TimeInterval = 30 * 60

    /// Pause When Hot is the rule above Ready By, so a pack that is hot as the Mac goes to sleep makes the decision the
    /// heat pause, which has no Ready By moment in it, and without this nothing would raise the limit asleep: Ready By
    /// would be lost for the night. Paused for heat with Ready By on, the battery below the limit, and the next moment
    /// inside its window, the plan is the person's limit at the later of the start moment and `heatCoolingTime` from now,
    /// so the pack has cooled asleep. If Ready By had already started charging (the start moment has passed) it is
    /// half an hour from now. Awake, heat still outranks Ready By, as it did.
    private func heatPausePlan(now: Date) -> (by: Date, limit: Int, raiseAt: Date)? {
        guard lastDecision?.reason == .heat, settings.chargeReadyByEnabled, let b = battery(),
              b.onAC || b.adapterPresent else { return nil }
        let limit = settings.chargeLimit
        guard b.percent < limit,
              let by = Self.nextReadyBy(after: now, minutes: settings.chargeReadyByMinutes, calendar: calendar()),
              by.timeIntervalSince(now) <= ChargePolicy.readyByWindow else { return nil }
        let cooled = now.addingTimeInterval(Self.heatCoolingTime)
        if memory.readyBy?.started == true { return (by, limit, cooled) }
        let level = min(limit, max(b.percent, min(ChargePolicy.readyByFloor, limit)))
        let lead = ChargePolicy.minutesToCharge(from: level, to: limit,
                                                rate: loadedRates().rate(forAdapterWatts: b.adapterWatts)) * 60
            + ChargePolicy.readyByMargin
        return (by, limit, max(by.addingTimeInterval(-lead), cooled))
    }

    /// The helper was told to forget the plan to raise the limit: a hold that has ended for a reason of its own (the
    /// charger unplugged, Ready By switched off, the time or the limit changed, Charge to Full pressed, the moment come),
    /// or Charge Control going away. `deadline` when it must be answered before this returns (switching off, quitting,
    /// another account coming on screen); otherwise it goes on its way. Nothing is sent when nothing was planned, and
    /// nothing to a helper that does not know the command.
    private func cancelPlan(because why: String, waitingUntil deadline: Date? = nil) {
        guard let plan = wakePlan else { return }
        wakePlan = nil
        guard helper.speaksReadyBy else { return }
        // Until the helper says yes it may still write the plan's limit (`checkDrift`).
        cancelledPlan = plan
        if let deadline {
            let r = helper.sendWaiting(.cancelScheduledChargeLimit, timeout: Self.timeLeft(deadline))
            if r?.ok == true, cancelledPlan == plan { cancelledPlan = nil }
            log("the plan to raise the limit was cancelled (\(why)): \(r?.message ?? "no answer in time")")
        } else {
            log("the plan to raise the limit was cancelled (\(why))")
            let mine = session
            helper.send(.cancelScheduledChargeLimit) { [weak self] r in
                guard let self, self.session == mine else { return }
                if r.ok { if self.cancelledPlan == plan { self.cancelledPlan = nil } }
                else { self.log("the helper did not cancel the plan to raise the limit: \(r.message)") }
            }
        }
    }

    /// The plan the helper holds stays only while the hold it was made for does: this same moment and this same limit.
    /// A wake that is not the moment changes nothing about that, so it leaves the plan where it is.
    private func reconcilePlan() {
        guard let plan = wakePlan, !planSending else { return }
        if sessionActive, helper.speaksReadyBy, lastDecision?.reason == .readyBy, let hold = lastDecision?.readyBy,
           hold.isHolding, hold.by == plan.by, hold.raiseTo == plan.limit { return }
        // A plan is for sleep only while the pack is paused for heat: awake, heat outranks Ready By, and the helper's own
        // timer would raise the limit onto the hot pack at the plan's moment. It is sent again before the next sleep if
        // it is still wanted (`sendThePlan`).
        if lastDecision?.reason == .heat, !sleeping {
            cancelPlan(because: "the Mac is awake and the battery is paused for heat", waitingUntil: waitUntil)
            return
        }
        // A plan made for a pack paused for heat (`heatPausePlan`) stands while the pack is, for the same moment and limit.
        if sessionActive, helper.speaksReadyBy, lastDecision?.reason == .heat, settings.chargeReadyByEnabled,
           plan.limit == settings.chargeLimit, (batteryPercent ?? 100) < plan.limit,
           Self.nextReadyBy(after: lastTickNow, minutes: settings.chargeReadyByMinutes, calendar: calendar()) == plan.by {
            return
        }
        let why: String
        if lastDecision?.reason != .readyBy {
            why = isCablePresent ? "Ready By is no longer holding the charge" : "the charger is unplugged"
        } else if lastDecision?.readyBy?.isHolding != true {
            why = "the time to charge has come"
        } else {
            why = "the time or the limit changed"
        }
        // Going to sleep, a cancel is waited for like the plan itself: a Mac asleep cannot send one.
        cancelPlan(because: why, waitingUntil: waitUntil)
    }

    /// One timer for the start moment while awake, so that the limit is raised when the moment comes and not up to a
    /// tick later. Only for precision: the 30 s tick and the tick after a wake find the moment on their own.
    private func syncReadyByTimer() {
        var want: Date?
        if running, !sleeping, lastDecision?.reason == .readyBy, let at = lastDecision?.readyBy?.raiseAt,
           at > lastTickNow {
            want = at
        }
        guard want != readyByTimerAt else { return }
        readyByTimer?.invalidate()
        readyByTimer = nil
        readyByTimerAt = want
        guard let at = want else { return }
        let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in self?.readyByDue() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        readyByTimer = t
    }

    /// A moment for the charge log: the time on the person's own clock, with the zone.
    private static func logTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f.string(from: d)
    }

    func didWake(now: Date? = nil) {
        guard running else { return }
        let t = now ?? clock()
        sleeping = false
        readyBySetAside = false
        // The person may have changed macOS's settings while the Mac slept. The helper may have raised the limit by itself
        // at the plan's moment: that is its plan working, not a change someone else made, and the decision below says
        // whether it is wanted (`checkDrift`, `tickOnce`).
        if sessionActive { checkDrift(now: t) }
        // Asserted again after every sleep, whatever the books say. The plan is not touched: a Mac wakes by itself many
        // times a night, and only the decision (this moment, this limit, still holding) says whether it stands.
        appliedLimit = nil
        refusedLimit = nil
        tick(now: t)
    }

    /// A discharge this controller holds (or may hold) is stopped and the answer waited for: what comes next has
    /// nobody watching the floor. Not answered yes, the cut may outlive it: asked again on every tick.
    private func stopAndWait(for why: String, deadline: Date) {
        guard appliedDischarge != nil || dischargeInFlight || cutOwed else { return }
        let r = waitedStop(timeout: Self.timeLeft(deadline))
        log("drain stopped for \(why): \(r?.message ?? "no answer in time")")
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
        let deadline = Date().addingTimeInterval(Self.stopTimeout)
        // Its Anode holds the limit now: a wake of ours must not raise it under that.
        cancelPlan(because: "another account is on screen", waitingUntil: deadline)
        stopAndWait(for: "another account", deadline: deadline)
        cutSeen = false
        cutLookSince = nil
        forgetTheAnswer()
        // Every lost cut is owed: a discharge is owed before it is asked for, and the net owes what it finds, so a
        // debt this Anode has written down is still asked about while away (that is putting right, not holding),
        // warning and all. This holds only a lost cut with no debt behind it, which nothing makes now; it is kept so
        // that one could never outlive the debt it belongs to.
        if !cutOwed {
            cutLost = false
            stopDue = false
        }
        if isDrainRequested {
            isDrainRequested = false
            log("manual drain ended: another account is on screen")
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
        // Launched while another account was on screen, nothing has been asserted yet: that is a switch-on, not a
        // change someone else made.
        if let c = client, !asserted { assertMacOSSettings(c) } else { checkDrift() }
        appliedLimit = nil
        refusedLimit = nil
        tick()
    }

    // ── Deciding ────────────────────────────────────────────────────────────

    /// Ask the policy, and apply what changed.
    func tick(now given: Date? = nil) {
        guard running, !switchingOff else { return }
        let now = given ?? clock()
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
        lastTickNow = now
        guard let b = battery() else { return setStatus(.unavailable(Self.noBatteryText)) }
        // Anode's own charger cut can make macOS report the Mac off the adapter while the cable is in (measured with
        // no macOS limit holding the battery); the adapter's details still describe a charger then, and stop
        // describing one when the cable is really pulled.
        let onAC = b.onAC || b.adapterPresent
        // What the section reads, from the same reading the decision is made from, so the two always agree.
        var announce = false
        if b.percent != batteryPercent || onAC != isCablePresent || b.isCharging != isCharging {
            batteryPercent = b.percent
            isCablePresent = onAC
            isCharging = b.isCharging
            if !onAC { dischargeEndedAt = nil }
            // Charging again is the end of the reconnecting wait, whatever it does after: it is not asked about again.
            if b.isCharging { dischargeEndedAt = nil }
            announce = true
        }
        learnChargeRate(from: b, at: now)
        let snapshot = settings.chargeSettingsSnapshot()
        // Ready By needs a helper that can wake the Mac: without one (or with one too old to know how) it is not in
        // force and the battery charges to the limit as usual. Holding without it would only stop at the nearest limit
        // macOS takes, which may be below the person's own.
        let readyBy = snapshot.readyByEnabled && helper.speaksReadyBy && !readyBySetAside
            ? Self.nextReadyBy(after: now, minutes: snapshot.readyByMinutes, calendar: calendar()) : nil
        let inputs = ChargeInputs(percent: b.percent, onAC: onAC,
                                  temperatureC: b.temperature_C.flatMap { $0.isFinite ? $0 : nil },
                                  sleeping: sleeping, fullCharge: isFullChargeRequested,
                                  manualDrain: isDrainRequested, now: now,
                                  readyBy: readyBy, chargeRate: loadedRates().rate(forAdapterWatts: b.adapterWatts))
        let decision = ChargePolicy.decide(snapshot, inputs, &memory)
        if decision.endFullCharge && isFullChargeRequested { isFullChargeRequested = false; announce = true }
        if decision.endManualDrain && isDrainRequested {
            isDrainRequested = false
            announce = true
            log(onAC ? "manual drain finished" : "manual drain ended: unplugged")
        }
        lastDecision = decision
        // The helper's planned write, found by the drift pass just before this: the limit macOS holds is the plan's, and
        // the decision made now says whether that is what is wanted. Said plainly when it is not (`apply` puts the
        // decision's own limit in force just below).
        if let wrote = plannedWriteSeen {
            plannedWriteSeen = nil
            if decision.osLimit != wrote.limit { log(Self.plannedWriteNotWanted(wrote.limit, decision)) }
        }
        // The net is this account's alone: while another is on screen, its Anode may be discharging through a
        // helper this one cannot even reach. It looks only with a charger on the cable: with the cable out nothing
        // is cut off from anything, and the Mac is on its battery, where every read costs.
        let netLooks = sessionActive && onAC && appliedDischarge == nil
        noteCutLook(looked: netLooks, switchReads: netLooks ? chargerSwitchThisTick() : nil,
                    macOSLook: sessionActive && !b.onAC && b.adapterPresent, now: now)
        // macOS's own flag, not `onAC` above: the adapter's details say yes all through a cut.
        noteConnected(externalConnected: b.onAC, now: now)
        apply(decision)
        // Drift and heat memory belong to one connection to the adapter.
        if !onAC { memory = ChargeMemory() }
        settle()
        noteHelperNeed(now: now)
        if announce { changed() }
    }

    private func loadedRates() -> ChargeRate {
        if let r = rates { return r }
        let r = rateStore.load()
        rates = r
        return r
    }

    /// What the battery is doing teaches how fast this charger charges (`ChargeRateMeter`); what is learned is kept.
    private func learnChargeRate(from b: Battery.State, at now: Date) {
        guard let m = meter.observe(percent: b.percent, charging: b.isCharging, onAC: b.onAC,
                                    adapterWatts: b.adapterWatts, at: now) else { return }
        var r = loadedRates()
        guard r.record(m.rate, for: m.band) else { return }
        rates = r
        rateStore.save(r)
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

    /// The helper's yes for this stretch of the look is forgotten, and with it how often it was asked again.
    private func forgetTheAnswer() {
        cutLookAnsweredAt = nil
        cutReasks = 0
        cutReaskLogged = nil
    }

    /// A helper said the charger is connected, and Anode's own read of the switch still says cut after the time the
    /// net waits: the warning stays while the asking backs off (`cutReaskInterval`).
    private var cutDisputed: Bool {
        guard cutLookAnsweredAt != nil, switchRead?.value == AdapterCutKey.cut, let since = cutLookSince else {
            return false
        }
        return lastTickNow.timeIntervalSince(since) > Self.chargerReconnectTime
    }

    /// The helper said the charger is connected earlier in this stretch, the switch still reads cut, and it is being
    /// asked again (`cutReasks`) without its answer back yet. The sentence about the switch stays up through the ask:
    /// "Reconnecting…" for the few seconds between the ask and the yes made the line flap every time. A helper that
    /// does not say yes sets `cutLost`, which is another sentence.
    private var cutReasking: Bool {
        cutReasks > 0 && cutLookAnsweredAt == nil && !cutLost && cutLookSince != nil
            && switchRead?.value == AdapterCutKey.cut
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
    ///     for a Mac whose switch has never been read in this run, and only for it. It is not believed against a
    ///     switch that reads connected (there is then nothing to reconnect, and the helper is not woken to say so),
    ///     nor against one that reads a value Anode never writes (not Anode's cut, and not Anode's to touch).
    ///
    /// `looked` is whether the switch was asked at all this tick (`read` is nil when it was not). A read that fails
    /// is no information once the switch has been read in this run: the look neither ends nor goes on, `cutLookSince`
    /// and `cutSeen` stay as they were, and nothing fires on it. (Before that, a read that fails means this Mac's
    /// switch cannot be read, and macOS's word is all there is.) A cut read as cut, cut, failed, cut would otherwise
    /// start its 90 s again, and one failing every third tick would never be found.
    private func noteCutLook(looked: Bool, switchReads read: UInt8?, macOSLook: Bool, now: Date) {
        if looked, read == nil, switchEverRead { return }
        let switchCut = read == AdapterCutKey.cut
        // macOS's word is for a switch that could not be read at all (above, a read that fails after one that worked
        // returned). A switch that reads connected disproves it, and one that reads a value Anode never writes is not
        // Anode's cut and not Anode's to touch: owing a stop for it would write a debt only a helper can clear.
        let looksCut = switchCut || (macOSLook && read == nil)
        guard looksCut, appliedDischarge == nil else {
            cutLookSince = nil
            forgetTheAnswer()
            cutSeen = false
            return
        }
        let since = cutLookSince ?? now
        cutLookSince = since
        // A yes to the stop settles the stretch for macOS's word, which is no proof. The switch itself still reading
        // cut is: asked again, no sooner than `cutReaskAfter` after the answer.
        if let answered = cutLookAnsweredAt, switchCut,
           now.timeIntervalSince(answered) >= Self.cutReaskInterval(afterReasks: cutReasks) {
            cutLookAnsweredAt = nil
            cutReasks += 1
        }
        guard !dischargeInFlight, !cutLookAnswered, !cutSeen,
              now.timeIntervalSince(since) > Self.chargerReconnectTime else { return }
        cutSeen = true
        // A cut the net finds is a debt like any other: written down before the helper is asked (`applyDischarge`,
        // later in this tick), so a switch-off or a quit while it is unsettled still asks the helper, and the line
        // while off still says so. The look itself is only in memory, and ends with the look.
        oweCut()
        if cutReasks > 0 {
            // A helper that said the charger is connected, and a switch that still reads cut: each ask waits twice as
            // long as the one before, and the line is written when the wait changes, not at each ask.
            let wait = Self.cutReaskInterval(afterReasks: cutReasks)
            if wait != cutReaskLogged {
                cutReaskLogged = wait
                log("the helper said the charger is connected, but the charger switch still reads cut; asked it "
                    + "again, and will ask again in \(Int(wait / 60)) minutes if it still does")
            }
            return
        }
        let what = switchCut ? "the charger switch has read cut" : "macOS has said the Mac is off the adapter"
        log("\(what), with the adapter there and no drain running, for over \(Int(Self.chargerReconnectTime)) s: "
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
        settleWithoutTheHelper("\(what) for over \(Int(Self.chargerReconnectTime)) s with no drain running: the "
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
        // The sentence beside the status can change with no change of status.
        if readyByNeedsNewerHelper != shownReadyByNeedsNewerHelper {
            shownReadyByNeedsNewerHelper = readyByNeedsNewerHelper
            changed()
        }
        reconcilePlan()
        syncReadyByTimer()
        helper.keepOpen(linkNeeded)
    }

    /// A discharge lives on the connection (closing it ends the cut), from the moment one is wanted until it has
    /// stopped; and while a stop is owed, it is held for the stop. Nothing else keeps it open.
    private var linkNeeded: Bool {
        if appliedDischarge != nil || dischargeInFlight || stopDue || cutLost || cutSeen { return true }
        // The helper keeps a plan only as long as the connection it came on.
        if wakePlan != nil || planSending { return true }
        guard let target = lastDecision?.dischargeTo, !sleeping, sessionActive, helper.available else { return false }
        return blockedDischarge?.target != target
    }

    // ── The limit ───────────────────────────────────────────────────────────

    private func applyLimit(_ d: ChargeDecision) {
        let want = d.osLimit
        if let r = refusedLimit, r.value != want { refusedLimit = nil }
        if let n = notHolding, n.wanted != want {
            notHolding = nil
            driftRepeats = 0
        }
        guard appliedLimit != want, let c = client else { return }
        // One on its way is waited for, except going to sleep, when this one must land first (see below).
        if limitInFlight && waitUntil == nil { return }
        if NativeChargeLimit.isClientSettable(want) {
            setClientLimit(want, client: c, reason: d.reason)
        } else if helper.available, refusedLimit == nil {
            let from = appliedLimit
            standInForTheHelper(want, client: c)
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
            macOSRefusedLimit = nil
            log("\(Self.limitChange(from, want)) (\(Self.logWords(reason)))")
        } else {
            log("the helper did not set the limit to \(want): \(r.message)")
            if r.message != HelperConnection.stoppedAnswering { refusedLimit = (want, r.message) }
        }
    }

    /// The one place the limit's switch is turned on for a value only the helper can set, and it is turned on by setting
    /// a limit, never by enabling it.
    ///
    /// Measured on Mac17,9, macOS 27.0, 2026-11-13 (unprivileged calls on `PowerUISmartChargeClient`, each read back
    /// from the client and from `pmset -g battlimit`): enabling the limit sets it to 80 every time (set 95, enable: 80;
    /// set 90, enable: 80), so enabling after the helper's yes put an 87 back to 80; setting a limit below 100 turns
    /// the switch on by itself (off, 100 then set 90 gave on, 90), and setting 100 turns it off; a limit the helper's
    /// preference write stores is read back by the client at once. Nothing was measured of what the helper's write does
    /// to the switch.
    ///
    /// So when the switch reads off, cannot be read, or nothing is booked as in force, the nearest value macOS takes at
    /// or above `want` is set first (never lower than asked, on the way too) and the helper's value follows. With the
    /// switch on and a limit booked, the helper alone is asked.
    private func standInForTheHelper(_ want: Int, client c: ChargeLimitClient) {
        if appliedLimit != nil, c.read()?.mclEnabled == true { return }
        let standIn = Self.standInValue(for: want)
        if !c.setLimit(standIn) { log("macOS would not take \(standIn)% ahead of the helper's \(want)%") }
    }

    /// The value set through macOS itself to turn the switch on ahead of a helper's `want`: the nearest it takes at or
    /// above. For 96 to 99 that would be 100, and setting 100 turns the switch OFF (measured), which would leave the
    /// helper's value stored and not enforced; so there it is 95, the highest that keeps the switch on, for the moment
    /// before the helper's value lands.
    static func standInValue(for want: Int) -> Int {
        let nearest = nearestClientValue(atOrAbove: want)
        return nearest == noLimit ? 95 : nearest
    }

    private func setClientLimit(_ value: Int, client c: ChargeLimitClient, reason: ChargeReason, wanted: Int? = nil) {
        guard NativeChargeLimit.isClientSettable(value) else { return }
        let from = appliedLimit
        if c.setLimit(value) {
            appliedLimit = value
            macOSRefusedLimit = nil
            let note = wanted.map { "; \($0) needs the helper" } ?? ""
            log("\(Self.limitChange(from, value)) (\(Self.logWords(reason))\(note))")
        } else {
            macOSRefusedLimit = value
            log("macOS refused the limit \(value)")
        }
    }

    private static func limitChange(_ from: Int?, _ to: Int) -> String {
        from.map { "limit \($0) -> \(to)" } ?? "limit set to \(to)"
    }

    // ── Draining (the helper's discharge) ───────────────────────────────

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
            return stopDischarge(why: Self.logWords(d.reason))
        }
        guard let target = want else {
            // Not wanted: a discharge in force is stopped, and so is one whose end no running helper confirmed (a
            // refused or unanswered request may have cut the charger all the same).
            if appliedDischarge != nil || cutOwed { stopDischarge(why: Self.logWords(d.reason)) }
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
                if !r.ok { log("stopping the old drain first: \(r.message)") }
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
                    self.log(from.map { "drain \($0) -> \(target)" } ?? "drain to \(target) started")
                } else {
                    // The connection was reset after this went out: the helper that cut may be gone, or may have
                    // reconnected the charger. Neither running nor ended as far as anyone knows, so a stop goes
                    // out before anything else.
                    self.appliedDischarge = nil
                    self.seenResets = self.helper.resets
                    self.stopDue = true
                    self.log("the helper's connection was reset as the drain to \(target) started; stopping it "
                             + "before anything else")
                }
                self.reapply()
            } else if r.message == HelperConnection.stoppedAnswering {
                // Not a refusal: the helper went away with this on its way, and may have cut the charger first.
                self.stopNotConfirmed("the helper stopped answering as the drain to \(target) went out")
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
                    if why != ChargeRefusal.goingToSleep { self.log("drain to \(target) refused: \(why)") }
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
                    self.log("drain to \(from) stopped (\(why))")
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
        if cutReasking { return setStatus(.warning(Self.cutWarningDisputedText)) }
        if cutLost || cutSeen {
            return setStatus(.warning(helper.installed ? Self.cutWarningText : Self.cutWarningNoHelperText))
        }
        if cutDisputed { return setStatus(.warning(Self.cutWarningDisputedText)) }
        // The value macOS would have to take for this decision, when it is macOS and not the helper that holds it:
        // not in force because macOS refused it. (A refusal of an earlier value, or of one the helper has since set,
        // is not this.)
        if let n = notHolding, n.wanted == d.osLimit {
            return setStatus(.refused(Self.notHoldingText(wanted: n.wanted, inForce: n.inForce)))
        }
        let viaMacOS = NativeChargeLimit.isClientSettable(d.osLimit) || !(helper.available && refusedLimit == nil)
        let viaMacOSValue = NativeChargeLimit.isClientSettable(d.osLimit) ? d.osLimit
            : Self.nearestClientValue(atOrAbove: d.osLimit)
        if viaMacOS, let refused = macOSRefusedLimit, refused == viaMacOSValue, appliedLimit != viaMacOSValue {
            return setStatus(.refused(Self.macOSRefusedLimitText(wanted: d.osLimit, refused: refused,
                                                                 inForce: appliedLimit)))
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
            setStatus(.refused(Self.drainRefusedText(b.why)))
        } else if d.dischargeTo != nil, !helper.available {
            guard helper.known else { return }
            setStatus(.needsHelper(missing ?? Self.drainNeedsHelperText))
        } else if settings.chargeReadyByEnabled, !helper.speaksReadyBy, !helper.available {
            // Switched on and not in force: it needs a helper that knows how to wake the Mac, and the battery charges to
            // the limit as usual meanwhile. Nothing is said about the helper until it has answered. A helper too old for
            // any charge command says so in the old words; one that speaks protocol 2 does control charging, and says
            // only what Ready By needs (`readyByNeedsNewerHelper`), beside the status of what works.
            guard helper.known else { return }
            setStatus(.needsHelper(helper.outdated ? Self.helperOutdatedText : Self.readyByNeedsHelperText))
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

    static func encodeRecord(_ s: NativeChargeState) -> String? {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// nil for no record, and for a string that is not one.
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
    var speaksReadyBy: Bool { (version ?? 0) >= 3 }
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
