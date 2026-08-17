import Foundation
import ServiceManagement

/// Typed, validated, observable settings persisted in UserDefaults.
///
/// Why a named suite instead of `.standard`: three executables (GUI app, CLI,
/// helper) share these settings, and an unbundled binary's `.standard` domain is
/// keyed by *process name* — each target would get its own orphan plist and the
/// CLI would never see what the app configured. One suite file
/// (`~/Library/Preferences/com.anode.settings.plist`) is the single truth
/// for all of them. Works because we are not sandboxed.
///
/// Why clamp on write AND on read: values arrive from three untrusted directions —
/// our own UI, `defaults write` in a terminal, and stale plists from older builds.
/// A `sampleInterval` of 0 would spin the CPU in the sampling loop; a negative
/// window would break every history query. So ranges are enforced at both
/// boundaries, and non-finite values (NaN/inf poison every comparison) are
/// dropped on the floor rather than stored.
///
/// `launchAtLogin` is deliberately NOT persisted here. `SMAppService` is the
/// system's source of truth and the user can revoke approval in System Settings
/// behind our back — a cached Bool would let the checkbox lie. The getter always
/// asks the OS.
public final class Settings {

    // ── Keys ────────────────────────────────────────────────────────────────
    /// Observation keys. These are the *logical* names; storage keys carry a
    /// "anode." prefix so a shared defaults domain can't collide with us.
    public enum Key {
        public static let sampleInterval = "sampleInterval"
        public static let powerWindowHours = "powerWindowHours"
        public static let historyRetentionDays = "historyRetentionDays"
        public static let showDaemons = "showDaemons"
        public static let minimumDisplayPercentPerHour = "minimumDisplayPercentPerHour"
        public static let launchAtLogin = "launchAtLogin"
        public static let menuBarWidgets = "menuBarWidgets"
        public static let startInMenuBarOnly = "startInMenuBarOnly"
        public static let batteryLogging = "batteryLogging"
        public static let menuBarWidgetsEnabled = "menuBarWidgetsEnabled"
        public static let fanControlEnabled = "fanControlEnabled"
        public static let fanDisclosureSeen = "fanDisclosureSeen"
        public static let fanSyncEnabled = "fanSyncEnabled"
        public static let speedTestAgreed = "speedTestAgreed"
        /// The stats panel's arrangement. Empty until the user edits it — see
        /// `panelOrder` for why the default is not materialized here.
        public static let panelOrder = "panelOrder"
        public static let panelHidden = "panelHidden"
        /// Wildcard — an observer registered on this key fires for every change.
        public static let any = "*"
    }

    // ── Ranges (public so UI controls stay in lockstep with validation) ─────
    public static let sampleIntervalRange: ClosedRange<Double> = 1...30
    /// The user said "10 hr power"; Activity Monitor uses 12. This is a
    /// preference, never a constant — hence the wide range.
    public static let powerWindowHoursRange: ClosedRange<Double> = 1...48
    public static let historyRetentionDaysRange: ClosedRange<Double> = 1...365
    public static let minimumDisplayRange: ClosedRange<Double> = 0...1
    /// Cap the widget list so a corrupt plist can't flood the menu bar.
    public static let maxMenuBarWidgets = 12

    private enum Default {
        static let sampleInterval = 2.0
        static let powerWindowHours = 10.0
        static let historyRetentionDays = 7.0
        static let showDaemons = true
        static let minimumDisplayPercentPerHour = 0.01
        /// OFF. macOS gives an app no way to tell a login launch from a
        /// double-click (see `AppPresence`), so this one switch governs both — and
        /// a user who opens an app from Finder and gets no window concludes it
        /// failed to launch. Opt in, never on by default.
        static let startInMenuBarOnly = false
        /// ON. The trailing-window column, the history graph and every range
        /// beyond the live hour are read out of this history; defaulting it off
        /// would silently empty features that already exist.
        static let batteryLogging = true
        /// ON. Matches what every build so far has done, and the widgets are the
        /// app's front door once the window is closed.
        static let menuBarWidgetsEnabled = true
        /// OFF, and it is the one setting in this file that must stay that way.
        ///
        /// Turning it on is a decision to let a root process on this machine
        /// write to the fans while you run it — see the trust model at the top of
        /// `FanLink.swift`. A default of true would make that decision for
        /// someone who never read it, and `FanMode.native`'s contract is that a
        /// user who has not opted in is on a machine this code has never touched.
        static let fanControlEnabled = false
        static let fanDisclosureSeen = false
        /// One slider for every fan, on by default.
        ///
        /// Two fans in one chassis cool one shared thermal mass, and a machine
        /// where they are set differently is one where the quiet fan is doing
        /// nothing about the heat the loud one is chasing. Independent control is
        /// there for the person who has a reason; matching them is the sane
        /// default, and it also halves the number of privileged writes a drag
        /// makes on the common case.
        static let fanSyncEnabled = true
        /// Has the user been told, once, what the speed test sends and to whom?
        /// False until they have agreed — never assumed, and never true by
        /// default, because the whole point of the disclosure is that egress from
        /// this app is a thing someone chose.
        static let speedTestAgreed = false
        /// Matches what the status item shows today: smoothed drain + runtime.
        // Must be real, currently-registered metric IDs. Stale ones are invisible
        // in the picker and get preserved forever as "unknown" bindings.
        static let menuBarWidgets = [MetricID.batteryDrain.rawValue,
                                     MetricID.cpuUsage.rawValue,
                                     MetricID.memoryUsage.rawValue,
                                     MetricID.groupPlaceholder.rawValue]
    }

    // ── Storage ─────────────────────────────────────────────────────────────
    public static let suiteName = "com.anode.settings"

    /// What this app used to be called, and where it used to keep things.
    ///
    /// The rename from BetterStats moved the settings domain, the history store
    /// and the login agent's label. None of that is a problem for a machine that
    /// has never run the old build and all of it is a problem for one that has:
    /// preferences silently back to defaults, a 240 MB history the app can no
    /// longer see, and a login item registered under a name nothing looks for.
    ///
    /// Migration runs ONCE and only into an untouched destination, so it can never
    /// overwrite settings someone has since changed. See `migrateFromPreviousName`.
    static let previousSuiteName = "com.betterstats.settings"
    public static let shared = Settings()

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// Last effective values, used only to (a) suppress notifications for no-op
    /// writes and (b) diff on `UserDefaults.didChangeNotification` so a write
    /// through *another* Settings instance in this process still fires observers.
    private struct Values: Equatable {
        var sampleInterval, powerWindowHours, historyRetentionDays,
            minimumDisplayPercentPerHour: Double
        var showDaemons, startInMenuBarOnly, batteryLogging, menuBarWidgetsEnabled,
            fanControlEnabled, fanSyncEnabled, speedTestAgreed: Bool
        var fanDisclosureSeen: Bool
        var menuBarWidgets: [String]
        var panelOrder: [String]
        var panelHidden: [String]
    }
    private var snapshot: Values
    private var defaultsObserver: NSObjectProtocol?

    /// Pass nil for the shared suite. A distinct `UserDefaults` handle on the
    /// same suite reads the same data — used by tests to prove persistence.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Settings.suiteName) ?? .standard
        Settings.migrateFromPreviousName(into: self.defaults)
        self.snapshot = Settings.readAll(self.defaults)
        // UserDefaults posts didChange synchronously, in-process only. Out-of-
        // process edits (defaults write) are still *read* correctly because
        // getters go to UserDefaults, not the snapshot — they just don't notify.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.reconcile() }
    }

    deinit {
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
    }

    // ── Properties ──────────────────────────────────────────────────────────

    /// Seconds between PowerMonitor ticks. Clamped to 1...30: 0 would spin the
    /// CPU and burn the battery we are trying to measure.
    public var sampleInterval: TimeInterval {
        get { Settings.readDouble(defaults, Key.sampleInterval,
                                  Default.sampleInterval, Settings.sampleIntervalRange) }
        set { writeDouble(Key.sampleInterval, \.sampleInterval, newValue,
                          Default.sampleInterval, Settings.sampleIntervalRange) }
    }

    /// Trailing on-battery window (hours) behind the "10 hr power" figure.
    public var powerWindowHours: Double {
        get { Settings.readDouble(defaults, Key.powerWindowHours,
                                  Default.powerWindowHours, Settings.powerWindowHoursRange) }
        set { writeDouble(Key.powerWindowHours, \.powerWindowHours, newValue,
                          Default.powerWindowHours, Settings.powerWindowHoursRange) }
    }

    /// How long sampled history is kept before pruning.
    public var historyRetentionDays: Double {
        get { Settings.readDouble(defaults, Key.historyRetentionDays,
                                  Default.historyRetentionDays, Settings.historyRetentionDaysRange) }
        set { writeDouble(Key.historyRetentionDays, \.historyRetentionDays, newValue,
                          Default.historyRetentionDays, Settings.historyRetentionDaysRange) }
    }

    /// When false the UI hides non-.app rows. Display-only: daemon drain still
    /// counts toward the measured total — hiding a row must never move energy
    /// into other rows or the ledger stops being honest.
    public var showDaemons: Bool {
        get { Settings.readBool(defaults, Key.showDaemons, Default.showDaemons) }
        set { writeBool(Key.showDaemons, \.showDaemons, newValue, Default.showDaemons) }
    }

    /// Launch with no window and no Dock tile — a menu bar tool, nothing else.
    ///
    /// Applies to EVERY launch, deliberately. The tempting design is "headless at
    /// login, windowed when opened by hand", and it is not implementable: an
    /// `SMAppService.mainApp` login launch is argv- and environment-identical to a
    /// Finder launch (measured — see `AppPresence`). Offering it as two behaviours
    /// would mean guessing which one happened, and guessing wrong looks exactly
    /// like the app failing to start.
    ///
    /// `AppPresence` overrides this to false when widgets are off, because the
    /// combination leaves nothing on screen to click.
    public var startInMenuBarOnly: Bool {
        get { Settings.readBool(defaults, Key.startInMenuBarOnly, Default.startInMenuBarOnly) }
        set { writeBool(Key.startInMenuBarOnly, \.startInMenuBarOnly, newValue,
                        Default.startInMenuBarOnly) }
    }

    /// Whether sampled history is written to the durable store at all.
    ///
    /// Off is a real saving, not just a suppressed write: with the window closed
    /// the app's only reason to run the expensive per-process sweep is to keep
    /// this history accruing, so the sweep stops too. What was already recorded is
    /// kept — this stops the pen, it does not tear out the pages.
    public var batteryLogging: Bool {
        get { Settings.readBool(defaults, Key.batteryLogging, Default.batteryLogging) }
        set { writeBool(Key.batteryLogging, \.batteryLogging, newValue, Default.batteryLogging) }
    }

    /// Master switch for the menu bar. `menuBarWidgets` still records WHICH
    /// widgets are bound, so turning this off and on again restores the same set
    /// rather than resetting to the defaults.
    public var menuBarWidgetsEnabled: Bool {
        get { Settings.readBool(defaults, Key.menuBarWidgetsEnabled,
                                Default.menuBarWidgetsEnabled) }
        set { writeBool(Key.menuBarWidgetsEnabled, \.menuBarWidgetsEnabled, newValue,
                        Default.menuBarWidgetsEnabled) }
    }

    /// Whether the app will talk to a fan helper at all.
    ///
    /// Off means the app never opens the helper's socket and never asks for a
    /// write — not "asks and is refused". A user who leaves this alone is on a
    /// machine Anode has never written to, which is `FanMode.native`'s
    /// whole contract.
    /// Has the user read the fan disclosure and asked not to see it again?
    ///
    /// It suppresses an EXPLANATION, never a safeguard. The disclosure describes
    /// what the helper is and what running it as root means; the thing that
    /// actually stops anything happening is the Terminal window and the password,
    /// and neither is affected by this. Someone who has read it once and is now
    /// adjusting fans daily should not have to read it daily.
    ///
    /// Separate from `fanControlEnabled` because they answer different questions.
    /// Turning the feature off does not un-read the disclosure, so switching back
    /// on should not re-explain it.
    public var fanDisclosureSeen: Bool {
        get { Settings.readBool(defaults, Key.fanDisclosureSeen, Default.fanDisclosureSeen) }
        set { writeBool(Key.fanDisclosureSeen, \.fanDisclosureSeen, newValue,
                        Default.fanDisclosureSeen) }
    }

    public var fanControlEnabled: Bool {
        get { Settings.readBool(defaults, Key.fanControlEnabled, Default.fanControlEnabled) }
        set { writeBool(Key.fanControlEnabled, \.fanControlEnabled, newValue,
                        Default.fanControlEnabled) }
    }

    /// Drive every fan from one slider.
    ///
    /// A view preference, not a hardware one: turning it off does not release
    /// anything, it splits the strip back into a row per fan and leaves each
    /// where it is.
    public var fanSyncEnabled: Bool {
        get { Settings.readBool(defaults, Key.fanSyncEnabled, Default.fanSyncEnabled) }
        set { writeBool(Key.fanSyncEnabled, \.fanSyncEnabled, newValue, Default.fanSyncEnabled) }
    }

    /// Has the user agreed, once, to the speed test's egress disclosure?
    public var speedTestAgreed: Bool {
        get { Settings.readBool(defaults, Key.speedTestAgreed, Default.speedTestAgreed) }
        set { writeBool(Key.speedTestAgreed, \.speedTestAgreed, newValue, Default.speedTestAgreed) }
    }

    /// Floor below which rows display as "<0.01" instead of a meaningless digit.
    public var minimumDisplayPercentPerHour: Double {
        get { Settings.readDouble(defaults, Key.minimumDisplayPercentPerHour,
                                  Default.minimumDisplayPercentPerHour, Settings.minimumDisplayRange) }
        set { writeDouble(Key.minimumDisplayPercentPerHour, \.minimumDisplayPercentPerHour,
                          newValue, Default.minimumDisplayPercentPerHour, Settings.minimumDisplayRange) }
    }

    /// Metric IDs bound to menu bar widgets, in display order. Sanitized on both
    /// paths: trimmed, deduped, capped. Unknown IDs are kept — a metric from a
    /// module that isn't loaded right now must not be silently un-bound.
    public var menuBarWidgets: [String] {
        get { Settings.readWidgets(defaults, Default.menuBarWidgets) }
        set {
            let clean = Settings.sanitizeWidgets(newValue)
            let old = menuBarWidgets
            guard clean != old || defaults.object(forKey: Settings.storageKey(Key.menuBarWidgets)) == nil else { return }
            lock.lock(); snapshot.menuBarWidgets = clean; lock.unlock()
            defaults.set(clean, forKey: Settings.storageKey(Key.menuBarWidgets))
            if clean != old { notify(Key.menuBarWidgets) }
        }
    }

    /// The stats panel's row order, hidden rows included, as the user arranged
    /// it. EMPTY until they touch the editor, and that emptiness is meaningful:
    /// it is how `PanelOrder` knows to speak for itself. Materializing today's
    /// default into the plist on first launch would freeze it there and make
    /// every future improvement to the default invisible to everyone who had
    /// ever run the app.
    ///
    /// Not capped at `maxMenuBarWidgets`: that cap stops a corrupt plist
    /// flooding the MENU BAR with status items, and this is one scrollable menu
    /// with no such cost. Capping it would mean hiding one metric could evict
    /// another.
    public var panelOrder: [String] {
        get { Settings.readIDList(defaults, Key.panelOrder) }
        set { writeIDList(newValue, key: Key.panelOrder, keyPath: \.panelOrder) }
    }

    /// Metric IDs the user has unchecked in the panel editor. They keep their
    /// place in `panelOrder` — hiding a row must not cost it its position — and
    /// are filtered out only at render time.
    public var panelHidden: [String] {
        get { Settings.readIDList(defaults, Key.panelHidden) }
        set { writeIDList(newValue, key: Key.panelHidden, keyPath: \.panelHidden) }
    }

    /// Shared write path for both panel lists: sanitize, skip no-op writes,
    /// keep the snapshot in step, notify once.
    private func writeIDList(_ newValue: [String], key: String,
                             keyPath: WritableKeyPath<Values, [String]>) {
        let clean = Settings.sanitizeIDs(newValue)
        let old = Settings.readIDList(defaults, key)
        guard clean != old else { return }
        lock.lock(); snapshot[keyPath: keyPath] = clean; lock.unlock()
        defaults.set(clean, forKey: Settings.storageKey(key))
        notify(key)
    }

    // ── Launch at login (SMAppService, macOS 13+) ───────────────────────────

    /// OS-truth status, mapped so callers don't need ServiceManagement.
    public enum LoginItemStatus: String {
        case enabled
        /// Registered, but the user must approve it in System Settings →
        /// General → Login Items before it takes effect. The checkbox must NOT
        /// show "on" in this state — nothing will actually launch.
        case requiresApproval
        case notRegistered
        /// SMAppService can't find us. TWO different situations reach this, and
        /// the UI used to report only one of them — see `notFoundNote`.
        ///
        /// MEASURED on this machine: `register()` on the bare executable still
        /// succeeds and flips status to `.enabled`, so don't treat this state as
        /// terminally broken.
        case notFound
        /// Running from a `~/Library/LaunchAgents` plist because SMAppService
        /// would not hold a registration on this ad-hoc signed build. It WILL
        /// launch at login; it is simply a different mechanism, and the UI says
        /// so rather than claiming the modern one is in use. See `LoginAgent`.
        case enabledViaAgent
        case unknown
    }

    /// True only when the OS says the login item is actually enabled.
    /// Setting registers/unregisters via SMAppService and never caches: the
    /// user can revoke in System Settings behind our back, and a checkbox that
    /// lies is worse than no checkbox.
    public var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                    // SMAppService accepted it — but on an ad-hoc signed build it
                    // will be dropped at boot (see LoginAgent for the measurement).
                    // If it did not actually reach `.enabled`, install the agent
                    // that does not depend on a code identity.
                    if SMAppService.mainApp.status != .enabled,
                       SMAppService.mainApp.status != .requiresApproval {
                        try LoginAgent.install()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled
                        || SMAppService.mainApp.status == .requiresApproval {
                        // Unregistering something that isn't registered throws;
                        // don't turn a no-op into an error banner.
                        try SMAppService.mainApp.unregister()
                    }
                    // Always remove the fallback, whichever path installed it.
                    // Leaving it behind is how an app the user switched off comes
                    // back at the next login.
                    LoginAgent.uninstall()
                }
                lastLaunchAtLoginError = nil
            } catch {
                // SMAppService refused. That is expected for an ad-hoc build, so
                // it is not the end of the attempt: try the agent, and only
                // report failure if that fails too.
                if newValue {
                    do {
                        try LoginAgent.install()
                        lastLaunchAtLoginError = nil
                    } catch let agentError {
                        lastLaunchAtLoginError = agentError
                    }
                } else {
                    LoginAgent.uninstall()
                    lastLaunchAtLoginError = error
                }
            }
            notify(Key.launchAtLogin)
        }
    }

    /// Set on the last failed register/unregister, cleared on success.
    public private(set) var lastLaunchAtLoginError: Error?

    public var launchAtLoginStatus: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // SMAppService has nothing. Before reporting that, ask whether the
        // fallback agent is installed and pointing at THIS executable — on an
        // ad-hoc build that is the mechanism actually in force, and reporting
        // "not registered" while a launchd job exists would be a lie in the
        // direction that matters (the user would tick the box again).
        case .notRegistered:
            return LoginAgent.isInstalled ? .enabledViaAgent : .notRegistered
        case .notFound:
            return LoginAgent.isInstalled ? .enabledViaAgent : .notFound
        @unknown default:
            return LoginAgent.isInstalled ? .enabledViaAgent : .unknown
        }
    }

    /// What to say for `.notFound`, which has two quite different causes.
    ///
    /// The UI asserted one of them: "this build is not an .app bundle". That is
    /// true for a `swift run` binary and false for every user of this project,
    /// because everyone builds from source and gets an ad-hoc signature —
    /// reported from a screenshot of Settings taken while running from
    /// ~/Applications/Anode.app, which is unambiguously a bundle.
    ///
    /// The real cause when bundled is that `SMAppService` identifies a login item
    /// by its CODE IDENTITY, and an ad-hoc signature has none to identify — no
    /// Team ID, nothing stable across rebuilds. Verified on the shipped bundle:
    /// `codesign -dvv` reports `Signature=adhoc`, `TeamIdentifier=not set`.
    ///
    /// Neither case is terminal, and the sentence has to say so: ticking the box
    /// installs a launch agent, which does not depend on a code identity and does
    /// work. Telling someone their app "is not a bundle" while they look at it in
    /// ~/Applications teaches them to distrust the rest of the window.
    public static func notFoundNote(isBundled: Bool) -> String {
        isBundled
            ? "Not registered. macOS registers login items by code identity, and "
            + "this build is ad-hoc signed — it has none. Ticking the box installs "
            + "a launch agent instead, which does not need one and does work."
            : "Not registered. This build is not an .app bundle; registering may "
            + "still work."
    }

    /// Is this running from a real `.app`, or from a bare `swift build` product?
    public static func isBundled(_ bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }

    /// Deep-links to System Settings → General → Login Items, for the
    /// `.requiresApproval` state where only the user can finish the job.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Re-poll SMAppService and tell observers. Call when a window becomes key:
    /// there is no notification for the user toggling us in System Settings.
    public func refreshLaunchAtLogin() {
        notify(Key.launchAtLogin)
    }

    // ── Observation ─────────────────────────────────────────────────────────

    /// Token-based observation. The handler fires on the main thread —
    /// synchronously when the write happened on main (so a prefs-window write
    /// updates the app in the same runloop pass), async otherwise. Retain the
    /// returned token; releasing it unobserves.
    public func observe(_ key: String, _ handler: @escaping () -> Void) -> AnyObject {
        let token = Token(owner: self)
        lock.lock(); observers[token.id] = (key, handler); lock.unlock()
        return token
    }

    private var observers: [UUID: (key: String, fire: () -> Void)] = [:]

    private final class Token {
        let id = UUID()
        private weak var owner: Settings?
        init(owner: Settings) { self.owner = owner }
        deinit { owner?.removeObserver(id) }
    }

    private func removeObserver(_ id: UUID) {
        lock.lock(); observers[id] = nil; lock.unlock()
    }

    private func notify(_ key: String) {
        lock.lock()
        let fires = observers.values.filter { $0.key == key || $0.key == Key.any }.map { $0.fire }
        lock.unlock()
        guard !fires.isEmpty else { return }
        // Handlers run outside the lock — they may re-enter Settings freely.
        let run = { for f in fires { f() } }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    /// Diff against the snapshot after any in-process UserDefaults change, so a
    /// write through a *different* Settings instance still notifies this one.
    /// Our own setters update the snapshot BEFORE touching UserDefaults, so the
    /// synchronous didChange re-entry sees no diff and can't double-fire.
    private func reconcile() {
        let now = Settings.readAll(defaults)
        lock.lock()
        let old = snapshot
        snapshot = now
        lock.unlock()
        guard old != now else { return }
        if old.sampleInterval != now.sampleInterval { notify(Key.sampleInterval) }
        if old.powerWindowHours != now.powerWindowHours { notify(Key.powerWindowHours) }
        if old.historyRetentionDays != now.historyRetentionDays { notify(Key.historyRetentionDays) }
        if old.minimumDisplayPercentPerHour != now.minimumDisplayPercentPerHour {
            notify(Key.minimumDisplayPercentPerHour)
        }
        if old.showDaemons != now.showDaemons { notify(Key.showDaemons) }
        if old.startInMenuBarOnly != now.startInMenuBarOnly { notify(Key.startInMenuBarOnly) }
        if old.batteryLogging != now.batteryLogging { notify(Key.batteryLogging) }
        if old.menuBarWidgetsEnabled != now.menuBarWidgetsEnabled {
            notify(Key.menuBarWidgetsEnabled)
        }
        if old.fanControlEnabled != now.fanControlEnabled { notify(Key.fanControlEnabled) }
        if old.fanDisclosureSeen != now.fanDisclosureSeen { notify(Key.fanDisclosureSeen) }
        if old.fanSyncEnabled != now.fanSyncEnabled { notify(Key.fanSyncEnabled) }
        if old.speedTestAgreed != now.speedTestAgreed { notify(Key.speedTestAgreed) }
        if old.menuBarWidgets != now.menuBarWidgets { notify(Key.menuBarWidgets) }
    }

    // ── Plumbing ────────────────────────────────────────────────────────────

    private static func storageKey(_ key: String) -> String { "anode." + key }

    private func writeDouble(_ key: String, _ path: WritableKeyPath<Values, Double>,
                             _ value: Double, _ def: Double, _ range: ClosedRange<Double>) {
        // NaN/inf: drop the write and keep the last good value. Clamping NaN is
        // undefined (every comparison is false), so refusing is the only honest move.
        guard value.isFinite else { return }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let old = Settings.readDouble(defaults, key, def, range)
        let neverStored = defaults.object(forKey: Settings.storageKey(key)) == nil
        guard clamped != old || neverStored else { return }
        lock.lock(); snapshot[keyPath: path] = clamped; lock.unlock()
        defaults.set(clamped, forKey: Settings.storageKey(key))
        if clamped != old { notify(key) }
    }

    /// Bool counterpart of `writeDouble`, sharing its two guards: a value that is
    /// already stored and unchanged writes nothing and notifies nobody, and a
    /// value equal to the DEFAULT is still written the first time so "never set"
    /// and "explicitly set to the default" stop being the same state on disk.
    private func writeBool(_ key: String, _ path: WritableKeyPath<Values, Bool>,
                           _ value: Bool, _ def: Bool) {
        let old = Settings.readBool(defaults, key, def)
        let neverStored = defaults.object(forKey: Settings.storageKey(key)) == nil
        guard value != old || neverStored else { return }
        lock.lock(); snapshot[keyPath: path] = value; lock.unlock()
        defaults.set(value, forKey: Settings.storageKey(key))
        if value != old { notify(key) }
    }

    private static func readDouble(_ d: UserDefaults, _ key: String,
                                   _ def: Double, _ range: ClosedRange<Double>) -> Double {
        guard let n = d.object(forKey: storageKey(key)) as? NSNumber else { return def }
        let v = n.doubleValue
        guard v.isFinite else { return def }  // hand-edited plist garbage
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private static func readBool(_ d: UserDefaults, _ key: String, _ def: Bool) -> Bool {
        // bool(forKey:) returns false for "absent" — indistinguishable from a
        // stored false, which would break a true default. object(forKey:) doesn't.
        (d.object(forKey: storageKey(key)) as? Bool) ?? def
    }

    private static func readWidgets(_ d: UserDefaults, _ def: [String]) -> [String] {
        guard let raw = d.stringArray(forKey: storageKey(Key.menuBarWidgets)) else { return def }
        return sanitizeWidgets(raw)
    }

    private static func sanitizeWidgets(_ ids: [String]) -> [String] {
        Array(sanitizeIDs(ids).prefix(maxMenuBarWidgets))
    }

    /// Trim, drop empties, dedupe, preserve order — and preserve UNKNOWN ids,
    /// which is the whole point: an id belonging to a module that isn't loaded
    /// right now must survive a round trip rather than be quietly forgotten.
    /// No cap; `sanitizeWidgets` applies the menu bar's own.
    private static func sanitizeIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    /// An id list that is ABSENT rather than defaulted: no stored value means
    /// the empty list, which callers read as "the user has never said".
    private static func readIDList(_ d: UserDefaults, _ key: String) -> [String] {
        sanitizeIDs(d.stringArray(forKey: storageKey(key)) ?? [])
    }

    private static func readAll(_ d: UserDefaults) -> Values {
        Values(sampleInterval: readDouble(d, Key.sampleInterval,
                                          Default.sampleInterval, sampleIntervalRange),
               powerWindowHours: readDouble(d, Key.powerWindowHours,
                                            Default.powerWindowHours, powerWindowHoursRange),
               historyRetentionDays: readDouble(d, Key.historyRetentionDays,
                                                Default.historyRetentionDays, historyRetentionDaysRange),
               minimumDisplayPercentPerHour: readDouble(d, Key.minimumDisplayPercentPerHour,
                                                        Default.minimumDisplayPercentPerHour, minimumDisplayRange),
               showDaemons: readBool(d, Key.showDaemons, Default.showDaemons),
               startInMenuBarOnly: readBool(d, Key.startInMenuBarOnly,
                                            Default.startInMenuBarOnly),
               batteryLogging: readBool(d, Key.batteryLogging, Default.batteryLogging),
               menuBarWidgetsEnabled: readBool(d, Key.menuBarWidgetsEnabled,
                                               Default.menuBarWidgetsEnabled),
               fanControlEnabled: readBool(d, Key.fanControlEnabled,
                                           Default.fanControlEnabled),
               fanSyncEnabled: readBool(d, Key.fanSyncEnabled, Default.fanSyncEnabled),
               speedTestAgreed: readBool(d, Key.speedTestAgreed, Default.speedTestAgreed),
               fanDisclosureSeen: readBool(d, Key.fanDisclosureSeen,
                                           Default.fanDisclosureSeen),
               menuBarWidgets: readWidgets(d, Default.menuBarWidgets),
               panelOrder: readIDList(d, Key.panelOrder),
               panelHidden: readIDList(d, Key.panelHidden))
    }
}


// ─────────────────────────────────────────────────────────────────────────────

extension Settings {

    /// Carry settings across the rename from BetterStats to Anode.
    ///
    /// COPIES rather than moves, and only into a domain that has nothing in it.
    /// A move would make going back to the old build a data loss, and this is
    /// exactly the kind of change someone reverts; leaving the old domain alone
    /// costs a few kilobytes and keeps that door open. Writing only into an empty
    /// destination means running it twice is harmless and it can never overwrite a
    /// preference set since the rename.
    ///
    /// Keys are unchanged by the rename — only the DOMAIN moved — so this is a
    /// straight copy rather than a mapping, and a key added later needs nothing
    /// here.
    /// `from` is injectable ONLY so a test can point it at a domain of its own.
    ///
    /// It has no other caller and no other reason to exist. The test that needed
    /// it wrote to the real `com.betterstats.settings` instead — and cleared it in
    /// its teardown, which destroyed a live machine's preferences. A migration
    /// test is precisely the test most likely to reach for a production domain,
    /// because the domain name is the thing under test, so the seam belongs here
    /// rather than in the discipline of whoever writes the next one.
    static func migrateFromPreviousName(into defaults: UserDefaults,
                                        from source: String = previousSuiteName) {
        guard let old = UserDefaults(suiteName: source),
              let values = old.persistentDomain(forName: source),
              !values.isEmpty
        else { return }
        // THE KEYS ARE RENAMED TOO, not just the domain.
        //
        // Every key is namespaced — `storageKey` prefixes them — and the rename
        // moved that prefix along with everything else. Copying keys verbatim put
        // the old values in the new domain under names the app no longer reads:
        // present, correct, and invisible. Caught by looking at the migrated
        // domain rather than by trusting that a copy is a copy.
        //
        // PER KEY, and only where the destination has nothing. That carries
        // everything the old build set, skips anything already answered under the
        // new name, and needs no marker to be safe to run twice.
        let oldPrefix = "betterstats."
        let newPrefix = "anode."
        for (key, value) in values {
            let renamed = key.hasPrefix(oldPrefix)
                ? newPrefix + key.dropFirst(oldPrefix.count)
                : key
            guard defaults.object(forKey: renamed) == nil else { continue }
            defaults.set(value, forKey: renamed)
        }
    }
}
