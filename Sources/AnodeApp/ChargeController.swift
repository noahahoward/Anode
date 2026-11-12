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
// The first time it is switched on, the state of macOS's limit and Optimized Battery Charging is written down
// (`Settings.chargeRestoreRecord`, flushed to disk) BEFORE anything is changed, and switching off puts it back at
// once. Quitting does not: the limit is macOS's own setting and stays in force while Anode is closed.
//
// While the setting is off nothing exists: no client, no timer, no observer but the one on the switch itself, no
// helper connection and no helper command.
//
// Main thread throughout.

/// The root helper as Charge Control sees it. A protocol so the tests can script it; the real one is
/// `ChargeHelperAdapter`.
protocol ChargeHelperLink: AnyObject {
    /// The helper answered hello on this app's connection and speaks protocol 2 or later.
    var available: Bool { get }
    /// A helper answered, but one too old to know the charge commands.
    var outdated: Bool { get }
    /// Goes up whenever the helper may have ended a discharge that Charge Control did not end: its socket closed
    /// or was replaced, or the Fans tab sent "release everything".
    var resets: Int { get }
    /// Keep the link open, and call `changed` (on the main thread) when `available`, `outdated` or `resets` change.
    func hold(_ changed: @escaping () -> Void)
    /// Stop holding the link. It closes only if nothing else in the app holds it.
    func letGo()
    /// Check the link is still there, and reopen it if it is not. Cheap; on the controller's timer.
    func refresh()
    /// `done` is called on the main thread; nil when nothing answered.
    func send(_ c: FanCommand, _ done: @escaping (FanReply?) -> Void)
    /// `send`, answered before it returns, or nil after `timeout`. Blocks the caller.
    func sendWaiting(_ c: FanCommand, timeout: TimeInterval) -> FanReply?
}

/// What the Beta Features section shows.
enum ChargeStatus: Equatable {
    case off
    /// Charge Control cannot run on this Mac, and why.
    case unavailable(String)
    /// What was asked for needs the helper, which is missing or too old; the sentence says which.
    case needsHelper(String)
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

    /// How often the battery is looked at while on. Charging moves about 1% a minute at most, and every change
    /// that matters sooner (a plug, a setting, a sleep) has its own trigger.
    static let tickInterval: TimeInterval = 30
    /// The longest going to sleep waits for the helper to stop a discharge.
    static let stopTimeout: TimeInterval = 2
    /// What the helper says when it refuses a discharge because the Mac is going to sleep. Not an error: the next
    /// tick asks again.
    static let goingToSleepRefusal = "the Mac is going to sleep"

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
    private var appliedDischarge: Int?
    private var dischargeInFlight = false
    /// Bumped when a discharge in flight is overtaken (going to sleep stops it), so its late answer is ignored.
    private var dischargeEpoch = 0
    /// A discharge request went unanswered, or was refused: the helper may be in a state this controller does
    /// not know, so the next start stops first.
    private var dischargeUncertain = false
    private var seenResets = 0
    private var lastRefusal: String?
    /// The helper link has answered at least once since this switch-on. Until it has, a limit only the helper can
    /// set is not replaced by the client's nearest value: at launch the hello is a moment away, and the limit would
    /// otherwise go up and come back down every time the app starts.
    private var helperAnswered = false

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
        // is the state before Charge Control ever ran, and stays.
        if Self.decodeRecord(settings.chargeRestoreRecord) == nil {
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
        helper.hold { [weak self] in self?.helperChanged() }
        tick()
    }

    private func disable() {
        if running {
            restore(waiting: false)
            stop()
            log("off")
        }
        setStatus(.off)
    }

    /// Put macOS back as the record says, now: the limit, the limit's switch and Optimized Battery Charging, after
    /// stopping a discharge. `waiting` waits (boundedly) for the helper's answers, for a caller that is about to
    /// lose the helper.
    private func restore(waiting: Bool) {
        guard let c = client else { return }
        if appliedDischarge != nil || dischargeInFlight || dischargeUncertain {
            if waiting {
                let r = helper.sendWaiting(.stopDischarge, timeout: Self.stopTimeout)
                log("discharge stopped (switching off): \(r?.message ?? "no answer")")
            } else {
                helper.send(.stopDischarge) { [log] r in log("discharge stopped (switching off): \(r?.message ?? "no answer")") }
            }
        }
        guard let record = Self.decodeRecord(settings.chargeRestoreRecord) else {
            log("no record of macOS's own settings to put back")
            return
        }
        var ok = restoreLimit(record.mclLimit, client: c, waiting: waiting)
        ok = c.setLimitEnabled(record.mclEnabled) && ok
        ok = c.setOptimizedCharging(record.optimizedChargingEnabled) && ok
        if ok {
            settings.chargeRestoreRecord = nil
            settings.flush()
            log("put back macOS's own settings: limit \(record.mclLimit) \(record.mclEnabled ? "on" : "off"), "
                + "Optimized Battery Charging \(record.optimizedChargingEnabled ? "on" : "off")")
        } else {
            // Kept, so the next switch-off tries again from the true original rather than from what is left.
            log("macOS refused part of putting its settings back; the record is kept")
        }
    }

    private func restoreLimit(_ limit: Int, client c: ChargeLimitClient, waiting: Bool) -> Bool {
        if NativeChargeLimit.isClientSettable(limit) { return c.setLimit(limit) }
        if helper.available {
            if waiting {
                return helper.sendWaiting(.setChargeLimit(limit), timeout: Self.stopTimeout)?.ok == true
            }
            helper.send(.setChargeLimit(limit)) { [log] r in
                if r?.ok != true { log("the helper did not put the limit back to \(limit): \(r?.message ?? "no answer")") }
            }
            return true
        }
        let nearest = Self.nearestClientValue(atOrAbove: limit)
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
        appliedDischarge = nil
        dischargeInFlight = false
        dischargeUncertain = false
        isDischargeRequested = false
        isTopUpRequested = false
        lastRefusal = nil
        helperAnswered = false
    }

    /// The app is quitting. macOS's limit stays in force (it outlives the app by design); the helper link is let go,
    /// and if nothing else holds it the helper's dead man's switch ends any discharge.
    func shutdown() {
        enabledToken = nil
        guard running else { return }
        stop()
    }

    /// Anode is being uninstalled: put macOS back now, waiting for the helper, and switch Charge Control off.
    func restoreForUninstall() {
        if running {
            restore(waiting: true)
            stop()
            log("off (uninstalling)")
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
            guard let self else { return }
            self.helperAnswered = true   // waited long enough
            self.helper.refresh()
            self.tick()
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

    /// The helper link came, went, or was reset under a discharge.
    private func helperChanged() {
        guard running else { return }
        helperAnswered = true
        if helper.resets != seenResets {
            seenResets = helper.resets
            if appliedDischarge != nil {
                log("the helper's connection was reset, which ends a discharge; asking again if it is still wanted")
                appliedDischarge = nil
            }
        }
        tick()
    }

    // ── The person ──────────────────────────────────────────────────────────

    /// Discharge to the limit on the adapter; pressed again, cancel. Cancels Top Up, which would otherwise outrank it.
    func pressDischarge() {
        guard running else { return }
        isDischargeRequested.toggle()
        if isDischargeRequested { isTopUpRequested = false }
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
        // Asserted again after every sleep, whatever the books say.
        appliedLimit = nil
        helper.refresh()
        tick()
    }

    // ── Deciding ────────────────────────────────────────────────────────────

    /// Ask the policy, and apply what changed.
    func tick(now: Date = Date()) {
        guard running else { return }
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
        updateStatus()
        if flagsChanged { onChange?() }
    }

    /// Apply `lastDecision` again after an answer came back, in case it changed while the request was on its way.
    private func reapply() {
        guard running, let d = lastDecision else { return }
        apply(d)
        updateStatus()
    }

    private func apply(_ d: ChargeDecision) {
        applyLimit(d)
        applyDischarge(d)
    }

    // ── The limit ───────────────────────────────────────────────────────────

    private func applyLimit(_ d: ChargeDecision) {
        let want = d.osLimit
        guard appliedLimit != want, !limitInFlight, let c = client else { return }
        if NativeChargeLimit.isClientSettable(want) {
            setClientLimit(want, client: c, reason: d.reason)
        } else if helper.available {
            limitInFlight = true
            let from = appliedLimit
            let mine = session
            helper.send(.setChargeLimit(want)) { [weak self] r in
                guard let self, self.session == mine else { return }
                self.limitInFlight = false
                guard self.running else { return }
                if r?.ok == true {
                    self.appliedLimit = want
                    self.log("\(Self.limitChange(from, want)) (\(d.reason.rawValue), through the helper)")
                    self.reapply()
                } else {
                    self.log("the helper did not set the limit to \(want): \(r?.message ?? "no answer")")
                    self.updateStatus()
                }
            }
        } else {
            // Never lower than asked: the nearest value the client takes at or above it.
            guard helperAnswered else { return }
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
        guard want != appliedDischarge else { return }
        guard helper.available else {
            // Without the helper nothing of ours can be running: losing the link ended it.
            if want == nil { appliedDischarge = nil }
            return
        }
        if let target = want {
            // Nothing watches the floor while the Mac sleeps, and the helper would refuse anyway.
            guard !sleeping else { return }
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
                if r?.ok != true { log("stopping the old discharge first: \(r?.message ?? "no answer")") }
            }
        }
        helper.send(.discharge(toPercent: target)) { [weak self] r in
            guard let self, self.session == mine, self.dischargeEpoch == epoch else { return }
            self.dischargeInFlight = false
            guard self.running else { return }
            if let r, r.ok {
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
                // A refusal starts nothing, and a stop sent first ended whatever ran. Asked again on the next tick.
                self.appliedDischarge = nil
                self.dischargeUncertain = true
                let why = r?.message ?? "no answer"
                if why != self.lastRefusal {
                    self.lastRefusal = why
                    if why != Self.goingToSleepRefusal { self.log("discharge to \(target) refused: \(why)") }
                }
                self.updateStatus()
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
            if r?.ok == true || r == nil {
                // No answer means the socket is gone, and the helper reconnects the charger when it goes.
                self.appliedDischarge = nil
                self.dischargeUncertain = r == nil
                self.log("discharge\(from.map { " to \($0)" } ?? "") stopped (\(reason.rawValue))")
                self.reapply()
            } else {
                // Still booked as running, so the next tick asks again; the helper retries the reconnect itself too.
                self.log("could not stop the discharge: \(r?.message ?? "no answer")")
            }
        }
    }

    // ── Status ──────────────────────────────────────────────────────────────

    private func updateStatus() {
        guard running, let d = lastDecision else { return }
        let missing = helper.outdated ? Self.helperOutdatedText : nil
        if !NativeChargeLimit.isClientSettable(d.osLimit), !helper.available, appliedLimit != d.osLimit {
            setStatus(.needsHelper(missing ?? Self.limitNeedsHelperText))
        } else if d.dischargeTo != nil, !helper.available {
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

    static func encodeRecord(_ s: NativeChargeState) -> String? {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// nil for no record, and for a string that is not one: that is treated as no record, and replaced.
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
final class ChargeHelperAdapter: ChargeHelperLink {

    private let connection: HelperConnection
    private var token: AnyObject?

    init(connection: HelperConnection = .shared) {
        self.connection = connection
    }

    var available: Bool { connection.speaksCharge }
    var outdated: Bool { connection.isConnected && !connection.speaksCharge }
    var resets: Int { connection.resets }

    func hold(_ changed: @escaping () -> Void) {
        token = connection.watch(changed)
        // Connecting starts the installed daemon on demand, and its startup clears a charger cut that a helper
        // which died left behind. `changed` also hears the first answer when it changes nothing, such as "still
        // not running".
        connection.connect(for: .charge) { _ in changed() }
    }

    func letGo() {
        token = nil
        connection.release(.charge)
    }

    func refresh() {
        guard token != nil else { return }
        connection.connect(for: .charge) { _ in }
    }

    func send(_ c: FanCommand, _ done: @escaping (FanReply?) -> Void) {
        connection.send(c) { done($0) }
    }

    func sendWaiting(_ c: FanCommand, timeout: TimeInterval) -> FanReply? {
        connection.sendWaiting(c, timeout: timeout)
    }
}
