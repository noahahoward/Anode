import AppKit
import PowerKit

// ── Anode's Battery menu: what it does ──────────────────────────────────────
//
// A click on macOS's own Battery icon opens Anode's menu instead of macOS's panel. What the menu shows is what macOS's panel says,
// read through Accessibility with the panel moved off the screen (`SystemPanelDriving`, kind `.battery`); choosing an Energy Mode
// presses macOS's own row, since only macOS can change the mode. The menu opens at once with the last reading kept, and the reading
// behind the opening corrects it in place, the way the Sound menu does. With nothing known yet it opens when the first reading
// arrives: a blank panel is never drawn. Every dependency is a protocol so all of it is tested with fakes; the drawn menu is
// BatteryMenuPanel.swift.

/// The drawn menu.
protocol BatteryMenuPresenting: AnyObject {
    var isOpen: Bool { get }
    func show(_ model: BatteryMenuModel, below frame: CGRect)
    func update(_ model: BatteryMenuModel)
    func close()
}

final class BatteryMenuController {

    private let settings: Settings
    private let driver: SystemPanelDriving
    private let accessibility: () -> Bool
    private let presenter: BatteryMenuPresenting
    private let native: NativeIconHosting
    private let pollInterval: TimeInterval
    /// macOS's panel is read once more this many seconds after the menu opens, if it is still open (0: not at all).
    private let followUpDelay: TimeInterval
    /// What the gear does: Anode's Beta Features window.
    private let openBetaFeatures: () -> Void

    /// How a URL is opened (the Settings pane); the tests replace it.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var reading: AppleBatteryPanel?
    private var installed = false
    private var nativeRunning = false
    private var settingObserver: AnyObject?
    private var pollTimer: Timer?
    private var clickAnchor: CGRect?
    /// A click opened the menu but there was nothing to draw yet: it opens when the reading arrives (unless clicked away).
    private var pendingAnchor: CGRect?
    private var generation = 0
    private var openCount = 0
    private var readInFlight = false
    /// Presses not yet answered: a reading that finishes meanwhile is from before them and is not used.
    private var pressesInFlight = 0

    init(settings: Settings, driver: SystemPanelDriving, accessibility: @escaping () -> Bool, presenter: BatteryMenuPresenting,
         native: NativeIconHosting, pollInterval: TimeInterval = 3, followUpDelay: TimeInterval = 1.5,
         openBetaFeatures: @escaping () -> Void = {}) {
        self.settings = settings; self.driver = driver; self.accessibility = accessibility; self.presenter = presenter
        self.native = native; self.pollInterval = pollInterval; self.followUpDelay = followUpDelay
        self.openBetaFeatures = openBetaFeatures
    }

    var isMenuOpen: Bool { presenter.isOpen }

    /// What the menu shows now: nil while nothing is known.
    var model: BatteryMenuModel? {
        guard let reading else { return nil }
        var m = BatteryMenuModel(apple: reading)
        m.showsGear = true
        return m
    }

    // ── Starting and stopping ───────────────────────────────────────────────

    /// Follows the setting from here on: macOS's Battery icon is taken over while it is on.
    func start() {
        if settingObserver == nil {
            settingObserver = settings.observe(Settings.Key.batteryMenuEnabled) { [weak self] in self?.apply() } as AnyObject
        }
        apply()
    }

    func stop() {
        settingObserver = nil
        tearDown()
    }

    private func apply() {
        if settings.batteryMenuEnabled { install() } else { settings.batteryMenuLastReading = nil; tearDown() }
    }

    private func install() {
        guard !installed else { return }
        installed = true
        reading = settings.batteryMenuLastReading.flatMap { try? JSONDecoder().decode(AppleBatteryPanel.self, from: $0) }
        native.onClick = { [weak self] frame in self?.nativeClicked(frame) }
        native.start(); nativeRunning = true
        if pollInterval > 0 {
            // The icon moves when the bar's other items change width: its frame is looked up again now and then.
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in _ = self?.native.currentFrame() }
        }
    }

    private func tearDown() {
        generation += 1
        pendingAnchor = nil
        presenter.close()
        driver.cancelAll()
        pollTimer?.invalidate(); pollTimer = nil
        if nativeRunning { native.stop(); nativeRunning = false }
        installed = false
        reading = nil
    }

    private func nativeClicked(_ frame: CGRect) {
        clickAnchor = frame
        toggleMenu()
    }

    // ── The menu ────────────────────────────────────────────────────────────

    func toggleMenu() {
        if presenter.isOpen || pendingAnchor != nil { closeMenu() } else { openMenu() }
    }

    func openMenu() {
        guard !presenter.isOpen, pendingAnchor == nil, accessibility(), let anchor = clickAnchor ?? native.currentFrame() else { return }
        openCount += 1
        if let model {
            presenter.show(model, below: anchor)
        } else {
            pendingAnchor = anchor
        }
        readApple()
        if followUpDelay > 0 {
            let mine = openCount
            DispatchQueue.main.asyncAfter(deadline: .now() + followUpDelay) { [weak self] in
                guard let self, mine == self.openCount, self.presenter.isOpen else { return }
                self.readApple()
            }
        }
    }

    func closeMenu() {
        generation += 1
        pendingAnchor = nil
        presenter.close()
    }

    /// Reads macOS's panel. What came back replaces what was known; the menu is redrawn (or opened, if it was waiting for this).
    private func readApple() {
        guard !readInFlight else { return }
        readInFlight = true
        driver.run(.battery, job: .read) { [weak self] outcome in
            guard let self else { return }
            self.readInFlight = false
            guard self.installed, self.pressesInFlight == 0 else { self.pendingAnchor = nil; return }
            if case .tree(let tree) = outcome {
                let parsed = AppleBatteryPanel.parse(tree)
                if parsed.looksLikeTheBatteryPanel {
                    self.reading = parsed
                    self.settings.batteryMenuLastReading = try? JSONEncoder().encode(parsed)
                }
            }
            self.redraw()
        }
    }

    /// Draws what is known: updates the open menu, or opens the one that was waiting for a first reading.
    private func redraw() {
        if let anchor = pendingAnchor {
            pendingAnchor = nil
            if let model { presenter.show(model, below: anchor) }
        } else if presenter.isOpen, let model {
            presenter.update(model)
        }
    }

    // ── What the person presses ─────────────────────────────────────────────

    func pickMode(_ id: String) {
        guard var apple = reading, let mode = apple.modes.first(where: { $0.id == id }), !mode.isSelected else { return }
        let before = reading
        // The check moves at once; macOS's answer decides whether it stays.
        apple.modes = apple.modes.map { var m = $0; m.isSelected = m.id == id; return m }
        reading = apple
        redraw()
        let mine = generation
        pressesInFlight += 1
        driver.run(.battery, job: .press(SystemPanelRow(identifier: AppleBatteryPanel.modePrefix + id, description: mode.title))) { [weak self] outcome in
            guard let self else { return }
            self.pressesInFlight = max(0, self.pressesInFlight - 1)
            guard mine == self.generation else { return }
            switch outcome {
            case .pressed, .tree: break
            case .refused, .failed: self.reading = before
            }
            self.redraw()
            // How it ended is read from macOS's panel, not assumed.
            if self.presenter.isOpen { self.readApple() }
        }
    }

    func pressGear() {
        closeMenu()
        openBetaFeatures()
    }

    func pressSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { openURL(url) }
        closeMenu()
    }
}
