import AppKit
import PowerKit

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

    private var tokens: [AnyObject] = []
    private var observing = false
    private var previewUntil: Date?

    init(settings: Settings = .shared, presenter: GameHUDPresenting, observer: ActivationObserving,
         frontmost: @escaping () -> FrontmostApp?, value: @escaping (MetricID) -> MetricValue?,
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.presenter = presenter
        self.observer = observer
        self.frontmost = frontmost
        self.value = value
        self.now = now
        for key in [Settings.Key.gameHUDEnabled, Settings.Key.gameHUDCorner, Settings.Key.gameHUDExtraApps] {
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
            if observing {
                observing = false
                observer.stop()
            }
        }
        reevaluate()
    }

    /// Look at the frontmost app and put the strip up or take it down. Called on every activation, Space or display change.
    func reevaluate() {
        if let until = previewUntil, now() >= until { previewUntil = nil }
        guard let app = frontmost(), shouldShow(for: app) else {
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

    private func shouldShow(for app: FrontmostApp) -> Bool {
        if previewUntil != nil { return true }
        guard settings.gameHUDEnabled else { return false }
        return GameRules.isGame(bundleID: app.bundleID, category: app.category, extraApps: settings.gameHUDExtraApps)
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
        previewUntil = now().addingTimeInterval(seconds)
        reevaluate()
    }

    func shutdown() {
        tokens.removeAll()
        previewUntil = nil
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

    func start(_ onChange: @escaping () -> Void) {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        for (center, name) in [(ws, NSWorkspace.didActivateApplicationNotification),
                               (ws, NSWorkspace.activeSpaceDidChangeNotification),
                               (nc, NSApplication.didChangeScreenParametersNotification)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in onChange() }))
        }
    }

    func stop() {
        for (center, o) in observers { center.removeObserver(o) }
        observers.removeAll()
    }

    deinit { stop() }
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
        let screen = window.flatMap { screen(containing: $0) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        let safeTop = screen.safeAreaInsets.top
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, safeTop, 24)
        let fullscreen = window.map { isFullscreen($0, on: screen, safeTop: safeTop, windows: windows) } ?? false
        return FrontmostApp(bundleID: app.bundleIdentifier, category: category, fullscreen: fullscreen,
                            screenFrame: screen.frame, safeTop: safeTop, menuBarHeight: menuBarHeight)
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

    /// A window that fills the screen AND the menu bar is not showing there. A zoomed window fills the same rectangle but the
    /// menu bar (a "Menubar" window owned by the window server, at the top of its screen) is still up over it.
    private static func isFullscreen(_ window: CGRect, on screen: NSScreen, safeTop: CGFloat, windows: [[String: Any]]) -> Bool {
        guard window.width >= screen.frame.width - 1, window.height >= screen.frame.height - max(safeTop, 39) - 1 else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let menuBarUp = windows.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == 24, (w[kCGWindowOwnerName as String] as? String) == "Window Server",
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double, let h = b["Height"] as? Double else { return false }
            let cocoaY = primaryHeight - y - h
            return screen.frame.contains(CGPoint(x: x + 1, y: cocoaY + h - 1))
        }
        return !menuBarUp
    }
}
