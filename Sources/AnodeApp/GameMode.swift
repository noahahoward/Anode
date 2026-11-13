import AppKit
import PowerKit
import notify

// ── Game Mode HUD (Beta Features) ───────────────────────────────────────────
//
// A thin strip over a fullscreen game with temperatures, use, memory and battery, shown while a game is the frontmost app.
//
// This file is the decision: when the strip is up, what it says and where it sits. The strip itself (`GameHUDWindow`) and the
// workspace notifications that say "the frontmost app changed" are behind protocols, so the whole controller is tested with
// fakes and nothing in a test shows a window or reads the real frontmost app. The arithmetic (what counts as a game, the
// text, the placement) is in PowerKit's `GameMode.swift`.
//
// Cost rule: with the setting off nothing exists, and with it on and no game in front the only thing running is the
// workspace observer, which is event-driven. The sampler is asked for extra readings (`needs`) only while the strip is up.
// There is no timer here: the app's own tick calls `refresh()`. Main thread.

/// The app in front, as far as the HUD cares.
struct FrontmostApp: Equatable {
    let bundleID: String?
    /// `LSApplicationCategoryType` from its Info.plist.
    let category: String?
    /// Its window fills the screen it is on.
    let fullscreen: Bool
    let screenFrame: CGRect
    /// The height of the black band above the picture on a notched screen in fullscreen, else 0.
    let safeTop: CGFloat
    let menuBarHeight: CGFloat
}

/// The strip.
protocol GameHUDPresenting: AnyObject {
    func size(for text: String) -> CGSize
    func show(text: String, frame: CGRect)
    func hide()
    var isShowing: Bool { get }
}

/// The tiny pointer-catching panels in the strip's corner of every screen.
protocol HotCornerPresenting: AnyObject {
    /// Put a hot spot in `corner` of every screen (replacing any before); `onEnter` gets that screen as a target.
    func show(corner: HUDCorner, onEnter: @escaping (FrontmostApp) -> Void)
    func hide()
}

/// No hot corner (the default, so a controller can be made without one).
final class NoHotCorner: HotCornerPresenting {
    func show(corner: HUDCorner, onEnter: @escaping (FrontmostApp) -> Void) {}
    func hide() {}
}

/// "The frontmost app, the Space or the screens changed."
protocol ActivationObserving: AnyObject {
    func start(_ onChange: @escaping () -> Void)
    func stop()
}

final class GameModeController {

    /// The running controller, for the Beta Features section to read.
    static weak var current: GameModeController?

    /// Called when the strip goes up or comes down (not on every refresh).
    var onChange: (() -> Void)?

    private(set) var isShowing = false

    /// What the sampler must read for the strip: only while it is up, so a closed game costs nothing.
    var needs: SystemMetrics.Needs { isShowing ? [.cpu, .memory, .gpu, .sensors] : [] }

    private let settings: Settings
    private let presenter: GameHUDPresenting
    private let observer: ActivationObserving
    private let frontmost: () -> FrontmostApp?
    private let value: (MetricID) -> MetricValue?
    private let now: () -> Date
    private let appleGameMode: () -> Bool
    private let hotCorner: HotCornerPresenting
    /// Is Ultra Low Power Mode on? The app measures nothing then, so there is nothing to put on the strip.
    private let ultraOn: () -> Bool

    private let log: (String) -> Void
    private var lastNote = ""
    private var tokens: [AnyObject] = []
    private var observing = false
    private var previewUntil: Date?
    /// Where a hot-corner peek shows; nil for a preview, which shows wherever the frontmost app is.
    private var previewTarget: FrontmostApp?
    private var hotCornerShownIn: HUDCorner?

    init(settings: Settings = .shared, presenter: GameHUDPresenting, observer: ActivationObserving,
         frontmost: @escaping () -> FrontmostApp?, value: @escaping (MetricID) -> MetricValue?,
         now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { FeatureLog.append("gamemode.log", $0) },
         appleGameMode: @escaping () -> Bool = { false },
         hotCorner: HotCornerPresenting = NoHotCorner(),
         ultraOn: @escaping () -> Bool = { false }) {
        self.settings = settings
        self.ultraOn = ultraOn
        self.hotCorner = hotCorner
        self.appleGameMode = appleGameMode
        self.log = log
        self.presenter = presenter
        self.observer = observer
        self.frontmost = frontmost
        self.value = value
        self.now = now
        for key in [Settings.Key.gameHUDEnabled, Settings.Key.gameHUDCorner, Settings.Key.gameHUDExtraApps,
                    Settings.Key.gameHUDHotCorner] {
            tokens.append(settings.observe(key) { [weak self] in
                DispatchQueue.main.async { self?.settingsChanged() }
            })
        }
        settingsChanged()
    }

    deinit { observer.stop() }

    // ── Deciding ────────────────────────────────────────────────────────────

    private func settingsChanged() {
        if settings.gameHUDEnabled {
            if !observing {
                observing = true
                observer.start { [weak self] in self?.reevaluate() }
            }
        } else {
            previewUntil = nil
            previewTarget = nil
            if observing {
                observing = false
                observer.stop()
            }
        }
        applyHotCorner()
        reevaluate()
    }

    private func applyHotCorner() {
        if settings.gameHUDHotCorner {
            let corner = settings.gameHUDCorner
            guard hotCornerShownIn != corner else { return }
            hotCornerShownIn = corner
            hotCorner.show(corner: corner) { [weak self] target in self?.peek(on: target) }
        } else if hotCornerShownIn != nil {
            hotCornerShownIn = nil
            hotCorner.hide()
        }
    }

    /// Look at the frontmost app and put the strip up or take it down. Called on every activation, Space or display change.
    func reevaluate() {
        if let until = previewUntil, now() >= until { previewUntil = nil; previewTarget = nil }
        // A peek's target only counts while the peek is running; a leftover one must never stand in for the frontmost app.
        let app = previewUntil != nil ? (previewTarget ?? frontmost()) : frontmost()
        let (show, reason) = decision(for: app)
        note("front=\(app?.bundleID ?? "nil") category=\(app?.category ?? "nil") fullscreen=\(app?.fullscreen ?? false) "
             + "\u{2192} \(show ? "show" : "hide") (\(reason))")
        guard show, let app else {
            takeDown()
            return
        }
        let text = GameHUDText.line(value)
        let size = presenter.size(for: text)
        let frame = GameHUDPlacement.frame(size: size, corner: settings.gameHUDCorner, screenFrame: app.screenFrame,
                                           safeTop: app.safeTop, menuBarHeight: app.menuBarHeight, fullscreen: app.fullscreen)
        presenter.show(text: text, frame: frame)
        if !isShowing {
            isShowing = true
            onChange?()
        }
    }

    /// Whether the strip should be up, and why in a few words (for the log).
    private func decision(for app: FrontmostApp?) -> (show: Bool, reason: String) {
        // Before a preview or a peek too: with the app's measuring stopped the numbers would not move.
        if ultraOn() { return (false, "Ultra Low Power Mode is on") }
        guard let app else { return (false, "no frontmost app") }
        if previewUntil != nil { return (true, previewTarget != nil ? "hot corner" : "preview") }
        guard settings.gameHUDEnabled else { return (false, "disabled") }
        // Apple's own Game Mode first; the Games category and the owner's list are the fallback, so neither can hide a game
        // the other finds.
        if appleGameMode() { return (true, "Apple Game Mode") }
        let game = GameRules.isGame(bundleID: app.bundleID, category: app.category, extraApps: settings.gameHUDExtraApps)
        return game ? (true, "a game") : (false, "not a game")
    }

    /// Log a decision only when it differs from the last one: a tick every two seconds must not fill a file.
    private func note(_ line: String) {
        guard line != lastNote else { return }
        lastNote = line
        log(line)
    }

    private func takeDown() {
        guard isShowing else { return }
        isShowing = false
        presenter.hide()
        onChange?()
    }

    /// On every tick of the app's sampler: new numbers for the strip, and the end of a preview. Does nothing when no strip
    /// is up (an app coming to the front is announced by the observer, not found by polling).
    func refresh() {
        guard isShowing else { return }
        reevaluate()
    }

    /// Show the strip for a few seconds whatever is in front, so a corner can be chosen without a game running.
    func preview(seconds: TimeInterval = 5) {
        previewTarget = nil
        previewUntil = now().addingTimeInterval(seconds)
        reevaluate()
    }

    /// The pointer touched the hot corner of `target`'s screen: show the strip there for a few seconds.
    func peek(on target: FrontmostApp, seconds: TimeInterval = 4) {
        previewTarget = target
        previewUntil = now().addingTimeInterval(seconds)
        reevaluate()
    }

    func shutdown() {
        tokens.removeAll()
        previewUntil = nil
        previewTarget = nil
        if hotCornerShownIn != nil {
            hotCornerShownIn = nil
            hotCorner.hide()
        }
        if observing {
            observing = false
            observer.stop()
        }
        takeDown()
    }
}

// ── The real workspace ──────────────────────────────────────────────────────

/// "The frontmost app, the Space or the screens changed", from the three notifications that say so. Event-driven; `stop()`
/// removes every one of them.
final class WorkspaceActivationObserver: ActivationObserving {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var darwinToken: Int32 = 0
    private var darwinRegistered = false

    var isListening: Bool { !observers.isEmpty || darwinRegistered }

    func start(_ onChange: @escaping () -> Void) {
        guard !isListening else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        for (center, name) in [(ws, NSWorkspace.didActivateApplicationNotification),
                               (ws, NSWorkspace.activeSpaceDidChangeNotification),
                               (nc, NSApplication.didChangeScreenParametersNotification)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in onChange() }))
        }
        // Apple's Game Mode turning on or off.
        darwinRegistered = notify_register_dispatch(AppleGameMode.notificationName, &darwinToken, .main) { _ in onChange() }
            == UInt32(NOTIFY_STATUS_OK)
    }

    func stop() {
        for (center, o) in observers { center.removeObserver(o) }
        observers.removeAll()
        if darwinRegistered {
            notify_cancel(darwinToken)
            darwinRegistered = false
        }
    }

    deinit { stop() }
}

/// Whether macOS says Game Mode is on right now. Main thread only.
enum AppleGameModeReader {
    private static var token: Int32 = 0
    private static var registered = false

    static func isOn() -> Bool {
        if !registered { registered = notify_register_check(AppleGameMode.notificationName, &token) == UInt32(NOTIFY_STATUS_OK) }
        guard registered else { return false }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK) else { return false }
        return AppleGameMode.isOn(state: state)
    }
}

/// Reads the real frontmost app. Every failure (no app, no bundle, no window, no screen) is "not a game", never a crash.
enum RealFrontmost {

    static func current() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let category = app.bundleURL
            .flatMap { Bundle(url: $0) }
            .flatMap { $0.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let window = largestWindow(of: app.processIdentifier, in: windows)
        // Not `let screen = ... screen(containing:) ...`: a variable named like the function it calls in its own
        // initializer is read as the variable by older Swift compilers ("cannot call value of non-function type
        // 'NSScreen?'") and as the function by newer ones, so the install failed on a Mac with an older toolchain.
        let found = window.flatMap { Self.screen(containing: $0) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = found else { return nil }
        let safeTop = screen.safeAreaInsets.top
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, safeTop, 24)
        let fullscreen = window != nil && isFullscreen(presentationOptions: NSApp.currentSystemPresentationOptions)
        return FrontmostApp(bundleID: app.bundleIdentifier, category: category, fullscreen: fullscreen,
                            screenFrame: screen.frame, safeTop: safeTop, menuBarHeight: menuBarHeight)
    }

    /// A target for the strip on `screen` with no app behind it: where a hot-corner peek shows.
    static func target(for screen: NSScreen) -> FrontmostApp {
        let safeTop = screen.safeAreaInsets.top
        return FrontmostApp(bundleID: nil, category: nil,
                            fullscreen: isFullscreen(presentationOptions: NSApp.currentSystemPresentationOptions),
                            screenFrame: screen.frame, safeTop: safeTop,
                            menuBarHeight: max(screen.frame.maxY - screen.visibleFrame.maxY, safeTop, 24))
    }

    /// The app's biggest ordinary (layer 0) window on screen, in Cocoa coordinates.
    private static func largestWindow(of pid: pid_t, in windows: [[String: Any]]) -> CGRect? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var best: CGRect?
        for w in windows {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
            let rect = CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        return best
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return ia.width * ia.height < ib.width * ib.height
        }
    }

    /// Whether the app in front has taken the whole screen. A fullscreen app changes the presentation options in force for
    /// the whole system: Bloons TD6 hides the menu bar and the Dock, a Cocoa fullscreen window sets `.fullScreen`; with a
    /// browser in front there are none. (The menu bar's own window cannot tell: on a notched screen it stays listed on
    /// screen even in fullscreen. Measured 2026-11-09.)
    static func isFullscreen(presentationOptions options: NSApplication.PresentationOptions) -> Bool {
        !options.isDisjoint(with: [.hideMenuBar, .autoHideMenuBar, .fullScreen])
    }
}
