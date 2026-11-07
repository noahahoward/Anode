import AppKit
import Network
import PowerKit

// ── Live wallpapers: which display shows what, and when it plays ────────────
//
// The one object that knows the whole picture. It keeps one surface per display that has something assigned, reconciles that
// set against the displays, the assignments and the library whenever any of them changes, and decides per display whether each
// surface plays or stands still (`WallpaperPolicy`, with `PauseGate` holding back the one reason that flickers).
//
// Event-driven throughout. There is no polling and no repeating timer: the only timer is a single shot, set while a "covered"
// verdict is waiting out its gate and cancelled when nothing is pending. While the feature is off there are no surfaces, no
// timer and (apart from the settings and notification observers that switch it on) no work at all. Main thread throughout.
//
// When something goes wrong with one display's wallpaper (file gone, page failed, factory refused) that display's surface is
// closed, so the system wallpaper shows through, and the reason is kept for the Beta Features row. It is NOT retried on every
// later event: only a trigger that could change the outcome retries it (a different item assigned, `reload`).

enum WallpaperStatus: Equatable {
    case noWallpaper
    /// A surface that doesn't play or pause (an image) is up.
    case showing(itemName: String)
    case playing(itemName: String)
    case paused(WallpaperPauseReason, itemName: String)
    case failed(String)
}

final class LiveWallpaperController {

    /// The running controller, for the Beta Features section and the shortcut to reach.
    static weak var current: LiveWallpaperController?

    /// Called whenever anything the section shows may have changed.
    var onChange: (() -> Void)?

    /// One line per state change (a surface shown, closed or failed; a display playing or paused and why), never per event.
    /// The app points it at wallpaper.log; tests and the default leave it silent.
    var log: (String) -> Void = { _ in }

    private final class Live {
        let surface: WallpaperSurface
        let itemID: UUID
        let itemName: String
        let remote: Bool
        var display: DisplayInfo
        var gate = PauseGate()
        var covered = false
        var reason: WallpaperPauseReason?
        var told = false                      // setPlaying has been called at least once
        var appliedPrefs: WallpaperPrefs?
        init(surface: WallpaperSurface, itemID: UUID, itemName: String, remote: Bool, display: DisplayInfo) {
            self.surface = surface; self.itemID = itemID; self.itemName = itemName; self.remote = remote; self.display = display
        }
    }

    /// `remote`: the item is a link, so a failure may just mean there was no network at the time.
    private struct Failure { let itemID: UUID; let message: String; let remote: Bool }

    private let settings: Settings
    private let library: WallpaperLibrary
    private let prefsStore: WallpaperPrefsStore
    private let displays: () -> [DisplayInfo]
    private let factory: WallpaperSurfaceFactory
    private let conditions: () -> WallpaperGlobalConditions
    private let now: () -> Date
    private let watchNetwork: (_ onReturn: @escaping () -> Void) -> () -> Void
    private var stopWatchingNetwork: (() -> Void)?

    private var live: [String: Live] = [:]
    private var failures: [String: Failure] = [:]
    private var lastDisplays: [DisplayInfo] = []
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var settingsToken: AnyObject?
    private var reconciling = false
    private var reconcileAgain = false
    private var isShutDown = false

    var userPaused = false {
        didSet { if userPaused != oldValue { applyPolicy(); onChange?() } }
    }

    init(settings: Settings, library: WallpaperLibrary, prefsStore: WallpaperPrefsStore,
         displays: @escaping () -> [DisplayInfo], factory: WallpaperSurfaceFactory,
         conditions: @escaping () -> WallpaperGlobalConditions, now: @escaping () -> Date,
         watchNetwork: @escaping (_ onReturn: @escaping () -> Void) -> () -> Void = LiveWallpaperController.systemNetworkWatch) {
        self.settings = settings
        self.library = library
        self.prefsStore = prefsStore
        self.displays = displays
        self.factory = factory
        self.conditions = conditions
        self.now = now
        self.watchNetwork = watchNetwork
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: WallpaperPrefsStore.didChange, object: prefsStore, queue: .main) { [weak self] _ in
            self?.reconcile()
        })
        tokens.append(nc.addObserver(forName: WallpaperLibrary.didChange, object: library, queue: .main) { [weak self] _ in
            self?.reconcile()
        })
        settingsToken = settings.observe(Settings.Key.liveWallpaperEnabled) { [weak self] in self?.reconcile() }
    }

    deinit { shutdown() }

    func setUserPaused(_ paused: Bool) { userPaused = paused }
    func toggleUserPaused() { userPaused.toggle() }

    // MARK: reconcile

    /// Bring the live surfaces in line with the settings, the displays, the assignments and the library.
    func reconcile() {
        guard !isShutDown else { return }
        if reconciling { reconcileAgain = true; return }
        reconciling = true
        repeat {
            reconcileAgain = false
            performReconcile()
        } while reconcileAgain
        reconciling = false
        updateNetworkWatch()
        applyPolicy()
        onChange?()
    }

    // MARK: network

    /// Watches the network only while a link-based wallpaper is failed and waiting; `onReturn` fires when the network goes from
    /// unavailable to available. The first report is only the starting state and is not an event, so a failure that has nothing
    /// to do with the network (a dead page) does not retry in a loop.
    static func systemNetworkWatch(onReturn: @escaping () -> Void) -> () -> Void {
        let monitor = NWPathMonitor()
        var wasSatisfied: Bool?
        monitor.pathUpdateHandler = { path in
            let now = path.status == .satisfied
            defer { wasSatisfied = now }
            guard let before = wasSatisfied, !before, now else { return }
            DispatchQueue.main.async(execute: onReturn)
        }
        monitor.start(queue: DispatchQueue(label: "anode.wallpaper.network"))
        return { monitor.cancel() }
    }

    private func updateNetworkWatch() {
        let waiting = !isShutDown && failures.values.contains { $0.remote }
        if waiting, stopWatchingNetwork == nil {
            stopWatchingNetwork = watchNetwork { [weak self] in self?.networkReturned() }
        } else if !waiting, let stop = stopWatchingNetwork {
            stop(); stopWatchingNetwork = nil
        }
    }

    private func networkReturned() {
        guard !isShutDown else { return }
        for (uuid, f) in failures where f.remote { failures[uuid] = nil }
        reconcile()
    }

    private func performReconcile() {
        // An assignment to an item that is no longer in the library is dropped, whether or not the feature is on.
        var prefs = prefsStore.prefs
        let known = Set(library.items.map(\.id))
        var stale = Set<UUID>()
        if let d = prefs.assignments.defaultItem, !known.contains(d) { stale.insert(d) }
        for case .item(let id) in prefs.assignments.perDisplay.values where !known.contains(id) { stale.insert(id) }
        if !stale.isEmpty {
            for id in stale { prefs.assignments.removeItem(id) }
            prefsStore.prefs = prefs     // posts didChange; the nested reconcile is folded into this pass
            prefs = prefsStore.prefs
        }

        guard settings.liveWallpaperEnabled else {
            closeAll()
            failures.removeAll()
            lastDisplays = displays()
            return
        }

        let current = displays()
        lastDisplays = current
        var desired: [String: (DisplayInfo, WallpaperItem)] = [:]
        for d in current {
            if let id = prefs.assignments.resolved(forDisplay: d.uuid), let item = library.item(id: id) { desired[d.uuid] = (d, item) }
        }

        // Close what should no longer be there: an unplugged display, a cleared assignment, a different item.
        for (uuid, l) in live where desired[uuid]?.1.id != l.itemID {
            l.surface.close()
            log("\(uuid) close \(l.itemName)")
            live[uuid] = nil
        }
        for uuid in failures.keys where desired[uuid]?.1.id != failures[uuid]?.itemID { failures[uuid] = nil }

        for (uuid, pair) in desired {
            let (display, item) = pair
            if let l = live[uuid] {
                if l.display.frame != display.frame { l.surface.updateFrame(display.frame) }
                l.display = display
                if l.appliedPrefs != prefs { l.surface.apply(prefs); l.appliedPrefs = prefs }
                continue
            }
            if failures[uuid] != nil { continue }      // waiting for a trigger
            create(display: display, item: item, prefs: prefs)
        }
    }

    private func create(display: DisplayInfo, item: WallpaperItem, prefs: WallpaperPrefs) {
        if library.isMissing(item) {
            failures[display.uuid] = Failure(itemID: item.id, message: "File missing: \(item.name)", remote: false)
            log("\(display.uuid) fail File missing: \(item.name)")
            return
        }
        do {
            let surface = try factory.makeSurface(for: display, item: item, library: library, prefs: prefs)
            var isRemote = false
            if case .remote = item.source { isRemote = true }
            let l = Live(surface: surface, itemID: item.id, itemName: item.name, remote: isRemote, display: display)
            live[display.uuid] = l
            log("\(display.uuid) show \(item.name)")
            surface.onCoveredChange = { [weak self, weak l] covered in
                guard let self, let l, self.live[display.uuid] === l else { return }
                l.covered = covered
                self.applyPolicy()
                self.onChange?()
            }
            surface.onFailure = { [weak self, weak l] message in
                guard let self, let l, self.live[display.uuid] === l else { return }
                self.fail(display.uuid, message: message)
            }
            surface.apply(prefs)
            l.appliedPrefs = prefs
        } catch {
            let message = (error as? WallpaperSurfaceError)?.message ?? "Couldn't show \(item.name): \(error.localizedDescription)"
            var isRemote = false
            if case .remote = item.source { isRemote = true }
            failures[display.uuid] = Failure(itemID: item.id, message: message, remote: isRemote)
            log("\(display.uuid) fail \(message)")
        }
    }

    private func fail(_ uuid: String, message: String) {
        guard let l = live[uuid] else { return }
        l.surface.close()
        live[uuid] = nil
        failures[uuid] = Failure(itemID: l.itemID, message: message, remote: l.remote)
        log("\(uuid) fail \(message)")
        updateNetworkWatch()
        applyPolicy()
        onChange?()
    }

    /// Try a failed (or any) display again.
    func reload(displayUUID uuid: String) {
        failures[uuid] = nil
        if let l = live[uuid] { l.surface.close(); live[uuid] = nil }
        reconcile()
    }

    private func closeAll() {
        for (uuid, l) in live { l.surface.close(); log("\(uuid) close \(l.itemName)") }
        live.removeAll()
        timer?.invalidate(); timer = nil
    }

    func shutdown() {
        isShutDown = true
        closeAll()
        failures.removeAll()
        updateNetworkWatch()
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        tokens.removeAll()
        settingsToken = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: pausing

    /// Something about the Mac changed (power, heat, sleep, lock, displays). `refresh` is true for wake, unlock and a Space
    /// change: those tell every playing surface to play again even though its state hasn't changed, because the system can
    /// stop a player without saying so.
    func conditionsChanged(refresh: Bool = false) {
        guard !isShutDown else { return }
        if displays() != lastDisplays { reconcile(); return }
        applyPolicy(refresh: refresh)
        onChange?()
    }

    func gateTimerFired() {
        guard !isShutDown else { return }
        timer?.invalidate(); timer = nil
        applyPolicy()
        onChange?()
    }

    private func globalConditions() -> WallpaperGlobalConditions {
        var g = conditions()
        g.userPaused = userPaused
        return g
    }

    private func applyPolicy(refresh: Bool = false) {
        guard !isShutDown else { return }
        let prefs = prefsStore.prefs
        let g = globalConditions()
        let at = now()
        for l in live.values where l.surface.pausable {
            let raw = WallpaperPolicy.pauseReason(prefs: prefs, global: g, display: WallpaperDisplayConditions(covered: l.covered))
            let effective = l.gate.update(raw, now: at)
            if !l.told || effective != l.reason || (refresh && effective == nil) {
                if effective != l.reason || !l.told {
                    log("\(l.display.uuid) \(effective.map { "pause \($0)" } ?? "play") \(l.itemName)")
                }
                l.told = true
                l.reason = effective
                l.surface.setPlaying(effective == nil)
            }
        }
        scheduleTimer(at: at)
    }

    /// One single-shot timer for the soonest pending gate; none when nothing is pending.
    private func scheduleTimer(at at: Date) {
        timer?.invalidate(); timer = nil
        guard let next = live.values.compactMap({ $0.gate.nextCheck(now: at) }).min() else { return }
        let t = Timer(timeInterval: max(0.05, next.timeIntervalSince(at)), repeats: false) { [weak self] _ in self?.gateTimerFired() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: status

    func status(forDisplay uuid: String) -> WallpaperStatus {
        if let f = failures[uuid] { return .failed(f.message) }
        guard let l = live[uuid] else { return .noWallpaper }
        if !l.surface.pausable { return .showing(itemName: l.itemName) }
        if let r = l.reason { return .paused(r, itemName: l.itemName) }
        return .playing(itemName: l.itemName)
    }
}
