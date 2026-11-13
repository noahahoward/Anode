import AppKit
import IOKit.ps
import PowerKit

// ── The real inputs to the pause policy ─────────────────────────────────────
//
// What is true of the Mac right now (on battery, Low Power Mode, hot, displays asleep, screen locked), and a signal when any of
// it changes. EVENT-DRIVEN ONLY: every input here is a notification or a run-loop source; nothing polls, and `stop()` removes
// all of them. `start()` is called when live wallpapers are switched on and `stop()` when they are switched off.

final class WallpaperConditionsSource {

    /// Serious and critical thermal states are "hot"; nominal and fair are not.
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool { state == .serious || state == .critical }

    /// `refresh` is true for events after which a playing wallpaper must be told to play again (wake, unlock, a Space change).
    private let onChange: (_ refresh: Bool) -> Void
    private var displaysAsleep = false
    private var screenLocked = false
    private var started = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?

    init(onChange: @escaping (_ refresh: Bool) -> Void) { self.onChange = onChange }

    deinit { stop() }

    func current() -> WallpaperGlobalConditions {
        WallpaperGlobalConditions(onBattery: Self.isOnBattery(),
                                  lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                  thermalHot: Self.isHot(ProcessInfo.processInfo.thermalState),
                                  // A shut lid with nothing else plugged in is a display nobody can see, and Always Stay
                                  // Awake keeps the panel lit (at brightness 0) so the system never says it is asleep.
                                  displaysAsleep: displaysAsleep || !ScreenWatch.shared.isWatched,
                                  screenLocked: screenLocked, userPaused: false, ultraLowPower: UltraQuiet.isOn)
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    private static func sessionIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func start() {
        guard !started else { return }
        started = true
        screenLocked = Self.sessionIsLocked()

        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        let nc = NotificationCenter.default

        func watch(_ center: NotificationCenter, _ name: Notification.Name, refresh: Bool = false, _ update: (() -> Void)? = nil) {
            let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                update?()
                self?.onChange(refresh)
            }
            observers.append((center, o))
        }
        watch(ws, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.displaysAsleep = true }
        watch(ws, NSWorkspace.screensDidWakeNotification, refresh: true) { [weak self] in self?.displaysAsleep = false }
        // A whole-system wake: the display notification usually follows, but a missed one must not leave it "asleep".
        watch(ws, NSWorkspace.didWakeNotification, refresh: true) { [weak self] in self?.displaysAsleep = false }
        watch(ws, NSWorkspace.activeSpaceDidChangeNotification, refresh: true)
        watch(dnc, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.screenLocked = true }
        watch(dnc, Notification.Name("com.apple.screenIsUnlocked"), refresh: true) { [weak self] in self?.screenLocked = false }
        watch(nc, NSApplication.didChangeScreenParametersNotification, refresh: true)
        watch(nc, Notification.Name.NSProcessInfoPowerStateDidChange)
        watch(nc, ProcessInfo.thermalStateDidChangeNotification)
        // Ultra Low Power Mode starting or ending: the wallpaper stands still, or plays again.
        watch(nc, UltraLowPowerController.didChange)

        // Plugging in or unplugging the charger.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<WallpaperConditionsSource>.fromOpaque(ctx).takeUnretainedValue().onChange(false)
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
    }

    func stop() {
        guard started else { return }
        started = false
        for (center, o) in observers { center.removeObserver(o) }
        observers.removeAll()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            self.powerSource = nil
        }
    }
}
