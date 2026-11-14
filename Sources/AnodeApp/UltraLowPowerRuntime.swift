import AppKit
import PowerKit

// ── Ultra Low Power Mode: joined to the app ─────────────────────────────────
//
// The controller runs a session and knows nothing of the app around it. This file makes the real parts, hands them to the
// controller, and connects it to what the app does: the shortcut, the app that is in front, the app that is brought forward,
// the Mac being powered off, the menu bar's readings, the icon, a timer for the screen. It decides nothing about the mode
// itself.
//
// Layers, each there only while it is wanted:
//   · always: the controller (an object that does nothing until asked), the observer of the setting, and the undoing of a
//     record a session left behind;
//   · the box ticked: the shortcut, the tracking of the front app, the readings' hooks;
//   · the mode on: the watch on the brightness, the watch on the bar for the icon, the icon;
//   · from the question until the mode is off again: the notice of a power-off (apps are stopped before the mode is on).

/// The menu bar's readings, as far as the mode needs them. `MenuBarWidgetController` is one; a test has a fake.
protocol UltraReadingHosting: AnyObject {
    /// Is the app's measuring stopped? Asked at every redraw.
    var isPaused: () -> Bool { get set }
    /// A click on a reading while paused, with the reading that was clicked.
    var onPausedClick: ((NSStatusBarButton) -> Void)? { get set }
    /// What the readings' right-click menu adds for the mode, while the box is ticked; nil otherwise.
    var ultraMenuEntry: (() -> UltraReadingMenuEntry?)? { get set }
    /// Is at least one reading on the menu bar now: not switched off, not folded away, and made?
    var hasReadingsOnBar: Bool { get }
}

extension MenuBarWidgetController: UltraReadingHosting {
    var hasReadingsOnBar: Bool { !statusButtons.isEmpty }
}

/// The one queue the mode's slow calls run on (the display, the keyboard light, the screen put back), and a way to wait for it.
protocol UltraWorkRunning: AnyObject {
    func run(_ job: @escaping () -> Void)
    /// Returns when everything given to `run` before this call has finished (true), or after `limit` seconds (false).
    func waitUntilIdle(limit: TimeInterval) -> Bool
}

final class UltraWorkQueue: UltraWorkRunning {

    private let queue = DispatchQueue(label: "dev.anode.ultra.work", qos: .utility)

    func run(_ job: @escaping () -> Void) { queue.async(execute: job) }

    func waitUntilIdle(limit: TimeInterval) -> Bool {
        // The queue is serial: this marker runs after every job that was given before it.
        let reached = DispatchSemaphore(value: 0)
        queue.async { reached.signal() }
        return reached.wait(timeout: .now() + limit) == .success
    }
}

/// One window of the screen as the choice of an app to keep needs it, in a list ordered front to back.
struct UltraWindow: Equatable {
    var ownerPID: pid_t
    var layer: Int
    var onScreen: Bool
}

/// Starts something that fires every `every` seconds, and returns what stops it.
typealias UltraTicker = (_ every: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void

final class UltraLowPowerRuntime {

    /// How often the brightness is looked at while the mode is on. A pull-back is not visible as flicker even much faster
    /// (measured at 50 ms), so this is the cheap end.
    static let brightnessWatchSeconds: TimeInterval = 2
    static let shortcutOwner = "ultraLowPower"
    /// The section in Beta Features asks this runtime for the groups it may add to its list.
    static var current: UltraLowPowerRuntime?

    let controller: UltraLowPowerController
    private let settings: Settings
    private let processes: ProcessListing
    private let watchdog: UltraWatchdogging
    private let widgets: UltraReadingHosting
    private let icon: UltraIconPresenting
    private let presentMenu: (NSMenu, NSStatusBarButton) -> Void
    private let openBetaFeatures: () -> Void
    private let registerShortcut: (@escaping () -> Void) -> Void
    private let unregisterShortcut: () -> Void
    private let work: UltraWorkRunning
    private let startTicker: UltraTicker
    private let workspace: NotificationCenter
    private let center: NotificationCenter
    private let appPID: (Notification) -> pid_t?
    private let appBundleID: (Notification) -> String?
    private let frontmostPID: () -> pid_t?
    private let ownPIDs: () -> Set<pid_t>
    private let lastOtherFront: () -> pid_t?
    private let user: uid_t
    private let log: (String) -> Void

    /// The last app that came forward and is not Anode, as far as the box has been ticked: what the plan keeps when the owner
    /// asks. A remembered one wins; with none, the app behind Anode's windows is read at the moment it is asked.
    private final class Front { var pid: pid_t? }
    private let front: Front

    private var settingToken: AnyObject?
    private var finished = false
    /// The box is ticked and the shortcut, the front app and the readings' hooks are in place.
    private var available = false
    /// The mode is on, and what it needs while on is in place.
    private var running = false
    private var iconShown = false
    private var activationToken: NSObjectProtocol?
    private var powerOffToken: NSObjectProtocol?
    private var barToken: NSObjectProtocol?
    private var stopBrightnessWatch: (() -> Void)?
    /// The name of every group seen frozen or left running this session, by id: the menu names a group the guard let go
    /// (it is no longer in any list) by it.
    private(set) var groupNames: [String: String] = [:]

    var isWatchingBrightness: Bool { stopBrightnessWatch != nil }

    init(settings: Settings, processes: ProcessListing, freezer: ProcessFreezing, throttler: ProcessThrottling,
         processTable: @escaping () -> [UltraProcess]?, startTime: @escaping (pid_t) -> UInt64?, hasEfficiencyCores: Bool,
         hider: AppHiding, backlight: BacklightControl,
         ownBrightness: OwnBrightness, rate: DisplayRateControlling, keyboard: KeyboardBacklightControlling,
         power: PowerModeControlling, lowPowerOn: @escaping () -> Bool, watchdog: UltraWatchdogging, store: UltraRecordStoring,
         confirm: UltraConfirming,
         backdrop: BackdropPresenting, load: LoadReading, widgets: UltraReadingHosting, icon: UltraIconPresenting,
         presentMenu: @escaping (NSMenu, NSStatusBarButton) -> Void, openBetaFeatures: @escaping () -> Void,
         registerShortcut: @escaping (@escaping () -> Void) -> Void, unregisterShortcut: @escaping () -> Void,
         work: UltraWorkRunning, startTicker: @escaping UltraTicker, workspace: NotificationCenter, center: NotificationCenter,
         appPID: @escaping (Notification) -> pid_t?, appBundleID: @escaping (Notification) -> String?, frontmostPID: @escaping () -> pid_t?, windows: @escaping () -> [UltraWindow], ownPID: pid_t, user: uid_t,
         log: @escaping (String) -> Void, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         alert: @escaping () -> Void) {
        self.settings = settings
        self.processes = processes
        self.watchdog = watchdog
        self.widgets = widgets
        self.icon = icon
        self.presentMenu = presentMenu
        self.openBetaFeatures = openBetaFeatures
        self.registerShortcut = registerShortcut
        self.unregisterShortcut = unregisterShortcut
        self.work = work
        self.startTicker = startTicker
        self.workspace = workspace
        self.center = center
        self.appPID = appPID
        self.appBundleID = appBundleID
        self.frontmostPID = frontmostPID
        self.user = user
        self.log = log
        // Anode's own: this process and the watchdog, which has a pid only while a session runs, so it is asked each time.
        let ownPIDs: () -> Set<pid_t> = { [watchdog] in
            var pids: Set<pid_t> = [ownPID]
            if let pid = watchdog.pid { pids.insert(pid) }
            return pids
        }
        self.ownPIDs = ownPIDs
        let front = Front()
        self.front = front
        let lastOtherFront: () -> pid_t? = {
            front.pid ?? UltraLowPowerRuntime.frontOtherApp(in: windows(), excluding: ownPIDs())
        }
        self.lastOtherFront = lastOtherFront
        controller = UltraLowPowerController(
            settings: settings, processes: processes, freezer: freezer, throttler: throttler,
            processTable: processTable, startTime: startTime, hasEfficiencyCores: hasEfficiencyCores, hider: hider, backlight: backlight,
            ownBrightness: ownBrightness, rate: rate, keyboard: keyboard, power: power, lowPowerOn: lowPowerOn,
            watchdog: watchdog, store: store, confirm: confirm, backdrop: backdrop, load: load, lastOtherFrontApp: lastOtherFront, ownPIDs: ownPIDs, user: user,
            work: { work.run($0) }, waitForWork: { work.waitUntilIdle(limit: $0) }, schedule: schedule, alert: alert, log: log)
        controller.onChange = { [weak self] in self?.controllerChanged() }

        // Before anything else of the feature, and whether or not the box is ticked: a record left by a crash is undone even
        // when the owner has unticked the box since.
        controller.recoverAtLaunch()

        settingToken = settings.observe(Settings.Key.ultraLowPowerEnabled) { [weak self] in self?.apply() }
        apply()
    }

    /// The real thing, for the app.
    static func live(widgets: MenuBarWidgetController, openBetaFeatures: @escaping () -> Void) -> UltraLowPowerRuntime {
        let url = recordURL
        let log: (String) -> Void = { FeatureLog.append("ultra.log", $0) }
        let icon = UltraIcon()
        let runtime = UltraLowPowerRuntime(
            settings: .shared, processes: LiveProcessList(), freezer: LiveProcessFreezer(),
            throttler: LiveProcessThrottler(), processTable: LiveProcessList.processTable,
            startTime: { LiveProcessList.startTime($0) },
            hasEfficiencyCores: LiveProcessThrottler.hasEfficiencyCores,
            hider: LiveAppHider(), backlight: DisplayServicesBacklight(), ownBrightness: OwnBrightness.shared, rate: LiveDisplayRate(),
            keyboard: LiveKeyboardBacklight(), power: HelperPowerMode(),
            // Read each time it is asked: it follows the switch live in a running process, with no notification to wait for.
            lowPowerOn: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            watchdog: LiveUltraWatchdog(recordURL: url, log: log),
            store: UltraRecordFile(url: url),
            // What the box says is what will happen: the owner's choices, and whether this Mac has the cores to keep work on.
            confirm: UltraConfirmPanel(screenText: {
                UltraConfirmPanel.screenLine(backdrop: Settings.shared.ultraLowPowerBlackBackdrop,
                                             efficiencyCores: Settings.shared.ultraLowPowerEfficiencyCores,
                                             hasEfficiencyCores: LiveProcessThrottler.hasEfficiencyCores)
            }),
            backdrop: LiveUltraBackdrop(), load: LiveLoadReader(), widgets: widgets, icon: icon,
            presentMenu: { menu, button in
                // popUp, not a menu on the item plus a click: that re-enters the item's own action (as `BarChevron` found).
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
            },
            openBetaFeatures: openBetaFeatures,
            registerShortcut: { fire in
                KeybindCenter.shared.register(owner: shortcutOwner, commands: ShortcutCommands.ultra) { _ in fire() }
            },
            unregisterShortcut: { KeybindCenter.shared.unregister(owner: shortcutOwner) },
            work: UltraWorkQueue(), startTicker: liveTicker,
            workspace: NSWorkspace.shared.notificationCenter, center: .default, appPID: liveAppPID,
            appBundleID: liveAppBundleID,
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier }, windows: liveWindows, ownPID: getpid(), user: getuid(),
            log: log, schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
            alert: { NSSound.beep() })
        icon.onClick = { [weak runtime] button in runtime?.showMenu(under: button) }
        UltraLowPowerController.current = runtime.controller
        UltraLowPowerRuntime.current = runtime
        return runtime
    }

    /// Beside the history database and the logs, so an uninstall that removes the folder removes it too.
    static var recordURL: URL {
        let support = AnodeFiles.applicationSupport
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Anode/ultra-session.json")
    }

    static func liveTicker(every seconds: TimeInterval, fire: @escaping () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in fire() }
        // Nothing here is urgent: let the system fold it into a wake-up that is happening anyway.
        timer.tolerance = seconds / 2
        return { timer.invalidate() }
    }

    static func liveAppPID(_ note: Notification) -> pid_t? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }

    static func liveAppBundleID(_ note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    /// The app to keep when no other app has come forward since the box was ticked (Anode's own window was in front when it was
    /// ticked and Start was pressed there): the owner of the frontmost ordinary window that is not Anode's. `windows` is front to
    /// back; ordinary is layer 0, which leaves out the menu bar, the Dock, floating panels and the desktop. nil when only
    /// Anode's windows are on screen.
    static func frontOtherApp(in windows: [UltraWindow], excluding own: Set<pid_t>) -> pid_t? {
        windows.first { $0.layer == 0 && $0.onScreen && !own.contains($0.ownerPID) }?.ownerPID
    }

    /// The windows on screen, front to back. One query to the window server, made only when the mode is asked for (or the
    /// picker is filled) with no remembered app to go by.
    static func liveWindows() -> [UltraWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            // Only windows on screen were asked for, so one that does not say otherwise is on screen.
            return UltraWindow(ownerPID: pid, layer: layer, onScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? true)
        }
    }

    /// For the section in Beta Features, which is built before the runtime may exist and asks again each time it is shown:
    /// the runtime that is there when it is asked, or none.
    static func candidatesNow(_ done: @escaping ([FreezeGroup]) -> Void) {
        if let runtime = current { runtime.candidates(done) } else { done([]) }
    }

    /// The end of the app, before the rest of it tears down: the mode is ended (everything continued and put back), and
    /// nothing of the feature is left.
    func shutdown() {
        guard !finished else { return }
        finished = true
        settingToken = nil
        endSession()
        withdraw()
        if UltraLowPowerController.current === controller { UltraLowPowerController.current = nil }
        if UltraLowPowerRuntime.current === self { UltraLowPowerRuntime.current = nil }
    }

    // ── The box ─────────────────────────────────────────────────────────────

    private func apply() {
        guard !finished, settings.ultraLowPowerEnabled != available else { return }
        if settings.ultraLowPowerEnabled {
            offer()
        } else {
            // The mode comes off first: what it holds is put back before what reached it is taken away.
            controller.turnOff()
            withdraw()
        }
    }

    /// Ticked: the shortcut, the front app, the readings. Nothing starts: the mode starts when asked.
    private func offer() {
        available = true
        // Anode in front is no app to keep.
        front.pid = frontmostPID().flatMap { ownPIDs().contains($0) ? nil : $0 }
        registerShortcut { [weak self] in
            guard let self else { return }
            UltraMenu.toggle(self.controller)
        }
        activationToken = observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let pid = self?.appPID(note) else { return }
            self?.activated(pid, bundleID: self?.appBundleID(note))
        }
        // Paused for as long as the mode is on, window open or not: the numbers would be hours old and look live.
        widgets.isPaused = { UltraQuiet.isOn }
        widgets.onPausedClick = { [weak self] button in self?.showMenu(under: button) }
        // The readings' right-click menu carries the mode's entry for as long as the box is ticked.
        widgets.ultraMenuEntry = { [weak self] in self?.readingsMenuEntry() }
    }

    private func withdraw() {
        guard available else { return }
        available = false
        unregisterShortcut()
        forget(&activationToken, in: workspace)
        front.pid = nil
        widgets.isPaused = { false }
        widgets.onPausedClick = nil
        widgets.ultraMenuEntry = nil
    }

    // ── Reactions ───────────────────────────────────────────────────────────

    /// An app came forward. One the mode has frozen is let go first (its Dock icon, the app switcher); any other that is not
    /// Anode's own is the app to keep if the mode is asked for next.
    private func activated(_ pid: pid_t, bundleID: String?) {
        controller.appActivated(pid: pid, bundleID: bundleID)
        if !ownPIDs().contains(pid) { front.pid = pid }
    }

    /// The Mac is being powered off or logged out: the session is ended, here. A logout can still be cancelled after this
    /// notice, so the runtime stays as it is: the box and the shortcut keep working.
    private func powerOffNotice() { endSession() }

    /// What a quit or a power-off cannot leave to a queue: the controller continues everything here, first, and puts the
    /// refresh rate and the keyboard light back on the work queue, which it waits for (`UltraLowPowerController.shutdownWaitSeconds`).
    /// That queue is serial, so what is put back comes after any job already inside a display or keyboard call, and no job that has
    /// not started runs once the session has ended. The screen is in that job too, unless the mode switched Low Power Mode on and it is
    /// still on: macOS raises the screen when it ends, and a quit cannot wait for that, so the screen is left to the watchdog (the
    /// record is cut down to it), which waits and puts it back once Anode has gone. A session that has ended already is not ended again.
    private func endSession() { controller.shutdown() }

    /// The controller says something changed (the state, the groups): what the mode needs while on is there exactly then.
    private func controllerChanged() {
        // The apps are stopped from Confirm on, and the mode is not on until the screen and Low Power Mode have been dealt with,
        // which can wait on the helper: a logout in between must be heard, so the notice is listened for from the question
        // until the mode is off.
        let asked = !finished && controller.state != .off
        if asked != (powerOffToken != nil) {
            if asked {
                powerOffToken = observe(workspace, NSWorkspace.willPowerOffNotification) { [weak self] _ in self?.powerOffNotice() }
            } else {
                forget(&powerOffToken, in: workspace)
            }
        }
        let on = !finished && controller.state == .on
        if on != running {
            running = on
            if on { startRunning() } else { stopRunning() }
        }
        if on {
            for group in controller.frozen + controller.leftRunning { groupNames[group.id] = group.name }
        } else {
            groupNames = [:]
        }
        updateIcon()
    }

    private func startRunning() {
        stopBrightnessWatch = startTicker(Self.brightnessWatchSeconds) { [weak controller] in
            controller?.brightnessMayHaveChanged()
        }
        // Only this bar: another widget controller's rebuild says nothing about it.
        barToken = observe(center, MenuBarWidgetController.itemsDidRebuild, object: widgets) { [weak self] _ in self?.updateIcon() }
    }

    private func stopRunning() {
        stopBrightnessWatch?()
        stopBrightnessWatch = nil
        forget(&barToken, in: center)
    }

    /// The icon is the way to the mode's menu when no reading is on the bar to carry it: there while the mode is on and the
    /// bar has none, gone otherwise. Acted on only when it changes.
    private func updateIcon() {
        let wanted = running && !widgets.hasReadingsOnBar
        guard wanted != iconShown else { return }
        iconShown = wanted
        if wanted { icon.install() } else { icon.remove() }
    }

    // ── The menu ────────────────────────────────────────────────────────────

    /// What a click on a paused reading, or on the icon, opens: the menu for the mode as it is now.
    func menu() -> NSMenu {
        UltraMenu.build(state: controller.state, starting: controller.isStarting, frozen: controller.frozen, leftRunning: controller.leftRunning,
                        releasedForLoad: controller.releasedForLoad, names: groupNames,
                        onStart: { [weak self] in self?.controller.request() },
                        onTurnOff: { [weak self] in self?.controller.turnOff() },
                        onRelease: { [weak self] in self?.controller.release(groupID: $0) },
                        onOpenBeta: openBetaFeatures)
    }

    func showMenu(under button: NSStatusBarButton) { presentMenu(menu(), button) }

    /// The line the readings' right-click menu carries: the same words and the same press as the app menu's entry (start, cancel
    /// while the start runs, turn off), switched off while the confirm box is up.
    private func readingsMenuEntry() -> UltraReadingMenuEntry {
        let entry = UltraMenu.appEntry(ticked: true, state: controller.state, starting: controller.isStarting)
        return UltraReadingMenuEntry(title: entry.title, isEnabled: entry.isEnabled,
                                     run: { [weak self] in
                                         guard let self else { return }
                                         UltraMenu.toggle(self.controller)
                                     })
    }

    // ── The section ─────────────────────────────────────────────────────────

    /// Every group the picker may offer: those the plan would keep (the front app, the ones already on the list), freeze, or
    /// leave running whole. Anode's own processes and the system's are in none.
    func candidates(_ done: @escaping ([FreezeGroup]) -> Void) {
        processes.snapshot { [weak self] list in
            guard let self, let list else { return done([]) }
            let plan = FreezePlanner.plan(processes: list, user: self.user, front: self.lastOtherFront(),
                                          alwaysKeep: Set(self.settings.ultraLowPowerAlwaysKeep), ownPIDs: self.ownPIDs())
            done(plan.kept + plan.frozen + plan.leftRunning)
        }
    }

    // ── Small things ────────────────────────────────────────────────────────

    /// An observer whose handler runs on the main thread, and not after the runtime is finished.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil,
                         _ handler: @escaping (Notification) -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: object, queue: nil) { [weak self] note in
            let run = {
                guard let self, !self.finished else { return }
                handler(note)
            }
            if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
        }
    }

    private func forget(_ token: inout NSObjectProtocol?, in center: NotificationCenter) {
        guard let held = token else { return }
        center.removeObserver(held)
        token = nil
    }
}
