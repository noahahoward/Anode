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
//     running process, a brightness put back only when the screen is not above the ceiling and is below the earlier level);
//     it never finds the reverse. When a record cannot be written, what it would have named is not done;
//   · every piece of work that waits (a hidden app, the load, a call that can block, a helper) is tagged with the session
//     it belongs to and does nothing if that session is over. Ending bumps the number;
//   · ending takes the backdrop away and continues every process first, then lifts the background policy from every process the
//     record names, every living descendant of one (a child inherits the policy and is on no record) and every current member of
//     the kept, left-running and brought-back groups, then puts the settings back, and only then takes the watchdog and the record
//     away;
//   · the screen is put back LAST, after macOS's Low Power Mode is off: macOS lowers the screen a little more when the mode switches
//     it on and raises whatever level is there when it ends (measured), so a level set while it is still on is not the level that
//     stays. A turning off waits for it to go off (and for macOS to finish its own ramp) before it sets the screen; a quit cannot,
//     so it leaves the screen, in a record cut down to that, for the watchdog (and finishes it itself if the app is still here).

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
    /// Shows what is kept, what is frozen and what is left running whole (apps with a part Anode cannot freeze), by
    /// name, and calls back once on the main thread: true for Confirm.
    func ask(kept: [String], frozen: [String], leftRunning: [String], answer: @escaping (Bool) -> Void)
    /// The session ended while the box was up (the box unticked, a quit): the box goes away, and its question is answered No,
    /// once. Nothing happens when no box is up.
    func dismiss()
}

extension UltraConfirming {
    /// With nothing left running.
    func ask(kept: [String], frozen: [String], answer: @escaping (Bool) -> Void) {
        ask(kept: kept, frozen: frozen, leftRunning: [], answer: answer)
    }
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
    /// How long a quit waits for the screen, the refresh rate, the keyboard light and the power mode to be put back on the work
    /// queue. Past it the quit goes on without them: the watchdog and the next launch finish the job.
    static let shutdownWaitSeconds: TimeInterval = 2
    /// How long each part of the start that can block (the brightness, the refresh rate, the keyboard light) is given.
    static let displayStepSeconds: TimeInterval = 3
    /// How long the helper is given to switch Low Power Mode on: its own worst case is a little under five seconds.
    static let helperStepSeconds: TimeInterval = 5
    /// How often a turning off looks at whether macOS's Low Power Mode is off yet, before it puts the screen back.
    static let lowPowerPollSeconds: TimeInterval = 0.25
    /// The most a turning off waits for Low Power Mode to go off. Past it the screen is put back all the same.
    static let lowPowerWaitSeconds: TimeInterval = 6
    /// After Low Power Mode is off, how long macOS is given to finish raising the screen by itself (measured, 0.3 to 0.5 s)
    /// before the owner's level is set over it.
    static let brightnessSettleSeconds: TimeInterval = 1
    /// What the section says when the list of running apps could not be read.
    static let couldNotReadApps = "Anode could not read the running apps. Try again."
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
    private let processTable: () -> [UltraProcess]?
    private let startTime: (pid_t) -> UInt64?
    private let hasEfficiencyCores: Bool
    private let hider: AppHiding
    private let backlight: BacklightControl
    private let ownBrightness: OwnBrightness
    private let rate: DisplayRateControlling
    private let keyboard: KeyboardBacklightControlling
    private let power: PowerModeControlling
    private let lowPowerOn: () -> Bool
    private let watchdog: UltraWatchdogging
    private let store: UltraRecordStoring
    private let confirm: UltraConfirming
    private let backdrop: BackdropPresenting
    private let load: LoadReading
    private let lastOtherFrontApp: () -> pid_t?
    private let ownPIDs: () -> Set<pid_t>
    private let user: uid_t
    private let work: (@escaping () -> Void) -> Void
    private let waitForWork: (TimeInterval) -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let alert: () -> Void
    private let log: (String) -> Void

    private(set) var state: State = .off
    /// Still frozen: a group the owner or the guard released is not here, nor one whose stop failed.
    private(set) var frozen: [FreezeGroup] = []
    private(set) var skipped: [UltraSkipped] = []
    /// From the plan: has a part Anode cannot stop, so it keeps running whole.
    private(set) var leftRunning: [FreezeGroup] = []
    /// Group ids the spin guard continued this session; they are never frozen again in it.
    private(set) var releasedForLoad: [String] = []
    /// The owner has pressed Confirm and the mode is not on yet: the start is running, and can be cancelled.
    private(set) var isStarting = false
    /// Why the last ask came to nothing, for the section to say under the button; nil from the next ask.
    private(set) var lastFailure: String?
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
    /// Processes the sweep must not ask about again because the system refused them, each by its start time: a pid that was reused
    /// is a new process.
    private var throttleSkipped: [pid_t: UInt64] = [:]
    /// The latest full snapshot of the process list (the start's, then each sweep's): what the end of a session knows of the apps
    /// when it places the processes born since in their groups.
    private var known: [UltraProcess] = []
    /// The app with windows of each group that was asked to hide, by group id, so that bringing it forward finds its
    /// group whether or not Anode hid it and whether or not its own stop worked. Not what is unhidden at the end: that
    /// is `appPID` on the record, set only for an app Anode hid.
    private var appOfGroup: [String: pid_t] = [:]
    /// The mode is being put back; the state stays `.on` until it is done.
    private var ending = false
    private var sweeping = false
    private var adjustingBrightness = false
    /// How many groups the plan kept, for the line the log says when the mode comes on.
    private var keptCount = 0
    private var brightnessTaken = false
    private var brightnessToPutBack: Float?

    init(settings: Settings, processes: ProcessListing, freezer: ProcessFreezing, throttler: ProcessThrottling,
         processTable: @escaping () -> [UltraProcess]?, startTime: @escaping (pid_t) -> UInt64?, hasEfficiencyCores: Bool,
         hider: AppHiding, backlight: BacklightControl,
         ownBrightness: OwnBrightness, rate: DisplayRateControlling, keyboard: KeyboardBacklightControlling,
         power: PowerModeControlling, lowPowerOn: @escaping () -> Bool, watchdog: UltraWatchdogging, store: UltraRecordStoring,
         confirm: UltraConfirming,
         backdrop: BackdropPresenting, load: LoadReading, lastOtherFrontApp: @escaping () -> pid_t?, ownPIDs: @escaping () -> Set<pid_t>, user: uid_t,
         work: @escaping (@escaping () -> Void) -> Void, waitForWork: @escaping (TimeInterval) -> Bool,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void, alert: @escaping () -> Void,
         log: @escaping (String) -> Void) {
        self.settings = settings
        self.processes = processes
        self.freezer = freezer
        self.throttler = throttler
        self.processTable = processTable
        self.startTime = startTime
        self.hasEfficiencyCores = hasEfficiencyCores
        self.hider = hider
        self.backlight = backlight
        self.ownBrightness = ownBrightness
        self.rate = rate
        self.keyboard = keyboard
        self.power = power
        self.lowPowerOn = lowPowerOn
        self.watchdog = watchdog
        self.store = store
        self.confirm = confirm
        self.backdrop = backdrop
        self.load = load
        self.lastOtherFrontApp = lastOtherFrontApp
        self.ownPIDs = ownPIDs
        self.user = user
        self.work = work
        self.waitForWork = waitForWork
        self.schedule = schedule
        self.alert = alert
        self.log = log
    }

    func isFrozen(pid: pid_t) -> Bool { frozen.contains { $0.members.contains { $0.pid == pid } } }

    // ── Asking ──────────────────────────────────────────────────────────────

    func request() {
        guard state == .off, !ending else { return }
        lastFailure = nil
        let token = counter.increment()
        state = .confirming
        // The app in front is the one in front NOW: asking may bring Anode forward, and the box names what was picked.
        let front = lastOtherFrontApp()
        changed()
        // The reader compares with its last reading and has none the first time, so it answers nil. This read is only here
        // so that the one at Confirm has something to compare with.
        load.read { _ in }
        // The owner is waiting on this one: it is read at the priority of what they asked for.
        processes.snapshot(urgent: true) { [weak self] list in
            guard let self, self.session == token else { return }
            guard let list else {
                self.log("ultra: the process list could not be read, so nothing was started")
                // Said under the button until the next ask, and out loud once: the shortcut has no button to look at.
                self.lastFailure = Self.couldNotReadApps
                self.reset()
                self.alert()
                return
            }
            let plan = FreezePlanner.plan(processes: list, user: self.user, front: front,
                                          alwaysKeep: Set(self.settings.ultraLowPowerAlwaysKeep), ownPIDs: self.anodes())
            self.asked = (plan, list)
            self.confirm.ask(kept: plan.kept.map(\.name), frozen: plan.frozen.map(\.name),
                             leftRunning: plan.leftRunning.map(\.name)) { [weak self] yes in
                self?.answered(yes, token: token)
            }
        }
    }

    private func answered(_ yes: Bool, token: Int) {
        guard session == token, state == .confirming, let asked else { return }
        self.asked = nil
        guard yes else { reset(); return }
        // From now until the mode is on or off the start can be cancelled: the menus and the button say so.
        isStarting = true
        changed()
        begin(asked.plan, asked.processes, token: token)
    }

    // ── Starting ────────────────────────────────────────────────────────────

    /// The owner pressed Confirm, on the plan they were shown. In this order: the load, the record, the watchdog, each
    /// group hidden and stopped, what keeps running put on the efficiency cores, the screen, the refresh rate, the keyboard
    /// light, Low Power Mode, then `.on`.
    private func begin(_ plan: FreezePlan, _ list: [UltraProcess], token: Int) {
        leftRunning = plan.leftRunning
        keptCount = plan.kept.count
        known = list
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
        isStarting = false
        log("ultra: the mode is on; groups: \(keptCount) kept running, \(frozen.count) frozen, \(leftRunning.count) left running")
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
        // The plan can be minutes old (the box was up): a pid that has been reused since is another process, and is not hidden.
        guard startTime(app) == group.members.first(where: { $0.pid == app })?.startTime else {
            log("ultra: \(group.name) (\(app)) is not the process that was planned any more, so it was not hidden")
            return proceed(nil)
        }
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
    /// The choice is made here, once: whether the owner asked for it, and whether this Mac has such cores to keep it on. A group
    /// that is on a call is not put under it (see `UltraThrottle.members`); a later sweep does that once the call is over.
    private func keepOnEfficiencyCores(_ plan: FreezePlan, _ list: [UltraProcess], token: Int) {
        guard session == token, settings.ultraLowPowerEfficiencyCores else { return }
        guard hasEfficiencyCores else {
            skipped.append(.noEfficiencyCores)
            return
        }
        throttling = true
        keptIDs = Set(plan.kept.map(\.id))
        throttle(UltraThrottle.members(kept: plan.kept, leftRunning: plan.leftRunning, processes: list))
    }

    /// The one place a process is put under the policy, for the start, an app brought back and the sweep. The record names the
    /// processes first, and when it cannot be written none of them is touched: a process slowed with no record is slowed for
    /// good if Anode dies. One the system refuses is taken off the record again, so that only what was done is lifted.
    private func throttle(_ members: [FreezeGroup.Member]) {
        var none: [UltraRecord.Member] = []
        throttle(members, dropping: &none)
    }

    /// `stale` is what the record names that is gone: it goes in this same write, when the write is made, and is then no longer owed.
    private func throttle(_ members: [FreezeGroup.Member], dropping stale: inout [UltraRecord.Member]) {
        guard !members.isEmpty else { return }
        let gone = stale
        let named = record(mustSave: true) {
            $0.throttled = (($0.throttled ?? []).filter { !gone.contains($0) }) + members.map(Self.recordMember)
        }
        guard named else {
            log("ultra: the record could not take the processes to keep on the efficiency cores, so they were left as they are")
            return
        }
        stale = []
        var refused: [UltraRecord.Member] = []
        for member in members where !throttler.throttle(pid: member.pid, startTime: member.startTime) {
            log("ultra: could not keep \(member.pid) on the efficiency cores")
            throttleSkipped[member.pid] = member.startTime
            refused.append(Self.recordMember(member))
        }
        guard !refused.isEmpty else { return }
        record { $0.throttled?.removeAll { refused.contains($0) } }
    }

    /// The sweep's part for what keeps running: the kept groups, the groups left running and the groups the owner or the guard
    /// brought back, read from the fresh list. The groups are whole, so that the rule about a call is read over every part of one.
    ///
    ///  · A group that is not on a call: each part of it that is not under the policy yet (a new helper, a tool the editor ran, what
    ///    a call left behind) is put under it. A part the system refused is not asked again.
    ///  · A group that has started using the microphone or camera: the policy is lifted from its parts that are on the record, and
    ///    from what they started since the last sweep (which inherited it and is on no record, and may be the very part on the
    ///    call), and only then are the parts taken off the record. It is not put back under it while it is in use; a later sweep
    ///    does that when it stops.
    private func keepRunningOnEfficiencyCores(in list: [UltraProcess]) {
        guard throttling else { return }
        // What the record names that is gone now goes off it in the one write this makes (naming a new part, or lifting from a group
        // that is on a call), or in one of its own when it makes none.
        var stale = throttledNoLongerThere(in: list)
        var wanted = keptIDs.union(leftRunning.map(\.id))
        wanted.formUnion(live?.groups.filter(\.released).map(\.id) ?? [])
        guard !wanted.isEmpty else { return dropFromRecord(stale) }
        let own = anodes()
        let groupOf = FreezePlanner.groupIDs(processes: list, user: user, ownPIDs: own)
        var held: [String: [FreezeGroup.Member]] = [:]
        for process in list {
            guard let id = groupOf[process.pid], wanted.contains(id) else { continue }
            held[id, default: []].append(FreezeGroup.Member(pid: process.pid, startTime: process.startTime))
        }
        let groups = held.map { FreezeGroup(id: $0.key, name: $0.key, members: $0.value) }
        // The rule about a call lives in one place: what it leaves out is the groups that are on one.
        let notOnACall = UltraThrottle.members(kept: groups, leftRunning: [], processes: list)
        let onACall = groups.filter { group in !group.members.contains { notOnACall.contains($0) } }

        let underPolicy = live?.throttled ?? []
        let isUnderPolicy: (FreezeGroup.Member) -> Bool = { member in underPolicy.contains(Self.recordMember(member)) }
        liftFromGroupsOnACall(onACall, underPolicy: isUnderPolicy, in: list, groupOf: groupOf, own: own, stale: &stale)
        throttle(notOnACall.filter { !isUnderPolicy($0) && throttleSkipped[$0.pid] != $0.startTime }, dropping: &stale)
        dropFromRecord(stale)
    }

    /// The processes the record names under the policy that are no longer in the list: the pid is gone, or is another process now
    /// (its start time differs). A session of days would otherwise carry every process that ever ran under it to the end, where each
    /// is asked to be lifted and none can be.
    private func throttledNoLongerThere(in list: [UltraProcess]) -> [UltraRecord.Member] {
        let startTimes = Dictionary(list.map { ($0.pid, $0.startTime) }, uniquingKeysWith: { first, _ in first })
        return (live?.throttled ?? []).filter { startTimes[$0.pid] != $0.startTime }
    }

    /// What no longer exists, off the record, in a write of its own: only when no other write of the sweep took it, and none when
    /// there is nothing to drop.
    private func dropFromRecord(_ stale: [UltraRecord.Member]) {
        guard !stale.isEmpty else { return }
        record { $0.throttled?.removeAll { stale.contains($0) } }
    }

    private func liftFromGroupsOnACall(_ groups: [FreezeGroup], underPolicy: (FreezeGroup.Member) -> Bool, in list: [UltraProcess],
                                       groupOf: [pid_t: String], own: Set<pid_t>, stale: inout [UltraRecord.Member]) {
        let roots = groups.flatMap(\.members).filter(underPolicy)
        guard !roots.isEmpty else { return }
        let onACall = Set(groups.map(\.id))
        // What they started since the last sweep, but not what belongs to another app that keeps running: that one is looked
        // after by its own group, and is not on a call.
        let children = UltraThrottle.descendants(of: roots, in: list).filter { child in
            !own.contains(child.pid) && (groupOf[child.pid].map { onACall.contains($0) || !wantedGroup($0) } ?? true)
        }
        var lifted: [UltraRecord.Member] = []
        for member in roots + children {
            if throttler.unthrottle(pid: member.pid, startTime: member.startTime) { lifted.append(Self.recordMember(member)) }
        }
        // After the lift: a crash in between finds them named, which only lifts again. A lift the system refused leaves the process
        // named, so that the end lifts it again and the next sweep tries. What is no longer there goes in the same write.
        guard !lifted.isEmpty else { return }
        let gone = stale
        stale = []
        record { $0.throttled?.removeAll { lifted.contains($0) || gone.contains($0) } }
    }

    /// Whether a group id is one of those the sweep keeps on the efficiency cores.
    private func wantedGroup(_ id: String) -> Bool {
        keptIDs.contains(id) || leftRunning.contains { $0.id == id } || live?.groups.contains { $0.id == id && $0.released } == true
    }

    // ── The screen, the keyboard light, the power mode ──────────────────────

    /// Each part is tried in turn and each can be skipped: a part this Mac cannot do goes in `skipped`, and the rest goes
    /// on. What can block (the display, the keyboard light, the backlight) runs on `work`. Each part also has a deadline, so
    /// that a display or a helper that never answers cannot hold the start for ever.
    private func lowerScreenAndPower(token: Int, then done: @escaping () -> Void) {
        run([Step(name: "the brightness", seconds: Self.displayStepSeconds, part: .ceilingRefused) { [unowned self] gate, next in
                lowerBrightness(token, gate, next) },
             Step(name: "the refresh rate", seconds: Self.displayStepSeconds, part: .rateRefused) { [unowned self] gate, next in
                lowerRate(token, gate, next) },
             Step(name: "the keyboard light", seconds: Self.displayStepSeconds, part: .keyboardLight) { [unowned self] gate, next in
                switchKeyboardOff(token, gate, next) },
             Step(name: "the helper", seconds: Self.helperStepSeconds, part: .lowPowerRefused) { [unowned self] gate, next in
                enterLowPower(token, gate, next) }], token: token, then: done)
    }

    /// One part of the start. It calls `next` when it is done; if `seconds` pass first, `part` goes in `skipped` and the start goes
    /// on without it.
    private struct Step {
        let name: String
        let seconds: TimeInterval
        let part: UltraSkipped
        let run: (_ gate: StepGate, _ next: @escaping () -> Void) -> Void
    }

    /// Who got to a step's end first, its answer or its deadline. Whichever it is, the other does nothing: the start goes on
    /// from a step exactly once, and an answer that comes after the deadline changes nothing (it is read on the work queue as
    /// well, so a job that has not started when its time is up does not start). What the record named before the call was made
    /// is still put back at the end, whether or not a late call landed.
    private final class StepGate {
        private let lock = NSLock()
        private var done = false
        private var late = false
        /// The step's deadline came first.
        var passed: Bool { lock.lock(); defer { lock.unlock() }; return late }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done || late }
        /// The step answered: true when this is the one that goes on.
        func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done, !late else { return false }
            done = true
            return true
        }
        /// The deadline came: true when this is the one that goes on.
        func pass() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done, !late else { return false }
            late = true
            return true
        }
    }

    private func run(_ steps: ArraySlice<Step>, token: Int, then done: @escaping () -> Void) {
        guard let step = steps.first else { return done() }
        let rest = steps.dropFirst()
        let gate = StepGate()
        step.run(gate) { [weak self] in
            guard let self, self.session == token, gate.finish() else { return }
            self.run(rest, token: token, then: done)
        }
        // A step that finished while it was started has no deadline to wait for.
        guard !gate.isFinished else { return }
        schedule(step.seconds) { [weak self] in
            guard let self, self.session == token, gate.pass() else { return }
            self.log("ultra: \(step.name) did not answer in \(Int(step.seconds)) s, so it was skipped")
            self.skipped.append(step.part)
            self.run(rest, token: token, then: done)
        }
    }

    private func run(_ steps: [Step], token: Int, then done: @escaping () -> Void) {
        run(steps[...], token: token, then: done)
    }

    /// `job` runs on the work queue and may block; `done` runs on the main thread, and only when the session is still
    /// the one that asked and the step's time (`gate`) has not run out. A job that has not started when its session ends, or
    /// its step's time does, does not run at all: it would lower something after the mode was put back or given up on. (One
    /// already inside a system call cannot be stopped; what it did was named on the record first, and the restore queued
    /// behind it puts that back.)
    private func background<T>(_ token: Int, _ gate: StepGate, _ job: @escaping () -> T, then done: @escaping (T) -> Void) {
        work { [weak self] in
            guard let self, self.session == token, !gate.passed else { return }
            let result = job()
            self.onMain { [weak self] in
                guard let self, self.session == token, !gate.passed else { return }
                done(result)
            }
        }
    }

    private func lowerBrightness(_ token: Int, _ gate: StepGate, _ next: @escaping () -> Void) {
        background(token, gate, { [backlight = self.backlight] in backlight.brightness() }) { [weak self] current in
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
            self.background(token, gate, { [backlight = self.backlight] in backlight.setBrightness(target) }) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.log("ultra: the screen was lowered from \(Self.level(current)) to \(Self.level(target))")
                } else {
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

    private func lowerRate(_ token: Int, _ gate: StepGate, _ next: @escaping () -> Void) {
        // Named before it is asked for, like the rest: a turning off that overtakes the call on the queue still puts it back.
        guard record(mustSave: true, { $0.rateLowered = true }) else {
            log("ultra: the record could not take the refresh rate, so it was left as it is")
            skipped.append(.rateRefused)
            return next()
        }
        background(token, gate, { [rate = self.rate] () -> RateOutcome in
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

    private func switchKeyboardOff(_ token: Int, _ gate: StepGate, _ next: @escaping () -> Void) {
        background(token, gate, { [keyboard = self.keyboard] in keyboard.level() }) { [weak self] level in
            guard let self else { return }
            guard let level else { self.skipped.append(.keyboardLight); return next() }
            // Off already: nothing to switch off, and a 0 put back at the end could undo a light the owner switched on since.
            guard level > 0 else { return next() }
            guard self.record(mustSave: true, { $0.keyboardBefore = level }) else {
                self.log("ultra: the record could not take the keyboard light, so it was left as it is")
                self.skipped.append(.keyboardLight)
                return next()
            }
            self.background(token, gate, { [keyboard = self.keyboard] in keyboard.set(0) }) { [weak self] accepted in
                guard let self else { return }
                if !accepted {
                    self.skipped.append(.keyboardLight)
                    self.record { $0.keyboardBefore = nil }
                }
                next()
            }
        }
    }

    private func enterLowPower(_ token: Int, _ gate: StepGate, _ next: @escaping () -> Void) {
        switch power.availability {
        case .noHelper:
            skipped.append(.lowPowerNoHelper)
            next()
        case .oldHelper:
            skipped.append(.lowPowerOldHelper)
            next()
        case .ready:
            // Named before the helper is asked, with the rest of what the record holds: whether Low Power Mode was the owner's own
            // decides, at the end, whether there is anything to wait for. A record that cannot take it means the helper is not asked.
            let wasOn = lowPowerOn()
            guard record(mustSave: true, { $0.lowPowerBefore = wasOn }) else {
                log("ultra: the record could not take whether Low Power Mode was on, so it was left as it is")
                skipped.append(.lowPowerRefused)
                return next()
            }
            power.enterLowPower { [weak self] modeBefore in
                self?.onMain { [weak self] in
                    guard let self else { return }
                    guard self.session == token, !gate.passed else {
                        // The mode ended while the helper was answering, or the helper was given up on (and the section says
                        // so). It did switch Low Power Mode on, and nothing else knows to switch it off.
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
    /// screen and the rest are put back on the work queue, and the state stays as it is until that is done. When the mode switched
    /// Low Power Mode on, the screen is put back after it is off, which can take up to about seven seconds: the state stays `.on`,
    /// and a new ask is refused, until then.
    func turnOff() {
        guard state != .off, !ending else { return }
        end(inline: false)
    }

    /// Quit and logout cannot wait for ever: the continues, the lifts and the unhide are done here, first; the refresh rate, the
    /// keyboard light and the power mode are put back on the work queue (this thread never calls the display or the keyboard) and
    /// waited for for `shutdownWaitSeconds`, and so is the screen, unless the mode switched Low Power Mode on and it is still on:
    /// macOS raises the screen when it ends, so the screen waits for it. When everything is done the record and the watchdog go too,
    /// before this returns. When the wait runs out, or the screen is left for Low Power Mode, they stay, cut down to what remains in
    /// the second case, for the watchdog and the next launch; the screen is then put back by the watchdog, or here a few seconds
    /// later if the app is still running (a logout that was cancelled). Call it on the main thread, like everything that changes
    /// the state.
    func shutdown() {
        guard state != .off else { return }
        end(inline: true)
    }

    /// Undoes a record a session left behind (a crash, a kill, a power cut): what it names, and nothing else. The
    /// record is all there is to go on, so the brightness comes from it and not from `OwnBrightness`, which a new
    /// process has noted nothing in.
    func recoverAtLaunch() {
        guard state == .off, !ending, let record = store.load() else { return }
        log("ultra: undoing a session that was not ended")
        ending = true
        putBack(record, brightnessBefore: record.brightnessBefore, inline: false, leavingADarkScreen: true,
                token: counter.increment()) { [weak self] in
            self?.store.clear()
            self?.ending = false
        }
    }

    private func end(inline: Bool) {
        // The black desktop is the first thing to go, before a process is continued or a setting put back: whatever the rest takes,
        // the owner sees their screen again at once.
        backdrop.hide()
        let token = counter.increment()
        asked = nil
        // No record yet: nothing was done, so there is nothing to undo, only the question or the start to drop.
        guard let record = live else { reset(); return }
        ending = true
        log(inline ? "ultra: the mode was turned off as the app quit" : "ultra: the mode was turned off")
        frozen = []
        // Cancelled, or quit: nothing is left to cancel, and the button and the menus stop offering it.
        if isStarting {
            isStarting = false
            changed()
        }
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

    /// What the settings job hands to a quit that waits for it, behind a lock (the job is on the work queue): what it could not
    /// put back, once it is done, or that nobody waits for it any more.
    private final class SettingsHandoff {
        private let lock = NSLock()
        private var failed: [String]?
        private var abandoned = false

        /// The job is done. True when the quit has given up on it, so the job finishes the put-back itself.
        func complete(_ lines: [String]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if abandoned { return true }
            failed = lines
            return false
        }

        /// The quit's look after its wait: what the job handed back, or nil, and then the quit does not look again.
        func take() -> [String]? {
            lock.lock(); defer { lock.unlock() }
            if let failed { return failed }
            abandoned = true
            return nil
        }
    }

    /// Continues everything the record names, then unhides, and only then touches the settings (the refresh rate, the keyboard
    /// light, the power mode, and last the screen), which can block and must not hold up a continue.
    ///
    /// The screen comes last, after Low Power Mode is off, when the mode is what switched it on (`waitsForLowPowerToEnd`): macOS
    /// raises the screen when Low Power Mode ends, so a level set before that is lost. Otherwise there is nothing to wait for and the
    /// screen is put back in the settings job, as it always was.
    ///
    /// The settings run on `work`. `inline` is a quit: it waits for them here, for at most `shutdownWaitSeconds`, and `finished` is
    /// called here if they are done; otherwise `finished` comes on the main thread if the session still stands. A quit that finds Low
    /// Power Mode still on cannot wait for it, and leaves the screen to the watchdog (see `leaveTheScreenToTheWatchdog`). Anything
    /// else is a turning off, or the undoing of a leftover record: it waits (`putTheScreenBackAfterLowPower`) and then finishes.
    ///
    /// A dark screen is left (`leavingADarkScreen`) by the undoing of a leftover record only: with the lid shut the lid dimmer holds the
    /// screen at 0, and a new process has noted nothing in `OwnBrightness` to ask. A turning off or a quit asks it (`brightnessBefore`
    /// is nil while another feature holds the screen), so a dark screen there is put back like any other.
    private func putBack(_ record: UltraRecord, brightnessBefore: Float?, inline: Bool, leavingADarkScreen: Bool = false, token: Int,
                         finished: @escaping () -> Void) {
        var record = record
        if record.brightnessBefore != nil, brightnessBefore == nil {
            log("ultra: the screen was left as it is: another feature holds it down")
        }
        record.brightnessBefore = brightnessBefore
        let actions = UltraRecovery.actions(for: record, brightnessNow: nil)
        let groupOf = Dictionary(record.groups.flatMap { group in group.members.map { ($0.pid, group.name) } },
                                 uniquingKeysWith: { first, _ in first })
        for case .resume(let pid, let startTime) in actions where !freezer.resume(pid: pid, startTime: startTime) {
            log("ultra: could not continue \(groupOf[pid] ?? "a process") (\(pid)): it has ended, or is not that process any more")
        }
        // Right after the continues, before anything that asks another app for something: what was slowed is lifted from
        // every process the record names, from every living descendant of one, and from every current member of the kept,
        // left-running and brought-back groups (see `liftTheLimit`). Not tied to the setting or to this Mac's cores: a record
        // is undone whatever the owner has changed since.
        liftTheLimit(actions, names: groupOf)
        for case .unhide(let pid) in actions { hider.unhide(pid: pid) }

        let waits = record.waitsForLowPowerToEnd
        let screenLevel = record.brightnessBefore
        // What each step could not do (and what it did to the screen), to be logged where the log is safe to write. The screen is put
        // back only as far as `BrightnessCeiling` says, against what it reads now; it is in this job only when nothing waits.
        let settings = { [backlight = self.backlight, rate = self.rate, keyboard = self.keyboard] (withScreen: Bool) -> [String] in
            var lines: [String] = []
            if withScreen { lines += Self.putTheScreenBack(to: screenLevel, on: backlight, leavingADarkScreen: leavingADarkScreen) }
            for action in actions {
                switch action {
                case .restoreRate:
                    rate.restore()
                case .keyboard(let level):
                    if !keyboard.set(level) { lines.append("ultra: the keyboard light could not be put back") }
                case .resume, .unthrottle, .unhide, .brightness, .powerMode:
                    break
                }
            }
            return lines
        }
        let restoreThePowerMode = { [weak self] in
            for case .powerMode(let mode) in actions { self?.restorePower(mode) }
        }
        if inline {
            // A quit puts the refresh rate and the keyboard light back on the work queue, like everything that can block, and waits
            // for it here, for at most `shutdownWaitSeconds`: those calls go to other processes, and a main thread that is stuck in
            // one cannot be told to quit. What the job found goes through a box, and the rest is done here on this thread (a hop back
            // to the main queue would not run until this returns, which is after the app is gone).
            //
            // The screen is in that job when nothing waits, or when Low Power Mode is off already. When it is still on the app cannot
            // wait for it to go off: it is going away, and the helper puts the power mode back when the connection closes.
            let screenInJob = !waits || !lowPowerOn()
            let inTime = runWhileQuitting(token: token, { settings(screenInJob) }) { [weak self] in
                restoreThePowerMode()
                if screenInJob { return finished() }
                self?.leaveTheScreenToTheWatchdog(screenLevel, of: record, token: token, finished: finished)
            }
            if !inTime {
                // Neither the record nor the watchdog is taken away: the watchdog sees Anode go and the next launch looks for the
                // record, and either puts back what is still named.
                log("ultra: the screen and the rest were not put back in time, so the record and the watchdog were left to finish it")
            }
        } else {
            work { [weak self] in
                // Overtaken by a quit that has put everything back already: it does not do it a second time.
                guard let self, self.session == token else { return }
                let lines = settings(!waits)
                self.onMain { [weak self] in
                    guard let self else { return }
                    lines.forEach(self.log)
                    guard self.session == token else { return }
                    restoreThePowerMode()
                    guard waits else { return finished() }
                    self.putTheScreenBackAfterLowPower(to: screenLevel, leavingADarkScreen: leavingADarkScreen, token: token,
                                                       finished: finished)
                }
            }
        }
    }

    /// Runs `job` on the work queue and waits for it here for at most `shutdownWaitSeconds`. When it is done in time its lines are
    /// logged and `afterwards` runs, here. When not, the job finishes the put-back itself if the app is still here (a logout that was
    /// cancelled): its lines are logged and `afterwards` runs on the main thread, if the session still stands. Says which happened.
    @discardableResult
    private func runWhileQuitting(token: Int, _ job: @escaping () -> [String], then afterwards: @escaping () -> Void) -> Bool {
        let handoff = SettingsHandoff()
        work { [weak self] in
            let lines = job()
            guard handoff.complete(lines) else { return }
            // The quit had given up and the app is still here: the job finishes the put-back the way the queue's own path does.
            self?.onMain { [weak self] in
                guard let self, self.session == token else { return }
                lines.forEach(self.log)
                afterwards()
            }
        }
        _ = waitForWork(Self.shutdownWaitSeconds)
        guard let lines = handoff.take() else { return false }
        lines.forEach(log)
        afterwards()
        return true
    }

    /// A quit that finds Low Power Mode still on: the power mode has been asked for, but the screen is not set, because macOS raises
    /// it again when Low Power Mode ends. The record is cut down to what remains (the screen, and what says whether to wait for Low
    /// Power Mode: the processes, the lifts, the rate and the keyboard light are done, so none of them is named any more), and neither
    /// it nor the watchdog is taken away, so the watchdog puts the screen back once it sees Anode go, and then takes the record away
    /// (the next launch does it, if the watchdog did not). If Anode does not go after all (a logout that was cancelled) it waits and
    /// puts the screen back itself, and then takes the record and the watchdog away.
    ///
    /// With no watchdog running, or a record that cannot be rewritten, nothing would put the screen back: it is put back now
    /// (`putTheScreenBackWhileQuitting`), which is better than not.
    private func leaveTheScreenToTheWatchdog(_ level: Float?, of held: UltraRecord, token: Int, finished: @escaping () -> Void) {
        // Nothing would put the screen back if no watchdog is running (it ended, or could not be started again): the app does it now.
        guard watchdog.pid != nil else {
            log("ultra: the watchdog is not running, so the screen was put back now")
            return putTheScreenBackWhileQuitting(level, token: token, finished: finished)
        }
        var rest = UltraRecord()
        rest.brightnessBefore = level
        rest.powerModeBefore = held.powerModeBefore
        rest.lowPowerBefore = held.lowPowerBefore
        if record(mustSave: true, { $0 = rest }) {
            log("ultra: Low Power Mode is still on, so the screen is left for the watchdog to put back once it is off")
            // The app may stay: a logout can be cancelled after the notice, and a controller left ending would refuse the mode for good.
            // Then the end is finished the way a turning off finishes it, a little later (the record and the watchdog go then). On a
            // quit this never runs, because the app is gone, and the watchdog does it.
            schedule(Self.lowPowerPollSeconds) { [weak self] in
                self?.putTheScreenBackAfterLowPower(to: level, token: token, finished: finished)
            }
            return
        }
        log("ultra: the record could not be rewritten for the watchdog, so the screen was put back now")
        putTheScreenBackWhileQuitting(level, token: token, finished: finished)
    }

    /// What a quit does when the screen cannot be left to the watchdog: it is put back here, now, in a job of its own that is waited
    /// for like the settings job, and then the end is finished. Low Power Mode may still be on, so macOS can raise it again; a screen
    /// the owner sees at the right level for a while is better than one nobody puts back.
    private func putTheScreenBackWhileQuitting(_ level: Float?, token: Int, finished: @escaping () -> Void) {
        let inTime = runWhileQuitting(token: token, { [backlight = self.backlight] in Self.putTheScreenBack(to: level, on: backlight) },
                                      then: finished)
        if !inTime {
            log("ultra: the screen was not put back in time, so the record and the watchdog were left to finish it")
        }
    }

    /// For a turning off, or the undoing of a leftover record, after the power mode has been asked for: looks every
    /// `lowPowerPollSeconds` until Low Power Mode is off or `lowPowerWaitSeconds` have passed, gives macOS `brightnessSettleSeconds`
    /// to finish raising the screen by itself, puts the screen back on the work queue, and calls `finished`. Every hop is this
    /// session's only: a quit that overtakes any of them has taken the end over, and this does nothing more.
    private func putTheScreenBackAfterLowPower(to level: Float?, leavingADarkScreen: Bool = false, token: Int,
                                               finished: @escaping () -> Void) {
        waitForLowPowerToEnd(token: token) { [weak self] in
            self?.schedule(Self.brightnessSettleSeconds) { [weak self] in
                guard let self, self.session == token else { return }
                self.work { [weak self] in
                    guard let self, self.session == token else { return }
                    let lines = Self.putTheScreenBack(to: level, on: self.backlight, leavingADarkScreen: leavingADarkScreen)
                    self.onMain { [weak self] in
                        guard let self else { return }
                        lines.forEach(self.log)
                        guard self.session == token else { return }
                        finished()
                    }
                }
            }
        }
    }

    /// Looks at Low Power Mode now and, while it is on, every `lowPowerPollSeconds` (through `schedule`) up to `lowPowerWaitSeconds`.
    /// `done` runs when it reads off, or at the limit. Counts the looks rather than the clock, so a test never waits.
    private func waitForLowPowerToEnd(token: Int, waited: TimeInterval = 0, then done: @escaping () -> Void) {
        guard session == token else { return }
        guard lowPowerOn() else {
            log(waited == 0 ? "ultra: Low Power Mode was off already"
                            : "ultra: Low Power Mode went off after \(String(format: "%.2f", waited)) s")
            return done()
        }
        guard waited < Self.lowPowerWaitSeconds else {
            log("ultra: Low Power Mode was still on after \(Int(Self.lowPowerWaitSeconds)) s, so the screen was set all the same")
            return done()
        }
        schedule(Self.lowPowerPollSeconds) { [weak self] in
            self?.waitForLowPowerToEnd(token: token, waited: waited + Self.lowPowerPollSeconds, then: done)
        }
    }

    /// Reads the screen and sets it to `before` where `BrightnessCeiling` says it is the mode's to: runs on the work queue and may
    /// block. Returns what to log, which is said on the main thread. Nothing is read when the mode lowered nothing.
    private static func putTheScreenBack(to before: Float?, on backlight: BacklightControl, leavingADarkScreen: Bool = false) -> [String] {
        guard let before else { return [] }
        let now = backlight.brightness()
        switch BrightnessCeiling.decide(before: before, now: now, leavingADarkScreen: leavingADarkScreen) {
        case .putBack(let level):
            return [backlight.setBrightness(level) ? "ultra: the screen was put back to \(Self.level(level))"
                                                   : "ultra: the brightness could not be put back"]
        case .couldNotBeRead:
            return ["ultra: the brightness could not be read, so it was not put back"]
        case .aboveTheCeiling:
            return ["ultra: the screen was left at \(Self.level(now ?? 0)): it is above the ceiling, so something else raised it"]
        case .alreadyAtTheEarlierLevel:
            return ["ultra: the screen was left at \(Self.level(now ?? 0)): it is not dimmer than it was before the mode (\(Self.level(before)))"]
        case .screenIsDark:
            return ["ultra: the screen is dark, so it was left"]
        case .nothingWasLowered:
            return []
        }
    }

    /// A brightness for the log, with two decimals.
    private static func level(_ value: Float) -> String { String(format: "%.2f", value) }

    /// Lifts the background policy from every process the record names, from every living descendant of one of them, and, in a
    /// session, from every current member of the groups the session kept on the efficiency cores. The last two come from one
    /// process table read now.
    ///
    ///  · A child started after the last sweep inherited the policy and is on no record (and keeps it when its parent is lifted).
    ///  · A long-lived process whose short-lived parent has gone (a build daemon a script started) belongs to launchd, so no walk
    ///    down the children can reach it; the group it belongs to can, by the process macOS holds responsible for it. The groups
    ///    are those the sweep keeps (the kept ones, the ones left running, the ones the owner brought back), placed with the same
    ///    function the sweep uses, on the table merged with the latest full snapshot. No exception for a call: lifting is always
    ///    safe, and lifting a process that was never set changes nothing.
    ///  · A frozen group, a system process and anything of Anode's own are never touched. A launch after a crash has the record
    ///    only: it does not know which groups were kept, and has no snapshot to place a process in a group with, so it lifts what
    ///    the record names and what those started, as the watchdog does.
    ///
    /// The table is read on this thread: it is the kernel's own, with no call into another process, and a quit cannot wait for
    /// a queue. A process is lifted once, and a false is logged once for a pid.
    private func liftTheLimit(_ actions: [UltraRecovery.Action], names: [pid_t: String]) {
        var notLifted: Set<pid_t> = []
        var lifted: [pid_t: Set<UInt64>] = [:]
        func lift(_ pid: pid_t, _ startTime: UInt64) {
            guard lifted[pid, default: []].insert(startTime).inserted else { return }
            guard !throttler.unthrottle(pid: pid, startTime: startTime), notLifted.insert(pid).inserted else { return }
            // One that has ended (or whose pid is another process now) has nothing left to lift: not a failure, and not said.
            guard self.startTime(pid) == startTime else { return }
            log("ultra: could not lift the efficiency-core limit from \(names[pid] ?? "a process") (\(pid)): the system refused")
        }
        var roots: [FreezeGroup.Member] = []
        for case .unthrottle(let pid, let startTime) in actions {
            lift(pid, startTime)
            roots.append(FreezeGroup.Member(pid: pid, startTime: startTime))
        }
        guard !roots.isEmpty || throttling else { return }
        guard let fresh = processTable() else {
            log("ultra: the process table could not be read, so what the kept apps started was not lifted")
            return
        }
        let table = UltraThrottle.merged(fresh: fresh, known: known)
        let own = anodes()
        for child in UltraThrottle.descendants(of: roots, in: table) where !own.contains(child.pid) {
            lift(child.pid, child.startTime)
        }
        guard throttling else { return }
        let groupOf = FreezePlanner.groupIDs(processes: table, user: user, ownPIDs: own)
        for process in table.sorted(by: { $0.pid < $1.pid }) {
            guard let id = groupOf[process.pid], wantedGroup(id) else { continue }
            lift(process.pid, process.startTime)
        }
    }

    // ── One group back ──────────────────────────────────────────────────────

    /// The owner took this group back (the menu): it is continued and stays running for the rest of the session.
    func release(groupID: String) { releaseGroup(groupID, forLoad: false) }

    /// An app was brought forward (its Dock icon, the app switcher): if it is in a frozen group, that group is released, whatever
    /// its pid. The group is the one the process was placed in by the latest list (an extension, a part the sweep read and could
    /// not stop), or, for a pid no list has seen yet (an app quit and opened again), the one the app's bundle id names.
    func appActivated(pid: pid_t, bundleID: String? = nil) {
        guard state == .on, !ending else { return }
        let placed = FreezePlanner.groupIDs(processes: known, user: user, ownPIDs: anodes())[pid] ?? bundleID
        let group = frozen.first { group in
            group.members.contains { $0.pid == pid } || appOfGroup[group.id] == pid || group.id == placed
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
        restartWatchdogIfItEnded()
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
            self.known = list
            // A pid is known only while it is still the process that was tried: a pid that was reused is a new process.
            let startTimes = Dictionary(list.map { ($0.pid, $0.startTime) }, uniquingKeysWith: { first, _ in first })
            let tried = Set(self.attempted.filter { startTimes[$0.key] == $0.value }.keys)
            var additions = FreezePlanner.additions(processes: list, user: self.user, frozenGroups: Set(self.frozen.map(\.id)),
                                                    known: tried, ownPIDs: self.anodes())
            // A frozen app that was quit and opened again has a new app process, which the mode did not stop: the owner is using
            // it. The group is released as the owner's own bringing it back would, and none of its new parts are stopped.
            let regular = Set(list.filter { $0.app == .regular }.map(\.pid))
            for add in additions where add.members.contains(where: { regular.contains($0.pid) }) {
                self.log("ultra: \(add.name) was opened again, so it is not frozen again")
                self.releaseGroup(add.id, forLoad: false)
            }
            additions.removeAll { add in !self.frozen.contains { $0.id == add.id } }
            // What keeps running is looked at on its own: nothing is stopped for it, so no reading of the load. After the
            // releases, so that an app just brought back is kept on the efficiency cores in this same sweep.
            self.keepRunningOnEfficiencyCores(in: list)
            guard !additions.isEmpty else { return finish() }
            // This step's own reading from before it, as the start has one.
            self.load.read { [weak self] before in
                guard let self, self.session == token else { return }
                self.freezeNewcomers(additions, before: before, token: token)
                finish()
            }
        }
    }

    /// The watchdog is what continues everything if Anode dies, so a session that has lost it is not left without: it is started
    /// again (the same call as at the start), once per time it is found ended. One that cannot be started is said, and the session
    /// goes on: the record is on disk, and the next launch still finishes the undo.
    private func restartWatchdogIfItEnded() {
        guard watchdog.pid == nil else { return }
        if watchdog.start() {
            log("ultra: the watchdog had ended, so it was started again")
        } else {
            log("ultra: the watchdog had ended and could not be started again; the session goes on")
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
    ///
    /// When the start did not lower the screen (the lid was closed, or it was at or under the ceiling already) nothing names a
    /// level to put back. The first pull-back of such a session names the level it pulls back from, as the start does for
    /// the one it lowers: remembered for the other features that dim the screen, and written on the record before the screen
    /// is touched. A record that cannot take it means the screen is left as it is.
    func brightnessMayHaveChanged() {
        guard state == .on, !ending, !adjustingBrightness else { return }
        adjustingBrightness = true
        let token = session
        work { [backlight = self.backlight, weak self] in
            // Not read at all when the mode has ended while this waited its turn.
            let now = self?.session == token ? backlight.brightness() : nil
            self?.onMain { [weak self] in
                guard let self, self.session == token else { return }
                guard let now, let ceiling = BrightnessCeiling.clamp(now) else {
                    self.adjustingBrightness = false
                    return
                }
                let firstPullBack = self.live?.brightnessBefore == nil
                if firstPullBack {
                    self.ownBrightness.remember(now, for: Self.ownerName)
                    guard self.record(mustSave: true, { $0.brightnessBefore = now }) else {
                        self.log("ultra: the record could not take the brightness, so the screen was not pulled back")
                        _ = self.ownBrightness.forget(Self.ownerName)
                        self.adjustingBrightness = false
                        return
                    }
                }
                self.work { [weak self] in
                    let refused = self?.session == token ? !backlight.setBrightness(ceiling) : false
                    self?.onMain { [weak self] in
                        guard let self, self.session == token else { return }
                        if refused {
                            self.log("ultra: the screen did not take the lower brightness")
                        } else if firstPullBack {
                            // The start did not lower it, so this is the one time the log hears of the screen being lowered.
                            self.log("ultra: the screen was lowered from \(Self.level(now)) to \(Self.level(ceiling))")
                        }
                        self.adjustingBrightness = false
                    }
                }
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
        isStarting = false
        // A box still up is for a session that is over: it goes, and its No finds the session moved on.
        confirm.dismiss()
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
        throttleSkipped = [:]
        known = []
        appOfGroup = [:]
        sweeping = false
        adjustingBrightness = false
        keptCount = 0
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
