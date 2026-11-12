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
// once, after anything still on its way to the helper has landed. Quitting does not: the limit is macOS's own
// setting and stays in force while Anode is closed. While on, macOS is read back on the timer and after a wake, and
// put back if something else changed it.
//
// A charger cut outlives the helper that made it (measured: a killed helper leaves it cut, and the installed daemon
// is not kept alive; only a new connection to its socket starts a fresh helper, whose startup reconnects the
// charger). So a discharge is never taken as ended until a RUNNING helper has answered a stop with yes. The debt is
// written down (`Settings.chargeCutUnconfirmed`, flushed) before a discharge is asked for; a stop nobody answered,
// a connection reset under a discharge, or macOS saying the Mac is off the adapter with the adapter there for more
// than 90 s with no discharge running, all mean the cut may be left with nobody watching: the connection is opened
// again at once and the stop asked again, then on every tick, with a warning, until a running helper says yes.
//
// While the setting is off nothing exists: no client, no timer, no observer but the one on the switch itself, no
// helper connection and no helper command. The exceptions are what an earlier run left unfinished: a restore record
// is put back once at launch (and before an uninstall), with a client made for that alone; and that debt, which is
// paid at launch through an installed helper, and asked again every 30 s until a running helper answers.
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
    /// What the helper says when it refuses a discharge because the Mac is going to sleep. Not an error, and not
    /// logged: the next tick asks again.
    static let goingToSleepRefusal = "the Mac is going to sleep"
    /// The helper's refusals of a discharge that pass by themselves, so the next tick asks again: the Mac going to
    /// sleep, and the charger switched a moment ago (the helper waits 10 s between switches). Every other refusal is
    /// shown, and not asked again until the person presses again or the decision changes. The one place these
    /// sentences live in the app.
    static let transientDischargeRefusals: Set<String> = [
        goingToSleepRefusal,
        "the charger was switched a moment ago; try again shortly",
    ]

    /// How long after a discharge ends with the cable in that macOS may still show "not charging". Measured on
    /// this Mac: about a minute before charging resumes; this leaves room.
    static let chargerReconnectTime: TimeInterval = 90

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
    /// (macOS then reports the Mac on battery, but the adapter is still there). False while off.
    private(set) var isCablePresent = false
    /// The discharge the helper said yes to and has not said it stopped: what is running, not what was asked for.
    var dischargeInForce: Int? { appliedDischarge }

    private let settings: Settings
    private let makeClient: () -> ChargeLimitClient?
    private let helper: ChargeHelperLink
    private let battery: () -> Battery.State?
    private let log: (String) -> Void

    private var client: ChargeLimitClient?
    private var memory = ChargeMemory()
    private var sleeping = false
    /// Bumped on every switch-on, so an answer from the helper that belongs to an earlier one is ignored.
    private var session = 0

    // What is in force, as far as this controller knows. Applied values are booked only when macOS or the helper
    // said yes, so a refusal is tried again on a later tick.
    private var appliedLimit: Int?
    private var limitInFlight = false
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

    /// The debt: a discharge was asked for and no running helper has said the charger is connected since. Mirrors
    /// `Settings.chargeCutUnconfirmed`, which is written (and flushed) before the discharge goes out.
    private var cutOwed = false
    /// A stop goes out before anything else, whatever the policy wants and whether or not the helper has answered:
    /// the debt was found at launch, or the connection was reset under a discharge.
    private var stopDue = false
    /// A stop was not answered yes (the helper is gone, or could not reconnect the charger): the cut may be left
    /// with nobody watching. The warning shows, and the stop is asked again once a tick until a running helper says
    /// yes.
    private var cutLost = false
    /// macOS has said the Mac is off the adapter, with the adapter there and no discharge in force, for longer than
    /// the end of a discharge takes: the look of a cut nobody holds. Treated like `cutLost` while it lasts.
    private var cutSeen = false
    /// When that look began; nil while macOS says otherwise or a discharge is in force.
    private var cutLookSince: Date?
    /// A running helper said the charger is connected during this stretch of that look: not asked again until it
    /// ends, or a charger macOS reports oddly would wake the helper every tick.
    private var cutLookAnswered = false
    /// Counts the discharges sent: a stop's yes settles the debt only if no discharge went out after the stop.
    private var dischargeSeq = 0
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

    init(settings: Settings, makeClient: @escaping () -> ChargeLimitClient? = { PowerUIChargeClient() },
         helper: ChargeHelperLink, battery: @escaping () -> Battery.State? = { Battery.state() },
         log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) }) {
        self.settings = settings
        self.makeClient = makeClient
        self.helper = helper
        self.battery = battery
        self.log = log
        cutOwed = settings.chargeCutUnconfirmed
        enabledToken = settings.observe(Settings.Key.chargeControlEnabled) { [weak self] in self?.applyEnabled() }
        applyEnabled()
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
        guard !running else { return }
        guard let c = makeClient() else {
            log("unavailable: the macOS charge limit client is missing on this Mac")
            return setStatus(.unavailable(Self.unavailableText))
        }
        // The way back is written down before anything is changed, and flushed: macOS keeps these settings after
        // Anode is gone, so the record has to survive a crash in the next few lines. A record from an earlier run
        // is the state before Charge Control ever ran, and stays. So does one that cannot be read: the state found
        // now may be one Charge Control made, and switching off puts back macOS's defaults instead.
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
    /// are waited for, `stopTimeout` at most each, on this thread.
    ///
    /// The record is cleared only when every step is known to have worked. Otherwise it is kept and that is logged,
    /// so the next switch-off tries again from the true original rather than from what is left.
    private func restore(client c: ChargeLimitClient) {
        // A stop goes behind everything already sent on the same link, so its answer also says those have landed.
        let settled: Bool
        if appliedDischarge != nil || dischargeInFlight || cutOwed {
            let r = waitedStop(timeout: Self.stopTimeout)
            log("discharge stopped (switching off): \(r?.message ?? "no answer within \(Int(Self.stopTimeout)) s")")
            settled = r != nil
        } else {
            settled = helper.drain(timeout: Self.stopTimeout)
        }
        if !settled {
            log("the helper had not finished what it was asked within \(Int(Self.stopTimeout)) s; it may land after "
                + "this")
        }
        guard let record = recordToRestore() else {
            log("no record of macOS's own settings to put back")
            return
        }
        var ok = restoreLimit(record.mclLimit, client: c) && settled
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

    private func restoreLimit(_ limit: Int, client c: ChargeLimitClient) -> Bool {
        if NativeChargeLimit.isClientSettable(limit) { return c.setLimit(limit) }
        let nearest = Self.nearestClientValue(atOrAbove: limit)
        if helper.available {
            let r = helper.sendWaiting(.setChargeLimit(limit), timeout: Self.stopTimeout)
            if r?.ok == true { return true }
            // Never left lower than it was meant to be put back to; the record says the rest.
            log("the helper did not put the limit back to \(limit): "
                + "\(r?.message ?? "no answer within \(Int(Self.stopTimeout)) s"); set \(nearest) for now")
            _ = c.setLimit(nearest)
            return false
        }
        log("limit \(limit) needs the helper to put back; set \(nearest) instead")
        return c.setLimit(nearest)
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
        lookDueAt = nil
        lookCount = 0
    }

    /// The app is quitting. macOS's limit stays in force (it outlives the app by design); the helper link is let go,
    /// and if nothing else holds it the helper's dead man's switch ends any discharge.
    func shutdown() {
        enabledToken = nil
        endOffRetry()
        guard running else { return }
        switchingOff = true
        defer { switchingOff = false }
        // Nothing is put back, but what is still on its way lands before the link is let go.
        if limitInFlight || dischargeInFlight { _ = helper.drain(timeout: Self.stopTimeout) }
        stop()
    }

    /// Anode is being uninstalled: put macOS back now, waiting for the helper, and switch Charge Control off.
    ///
    /// Also while off, if a record is left over (a switch-off macOS partly refused, or the setting turned off while
    /// Anode was closed): once Anode is gone nothing could ever undo that hold.
    func restoreForUninstall() {
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
    private func putBackLeftoverRecord(when: String) -> Bool {
        guard !running, settings.chargeRestoreRecord != nil, let c = makeClient() else { return false }
        log("a record of macOS's own settings was left over while off; putting it back \(when)")
        restore(client: c)
        return true
    }

    /// A stop, waited for, after a hello over the connection (a new one if the old one does not answer: for an
    /// installed helper that starts a fresh one, whose startup reconnects the charger). A yes settles the debt.
    private func waitedStop(timeout: TimeInterval) -> FanReply? {
        let seq = dischargeSeq
        let r = helper.sendWaiting(.stopDischarge, timeout: timeout)
        if r?.ok == true { chargerConfirmed(stopSentAt: seq) }
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
                self.chargerConfirmed(stopSentAt: seq)
                self.log("the charger is connected: \(r.message)")
                self.endOffRetry()
            } else if r.message != self.lastOffFailure {
                self.lastOffFailure = r.message
                self.log("a discharge's end is still not confirmed: \(r.message); asking again every "
                         + "\(Int(Self.tickInterval)) s")
            }
        }
    }

    private func endOffRetry() {
        offRetryTimer?.invalidate()
        offRetryTimer = nil
        lastOffFailure = nil
    }

    // ── The debt ────────────────────────────────────────────────────────────

    /// Written down, and flushed, before anything that can cut the charger goes out.
    private func oweCut() {
        guard !cutOwed else { return }
        cutOwed = true
        settings.chargeCutUnconfirmed = true
        settings.flush()
    }

    /// A running helper answered a stop with yes: the charger is connected (or was never cut). Settles the debt,
    /// unless a discharge went out after that stop.
    private func chargerConfirmed(stopSentAt seq: Int) {
        guard seq == dischargeSeq else { return }
        let wasLost = cutLost || cutSeen
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

        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.willSleep()
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.didWake()
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
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
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
        checkDrift()
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
        guard running, helperMissedWhileNeeded, let due = lookDueAt,
              now >= due.addingTimeInterval(-5) else { return }
        lookCount += 1
        lookDueAt = now.addingTimeInterval(Self.lookAgainAfter[min(lookCount, Self.lookAgainAfter.count - 1)])
        helper.recheck()
    }

    /// Read macOS back. If the limit's switch, the limit or Optimized Battery Charging is not what this controller
    /// put in force (the person changed it in System Settings, or something else did), say so once, forget what
    /// was believed, and put all three back; the tick that follows sets the limit. Once per call, on the timer and
    /// after a wake, so a Mac that keeps refusing is asked again 30 s later, never in a loop.
    private func checkDrift() {
        guard let c = client, let found = c.read() else { return }
        var changed: [String] = []
        if !found.mclEnabled { changed.append("the limit was turned off") }
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
    func recheckHelper() {
        guard running else { return }
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

    /// The Mac is going to sleep. A running discharge is stopped, and the helper's answer awaited (2 s at most),
    /// before this returns, whatever Stop Charging when Sleeping says: nothing watches the floor while the Mac
    /// sleeps. A manual discharge ends here and does not come back; an automatic one comes back by itself after the
    /// wake, through the policy. Then the sleeping decision is applied.
    func willSleep() {
        guard running else { return }
        sleeping = true
        if appliedDischarge != nil || dischargeInFlight || cutOwed {
            let r = waitedStop(timeout: Self.stopTimeout)
            log("discharge stopped for sleep: \(r?.message ?? "no answer within \(Int(Self.stopTimeout)) s")")
            dischargeEpoch += 1
            dischargeInFlight = false
            appliedDischarge = nil
            // Not answered yes: the cut may outlive the sleep. Asked again on every tick from the wake.
            if r?.ok != true {
                stopDue = true
                cutLost = true
            }
        }
        if isDischargeRequested {
            isDischargeRequested = false
            log("manual discharge ended by sleep")
            changed()
        }
        tick()
    }

    func didWake() {
        guard running else { return }
        sleeping = false
        // The person may have changed macOS's settings while the Mac slept.
        checkDrift()
        // Asserted again after every sleep, whatever the books say.
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
        // Anode's own charger cut makes macOS report the Mac off the adapter while the cable is in; the adapter's
        // details still describe a charger then, and stop describing one when the cable is really pulled.
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
        noteCutLook(!b.onAC && b.adapterPresent, now: now)
        apply(decision)
        // Sailing and heat memory belong to one connection to the adapter.
        if !onAC { memory = ChargeMemory() }
        settle()
        noteHelperNeed(now: now)
        if announce { changed() }
    }

    /// The safety net under the bookkeeping. macOS reporting the Mac off the adapter while the adapter is there is
    /// what a charger cut looks like. With no discharge in force, a cut is expected for a minute or so after one
    /// ends (macOS is slow to say it is charging again); longer than `chargerReconnectTime`, it is taken for a cut
    /// nobody holds: the helper is asked to reconnect it and the warning shows, until a running helper says the
    /// charger is connected (then not again for the same stretch) or macOS stops saying it.
    private func noteCutLook(_ looksCut: Bool, now: Date) {
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
        log("macOS has said the Mac is off the adapter, with the adapter there and no discharge running, for over "
            + "\(Int(Self.chargerReconnectTime)) s: the charger may have been left cut; asking the helper to "
            + "reconnect it")
    }

    /// Apply `lastDecision` again after an answer came back, in case it changed while the request was on its way.
    private func reapply() {
        guard running, let d = lastDecision else { return }
        apply(d)
        settle()
    }

    private func apply(_ d: ChargeDecision) {
        applyLimit(d)
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
        guard let target = lastDecision?.dischargeTo, !sleeping, helper.available else { return false }
        return blockedDischarge?.target != target
    }

    // ── The limit ───────────────────────────────────────────────────────────

    private func applyLimit(_ d: ChargeDecision) {
        let want = d.osLimit
        if let r = refusedLimit, r.value != want { refusedLimit = nil }
        guard appliedLimit != want, !limitInFlight, let c = client else { return }
        if NativeChargeLimit.isClientSettable(want) {
            setClientLimit(want, client: c, reason: d.reason)
        } else if helper.available, refusedLimit == nil {
            limitInFlight = true
            let from = appliedLimit
            let mine = session
            helper.send(.setChargeLimit(want)) { [weak self] r in
                guard let self, self.session == mine else { return }
                self.limitInFlight = false
                guard self.running else { return }
                if r.ok {
                    self.appliedLimit = want
                    self.log("\(Self.limitChange(from, want)) (\(d.reason.rawValue))")
                    self.reapply()
                } else {
                    self.log("the helper did not set the limit to \(want): \(r.message)")
                    // Not sent again on every tick. A helper that stopped answering is unavailable now; one that
                    // refused is not asked for this value again until something changes. Either way the nearest
                    // value macOS takes above it holds meanwhile.
                    if r.message != HelperConnection.stoppedAnswering { self.refusedLimit = (want, r.message) }
                    self.reapply()
                }
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
        guard target != appliedDischarge, helper.available else { return }
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
                    if why != Self.goingToSleepRefusal { self.log("discharge to \(target) refused: \(why)") }
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
                self.chargerConfirmed(stopSentAt: seq)
                if let from {
                    self.log("discharge to \(from) stopped (\(why))")
                } else if !lost {
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
            setStatus(.needsHelper(missing ?? Self.limitNeedsHelperText))
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
