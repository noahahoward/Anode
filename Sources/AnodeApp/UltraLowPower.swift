import Foundation
import PowerKit

// ── Ultra Low Power Mode: the controller ────────────────────────────────────
//
// One session, from the owner's request to "off". It decides nothing about WHAT is frozen (`FreezePlanner`), what the
// screen is held to (`BrightnessCeiling`), what undoes a session (`UltraRecovery`) or whether a freeze made something burn
// (`SpinGuard`): it runs them in order against small protocols, so the whole of it is tested with fakes.
//
// What it must never do is leave the Mac stopped, dim or slow with nobody able to undo it, so:
//
//   · the record names everything BEFORE it is done: every process before it is stopped, each setting before it is
//     changed. A crash in between finds an entry for something that was not done yet, which is harmless (a continue of a
//     running process, a brightness put back only when the screen is still where the mode held it); it never finds the
//     reverse. When a record cannot be written, what it would have named is not done;
//   · every piece of work that waits (a hidden app, the load, a call that can block, a helper) is tagged with the session
//     it belongs to and does nothing if that session is over. Ending bumps the number;
//   · ending continues every process first, then lifts the background policy from every process the record names, then puts
//     the settings back, and only then takes the watchdog and the record away.

enum PowerModeAvailability: Equatable { case ready, noHelper, oldHelper }

protocol PowerModeControlling: AnyObject {
    var availability: PowerModeAvailability { get }
    /// Switches macOS's Low Power Mode on. Calls back exactly once, on any queue, with the power mode in force before;
    /// nil when it could not.
    func enterLowPower(_ done: @escaping (_ modeBefore: Int?) -> Void)
    /// Puts `mode` back. Calls back exactly once, on any queue.
    func restore(_ mode: Int, _ done: @escaping (Bool) -> Void)
}

protocol UltraConfirming: AnyObject {
    /// Shows what is kept and what is frozen, by name, and calls back once on the main thread: true for Confirm.
    func ask(kept: [String], frozen: [String], answer: @escaping (Bool) -> Void)
}

/// A part of the mode that was not done, for the section and the menu to say so: because this Mac cannot (no helper, an
/// old one, one refresh rate, no keyboard light), or because the system or the record refused it.
enum UltraSkipped: Equatable {
    case lowPowerNoHelper, lowPowerOldHelper, oneRefreshRate, keyboardLight
    /// The helper answered that it could not switch Low Power Mode on.
    case lowPowerRefused
    /// The display would not take the lower refresh rate.
    case rateRefused
    /// The brightness could not be read or set, so the ceiling is not held.
    case ceilingRefused
    /// This Mac has no efficiency cores, so what still runs was left on the cores it has.
    case noEfficiencyCores
}

final class UltraLowPowerController {

    enum State: Equatable { case off, confirming, on }

    /// How often the sweep looks for new parts of frozen groups.
    static let sweepSeconds: TimeInterval = 30
    /// After each freeze step, the load is read again this long after it.
    static let guardDelays: [TimeInterval] = [5, 15]
    /// Posted (main thread) whenever what the menu and the section show changes.
    static let didChange = Notification.Name("AnodeUltraLowPowerDidChange")
    /// Set by the app so Beta Features and the menus can reach the live controller.
    static var current: UltraLowPowerController?
    /// The name this feature is noted under in `OwnBrightness`.
    static let ownerName = "ultra"

    private let settings: Settings
    private let processes: ProcessListing
    private let freezer: ProcessFreezing
    private let throttler: ProcessThrottling
    private let hasEfficiencyCores: Bool
    private let hider: AppHiding
    private let backlight: BacklightControl
    private let ownBrightness: OwnBrightness
    private let rate: DisplayRateControlling
    private let keyboard: KeyboardBacklightControlling
    private let power: PowerModeControlling
    private let watchdog: UltraWatchdogging
    private let store: UltraRecordStoring
    private let confirm: UltraConfirming
    private let backdrop: BackdropPresenting
    private let load: LoadReading
    private let lastOtherFrontApp: () -> pid_t?
    private let ownPIDs: () -> Set<pid_t>
    private let user: uid_t
    private let work: (@escaping () -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void

    private(set) var state: State = .off
    /// Still frozen: a group the owner or the guard released is not here, nor one whose stop failed.
    private(set) var frozen: [FreezeGroup] = []
    private(set) var skipped: [UltraSkipped] = []
    /// From the plan: has a part Anode cannot stop, so it keeps running whole.
    private(set) var leftRunning: [FreezeGroup] = []
    /// Group ids the spin guard continued this session; they are never frozen again in it.
    private(set) var releasedForLoad: [String] = []
    /// Told (main thread) when any of the above changes.
    var onChange: (() -> Void)?

    /// Counts asks and sessions. Everything that waits captures it and does nothing when it has moved on. A job on the
    /// work queue reads it too (one that has not started when its session ends must not run), so it is behind a lock.
    private final class SessionCounter {
        private let lock = NSLock()
        private var number = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return number
        }
        /// The next session, in one step: a get and then a set could be interleaved with another change.
        @discardableResult
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            number += 1
            return number
        }
    }
    private let counter = SessionCounter()
    private var session: Int { counter.value }
    /// What the owner is being asked about: the plan, and the list it was made from.
    private var asked: (plan: FreezePlan, processes: [UltraProcess])?
    /// This session's record as it is now; nil until the first save and after the end.
    private var live: UltraRecord?
    /// Every process this session tried to stop, with its start time: the sweep must not try the same one again.
    private var attempted: [pid_t: UInt64] = [:]
    /// Decided once, at Confirm: the setting is on and this Mac has efficiency cores. The sweep and a release follow it, so a
    /// setting changed under a running session changes nothing in it.
    private var throttling = false
    /// The ids of the groups the plan kept. They keep running, so they are kept on the efficiency cores, new parts included.
    private var keptIDs: Set<String> = []
    /// Every process the mode has decided about for the efficiency cores, with its start time: put under the policy, or left at
    /// full speed on purpose (its app is on a call). The sweep must not decide about the same one again, or a process left alone
    /// during one call would be slowed after it and stay slow through the next. A pid that was reused is a new process.
    private var throttleDecided: [pid_t: UInt64] = [:]
    /// The app with windows of each group that was asked to hide, by group id, so that bringing it forward finds its
    /// group whether or not Anode hid it and whether or not its own stop worked. Not what is unhidden at the end: that
    /// is `appPID` on the record, set only for an app Anode hid.
    private var appOfGroup: [String: pid_t] = [:]
    /// The mode is being put back; the state stays `.on` until it is done.
    private var ending = false
    private var sweeping = false
    private var adjustingBrightness = false
    private var brightnessTaken = false
    private var brightnessToPutBack: Float?

    init(settings: Settings, processes: ProcessListing, freezer: ProcessFreezing, throttler: ProcessThrottling,
         hasEfficiencyCores: Bool, hider: AppHiding, backlight: BacklightControl,
         ownBrightness: OwnBrightness, rate: DisplayRateControlling, keyboard: KeyboardBacklightControlling,
         power: PowerModeControlling, watchdog: UltraWatchdogging, store: UltraRecordStoring, confirm: UltraConfirming,
         backdrop: BackdropPresenting, load: LoadReading, lastOtherFrontApp: @escaping () -> pid_t?, ownPIDs: @escaping () -> Set<pid_t>, user: uid_t,
         work: @escaping (@escaping () -> Void) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void, log: @escaping (String) -> Void) {
        self.settings = settings
        self.processes = processes
        self.freezer = freezer
        self.throttler = throttler
        self.hasEfficiencyCores = hasEfficiencyCores
        self.hider = hider
        self.backlight = backlight
        self.ownBrightness = ownBrightness
        self.rate = rate
        self.keyboard = keyboard
        self.power = power
        self.watchdog = watchdog
        self.store = store
        self.confirm = confirm
        self.backdrop = backdrop
        self.load = load
        self.lastOtherFrontApp = lastOtherFrontApp
        self.ownPIDs = ownPIDs
        self.user = user
        self.work = work
        self.schedule = schedule
        self.log = log
    }

    func isFrozen(pid: pid_t) -> Bool { frozen.contains { $0.members.contains { $0.pid == pid } } }

    // ── Asking ──────────────────────────────────────────────────────────────

    func request() {
        guard state == .off, !ending else { return }
        let token = counter.increment()
        state = .confirming
        // The app in front is the one in front NOW: asking may bring Anode forward, and the box names what was picked.
        let front = lastOtherFrontApp()
        changed()
        // The reader compares with its last reading and has none the first time, so it answers nil. This read is only here
        // so that the one at Confirm has something to compare with.
        load.read { _ in }
        processes.snapshot { [weak self] list in
            guard let self, self.session == token else { return }
            guard let list else {
                self.log("ultra: the process list could not be read, so nothing was started")
                self.reset()
                return
            }
            let plan = FreezePlanner.plan(processes: list, user: self.user, front: front,
                                          alwaysKeep: Set(self.settings.ultraLowPowerAlwaysKeep), ownPIDs: self.anodes())
            self.asked = (plan, list)
            self.confirm.ask(kept: plan.kept.map(\.name), frozen: plan.frozen.map(\.name)) { [weak self] yes in
                self?.answered(yes, token: token)
            }
        }
    }

    private func answered(_ yes: Bool, token: Int) {
        guard session == token, state == .confirming, let asked else { return }
        self.asked = nil
        guard yes else { reset(); return }
        begin(asked.plan, asked.processes, token: token)
    }

    // ── Starting ────────────────────────────────────────────────────────────

    /// The owner pressed Confirm, on the plan they were shown. In this order: the load, the record, the watchdog, each
    /// group hidden and stopped, what keeps running put on the efficiency cores, the screen, the refresh rate, the keyboard
    /// light, Low Power Mode, then `.on`.
    private func begin(_ plan: FreezePlan, _ list: [UltraProcess], token: Int) {
        leftRunning = plan.leftRunning
        load.read { [weak self] before in
            guard let self, self.session == token else { return }
            var record = UltraRecord()
            record.groups = plan.frozen.map(Self.recordGroup)
            guard self.store.save(record) else {
                self.log("ultra: the record could not be saved, so nothing was started")
                self.reset()
                return
            }
            self.live = record
            guard self.watchdog.start() else {
                self.log("ultra: the watchdog did not start, so nothing was started")
                self.store.clear()
                self.reset()
                return
            }
            self.freeze(plan.frozen[...], in: list, token: token) { [weak self] in
                self?.keepOnEfficiencyCores(plan, list, token: token)
                self?.lowerScreenAndPower(token: token) { [weak self] in
                    self?.becomeOn(before: before, token: token)
                }
            }
        }
    }

    private func becomeOn(before: LoadSample?, token: Int) {
        guard session == token else { return }
        state = .on
        // Only now, with the mode on: a start that did not finish never darkens the desktop. Nothing is recorded, as the window
        // is Anode's own and goes with it; `reset` takes it away on every path that ends the session.
        if settings.ultraLowPowerBlackBackdrop { backdrop.show() }
        changed()
        scheduleSweep(token: token)
        guardStep(before: before, groups: Set(frozen.map(\.id)), token: token)
    }

    /// One group after another: the app is hidden first when it has windows, and stopped once it says it is hidden (or has
    /// had its time). The completion may come at once or a second later, and does nothing when the mode has ended by then.
    ///
    /// The app is put on the record just before it is hidden, and taken off again if Anode did not hide it (the owner had
    /// hidden it already, or it would not hide): only what Anode hid is ever unhidden.
    private func freeze(_ groups: ArraySlice<FreezeGroup>, in list: [UltraProcess], token: Int, then done: @escaping () -> Void) {
        guard let group = groups.first else { return done() }
        let rest = groups.dropFirst()
        var proceeded = false
        let proceed = { [weak self] (hidByUs: Bool?) in
            guard let self, !proceeded, self.session == token else { return }
            proceeded = true
            if hidByUs == false { self.nameHiddenApp(nil, of: group.id) }
            let stopped = self.stop(group.members, of: group)
            if !stopped.isEmpty { self.frozen.append(FreezeGroup(id: group.id, name: group.name, members: stopped)) }
            self.freeze(rest, in: list, token: token, then: done)
        }
        guard let app = Self.appToHide(in: group, among: list) else { return proceed(nil) }
        appOfGroup[group.id] = app
        guard nameHiddenApp(app, of: group.id, mustSave: true) else {
            log("ultra: the record could not take the hidden app, so it was not hidden")
            return proceed(nil)
        }
        hider.hide(pid: app) { hidByUs in proceed(hidByUs) }
    }

    @discardableResult
    private func nameHiddenApp(_ app: pid_t?, of groupID: String, mustSave: Bool = false) -> Bool {
        record(mustSave: mustSave) { record in
            guard let i = record.groups.firstIndex(where: { $0.id == groupID }) else { return }
            record.groups[i].appPID = app
        }
    }

    /// The one place a process is stopped, for the start and for the sweep: members of a group the record already names.
    /// It notes that each was tried, says which refused, takes a refused member off the record, and drops a group left
    /// with nothing stopped, unhiding its app (nothing stopped behind that hide, so nothing else would ever unhide it).
    /// Returns the members that stopped.
    private func stop(_ members: [FreezeGroup.Member], of group: FreezeGroup) -> [FreezeGroup.Member] {
        var stopped: [FreezeGroup.Member] = []
        for member in members {
            attempted[member.pid] = member.startTime
            if freezer.stop(pid: member.pid, startTime: member.startTime) {
                stopped.append(member)
            } else {
                log("ultra: could not stop \(group.name) (\(member.pid))")
            }
        }
        let refused = Set(members.map(\.pid)).subtracting(stopped.map(\.pid))
        guard !refused.isEmpty else { return stopped }
        var appLeftBehind: pid_t?
        record { record in
            guard let i = record.groups.firstIndex(where: { $0.id == group.id }) else { return }
            record.groups[i].members.removeAll { refused.contains($0.pid) }
            if record.groups[i].members.isEmpty {
                appLeftBehind = record.groups[i].appPID
                record.groups.remove(at: i)
            }
        }
        if let appLeftBehind { hider.unhide(pid: appLeftBehind) }
        return stopped
    }

    // ── The efficiency cores ────────────────────────────────────────────────

    /// What keeps running (the kept apps, and the apps left running whole because they have a part Anode cannot stop) is put
    /// under the system's background policy, which on Apple silicon keeps all of a process's threads on the efficiency cores.
    /// Nothing that can block is called: it is a call on a pid, as a signal is.
    ///
    /// The choice is made here, once: whether the owner asked for it, and whether this Mac has such cores to keep it on.
    private func keepOnEfficiencyCores(_ plan: FreezePlan, _ list: [UltraProcess], token: Int) {
        guard session == token, settings.ultraLowPowerEfficiencyCores else { return }
        guard hasEfficiencyCores else {
            skipped.append(.noEfficiencyCores)
            return
        }
        throttling = true
        keptIDs = Set(plan.kept.map(\.id))
        // Everything these groups hold now is decided about, put under the policy or left alone on purpose; only what comes
        // after it is new to the sweep.
        for group in plan.kept + plan.leftRunning {
            for member in group.members { throttleDecided[member.pid] = member.startTime }
        }
        throttle(UltraThrottle.members(kept: plan.kept, leftRunning: plan.leftRunning, processes: list))
    }

    /// The one place a process is put under the policy, for the start, an app brought back and the sweep. The record names the
    /// processes first, and when it cannot be written none of them is touched: a process slowed with no record is slowed for
    /// good if Anode dies. One the system refuses is taken off the record again, so that only what was done is lifted.
    private func throttle(_ members: [FreezeGroup.Member]) {
        guard !members.isEmpty else { return }
        let named = record(mustSave: true) { $0.throttled = ($0.throttled ?? []) + members.map(Self.recordMember) }
        guard named else {
            log("ultra: the record could not take the processes to keep on the efficiency cores, so they were left as they are")
            return
        }
        var refused: [UltraRecord.Member] = []
        for member in members {
            throttleDecided[member.pid] = member.startTime
            if !throttler.throttle(pid: member.pid, startTime: member.startTime) {
                log("ultra: could not keep \(member.pid) on the efficiency cores")
                refused.append(Self.recordMember(member))
            }
        }
        guard !refused.isEmpty else { return }
        record { $0.throttled?.removeAll { refused.contains($0) } }
    }

    /// New parts of the groups that keep running (a helper the kept app started, a tool its terminal ran) and of an app the owner
    /// brought back are put under the policy too: a process started by one that is under it follows it, but not every part does.
    /// A group on a call is left at full speed (and what is new in it now is not slowed later either).
    private func keepNewcomersOnEfficiencyCores(in list: [UltraProcess]) {
        guard throttling else { return }
        var wanted = keptIDs.union(leftRunning.map(\.id))
        wanted.formUnion(live?.groups.filter(\.released).map(\.id) ?? [])
        guard !wanted.isEmpty else { return }
        let groupOf = FreezePlanner.groupIDs(processes: list, user: user, ownPIDs: anodes())
        var held: [String: [FreezeGroup.Member]] = [:]
        for process in list {
            guard let id = groupOf[process.pid], wanted.contains(id) else { continue }
            held[id, default: []].append(FreezeGroup.Member(pid: process.pid, startTime: process.startTime))
        }
        // Whole groups, so that the rule about a call is read over every part of one and not only over its new parts.
        let groups = held.map { FreezeGroup(id: $0.key, name: $0.key, members: $0.value) }
        let decided = throttleDecided
        let isNew: (FreezeGroup.Member) -> Bool = { decided[$0.pid] != $0.startTime }
        let eligible = UltraThrottle.members(kept: groups, leftRunning: [], processes: list).filter(isNew)
        for group in groups {
            for member in group.members where isNew(member) && !eligible.contains(member) {
                throttleDecided[member.pid] = member.startTime
            }
        }
        throttle(eligible)
    }

    // ── The screen, the keyboard light, the power mode ──────────────────────

    /// Each part is tried in turn and each can be skipped: a part this Mac cannot do goes in `skipped`, and the rest goes
    /// on. What can block (the display, the keyboard light, the backlight) runs on `work`.
    private func lowerScreenAndPower(token: Int, then done: @escaping () -> Void) {
        run([{ [unowned self] next in lowerBrightness(token, next) },
             { [unowned self] next in lowerRate(token, next) },
             { [unowned self] next in switchKeyboardOff(token, next) },
             { [unowned self] next in enterLowPower(token, next) }], then: done)
    }

    private func run(_ steps: ArraySlice<(@escaping () -> Void) -> Void>, then done: @escaping () -> Void) {
        guard let step = steps.first else { return done() }
        step { [weak self] in self?.run(steps.dropFirst(), then: done) }
    }

    private func run(_ steps: [(@escaping () -> Void) -> Void], then done: @escaping () -> Void) {
        run(steps[...], then: done)
    }

    /// `job` runs on the work queue and may block; `done` runs on the main thread, and only when the session is still
    /// the one that asked. A job that has not started when its session ends does not run at all: it would lower
    /// something after the mode was put back. (One already inside a system call cannot be stopped; what it did was
    /// named on the record first, and the restore queued behind it puts that back.)
    private func background<T>(_ token: Int, _ job: @escaping () -> T, then done: @escaping (T) -> Void) {
        work { [weak self] in
            guard let self, self.session == token else { return }
            let result = job()
            self.onMain { [weak self] in
                guard let self, self.session == token else { return }
                done(result)
            }
        }
    }

    private func lowerBrightness(_ token: Int, _ next: @escaping () -> Void) {
        background(token, { [backlight = self.backlight] in backlight.brightness() }) { [weak self] current in
            guard let self else { return }
            guard let current else {
                self.log("ultra: the brightness could not be read, so it was left as it is")
                self.skipped.append(.ceilingRefused)
                return next()
            }
            // At or below the ceiling already: nothing to lower, nothing to put back.
            guard let target = BrightnessCeiling.clamp(current) else { return next() }
            // Noted and written before it is lowered, so a crash in between finds both.
            self.ownBrightness.remember(current, for: Self.ownerName)
            guard self.record(mustSave: true, { $0.brightnessBefore = current }) else {
                self.log("ultra: the record could not take the brightness, so it was left as it is")
                _ = self.ownBrightness.forget(Self.ownerName)
                self.skipped.append(.ceilingRefused)
                return next()
            }
            self.background(token, { [backlight = self.backlight] in backlight.setBrightness(target) }) { [weak self] accepted in
                guard let self else { return }
                if !accepted {
                    self.log("ultra: the screen did not take the lower brightness")
                    _ = self.ownBrightness.forget(Self.ownerName)
                    self.skipped.append(.ceilingRefused)
                    self.record { $0.brightnessBefore = nil }
                }
                next()
            }
        }
    }

    private enum RateOutcome { case notOffered, lowered, refused }

    private func lowerRate(_ token: Int, _ next: @escaping () -> Void) {
        // Named before it is asked for, like the rest: a turning off that overtakes the call on the queue still puts it back.
        guard record(mustSave: true, { $0.rateLowered = true }) else {
            log("ultra: the record could not take the refresh rate, so it was left as it is")
            skipped.append(.rateRefused)
            return next()
        }
        background(token, { [rate = self.rate] () -> RateOutcome in
            guard rate.canLower else { return .notOffered }
            return rate.lower() ? .lowered : .refused
        }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .lowered:
                break
            case .notOffered:
                self.skipped.append(.oneRefreshRate)
                self.record { $0.rateLowered = false }
            // Asked for and refused: the system puts the rate back by itself, and nothing was changed.
            case .refused:
                self.log("ultra: the display did not take the lower refresh rate")
                self.skipped.append(.rateRefused)
                self.record { $0.rateLowered = false }
            }
            next()
        }
    }

    private func switchKeyboardOff(_ token: Int, _ next: @escaping () -> Void) {
        background(token, { [keyboard = self.keyboard] in keyboard.level() }) { [weak self] level in
            guard let self else { return }
            guard let level else { self.skipped.append(.keyboardLight); return next() }
            // Off already: nothing to switch off, and a 0 put back at the end could undo a light the owner switched on since.
            guard level > 0 else { return next() }
            guard self.record(mustSave: true, { $0.keyboardBefore = level }) else {
                self.log("ultra: the record could not take the keyboard light, so it was left as it is")
                self.skipped.append(.keyboardLight)
                return next()
            }
            self.background(token, { [keyboard = self.keyboard] in keyboard.set(0) }) { [weak self] accepted in
                guard let self else { return }
                if !accepted {
                    self.skipped.append(.keyboardLight)
                    self.record { $0.keyboardBefore = nil }
                }
                next()
            }
        }
    }

    private func enterLowPower(_ token: Int, _ next: @escaping () -> Void) {
        switch power.availability {
        case .noHelper:
            skipped.append(.lowPowerNoHelper)
            next()
        case .oldHelper:
            skipped.append(.lowPowerOldHelper)
            next()
        case .ready:
            power.enterLowPower { [weak self] modeBefore in
                self?.onMain { [weak self] in
                    guard let self else { return }
                    guard self.session == token else {
                        // The mode ended while the helper was answering. It did switch Low Power Mode on, and nothing
                        // else knows to switch it off.
                        if let modeBefore { self.restorePower(modeBefore) }
                        return
                    }
                    if let modeBefore {
                        self.record { $0.powerModeBefore = modeBefore }
                    } else {
                        self.log("ultra: the helper could not switch the power mode")
                        // A helper that had not been heard from reads ready until it is asked, and the answer to the ask
                        // is what shows it is an older one (or not there): so what it is now is read again, and a no from
                        // one that is still ready is a refusal.
                        switch self.power.availability {
                        case .oldHelper: self.skipped.append(.lowPowerOldHelper)
                        case .noHelper:  self.skipped.append(.lowPowerNoHelper)
                        case .ready:     self.skipped.append(.lowPowerRefused)
                        }
                    }
                    next()
                }
            }
        }
    }

    /// Fire and forget: the answer only goes to the log, and nothing waits for a helper that may not answer.
    private func restorePower(_ mode: Int) {
        power.restore(mode) { [weak self] ok in
            if !ok { self?.onMain { self?.log("ultra: the earlier power mode could not be put back") } }
        }
    }

    // ── Turning off ─────────────────────────────────────────────────────────

    /// Ends the mode, or the start of it, or the question: whatever there is. Every process is continued at once; the
    /// screen and the rest are put back on the work queue, and the state stays as it is until that is done.
    func turnOff() {
        guard state != .off, !ending else { return }
        end(inline: false)
    }

    /// Quit and logout cannot wait for a queue: the same, on this thread, and done when it returns. Call it on the main
    /// thread, like everything that changes the state: it does not go through `work`, but it does change what the main
    /// thread owns.
    func shutdown() {
        guard state != .off else { return }
        // The window is Anode's own and goes first: whatever the put-back does, a quit leaves nothing of the mode on screen.
        backdrop.hide()
        end(inline: true)
    }

    /// Undoes a record a session left behind (a crash, a kill, a power cut): what it names, and nothing else. The
    /// record is all there is to go on, so the brightness comes from it and not from `OwnBrightness`, which a new
    /// process has noted nothing in.
    func recoverAtLaunch() {
        guard state == .off, !ending, let record = store.load() else { return }
        log("ultra: undoing a session that was not ended")
        ending = true
        putBack(record, brightnessBefore: record.brightnessBefore, inline: false, token: counter.increment()) { [weak self] in
            self?.store.clear()
            self?.ending = false
        }
    }

    private func end(inline: Bool) {
        let token = counter.increment()
        asked = nil
        // No record yet: nothing was done, so there is nothing to undo, only the question or the start to drop.
        guard let record = live else { reset(); return }
        ending = true
        frozen = []
        putBack(record, brightnessBefore: brightnessToRestore(), inline: inline, token: token) { [weak self] in
            self?.watchdog.stop()
            self?.store.clear()
            self?.ending = false
            self?.reset()
        }
    }

    /// What `forget` gives back, once: it is the owner's brightness only when no other feature still holds the screen
    /// down, and nil then and when this feature never lowered it. Asked once, so a quit that overtakes a turning off
    /// does not find it gone.
    private func brightnessToRestore() -> Float? {
        if !brightnessTaken {
            brightnessTaken = true
            brightnessToPutBack = ownBrightness.forget(Self.ownerName)
        }
        return brightnessToPutBack
    }

    /// Continues everything the record names, then unhides, and only then touches the settings (the screen, the
    /// refresh rate, the keyboard light, the power mode), which can block and must not hold up a continue.
    /// `inline` runs them here; otherwise on `work`, and `finished` comes on the main thread if the session still stands.
    private func putBack(_ record: UltraRecord, brightnessBefore: Float?, inline: Bool, token: Int,
                         finished: @escaping () -> Void) {
        var record = record
        record.brightnessBefore = brightnessBefore
        let actions = UltraRecovery.actions(for: record, brightnessNow: nil)
        let groupOf = Dictionary(record.groups.flatMap { group in group.members.map { ($0.pid, group.name) } },
                                 uniquingKeysWith: { first, _ in first })
        for case .resume(let pid, let startTime) in actions where !freezer.resume(pid: pid, startTime: startTime) {
            log("ultra: could not continue \(groupOf[pid] ?? "a process") (\(pid)): it has ended, or is not that process any more")
        }
        // Right after the continues, before anything that asks another app for something: what was slowed is lifted from
        // every process the record names, and from nothing else. Not tied to the setting or to this Mac's cores: a record is
        // undone whatever the owner has changed since. Said once for a pid, however often the record names it.
        var notLifted: Set<pid_t> = []
        for case .unthrottle(let pid, let startTime) in actions where !throttler.unthrottle(pid: pid, startTime: startTime) {
            if notLifted.insert(pid).inserted {
                log("ultra: could not lift the efficiency-core limit from \(groupOf[pid] ?? "a process") (\(pid)): it has ended, or is not that process any more")
            }
        }
        for case .unhide(let pid) in actions { hider.unhide(pid: pid) }

        // What each step could not do, to be logged where the log is safe to write.
        let settings = { [backlight = self.backlight, rate = self.rate, keyboard = self.keyboard] () -> [String] in
            var failed: [String] = []
            // The screen is put back only where the mode left it: that is decided against what it reads now.
            if record.brightnessBefore != nil {
                if let now = backlight.brightness() {
                    for case .brightness(let value) in UltraRecovery.actions(for: record, brightnessNow: now)
                    where !backlight.setBrightness(value) {
                        failed.append("ultra: the brightness could not be put back")
                    }
                } else {
                    failed.append("ultra: the brightness could not be read, so it was not put back")
                }
            }
            for action in actions {
                switch action {
                case .restoreRate:
                    rate.restore()
                case .keyboard(let level):
                    if !keyboard.set(level) { failed.append("ultra: the keyboard light could not be put back") }
                case .resume, .unthrottle, .unhide, .brightness, .powerMode:
                    break
                }
            }
            return failed
        }
        let afterSettings = { [weak self] in
            for case .powerMode(let mode) in actions { self?.restorePower(mode) }
            finished()
        }
        if inline {
            settings().forEach(log)
            afterSettings()
        } else {
            work { [weak self] in
                // Overtaken by a quit that has put everything back already: it does not do it a second time.
                guard let self, self.session == token else { return }
                let failed = settings()
                self.onMain { [weak self] in
                    guard let self else { return }
                    failed.forEach(self.log)
                    guard self.session == token else { return }
                    afterSettings()
                }
            }
        }
    }

    // ── One group back ──────────────────────────────────────────────────────

    /// The owner took this group back (the menu): it is continued and stays running for the rest of the session.
    func release(groupID: String) { releaseGroup(groupID, forLoad: false) }

    /// An app was brought forward (its Dock icon, the app switcher): if it is in a frozen group, that group is released.
    func appActivated(pid: pid_t) {
        guard state == .on, !ending else { return }
        let group = frozen.first { group in
            group.members.contains { $0.pid == pid } || appOfGroup[group.id] == pid
        }
        if let group { releaseGroup(group.id, forLoad: false) }
    }

    /// Continues first, then says so on the record: a crash in between has the record naming a group that is running,
    /// which recovery only continues again.
    private func releaseGroup(_ id: String, forLoad: Bool) {
        guard state == .on, !ending, let index = frozen.firstIndex(where: { $0.id == id }) else { return }
        let group = frozen.remove(at: index)
        var notContinued: [pid_t] = []
        for member in group.members where !freezer.resume(pid: member.pid, startTime: member.startTime) {
            notContinued.append(member.pid)
        }
        // They are gone, or no longer that process: nothing is left to keep stopped, so the group is released all the same.
        if !notContinued.isEmpty {
            log("ultra: \(group.name) is released, but \(notContinued.map(String.init).joined(separator: ", ")) could not be continued (ended, or not that process any more)")
        }
        if let app = live?.groups.first(where: { $0.id == id })?.appPID { hider.unhide(pid: app) }
        record { record in
            guard let i = record.groups.firstIndex(where: { $0.id == id }) else { return }
            record.groups[i].released = true
        }
        if forLoad { releasedForLoad.append(id) }
        // It runs again for the rest of the session, so it is kept on the efficiency cores with the rest of what runs (an app the
        // guard let go included). Only what was continued: a process that is gone, or not that process any more, is not.
        if throttling { throttle(group.members.filter { !notContinued.contains($0.pid) }) }
        changed()
    }

    // ── What starts later ───────────────────────────────────────────────────

    private func scheduleSweep(token: Int) {
        schedule(Self.sweepSeconds) { [weak self] in
            guard let self, self.session == token, self.state == .on, !self.ending else { return }
            self.sweep()
            self.scheduleSweep(token: token)
        }
    }

    /// New parts of groups that are frozen (a respawned updater, a new helper) are stopped too, without hiding anything.
    /// New parts of what keeps running are put on the efficiency cores. Anything else that is new is left alone.
    func sweep() {
        guard state == .on, !ending, !sweeping else { return }
        sweeping = true
        let token = session
        let finish = { [weak self] in
            guard let self, self.session == token else { return }
            self.sweeping = false
        }
        processes.snapshot { [weak self] list in
            guard let self, self.session == token else { return }
            guard let list else {
                self.log("ultra: the process list could not be read, so the sweep did nothing")
                return finish()
            }
            // What keeps running is looked at first and on its own: nothing is stopped for it, so no reading of the load.
            self.keepNewcomersOnEfficiencyCores(in: list)
            // A pid is known only while it is still the process that was tried: a pid that was reused is a new process.
            let startTimes = Dictionary(list.map { ($0.pid, $0.startTime) }, uniquingKeysWith: { first, _ in first })
            let known = Set(self.attempted.filter { startTimes[$0.key] == $0.value }.keys)
            let additions = FreezePlanner.additions(processes: list, user: self.user, frozenGroups: Set(self.frozen.map(\.id)),
                                                    known: known, ownPIDs: self.anodes())
            guard !additions.isEmpty else { return finish() }
            // This step's own reading from before it, as the start has one.
            self.load.read { [weak self] before in
                guard let self, self.session == token else { return }
                self.freezeNewcomers(additions, before: before, token: token)
                finish()
            }
        }
    }

    private func freezeNewcomers(_ additions: [FreezeGroup], before: LoadSample?, token: Int) {
        // The owner may have released a group while the load was being read.
        let groups = additions.filter { add in frozen.contains { $0.id == add.id } }
        guard !groups.isEmpty else { return }
        // Named on the record before anything is stopped, as at the start.
        let named = record(mustSave: true) { record in
            for add in groups {
                guard let i = record.groups.firstIndex(where: { $0.id == add.id && !$0.released }) else { continue }
                record.groups[i].members += add.members.map(Self.recordMember)
            }
        }
        guard named else {
            log("ultra: the record could not take the new processes, so they were not stopped")
            return
        }
        var froze: Set<String> = []
        for add in groups {
            let stopped = stop(add.members, of: add)
            if !stopped.isEmpty, let i = frozen.firstIndex(where: { $0.id == add.id }) {
                frozen[i].members += stopped
                froze.insert(add.id)
            }
        }
        changed()
        guardStep(before: before, groups: froze, token: token)
    }

    // ── The screen is held ──────────────────────────────────────────────────

    /// Something may have raised the brightness (the keys, auto-brightness, another feature putting its own back): if it
    /// is above the ceiling it is pulled back. One check at a time, so a display that is slow to answer is not asked again
    /// and again.
    func brightnessMayHaveChanged() {
        guard state == .on, !ending, !adjustingBrightness else { return }
        adjustingBrightness = true
        let token = session
        work { [backlight = self.backlight, weak self] in
            var refused = false
            // Not run at all when the mode has ended while this waited its turn.
            if self?.session == token, let now = backlight.brightness(), let ceiling = BrightnessCeiling.clamp(now) {
                refused = !backlight.setBrightness(ceiling)
            }
            self?.onMain {
                if refused { self?.log("ultra: the screen did not take the lower brightness") }
                self?.adjustingBrightness = false
            }
        }
    }

    // ── The guard ───────────────────────────────────────────────────────────

    /// One freeze step as the guard sees it: the reading from before it, what it froze, and how many of its readings
    /// found a rise nothing explains.
    private final class GuardStep {
        let before: LoadSample?
        let groupIDs: Set<String>
        var unexplained = 0
        init(before: LoadSample?, groupIDs: Set<String>) {
            self.before = before
            self.groupIDs = groupIDs
        }
    }

    /// After a freeze step the load is read again at each of `guardDelays`, and compared with the reading from before it.
    private func guardStep(before: LoadSample?, groups ids: Set<String>, token: Int) {
        guard !ids.isEmpty else { return }
        let step = GuardStep(before: before, groupIDs: ids)
        for delay in Self.guardDelays {
            schedule(delay) { [weak self] in self?.check(step, token: token) }
        }
    }

    private func check(_ step: GuardStep, token: Int) {
        guard session == token, state == .on, !ending else { return }
        guard let before = step.before else {
            log("ultra: no reading of the load from before the freeze, so the guard cannot judge this step")
            return
        }
        load.read { [weak self] after in
            guard let self, self.session == token else { return }
            guard let after else {
                self.log("ultra: the load could not be read, so nothing was changed")
                return
            }
            self.processes.snapshot { [weak self] list in
                guard let self, self.session == token else { return }
                guard let list else {
                    self.log("ultra: the process list could not be read, so nothing was changed")
                    return
                }
                self.judge(step, before: before, after: after, list: list)
            }
        }
    }

    /// `kept` is every process of the owner's that is not in a group still frozen, and Anode's own, the watchdog among
    /// them. So what can be blamed is what a freeze left running in a frozen group (an extension, a newcomer), and a
    /// released group, a group left running and the owner's own apps can not: their work is not the freeze's doing.
    private func judge(_ step: GuardStep, before: LoadSample, after: LoadSample, list: [UltraProcess]) {
        let anodes = self.anodes()
        let groupOf = FreezePlanner.groupIDs(processes: list, user: user, ownPIDs: anodes)
        let frozenIDs = Set(frozen.map(\.id))
        var kept = anodes
        for process in list where process.uid == user && !(groupOf[process.pid].map(frozenIDs.contains) ?? false) {
            kept.insert(process.pid)
        }
        let verdict = SpinGuard.verdict(ownBefore: before.byProcess, ownAfter: after.byProcess,
                                        busyCoresBefore: before.busyCores, busyCoresAfter: after.busyCores,
                                        kept: kept, frozen: frozen, processes: list)
        switch verdict {
        case .fine:
            break
        case .release(let ids):
            log("ultra: continuing \(names(of: ids)): something it needs was stopped and began to burn")
            for id in ids { releaseGroup(id, forLoad: true) }
        case .releaseAll:
            // The system's own work, apps left running and what the owner starts all make the Mac busier now and then,
            // so one reading that nothing explains is not enough to undo the step: the next one has to agree.
            step.unexplained += 1
            guard step.unexplained == Self.guardDelays.count else {
                log("ultra: the Mac is busier and nothing explains it; waiting for the next reading")
                return
            }
            let ids = frozen.map(\.id).filter(step.groupIDs.contains)
            log("ultra: continuing \(names(of: ids)): the Mac got busier after they were stopped and nothing explains it")
            for id in ids { releaseGroup(id, forLoad: true) }
        }
    }

    private func names(of ids: [String]) -> String {
        ids.map { id in frozen.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
    }

    // ── The record ──────────────────────────────────────────────────────────

    /// Changes this session's record and writes it. A write that fails is logged. With `mustSave` the change is not kept
    /// either, and false comes back: for what must not be done unless the record names it.
    @discardableResult
    private func record(mustSave: Bool = false, _ change: (inout UltraRecord) -> Void) -> Bool {
        guard var record = live else { return false }
        change(&record)
        guard store.save(record) else {
            log("ultra: the record could not be saved")
            if !mustSave { live = record }
            return false
        }
        live = record
        return true
    }

    private static func recordMember(_ member: FreezeGroup.Member) -> UltraRecord.Member {
        UltraRecord.Member(pid: member.pid, startTime: member.startTime)
    }

    private static func recordGroup(_ group: FreezeGroup) -> UltraRecord.Group {
        UltraRecord.Group(id: group.id, name: group.name, members: group.members.map(recordMember))
    }

    /// The app with windows to hide before its group is stopped: the group's own regular app, by its bundle id.
    private static func appToHide(in group: FreezeGroup, among list: [UltraProcess]) -> pid_t? {
        let members = Set(group.members.map(\.pid))
        return list.filter { $0.app == .regular && $0.bundleID == group.id && members.contains($0.pid) }.map(\.pid).min()
    }

    // ── Small things ────────────────────────────────────────────────────────

    /// Anode's own processes: what the app says they are, and the watchdog. None of them is ever frozen or blamed.
    private func anodes() -> Set<pid_t> {
        var pids = ownPIDs()
        if let watchdog = watchdog.pid { pids.insert(watchdog) }
        return pids
    }

    /// The end of a session that came to nothing, or was ended: everything this controller holds is dropped.
    private func reset() {
        counter.increment()
        state = .off
        backdrop.hide()
        frozen = []
        skipped = []
        leftRunning = []
        releasedForLoad = []
        asked = nil
        live = nil
        attempted = [:]
        throttling = false
        keptIDs = []
        throttleDecided = [:]
        appOfGroup = [:]
        sweeping = false
        adjustingBrightness = false
        brightnessTaken = false
        brightnessToPutBack = nil
        changed()
    }

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
