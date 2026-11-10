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
