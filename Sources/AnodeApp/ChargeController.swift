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
// While the setting is off nothing exists: no client, no timer, no observer but the one on the switch itself, no
// helper connection and no helper command.
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
    /// Opens the connection if this link is not holding it, and lets it go after the answer unless it is kept open.
    /// `done` is called on the main thread. A helper that is gone answers ok:false with
    /// `HelperConnection.stoppedAnswering`; there is no "no answer".
    func send(_ c: FanCommand, _ done: @escaping (FanReply) -> Void)
    /// `send`, answered before it returns, or nil after `timeout`. Blocks the caller.
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

    static func dischargeRefusedText(_ why: String) -> String { "The Anode helper would not discharge: \(why)" }
    static func limitRefusedText(_ limit: Int, _ why: String) -> String {
        "The Anode helper did not set the limit to \(limit)%: \(why)"
    }

    /// How often the battery is looked at while on. Charging moves about 1% a minute at most, and every change
    /// that matters sooner (a plug, a setting, a sleep) has its own trigger.
    static let tickInterval: TimeInterval = 30
    /// The longest anything waits for the helper: going to sleep, switching off, uninstalling.
    static let stopTimeout: TimeInterval = 2
    /// What the helper says when it refuses a discharge because the Mac is going to sleep. Not an error: the next
    /// tick asks again.
    static let goingToSleepRefusal = "the Mac is going to sleep"
    /// The helper's refusals of a discharge that do not pass by themselves. Asking again on every tick would only
    /// be refused again.
    static let lastingDischargeRefusals: Set<String> = [
        "the charger may still be cut off from an earlier failure",
        "this Mac cannot warn the helper before it sleeps",
    ]

    /// Called whenever `status` or the two press flags may have changed.
    var onChange: (() -> Void)?

    /// The policy's last answer.
    private(set) var lastDecision: ChargeDecision?
    private(set) var status: ChargeStatus = .off
    /// The person pressed Discharge and it has not finished, been cancelled, or been ended by an unplug or a sleep.
    private(set) var isDischargeRequested = false
    /// The person pressed Top Up and has not unplugged or cancelled it.
    private(set) var isTopUpRequested = false

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
    private var appliedDischarge: Int?
    private var dischargeInFlight = false
    /// Bumped when a discharge in flight is overtaken (going to sleep stops it), so its late answer is ignored.
    private var dischargeEpoch = 0
    /// A discharge request was refused or went unanswered: the helper may be in a state this controller does not
    /// know, so the next start stops first.
    private var dischargeUncertain = false
    /// A discharge the helper refused for a lasting reason, and the reason. Not asked for again until the person
    /// presses again or the decision changes.
    private var blockedDischarge: (target: Int, why: String)?
    private var seenResets = 0
    private var lastRefusal: String?
    /// The last "changed outside Charge Control" line, so the same news is logged once.
    private var lastDrift: String?

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

    init(settings: Settings, makeClient: @escaping () -> ChargeLimitClient? = { PowerUIChargeClient() },
         helper: ChargeHelperLink, battery: @escaping () -> Battery.State? = { Battery.state() },
         log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) }) {
        self.settings = settings
        self.makeClient = makeClient
        self.helper = helper
        self.battery = battery
        self.log = log
        enabledToken = settings.observe(Settings.Key.chargeControlEnabled) { [weak self] in self?.applyEnabled() }
        applyEnabled()
    }

    deinit {
        removeTriggers()
        // The connection is shared: a claim left behind would keep it open for good.
        if running { helper.letGo() }
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
            restore(client: c)
            stop()
            log("off")
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
        if appliedDischarge != nil || dischargeInFlight || dischargeUncertain {
            let r = helper.sendWaiting(.stopDischarge, timeout: Self.stopTimeout)
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
        dischargeUncertain = false
        blockedDischarge = nil
        isDischargeRequested = false
        isTopUpRequested = false
        lastRefusal = nil
        lastDrift = nil
    }

    /// The app is quitting. macOS's limit stays in force (it outlives the app by design); the helper link is let go,
    /// and if nothing else holds it the helper's dead man's switch ends any discharge.
    func shutdown() {
        enabledToken = nil
        guard running else { return }
        // Nothing is put back, but what is still on its way lands before the link is let go.
        if limitInFlight || dischargeInFlight { _ = helper.drain(timeout: Self.stopTimeout) }
        stop()
    }

    /// Anode is being uninstalled: put macOS back now, waiting for the helper, and switch Charge Control off.
    ///
    /// Also while off, if a record is left over (a switch-off macOS partly refused, or the setting turned off while
    /// Anode was closed): once Anode is gone nothing could ever undo that hold. The one time a client is made while
    /// off, and it is let go at once.
    func restoreForUninstall() {
        if running, let c = client {
            restore(client: c)
            stop()
            log("off (uninstalling)")
        } else if settings.chargeRestoreRecord != nil, let c = makeClient() {
            restore(client: c)
            log("put back a leftover record before uninstalling")
        }
        setStatus(.off)
        settings.chargeControlEnabled = false
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
    /// under it. Otherwise the daemon is left asleep: a limit it set stays set without it.
    func periodicTick(now: Date = Date()) {
        guard running else { return }
        if appliedDischarge != nil { helper.refresh() }
        checkDrift()
        tick(now: now)
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
    private func helperChanged() {
        guard running else { return }
        if helper.resets != seenResets {
            seenResets = helper.resets
            if appliedDischarge != nil {
                log("the helper's connection was reset, which ends a discharge; asking again if it is still wanted")
                appliedDischarge = nil
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
        onChange?()
    }

    /// Charge to 100% until unplugged; pressed again, cancel. Cancels a manual discharge.
    func pressTopUp() {
        guard running else { return }
        isTopUpRequested.toggle()
        if isTopUpRequested { isDischargeRequested = false }
        log(isTopUpRequested ? "Top Up pressed" : "Top Up cancelled")
        tick()
        onChange?()
    }

    // ── Sleep ───────────────────────────────────────────────────────────────

    /// The Mac is going to sleep. A running discharge is stopped, and the helper's answer awaited (2 s at most),
    /// before this returns, whatever Stop Charging when Sleeping says: nothing watches the floor while the Mac
    /// sleeps. A manual discharge ends here and does not come back; an automatic one comes back by itself after the
    /// wake, through the policy. Then the sleeping decision is applied.
    func willSleep() {
        guard running else { return }
        sleeping = true
        if appliedDischarge != nil || dischargeInFlight || dischargeUncertain {
            let r = helper.sendWaiting(.stopDischarge, timeout: Self.stopTimeout)
            log("discharge stopped for sleep: \(r?.message ?? "no answer within \(Int(Self.stopTimeout)) s")")
            dischargeEpoch += 1
            dischargeInFlight = false
            appliedDischarge = nil
            dischargeUncertain = r?.ok != true
        }
        if isDischargeRequested {
            isDischargeRequested = false
            log("manual discharge ended by sleep")
            onChange?()
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
        guard running else { return }
        // The helper link may answer synchronously inside a tick (opening the connection, letting it go); that
        // news is acted on by one more pass afterwards, never by a tick inside this one.
        if ticking {
            tickAgain = true
            return
        }
        ticking = true
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
        let inputs = ChargeInputs(percent: b.percent, onAC: onAC,
                                  temperatureC: b.temperature_C.flatMap { $0.isFinite ? $0 : nil },
                                  sleeping: sleeping, topUp: isTopUpRequested,
                                  manualDischarge: isDischargeRequested, now: now)
        let decision = ChargePolicy.decide(settings.chargeSettingsSnapshot(), inputs, &memory)
        var flagsChanged = false
        if decision.endTopUp && isTopUpRequested { isTopUpRequested = false; flagsChanged = true }
        if decision.endManualDischarge && isDischargeRequested {
            isDischargeRequested = false
            flagsChanged = true
            log(onAC ? "manual discharge finished" : "manual discharge ended: unplugged")
        }
        lastDecision = decision
        apply(decision)
        // Sailing and heat memory belong to one connection to the adapter.
        if !onAC { memory = ChargeMemory() }
        settle()
        if flagsChanged { onChange?() }
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
    /// stopped. Nothing else keeps it open.
    private var linkNeeded: Bool {
        if appliedDischarge != nil || dischargeInFlight { return true }
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
        // A lasting refusal holds until the decision changes.
        if let b = blockedDischarge, b.target != want { blockedDischarge = nil }
        guard want != appliedDischarge else { return }
        guard helper.available else {
            // Without the helper nothing of ours can be running: losing the link ended it.
            if want == nil { appliedDischarge = nil }
            return
        }
        if let target = want {
            // Nothing watches the floor while the Mac sleeps, and the helper would refuse anyway.
            guard !sleeping, blockedDischarge == nil else { return }
            // A discharge lives on an open connection. Opening one answers through `helperChanged`, which ticks
            // again; a connection the Fans tab already holds is open at once.
            if !helper.isOpen { helper.keepOpen(true) }
            guard helper.isOpen else { return }
            startDischarge(to: target)
        } else {
            stopDischarge(reason: d.reason)
        }
    }

    private func startDischarge(to target: Int) {
        let from = appliedDischarge
        // The helper refuses a discharge while one runs, so a new target, or one after an unclear answer, stops
        // first. The link's queue keeps the two in order.
        let stopFirst = from != nil || dischargeUncertain
        dischargeInFlight = true
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
                self.dischargeUncertain = false
                self.lastRefusal = nil
                if self.helper.resets == resetsAtSend {
                    self.appliedDischarge = target
                    self.log(from.map { "discharge \($0) -> \(target)" } ?? "discharge to \(target) started")
                } else {
                    // Something reset the helper after this was sent: it is not running any more.
                    self.appliedDischarge = nil
                    self.seenResets = self.helper.resets
                }
                self.reapply()
            } else {
                // A refusal starts nothing, and a stop sent first ended whatever ran.
                self.appliedDischarge = nil
                self.dischargeUncertain = true
                let why = r.message
                if Self.lastingDischargeRefusals.contains(why) {
                    // Asked again only when the person presses again or the decision changes.
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

    private func stopDischarge(reason: ChargeReason) {
        let from = appliedDischarge
        dischargeInFlight = true
        let mine = session, epoch = dischargeEpoch
        helper.send(.stopDischarge) { [weak self] r in
            guard let self, self.session == mine, self.dischargeEpoch == epoch else { return }
            self.dischargeInFlight = false
            guard self.running else { return }
            let gone = r.message == HelperConnection.stoppedAnswering
            if r.ok || gone {
                // A helper that stopped answering has lost its client, and reconnects the charger when it does.
                self.appliedDischarge = nil
                self.dischargeUncertain = !r.ok
                self.log("discharge\(from.map { " to \($0)" } ?? "") stopped (\(reason.rawValue))"
                         + (gone ? ": the helper stopped answering, which reconnects the charger" : ""))
                self.reapply()
            } else {
                // Still booked as running, so the next tick asks again; the helper retries the reconnect itself too.
                self.log("could not stop the discharge: \(r.message)")
                self.settle()
            }
        }
    }

    // ── Status ──────────────────────────────────────────────────────────────

    private func updateStatus() {
        guard running, let d = lastDecision else { return }
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
        onChange?()
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
    private var wasSuspended = false

    init(connection: HelperConnection = .shared, isInstalled: @escaping () -> Bool = { FanDaemon.isInstalled() }) {
        self.connection = connection
        self.isInstalled = isInstalled
    }

    var available: Bool { (version ?? 0) >= 2 }
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
        claim()
        connection.send(c) { [weak self] reply in
            self?.inFlight -= 1
            self?.learn(reply)
            done(reply)
            self?.settle()
        }
    }

    func sendWaiting(_ c: FanCommand, timeout: TimeInterval) -> FanReply? {
        inFlight += 1
        claim()
        let reply = connection.sendWaiting(c, timeout: timeout)
        inFlight -= 1
        if let reply { learn(reply) }
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

    /// Open the connection for this link if it is not holding it already. Commands sent after this queue behind
    /// the open on the link's serial queue.
    private func claim() {
        guard !claimed else { return }
        claimed = true
        connect()
    }

    /// Greet over the shared connection, opening it if nobody has. Counted as in flight until answered, so the
    /// claim is not let go under it (which would close the socket and make the answer a stale one).
    private func connect() {
        inFlight += 1
        connection.connect(for: .charge) { [weak self] status in
            guard let self else { return }
            self.inFlight -= 1
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

    /// A reply says the helper is there, except "stopped answering", which says it is gone.
    private func learn(_ reply: FanReply) {
        guard !reply.ok, reply.message == HelperConnection.stoppedAnswering else { return }
        version = nil
        known = true
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
