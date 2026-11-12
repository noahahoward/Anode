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
        public static let menuBarBackdropShowOnDesktop = "menuBarBackdropShowOnDesktop"
        public static let windowSwitcherEnabled = "windowSwitcherEnabled"
        public static let windowSwitcherTrigger = "windowSwitcherTrigger"
        public static let desktopSwitcherEnabled = "desktopSwitcherEnabled"
        public static let lidGlassEnabled = "lidGlassEnabled"
        public static let keepAwakeEnabled = "keepAwakeEnabled"
        public static let keyboardCleanerShortcutEnabled = "keyboardCleanerShortcutEnabled"
        public static let liveWallpaperEnabled = "liveWallpaperEnabled"
        public static let gameHUDEnabled = "gameHUDEnabled"
        public static let gameHUDCorner = "gameHUDCorner"
        public static let gameHUDExtraApps = "gameHUDExtraApps"
        public static let gameHUDHotCorner = "gameHUDHotCorner"
        public static let menuBarHiderEnabled = "menuBarHiderEnabled"
        public static let menuBarHiderAutoCloseSeconds = "menuBarHiderAutoCloseSeconds"
        public static let menuBarHiderArrangement = "menuBarHiderArrangement"
        public static let lidGlassIdleHz = "lidGlassIdleHz"
        public static let lidGlassTriggerAngle = "lidGlassTriggerAngle"
        public static let windowSnapperEnabled = "windowSnapperEnabled"
        public static let windowGroupsEnabled = "windowGroupsEnabled"
        public static let windowDragSnapEnabled = "windowDragSnapEnabled"
        public static let menuBarWidgetsCollapse = "menuBarWidgetsCollapse"
        public static let dockPreviewsEnabled = "dockPreviewsEnabled"
        public static let dockPreviewsHoldDock = "dockPreviewsHoldDock"
        public static let dockRaisesTileGroup = "dockRaisesTileGroup"
        public static let fanControlEnabled = "fanControlEnabled"
        /// Versioned by its name: the sheet now says the helper also sets the charge limit and cuts the charger,
        /// and someone who ticked "Don't show this again" on the fans-only words (stored as "fanDisclosureSeen")
        /// has not read that. A new name shows it to them once more.
        public static let fanDisclosureSeen = "fanDisclosureSeenWithCharger"
        public static let fanSyncEnabled = "fanSyncEnabled"
        public static let speedTestAgreed = "speedTestAgreed"
        public static let autoUpdateEnabled = "autoUpdateEnabled"
        public static let autoUpdatePromptSeen = "autoUpdatePromptSeen"
        public static let menuBarBackdropMode = "menuBarBackdropMode"
        public static let menuBarBackdropBlur = "menuBarBackdropBlur"
        /// The stats panel's arrangement. Empty until the user edits it — see
        /// `panelOrder` for why the default is not materialized here.
        public static let panelOrder = "panelOrder"
        public static let panelHidden = "panelHidden"
        /// Which lines the ledger screen's bottom (battery) graph draws.
        public static let ledgerGraphLines = "ledgerGraphLines"
        /// Charge Control. Its restore record is stored too but is not listed: nothing may observe it, and
        /// `chargeRestoreRecord` says why.
        public static let chargeControlEnabled = "chargeControlEnabled"
        public static let chargeLimit = "chargeLimit"
        public static let chargeSailingEnabled = "chargeSailingEnabled"
        public static let chargeSailingGap = "chargeSailingGap"
        public static let chargeHeatProtectionEnabled = "chargeHeatProtectionEnabled"
        public static let chargeMaxTemperatureC = "chargeMaxTemperatureC"
        public static let chargeStopWhenSleeping = "chargeStopWhenSleeping"
        public static let chargeAutomaticDischarge = "chargeAutomaticDischarge"
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
    /// Charge Control's three numbers. The limit and the gap take `ChargePolicy`'s own ranges, so what a person can
    /// ask for is what the policy acts on. The temperature's is set here: the policy takes the maximum as given,
    /// and this file is all that stands between a stored number and it.
    public static let chargeLimitRange: ClosedRange<Int> = ChargePolicy.osLimitRange
    public static let chargeSailingGapRange: ClosedRange<Int> = ChargePolicy.sailingGapRange
    public static let chargeMaxTemperatureRange: ClosedRange<Double> = 25...50

    /// What the ledger graph drew before it was customizable: the drain line, its
    /// mean since the lid opened, and the battery level. The strings are the
    /// persistence format, like the metric IDs — never rename a shipped one.
    public static let defaultLedgerGraphLines = ["graph.drain", "graph.mean", "battery.percent"]

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
        /// ON: the menu bar backdrop is drawn over the desktop as well, as it always was.
        static let menuBarBackdropShowOnDesktop = true
        /// OFF: a beta feature that takes over a system shortcut is something the user turns on.
        static let windowSwitcherEnabled = false
        /// Command-Option-Tab: the system's own Command-Tab is left alone unless the user chooses to replace it.
        static let windowSwitcherTrigger = WindowSwitcherTrigger.commandOption
        /// OFF: it takes over Option-Tab, so the user turns it on.
        static let desktopSwitcherEnabled = false
        static let lidGlassEnabled = false
        /// OFF: it adds a menu bar icon, so the user turns it on.
        static let keepAwakeEnabled = false
        /// OFF: it listens for a key combination everywhere, so the user turns it on.
        static let keyboardCleanerShortcutEnabled = false
        /// OFF: it puts a window over the desktop and plays video behind it, so the user turns it on.
        static let liveWallpaperEnabled = false
        /// OFF: it puts a window over fullscreen games, so the user turns it on.
        static let gameHUDEnabled = false
        static let gameHUDCorner = HUDCorner.topRight
        /// OFF: it puts a tiny window in a screen corner, so the user turns it on.
        static let gameHUDHotCorner = false
        /// OFF: it covers part of the menu bar, so the user turns it on.
        static let menuBarHiderEnabled = false
        static let menuBarHiderAutoCloseSeconds = 10
        static let lidGlassIdleHz = 8.0
        static let lidGlassTriggerAngle = 110.0
        /// OFF: it claims a set of global shortcuts another window manager may already own.
        static let windowSnapperEnabled = false
        /// OFF: it raises windows on its own and claims a few global shortcuts.
        static let windowGroupsEnabled = false
        /// OFF: it watches every drag, and macOS's own edge tiling would act on the same drags.
        static let windowDragSnapEnabled = false
        static let menuBarWidgetsCollapse = true
        /// OFF, like every beta feature that watches the Dock or the keyboard.
        static let dockPreviewsEnabled = false
        /// ON: with an auto-hiding Dock, the preview is otherwise left floating over nothing.
        static let dockPreviewsHoldDock = true
        /// ON: clicking an app's icon brings back the layout its window was tiled in.
        static let dockRaisesTileGroup = true
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
        /// OFF. Turning it on lets the app pull and rebuild itself without a
        /// Terminal window to watch, which is a thing someone chooses — the
        /// first launch asks, once, and `autoUpdatePromptSeen` records that it
        /// did.
        static let autoUpdateEnabled = false
        static let autoUpdatePromptSeen = false
        /// OFF: the menu bar backdrop is a beta feature, and the system's own bar is
        /// what a fresh install shows. The follow mode in particular needs Screen
        /// Recording, which nothing may ask for until the user has chosen it. Any
        /// mode other than the follow one stops all reading of other windows at
        /// once, whatever macOS has granted.
        static let menuBarBackdropMode = MenuBarBackdropMode.off
        static let menuBarBackdropBlur = 0.5
        /// OFF: it changes macOS's own charge limit and turns Optimized Battery Charging off, so the user turns it on.
        static let chargeControlEnabled = false
        /// 80 is the lowest of the five limits macOS takes from an ordinary app (`NativeChargeLimit.clientValues`,
        /// measured), so Charge Control switched on and left alone needs no root helper.
        static let chargeLimit = 80
        /// OFF, all four: each changes when the battery charges or drains, so each is asked for.
        static let chargeSailingEnabled = false
        static let chargeHeatProtectionEnabled = false
        static let chargeStopWhenSleeping = false
        static let chargeAutomaticDischarge = false
        /// The policy's own defaults (5 percent, 35 °C), so they are written down in one place.
        static let chargeSailingGap = ChargePolicy.defaultSailingGap
        static let chargeMaxTemperatureC = ChargePolicy.defaultMaxTemperatureC
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
            fanControlEnabled, fanSyncEnabled, speedTestAgreed,
            autoUpdateEnabled, autoUpdatePromptSeen: Bool
        var menuBarBackdropShowOnDesktop: Bool
        var windowSwitcherEnabled: Bool
        var windowSwitcherTrigger: WindowSwitcherTrigger
        var desktopSwitcherEnabled: Bool
        var windowSnapperEnabled: Bool
        var windowGroupsEnabled: Bool
        var windowDragSnapEnabled: Bool
        var menuBarWidgetsCollapse: Bool
        var dockPreviewsEnabled: Bool
        var dockPreviewsHoldDock: Bool
        var dockRaisesTileGroup: Bool
        var menuBarBackdropMode: MenuBarBackdropMode
        var menuBarBackdropBlur: Double
        var fanDisclosureSeen: Bool
        var menuBarWidgets: [String]
        var panelOrder: [String]
        var panelHidden: [String]
        var ledgerGraphLines: [String]
        var lidGlassEnabled: Bool
        var keepAwakeEnabled: Bool
        var keyboardCleanerShortcutEnabled: Bool
        var liveWallpaperEnabled: Bool
        var gameHUDEnabled: Bool
        var gameHUDCorner: HUDCorner
        var gameHUDExtraApps: [String]
        var gameHUDHotCorner: Bool
        var menuBarHiderEnabled: Bool
        var menuBarHiderAutoCloseSeconds: Int
        var menuBarHiderArrangement: BarArrangement?
        var lidGlassIdleHz, lidGlassTriggerAngle: Double
        var chargeControlEnabled, chargeSailingEnabled, chargeHeatProtectionEnabled,
            chargeStopWhenSleeping, chargeAutomaticDischarge: Bool
        var chargeLimit, chargeSailingGap: Int
        var chargeMaxTemperatureC: Double
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

    /// Check for new commits when the app starts, and rebuild if there are
    /// any. See `AutoUpdate` for what that is allowed to do unasked.
    public var autoUpdateEnabled: Bool {
        get { Settings.readBool(defaults, Key.autoUpdateEnabled, Default.autoUpdateEnabled) }
        set { writeBool(Key.autoUpdateEnabled, \.autoUpdateEnabled, newValue,
                        Default.autoUpdateEnabled) }
    }

    /// Has the one-time "turn on automatic updates?" question been asked?
    /// Separate from the answer: "Not Now" is an answer, and asking again at
    /// every launch would make it not one.
    public var autoUpdatePromptSeen: Bool {
        get { Settings.readBool(defaults, Key.autoUpdatePromptSeen,
                                Default.autoUpdatePromptSeen) }
        set { writeBool(Key.autoUpdatePromptSeen, \.autoUpdatePromptSeen, newValue,
                        Default.autoUpdatePromptSeen) }
    }

    /// What sits behind the menu bar. See `MenuBarBackdropMode`.
    public var menuBarBackdropMode: MenuBarBackdropMode {
        get {
            defaults.string(forKey: Settings.storageKey(Key.menuBarBackdropMode))
                .flatMap(MenuBarBackdropMode.init(rawValue:)) ?? Default.menuBarBackdropMode
        }
        set {
            guard newValue != menuBarBackdropMode else { return }
            defaults.set(newValue.rawValue, forKey: Settings.storageKey(Key.menuBarBackdropMode))
            reconcile()
        }
    }

    /// How strong the blur mode's blur is: 0 is see-through (the least blur), 1 the most.
    public var menuBarBackdropBlur: Double {
        get { Settings.readDouble(defaults, Key.menuBarBackdropBlur,
                                  Default.menuBarBackdropBlur, 0...1) }
        set {
            let v = min(max(newValue, 0), 1)
            guard v != menuBarBackdropBlur else { return }
            defaults.set(v, forKey: Settings.storageKey(Key.menuBarBackdropBlur))
            reconcile()
        }
    }

    /// The upstream commit whose automatic rebuild last failed, so a push that
    /// does not build is tried once rather than at every launch. Bookkeeping
    /// rather than a preference: nothing observes it.
    public var autoUpdateFailedCommit: String? {
        get { defaults.string(forKey: Settings.storageKey("autoUpdateFailedCommit")) }
        set { defaults.set(newValue, forKey: Settings.storageKey("autoUpdateFailedCommit")) }
    }

    /// The checkout path git has been seen to read while a window was up.
    /// `AutoUpdate.mayCheckUnasked` explains why that has to be known first.
    public var autoUpdateConfirmedPath: String? {
        get { defaults.string(forKey: Settings.storageKey("autoUpdateConfirmedPath")) }
        set { defaults.set(newValue, forKey: Settings.storageKey("autoUpdateConfirmedPath")) }
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
    /// Whether the menu bar backdrop is drawn on a display that is showing nothing but the desktop —
    /// no ordinary app window on it. Off hides the bar there and brings it back with the first window.
    public var menuBarBackdropShowOnDesktop: Bool {
        get { Settings.readBool(defaults, Key.menuBarBackdropShowOnDesktop,
                                Default.menuBarBackdropShowOnDesktop) }
        set { writeBool(Key.menuBarBackdropShowOnDesktop, \.menuBarBackdropShowOnDesktop, newValue,
                        Default.menuBarBackdropShowOnDesktop) }
    }

    /// Whether Anode's window switcher replaces the system's Command-Tab (Beta Features).
    public var windowSwitcherEnabled: Bool {
        get { Settings.readBool(defaults, Key.windowSwitcherEnabled, Default.windowSwitcherEnabled) }
        set { writeBool(Key.windowSwitcherEnabled, \.windowSwitcherEnabled, newValue,
                        Default.windowSwitcherEnabled) }
    }

    /// Whether Anode's window actions (halves, thirds, maximize ...) answer their shortcuts (Beta Features).
    public var windowSnapperEnabled: Bool {
        get { Settings.readBool(defaults, Key.windowSnapperEnabled, Default.windowSnapperEnabled) }
        set { writeBool(Key.windowSnapperEnabled, \.windowSnapperEnabled, newValue, Default.windowSnapperEnabled) }
    }

    /// Whether dragging a window to a screen edge snaps it (Beta Features).
    /// Shrink the menu bar widgets when macOS hides some of them for lack of room (the default). Off keeps
    /// them as configured whatever the front app's menus do.
    public var menuBarWidgetsCollapse: Bool {
        get { Settings.readBool(defaults, Key.menuBarWidgetsCollapse, Default.menuBarWidgetsCollapse) }
        set { writeBool(Key.menuBarWidgetsCollapse, \.menuBarWidgetsCollapse, newValue, Default.menuBarWidgetsCollapse) }
    }

    public var windowDragSnapEnabled: Bool {
        get { Settings.readBool(defaults, Key.windowDragSnapEnabled, Default.windowDragSnapEnabled) }
        set { writeBool(Key.windowDragSnapEnabled, \.windowDragSnapEnabled, newValue, Default.windowDragSnapEnabled) }
    }

    /// Whether window groups (windows that come forward together) are on (Beta Features).
    public var windowGroupsEnabled: Bool {
        get { Settings.readBool(defaults, Key.windowGroupsEnabled, Default.windowGroupsEnabled) }
        set { writeBool(Key.windowGroupsEnabled, \.windowGroupsEnabled, newValue, Default.windowGroupsEnabled) }
    }

    /// The keys that open Anode's window switcher.
    public var windowSwitcherTrigger: WindowSwitcherTrigger {
        get {
            defaults.string(forKey: Settings.storageKey(Key.windowSwitcherTrigger))
                .flatMap(WindowSwitcherTrigger.init(rawValue:)) ?? Default.windowSwitcherTrigger
        }
        set {
            guard newValue != windowSwitcherTrigger else { return }
            defaults.set(newValue.rawValue, forKey: Settings.storageKey(Key.windowSwitcherTrigger))
            reconcile()
        }
    }

    /// Whether Anode's desktop (Spaces) switcher answers Option-Tab (Beta Features).
    public var desktopSwitcherEnabled: Bool {
        get { Settings.readBool(defaults, Key.desktopSwitcherEnabled, Default.desktopSwitcherEnabled) }
        set { writeBool(Key.desktopSwitcherEnabled, \.desktopSwitcherEnabled, newValue, Default.desktopSwitcherEnabled) }
    }

    /// Whether the lid-close glass effect runs (Beta Features). Off until asked for.
    public var lidGlassEnabled: Bool {
        get { Settings.readBool(defaults, Key.lidGlassEnabled, Default.lidGlassEnabled) }
        set { writeBool(Key.lidGlassEnabled, \.lidGlassEnabled, newValue, Default.lidGlassEnabled) }
    }

    /// Whether the Keep Awake icon is in the menu bar (Beta Features). Off until asked for.
    public var keepAwakeEnabled: Bool {
        get { Settings.readBool(defaults, Key.keepAwakeEnabled, Default.keepAwakeEnabled) }
        set { writeBool(Key.keepAwakeEnabled, \.keepAwakeEnabled, newValue, Default.keepAwakeEnabled) }
    }

    /// Whether live wallpapers are running (Beta Features). Off until asked for.
    public var liveWallpaperEnabled: Bool {
        get { Settings.readBool(defaults, Key.liveWallpaperEnabled, Default.liveWallpaperEnabled) }
        set { writeBool(Key.liveWallpaperEnabled, \.liveWallpaperEnabled, newValue, Default.liveWallpaperEnabled) }
    }

    /// Whether the Game Mode strip is shown over a game (Beta Features). Off until asked for.
    public var gameHUDEnabled: Bool {
        get { Settings.readBool(defaults, Key.gameHUDEnabled, Default.gameHUDEnabled) }
        set { writeBool(Key.gameHUDEnabled, \.gameHUDEnabled, newValue, Default.gameHUDEnabled) }
    }

    /// The corner the Game Mode strip sits in. An unknown stored value reads as the default.
    public var gameHUDCorner: HUDCorner {
        get { Settings.readHUDCorner(defaults) }
        set {
            guard newValue != gameHUDCorner else { return }
            lock.lock(); snapshot.gameHUDCorner = newValue; lock.unlock()
            defaults.set(newValue.rawValue, forKey: Settings.storageKey(Key.gameHUDCorner))
            notify(Key.gameHUDCorner)
        }
    }

    /// Bundle ids of apps the owner added by hand, treated as games whatever their category says.
    public var gameHUDExtraApps: [String] {
        get { Settings.readIDList(defaults, Key.gameHUDExtraApps) }
        set { writeIDList(newValue, key: Key.gameHUDExtraApps, keyPath: \.gameHUDExtraApps) }
    }

    /// Whether the pointer touching the strip's corner shows the strip for a few seconds, in any app (Beta Features).
    public var gameHUDHotCorner: Bool {
        get { Settings.readBool(defaults, Key.gameHUDHotCorner, Default.gameHUDHotCorner) }
        set { writeBool(Key.gameHUDHotCorner, \.gameHUDHotCorner, newValue, Default.gameHUDHotCorner) }
    }

    /// Whether the menu bar hider is on (Beta Features). Off until asked for: it puts a cover over part of the bar.
    public var menuBarHiderEnabled: Bool {
        get { Settings.readBool(defaults, Key.menuBarHiderEnabled, Default.menuBarHiderEnabled) }
        set { writeBool(Key.menuBarHiderEnabled, \.menuBarHiderEnabled, newValue, Default.menuBarHiderEnabled) }
    }

    /// Seconds the pill stays open before it closes itself; 0 means until the owner closes it. Only 0, 5, 10 and 30 are
    /// offered, so anything else reads as the default 10.
    public var menuBarHiderAutoCloseSeconds: Int {
        get { Settings.readAutoClose(defaults) }
        set {
            let clean = Settings.autoCloseChoices.contains(newValue) ? newValue : Default.menuBarHiderAutoCloseSeconds
            guard clean != menuBarHiderAutoCloseSeconds else { return }
            lock.lock(); snapshot.menuBarHiderAutoCloseSeconds = clean; lock.unlock()
            defaults.set(clean, forKey: Settings.storageKey(Key.menuBarHiderAutoCloseSeconds))
            notify(Key.menuBarHiderAutoCloseSeconds)
        }
    }
    public static let autoCloseChoices = [0, 5, 10, 30]

    /// Which icons are always on the bar and the order of the rest. nil until the owner has arranged them (or the first
    /// read of the bar has stored the default). Stored as JSON; anything unreadable reads as nil.
    public var menuBarHiderArrangement: BarArrangement? {
        get { Settings.readArrangement(defaults) }
        set {
            guard newValue != menuBarHiderArrangement else { return }
            lock.lock(); snapshot.menuBarHiderArrangement = newValue; lock.unlock()
            let key = Settings.storageKey(Key.menuBarHiderArrangement)
            if let newValue, let data = try? JSONEncoder().encode(newValue), let text = String(data: data, encoding: .utf8) {
                defaults.set(text, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            notify(Key.menuBarHiderArrangement)
        }
    }

    private static func readAutoClose(_ d: UserDefaults) -> Int {
        let key = storageKey(Key.menuBarHiderAutoCloseSeconds)
        guard d.object(forKey: key) != nil else { return Default.menuBarHiderAutoCloseSeconds }
        let n = d.integer(forKey: key)
        return autoCloseChoices.contains(n) ? n : Default.menuBarHiderAutoCloseSeconds
    }

    private static func readArrangement(_ d: UserDefaults) -> BarArrangement? {
        guard let text = d.string(forKey: storageKey(Key.menuBarHiderArrangement)),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BarArrangement.self, from: data)
    }

    private static func readHUDCorner(_ d: UserDefaults) -> HUDCorner {
        d.string(forKey: storageKey(Key.gameHUDCorner)).flatMap(HUDCorner.init(rawValue:)) ?? Default.gameHUDCorner
    }

    /// Whether the keyboard cleaner's start shortcut is listened for (Beta Features). The cleaner can always be started
    /// from its section; this only governs the shortcut, which is a standing key listener. Off until asked for.
    public var keyboardCleanerShortcutEnabled: Bool {
        get { Settings.readBool(defaults, Key.keyboardCleanerShortcutEnabled, Default.keyboardCleanerShortcutEnabled) }
        set { writeBool(Key.keyboardCleanerShortcutEnabled, \.keyboardCleanerShortcutEnabled, newValue, Default.keyboardCleanerShortcutEnabled) }
    }

    /// How often the lid angle is read while the lid is open and still, 4 to 30 times a second.
    public var lidGlassIdleHz: Double {
        get { Settings.readDouble(defaults, Key.lidGlassIdleHz, Default.lidGlassIdleHz, Self.lidGlassIdleHzRange) }
        set { writeDouble(Key.lidGlassIdleHz, \.lidGlassIdleHz, newValue, Default.lidGlassIdleHz, Self.lidGlassIdleHzRange) }
    }
    public static let lidGlassIdleHzRange: ClosedRange<Double> = 4...30

    /// The lid angle, in degrees, below which a closing lid starts the effect.
    public var lidGlassTriggerAngle: Double {
        get { Settings.readDouble(defaults, Key.lidGlassTriggerAngle, Default.lidGlassTriggerAngle, Self.lidGlassTriggerRange) }
        set { writeDouble(Key.lidGlassTriggerAngle, \.lidGlassTriggerAngle, newValue, Default.lidGlassTriggerAngle, Self.lidGlassTriggerRange) }
    }
    public static let lidGlassTriggerRange: ClosedRange<Double> = 60...150

    /// Whether resting the pointer on a Dock icon shows that app's windows (Beta Features).
    public var dockPreviewsEnabled: Bool {
        get { Settings.readBool(defaults, Key.dockPreviewsEnabled, Default.dockPreviewsEnabled) }
        set { writeBool(Key.dockPreviewsEnabled, \.dockPreviewsEnabled, newValue, Default.dockPreviewsEnabled) }
    }

    /// Whether an auto-hiding Dock is kept up while a Dock preview is open (Beta Features).
    public var dockPreviewsHoldDock: Bool {
        get { Settings.readBool(defaults, Key.dockPreviewsHoldDock, Default.dockPreviewsHoldDock) }
        set { writeBool(Key.dockPreviewsHoldDock, \.dockPreviewsHoldDock, newValue, Default.dockPreviewsHoldDock) }
    }

    /// Whether clicking a Dock icon also brings forward the windows tiled with that app's window.
    public var dockRaisesTileGroup: Bool {
        get { Settings.readBool(defaults, Key.dockRaisesTileGroup, Default.dockRaisesTileGroup) }
        set { writeBool(Key.dockRaisesTileGroup, \.dockRaisesTileGroup, newValue, Default.dockRaisesTileGroup) }
    }

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

    /// IDs of the lines the ledger graph draws. ABSENT means the default set; a
    /// stored empty list means the user unticked everything, which is a different
    /// answer and must stay one. Unknown IDs are kept, so a line from a build that
    /// is not running right now survives a round trip.
    public var ledgerGraphLines: [String] {
        get { Settings.readLedgerLines(defaults) }
        set {
            let clean = Settings.sanitizeIDs(newValue)
            let old = ledgerGraphLines
            let neverStored = defaults.object(forKey: Settings.storageKey(Key.ledgerGraphLines)) == nil
            guard clean != old || neverStored else { return }
            lock.lock(); snapshot.ledgerGraphLines = clean; lock.unlock()
            defaults.set(clean, forKey: Settings.storageKey(Key.ledgerGraphLines))
            if clean != old { notify(Key.ledgerGraphLines) }
        }
    }

    private static func readLedgerLines(_ d: UserDefaults) -> [String] {
        guard let raw = d.stringArray(forKey: storageKey(Key.ledgerGraphLines)) else {
            return defaultLedgerGraphLines
        }
        return sanitizeIDs(raw)
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

    // ── Charge Control (Beta Features) ──────────────────────────────────────

    /// Whether Charge Control is on (Beta Features). Off until asked for: it changes macOS's own charge limit and
    /// turns Optimized Battery Charging off for as long as it runs.
    public var chargeControlEnabled: Bool {
        get { Settings.readBool(defaults, Key.chargeControlEnabled, Default.chargeControlEnabled) }
        set { writeBool(Key.chargeControlEnabled, \.chargeControlEnabled, newValue, Default.chargeControlEnabled) }
    }

    /// The percent the battery charges to, 20 to 100.
    ///
    /// This number does not stay in the app. `ChargePolicy` hands it to macOS as the charge limit and drains to it
    /// as given: the policy clamps the limit it sets but not the level a discharge stops at, so a stored 5 with
    /// Automatic Discharge on would run the pack down to 10% on the adapter. That is why it is clamped on the read
    /// as well as the write. The plist is also written by `defaults write` and by builds other than this one.
    public var chargeLimit: Int {
        get { Settings.readInt(defaults, Key.chargeLimit, Default.chargeLimit, Settings.chargeLimitRange) }
        set { writeInt(Key.chargeLimit, \.chargeLimit, newValue, Default.chargeLimit, Settings.chargeLimitRange) }
    }

    /// Whether Sailing Mode is on: once the limit is reached the battery rests in a band below it, and is not
    /// charged again until it has fallen through the band.
    public var chargeSailingEnabled: Bool {
        get { Settings.readBool(defaults, Key.chargeSailingEnabled, Default.chargeSailingEnabled) }
        set { writeBool(Key.chargeSailingEnabled, \.chargeSailingEnabled, newValue, Default.chargeSailingEnabled) }
    }

    /// How deep that band is: how far below the limit the battery may fall before Sailing Mode charges it again,
    /// 1 to 30 percent.
    public var chargeSailingGap: Int {
        get { Settings.readInt(defaults, Key.chargeSailingGap, Default.chargeSailingGap,
                               Settings.chargeSailingGapRange) }
        set { writeInt(Key.chargeSailingGap, \.chargeSailingGap, newValue, Default.chargeSailingGap,
                       Settings.chargeSailingGapRange) }
    }

    /// Whether Heat Protection is on: charging is held while the pack is at or above `chargeMaxTemperatureC`, and
    /// for five minutes after it has cooled.
    public var chargeHeatProtectionEnabled: Bool {
        get { Settings.readBool(defaults, Key.chargeHeatProtectionEnabled, Default.chargeHeatProtectionEnabled) }
        set { writeBool(Key.chargeHeatProtectionEnabled, \.chargeHeatProtectionEnabled, newValue,
                        Default.chargeHeatProtectionEnabled) }
    }

    /// The pack temperature, in °C, at or above which Heat Protection holds the charge. 25 to 50.
    ///
    /// The range matters more here than for any other number in this file. The policy compares the pack against
    /// this as given, so a stored 0 would call every pack hot and hold charging for as long as the feature was on,
    /// and a stored NaN would call none hot and switch the protection off without a word. Neither gets through the
    /// setter and neither survives a read: out of range reads as the nearest end, and anything that is not a finite
    /// number reads as the default.
    public var chargeMaxTemperatureC: Double {
        get { Settings.readDouble(defaults, Key.chargeMaxTemperatureC, Default.chargeMaxTemperatureC,
                                  Settings.chargeMaxTemperatureRange) }
        set { writeDouble(Key.chargeMaxTemperatureC, \.chargeMaxTemperatureC, newValue,
                          Default.chargeMaxTemperatureC, Settings.chargeMaxTemperatureRange) }
    }

    /// Whether charging stops while the Mac sleeps on the adapter: the charge is held where it was when it slept.
    public var chargeStopWhenSleeping: Bool {
        get { Settings.readBool(defaults, Key.chargeStopWhenSleeping, Default.chargeStopWhenSleeping) }
        set { writeBool(Key.chargeStopWhenSleeping, \.chargeStopWhenSleeping, newValue,
                        Default.chargeStopWhenSleeping) }
    }

    /// Whether a battery above the limit is drained down to it on the adapter without being asked.
    public var chargeAutomaticDischarge: Bool {
        get { Settings.readBool(defaults, Key.chargeAutomaticDischarge, Default.chargeAutomaticDischarge) }
        set { writeBool(Key.chargeAutomaticDischarge, \.chargeAutomaticDischarge, newValue,
                        Default.chargeAutomaticDischarge) }
    }

    /// How macOS's own charge limit and Optimized Battery Charging were set before Charge Control first changed
    /// them, as the JSON of a `NativeChargeState`. nil when there is nothing to put back.
    ///
    /// Written once, the first time Charge Control is switched on, and cleared once that state has been restored.
    /// It is stored and not just held in memory because the limit outlives the app (macOS keeps it in its own
    /// preferences, measured in plan 0), so the way back has to survive a quit or a crash as well.
    ///
    /// Bookkeeping rather than a preference, like `autoUpdateFailedCommit`: it has no observation key and a write
    /// notifies nobody. Its one writer is Charge Control's own controller, in the middle of switching itself on or
    /// off, and a notification there would call that controller back into a switch it has not finished.
    ///
    /// Clearing removes the key, so "no record" is one state on disk. Anything stored that is not a string reads as
    /// nil too: `string(forKey:)` would hand a stray number back as text, the controller would take that for a
    /// record it already has, and the real state would never be written down.
    public var chargeRestoreRecord: String? {
        get { defaults.object(forKey: Settings.chargeRestoreRecordKey) as? String }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Settings.chargeRestoreRecordKey)
            } else {
                defaults.removeObject(forKey: Settings.chargeRestoreRecordKey)
            }
        }
    }
    private static let chargeRestoreRecordKey = storageKey("chargeRestoreRecord")

    /// True from just before Charge Control asks the helper to discharge until a helper that is running has said
    /// the charger is connected. While it is true the charger may be cut off with nothing watching it.
    ///
    /// A cut outlives the helper that made it: a helper that dies leaves the charger off, the Mac draining on the
    /// adapter, and only a fresh helper (started by the next connection to the installed daemon) switches it back
    /// on. So the debt is written down, like `chargeRestoreRecord`, to survive a quit or a crash, and the next
    /// launch pays it whether Charge Control is on or off.
    ///
    /// Bookkeeping, not a preference: no observation key, nothing is notified. Clearing removes the key.
    public var chargeCutUnconfirmed: Bool {
        get { (defaults.object(forKey: Settings.chargeCutUnconfirmedKey) as? Bool) ?? false }
        set {
            if newValue {
                defaults.set(true, forKey: Settings.chargeCutUnconfirmedKey)
            } else {
                defaults.removeObject(forKey: Settings.chargeCutUnconfirmedKey)
            }
        }
    }
    private static let chargeCutUnconfirmedKey = storageKey("chargeCutUnconfirmed")

    /// Write what this handle holds to disk now rather than when `cfprefsd` gets to it.
    ///
    /// For Charge Control's bookkeeping: it stores `chargeRestoreRecord` (or `chargeCutUnconfirmed`) and then
    /// changes something that outlives the app. If the app died between the two with the note still in memory,
    /// nothing would know how to put it back.
    public func flush() {
        defaults.synchronize()
    }

    /// Every charge setting `ChargePolicy` decides from, read together.
    ///
    /// The values come through the getters above, so they are already inside their ranges. That is the point of
    /// building the snapshot here: the policy trusts `limit` and `maxTemperatureC` as given, and this is the one
    /// place that hands them to it.
    public func chargeSettingsSnapshot() -> ChargeSettingsSnapshot {
        ChargeSettingsSnapshot(limit: chargeLimit,
                               sailingEnabled: chargeSailingEnabled, sailingGap: chargeSailingGap,
                               heatProtectionEnabled: chargeHeatProtectionEnabled,
                               maxTemperatureC: chargeMaxTemperatureC,
                               stopWhenSleeping: chargeStopWhenSleeping,
                               automaticDischarge: chargeAutomaticDischarge)
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
        if old.menuBarBackdropShowOnDesktop != now.menuBarBackdropShowOnDesktop {
            notify(Key.menuBarBackdropShowOnDesktop)
        }
        if old.windowSwitcherEnabled != now.windowSwitcherEnabled { notify(Key.windowSwitcherEnabled) }
        if old.windowSwitcherTrigger != now.windowSwitcherTrigger { notify(Key.windowSwitcherTrigger) }
        if old.desktopSwitcherEnabled != now.desktopSwitcherEnabled { notify(Key.desktopSwitcherEnabled) }
        if old.lidGlassEnabled != now.lidGlassEnabled { notify(Key.lidGlassEnabled) }
        if old.keepAwakeEnabled != now.keepAwakeEnabled { notify(Key.keepAwakeEnabled) }
        if old.keyboardCleanerShortcutEnabled != now.keyboardCleanerShortcutEnabled { notify(Key.keyboardCleanerShortcutEnabled) }
        if old.liveWallpaperEnabled != now.liveWallpaperEnabled { notify(Key.liveWallpaperEnabled) }
        if old.gameHUDEnabled != now.gameHUDEnabled { notify(Key.gameHUDEnabled) }
        if old.gameHUDCorner != now.gameHUDCorner { notify(Key.gameHUDCorner) }
        if old.gameHUDExtraApps != now.gameHUDExtraApps { notify(Key.gameHUDExtraApps) }
        if old.gameHUDHotCorner != now.gameHUDHotCorner { notify(Key.gameHUDHotCorner) }
        if old.menuBarHiderEnabled != now.menuBarHiderEnabled { notify(Key.menuBarHiderEnabled) }
        if old.menuBarHiderAutoCloseSeconds != now.menuBarHiderAutoCloseSeconds { notify(Key.menuBarHiderAutoCloseSeconds) }
        if old.menuBarHiderArrangement != now.menuBarHiderArrangement { notify(Key.menuBarHiderArrangement) }
        if old.lidGlassIdleHz != now.lidGlassIdleHz { notify(Key.lidGlassIdleHz) }
        if old.lidGlassTriggerAngle != now.lidGlassTriggerAngle { notify(Key.lidGlassTriggerAngle) }
        if old.windowSnapperEnabled != now.windowSnapperEnabled { notify(Key.windowSnapperEnabled) }
        if old.windowGroupsEnabled != now.windowGroupsEnabled { notify(Key.windowGroupsEnabled) }
        if old.windowDragSnapEnabled != now.windowDragSnapEnabled { notify(Key.windowDragSnapEnabled) }
        if old.menuBarWidgetsCollapse != now.menuBarWidgetsCollapse { notify(Key.menuBarWidgetsCollapse) }
        if old.dockPreviewsEnabled != now.dockPreviewsEnabled { notify(Key.dockPreviewsEnabled) }
        if old.dockPreviewsHoldDock != now.dockPreviewsHoldDock { notify(Key.dockPreviewsHoldDock) }
        if old.dockRaisesTileGroup != now.dockRaisesTileGroup { notify(Key.dockRaisesTileGroup) }
        if old.menuBarWidgetsEnabled != now.menuBarWidgetsEnabled {
            notify(Key.menuBarWidgetsEnabled)
        }
        if old.fanControlEnabled != now.fanControlEnabled { notify(Key.fanControlEnabled) }
        if old.fanDisclosureSeen != now.fanDisclosureSeen { notify(Key.fanDisclosureSeen) }
        if old.fanSyncEnabled != now.fanSyncEnabled { notify(Key.fanSyncEnabled) }
        if old.speedTestAgreed != now.speedTestAgreed { notify(Key.speedTestAgreed) }
        if old.autoUpdateEnabled != now.autoUpdateEnabled { notify(Key.autoUpdateEnabled) }
        if old.menuBarBackdropMode != now.menuBarBackdropMode { notify(Key.menuBarBackdropMode) }
        if old.menuBarBackdropBlur != now.menuBarBackdropBlur {
            notify(Key.menuBarBackdropBlur)
        }
        if old.autoUpdatePromptSeen != now.autoUpdatePromptSeen {
            notify(Key.autoUpdatePromptSeen)
        }
        if old.menuBarWidgets != now.menuBarWidgets { notify(Key.menuBarWidgets) }
        if old.ledgerGraphLines != now.ledgerGraphLines { notify(Key.ledgerGraphLines) }
        if old.chargeControlEnabled != now.chargeControlEnabled { notify(Key.chargeControlEnabled) }
        if old.chargeLimit != now.chargeLimit { notify(Key.chargeLimit) }
        if old.chargeSailingEnabled != now.chargeSailingEnabled { notify(Key.chargeSailingEnabled) }
        if old.chargeSailingGap != now.chargeSailingGap { notify(Key.chargeSailingGap) }
        if old.chargeHeatProtectionEnabled != now.chargeHeatProtectionEnabled { notify(Key.chargeHeatProtectionEnabled) }
        if old.chargeMaxTemperatureC != now.chargeMaxTemperatureC { notify(Key.chargeMaxTemperatureC) }
        if old.chargeStopWhenSleeping != now.chargeStopWhenSleeping { notify(Key.chargeStopWhenSleeping) }
        if old.chargeAutomaticDischarge != now.chargeAutomaticDischarge { notify(Key.chargeAutomaticDischarge) }
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

    /// Int counterpart of `writeDouble`, with the same guards as `writeBool`. There is no NaN to refuse: every
    /// Int clamps.
    private func writeInt(_ key: String, _ path: WritableKeyPath<Values, Int>,
                          _ value: Int, _ def: Int, _ range: ClosedRange<Int>) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let old = Settings.readInt(defaults, key, def, range)
        let neverStored = defaults.object(forKey: Settings.storageKey(key)) == nil
        guard clamped != old || neverStored else { return }
        lock.lock(); snapshot[keyPath: path] = clamped; lock.unlock()
        defaults.set(clamped, forKey: Settings.storageKey(key))
        if clamped != old { notify(key) }
    }

    /// The number stored under a key, or nil when what is there is not one: nothing, a string, a date, NaN,
    /// infinity (hand-edited plist garbage), or a Boolean.
    ///
    /// The Boolean is the one that needs saying. It bridges to `NSNumber`, so without the check a stored `true`
    /// is 1 and clamps to the bottom of whatever range it lands in. For Charge Control that is a limit of 20, or
    /// a maximum temperature of 25 °C. MEASURED 2026-11-11 on a Mac17,9: the pack read 27.0 to 31.8 °C, so Heat
    /// Protection at 25 would have held the charge at every reading. A Boolean is no more a number than the
    /// string "abc" is, and it reads as the default like one.
    private static func storedNumber(_ d: UserDefaults, _ key: String) -> Double? {
        guard let n = d.object(forKey: storageKey(key)) as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    private static func readDouble(_ d: UserDefaults, _ key: String,
                                   _ def: Double, _ range: ClosedRange<Double>) -> Double {
        guard let v = storedNumber(d, key) else { return def }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// Int counterpart of `readDouble`, with the same answers: nothing stored, or something that is not a number,
    /// reads as the default, and a number outside the range reads as the nearest end of it. A fraction reads as the
    /// nearest whole number.
    ///
    /// It goes through `Double` because `integer(forKey:)` cannot refuse anything. MEASURED (macOS 27, arm64): it
    /// reads a stored NaN and the text "abc" as 0, and +infinity and 1e300 as `Int.max`, so garbage would come
    /// back as the bottom or the top of the range and nothing would show it had ever been garbage. Clamping as a
    /// `Double` first also means `Int(_:)`, which traps on a value it cannot hold, only ever sees one that is
    /// already inside the range.
    private static func readInt(_ d: UserDefaults, _ key: String,
                                _ def: Int, _ range: ClosedRange<Int>) -> Int {
        guard let v = storedNumber(d, key) else { return def }
        return Int(min(max(v, Double(range.lowerBound)), Double(range.upperBound)).rounded())
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
               autoUpdateEnabled: readBool(d, Key.autoUpdateEnabled,
                                           Default.autoUpdateEnabled),
               autoUpdatePromptSeen: readBool(d, Key.autoUpdatePromptSeen,
                                              Default.autoUpdatePromptSeen),
               menuBarBackdropShowOnDesktop: readBool(d, Key.menuBarBackdropShowOnDesktop,
                                                      Default.menuBarBackdropShowOnDesktop),
               windowSwitcherEnabled: readBool(d, Key.windowSwitcherEnabled, Default.windowSwitcherEnabled),
               windowSwitcherTrigger: d.string(forKey: storageKey(Key.windowSwitcherTrigger))
                   .flatMap(WindowSwitcherTrigger.init(rawValue:)) ?? Default.windowSwitcherTrigger,
               desktopSwitcherEnabled: readBool(d, Key.desktopSwitcherEnabled, Default.desktopSwitcherEnabled),
               windowSnapperEnabled: readBool(d, Key.windowSnapperEnabled, Default.windowSnapperEnabled),
               windowGroupsEnabled: readBool(d, Key.windowGroupsEnabled, Default.windowGroupsEnabled),
               windowDragSnapEnabled: readBool(d, Key.windowDragSnapEnabled, Default.windowDragSnapEnabled),
               menuBarWidgetsCollapse: readBool(d, Key.menuBarWidgetsCollapse, Default.menuBarWidgetsCollapse),
               dockPreviewsEnabled: readBool(d, Key.dockPreviewsEnabled, Default.dockPreviewsEnabled),
               dockPreviewsHoldDock: readBool(d, Key.dockPreviewsHoldDock, Default.dockPreviewsHoldDock),
               dockRaisesTileGroup: readBool(d, Key.dockRaisesTileGroup, Default.dockRaisesTileGroup),
               menuBarBackdropMode: d.string(forKey: storageKey(Key.menuBarBackdropMode))
                   .flatMap(MenuBarBackdropMode.init(rawValue:)) ?? Default.menuBarBackdropMode,
               menuBarBackdropBlur: readDouble(d, Key.menuBarBackdropBlur,
                                                       Default.menuBarBackdropBlur, 0...1),
               fanDisclosureSeen: readBool(d, Key.fanDisclosureSeen,
                                           Default.fanDisclosureSeen),
               menuBarWidgets: readWidgets(d, Default.menuBarWidgets),
               panelOrder: readIDList(d, Key.panelOrder),
               panelHidden: readIDList(d, Key.panelHidden),
               ledgerGraphLines: readLedgerLines(d),
               lidGlassEnabled: readBool(d, Key.lidGlassEnabled, Default.lidGlassEnabled),
               keepAwakeEnabled: readBool(d, Key.keepAwakeEnabled, Default.keepAwakeEnabled),
               keyboardCleanerShortcutEnabled: readBool(d, Key.keyboardCleanerShortcutEnabled, Default.keyboardCleanerShortcutEnabled),
               liveWallpaperEnabled: readBool(d, Key.liveWallpaperEnabled, Default.liveWallpaperEnabled),
               gameHUDEnabled: readBool(d, Key.gameHUDEnabled, Default.gameHUDEnabled),
               gameHUDCorner: readHUDCorner(d),
               gameHUDExtraApps: readIDList(d, Key.gameHUDExtraApps),
               gameHUDHotCorner: readBool(d, Key.gameHUDHotCorner, Default.gameHUDHotCorner),
               menuBarHiderEnabled: readBool(d, Key.menuBarHiderEnabled, Default.menuBarHiderEnabled),
               menuBarHiderAutoCloseSeconds: readAutoClose(d),
               menuBarHiderArrangement: readArrangement(d),
               lidGlassIdleHz: readDouble(d, Key.lidGlassIdleHz, Default.lidGlassIdleHz, lidGlassIdleHzRange),
               lidGlassTriggerAngle: readDouble(d, Key.lidGlassTriggerAngle, Default.lidGlassTriggerAngle,
                                                lidGlassTriggerRange),
               chargeControlEnabled: readBool(d, Key.chargeControlEnabled, Default.chargeControlEnabled),
               chargeSailingEnabled: readBool(d, Key.chargeSailingEnabled, Default.chargeSailingEnabled),
               chargeHeatProtectionEnabled: readBool(d, Key.chargeHeatProtectionEnabled,
                                                     Default.chargeHeatProtectionEnabled),
               chargeStopWhenSleeping: readBool(d, Key.chargeStopWhenSleeping, Default.chargeStopWhenSleeping),
               chargeAutomaticDischarge: readBool(d, Key.chargeAutomaticDischarge, Default.chargeAutomaticDischarge),
               chargeLimit: readInt(d, Key.chargeLimit, Default.chargeLimit, chargeLimitRange),
               chargeSailingGap: readInt(d, Key.chargeSailingGap, Default.chargeSailingGap, chargeSailingGapRange),
               chargeMaxTemperatureC: readDouble(d, Key.chargeMaxTemperatureC, Default.chargeMaxTemperatureC,
                                                 chargeMaxTemperatureRange))
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


/// The keys that open Anode's window switcher.
public enum WindowSwitcherTrigger: String, CaseIterable {
    /// Command-Option-Tab, so the system's Command-Tab keeps working as it always did.
    case commandOption
    /// Command-Tab, which then belongs to Anode and no longer opens the system's switcher.
    case command

    public var title: String {
        switch self {
        case .commandOption: return "⌘⌥Tab (leaves the system's ⌘Tab alone)"
        case .command: return "⌘Tab (replaces the system's switcher)"
        }
    }

    /// The short form, for the section's text.
    public var label: String { self == .commandOption ? "⌘⌥Tab" : "⌘Tab" }
}

/// What sits behind the menu bar.
public enum MenuBarBackdropMode: String, CaseIterable {
    /// Nothing: the system's own transparent bar over the wallpaper.
    case off
    /// A frosted, tinted blur; the wallpaper survives as a smear.
    case blur
    /// A full opaque block, so the wallpaper cannot show at all.
    case solid
    /// The same block, fading into the colour of the window beneath it. Reading
    /// another app's window needs Screen Recording permission.
    case solidFollow

    public var title: String {
        switch self {
        case .off: return "Off"
        case .blur: return "Blur"
        case .solid: return "Solid"
        case .solidFollow: return "Solid, following the window"
        }
    }
}
