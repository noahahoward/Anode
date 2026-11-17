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

/// Ultra Low Power Mode as the menu needs it: whether it is on, asking for it, ending it, and being told when anything of it changes.
protocol UltraModeControlling: AnyObject {
    var isOn: Bool { get }
    /// Off, and done putting things back: only then may macOS's own Energy Mode be pressed.
    var isOff: Bool { get }
    /// Asks the person (the confirm box); the mode starts only on a Yes.
    func request()
    func turnOff()
    func observe(_ changed: @escaping () -> Void) -> AnyObject
}

/// Charge Control as the menu needs it: the limit, the two drains, and being told when any of it changes.
protocol ChargeLimiting: AnyObject {
    var limit: Int { get }
    var range: ClosedRange<Int> { get }
    func setLimit(_ value: Int)
    var softDrainRunning: Bool { get }
    var hardDrainRunning: Bool { get }
    /// Hard Drain has something to do now (the battery is above the level it comes down to).
    var canHardDrain: Bool { get }
    func pressSoftDrain()
    /// Starts Hard Drain, or stops it when it runs.
    func pressHardDrain()
    func observe(_ changed: @escaping () -> Void) -> AnyObject
}

/// The box a hold of the minus button brings up.
protocol HardDrainPrompting: AnyObject {
    /// "Would you like to Hard Drain?"; the answer is Yes (true) or No.
    func ask(_ done: @escaping (Bool) -> Void)
    /// Hard Drain cannot run just now: says why, in place of asking.
    func explainBlocked()
}

final class BatteryMenuController {

    /// The id of Anode's fourth Energy Mode row.
    static let ultraID = "ultra"

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
    private let ultra: UltraModeControlling?
    private let charge: ChargeLimiting?
    private let hardDrainPrompt: HardDrainPrompting?
    /// Anode's measurement of every app it knows, by name; read only while the menu is open.
    private let energyStats: () -> [String: EnergyStats]
    /// Told when the menu opens and closes: while it is open the app measures at the pace of someone reading.
    private let onOpenChanged: (Bool) -> Void
    private var statsTimer: Timer?
    /// The menu is open, or about to be: Anode's figures are read for it.
    private var statsWanted = false
    private let statsInterval: TimeInterval
    private var chargeObserver: AnyObject?
    private var ultraObserver: AnyObject?
    /// A mode chosen while Ultra Low Power runs: it ends first, and this is pressed in macOS's panel once it has put things back.
    private var afterUltra: String?

    /// Called as the menu is about to open: the Sound menu is closed then, as macOS closes one menu bar menu for the next.
    var onWillOpen: (() -> Void)?

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
         openBetaFeatures: @escaping () -> Void = {}, ultra: UltraModeControlling? = nil, charge: ChargeLimiting? = nil, hardDrainPrompt: HardDrainPrompting? = nil,
         energyStats: @escaping () -> [String: EnergyStats] = { [:] }, onOpenChanged: @escaping (Bool) -> Void = { _ in },
         statsInterval: TimeInterval = 0) {
        self.settings = settings; self.driver = driver; self.accessibility = accessibility; self.presenter = presenter
        self.native = native; self.pollInterval = pollInterval; self.followUpDelay = followUpDelay
        self.openBetaFeatures = openBetaFeatures
        self.ultra = ultra
        self.charge = charge
        self.hardDrainPrompt = hardDrainPrompt
        self.energyStats = energyStats
        self.onOpenChanged = onOpenChanged
        self.statsInterval = statsInterval
    }

    var isMenuOpen: Bool { presenter.isOpen }

    /// What the menu shows now: nil while nothing is known.
    var model: BatteryMenuModel? {
        guard let reading else { return nil }
        var m = BatteryMenuModel(apple: reading)
        m.showsGear = true
        if statsWanted, !m.energyApps.isEmpty {
            let known = energyStats()
            m.energyApps = m.energyApps.map { var a = $0; a.stats = known[$0.name]; return a }
        }
        if let ultra, settings.ultraLowPowerEnabled {
            // While the mode runs only its row is checked (macOS's Low Power Mode is on underneath); a choice made meanwhile is
            // shown at once, and the mode's row is not checked any more.
            let running = ultra.isOn && afterUltra == nil
            if running { m.modes = m.modes.map { var x = $0; x.isSelected = false; return x } }
            m.modes.append(.init(id: Self.ultraID, title: "Ultra Low Power", isSelected: running))
        }
        if let charge, settings.chargeControlEnabled {
            m.chargeLimit = .init(limit: charge.limit, range: charge.range, softDrainRunning: charge.softDrainRunning,
                                  hardDrainRunning: charge.hardDrainRunning)
        }
        return m
    }

    // ── Starting and stopping ───────────────────────────────────────────────

    /// Follows the setting from here on: macOS's Battery icon is taken over while it is on.
    func start() {
        if settingObserver == nil {
            settingObserver = [settings.observe(Settings.Key.batteryMenuEnabled) { [weak self] in self?.apply() },
                               settings.observe(Settings.Key.ultraLowPowerEnabled) { [weak self] in self?.redraw() },
                               settings.observe(Settings.Key.chargeControlEnabled) { [weak self] in self?.redraw() }] as AnyObject
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
        ultraObserver = ultra?.observe { [weak self] in self?.ultraChanged() }
        chargeObserver = charge?.observe { [weak self] in self?.redraw() }
        native.start(); nativeRunning = true
        if pollInterval > 0 {
            // The icon moves when the bar's other items change width: its frame is looked up again now and then.
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in _ = self?.native.currentFrame() }
        }
    }

    private func tearDown() {
        generation += 1
        pendingAnchor = nil
        setStatsWanted(false)
        afterUltra = nil
        ultraObserver = nil
        chargeObserver = nil
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
        onWillOpen?()
        openCount += 1
        setStatsWanted(true)
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
        setStatsWanted(false)
    }

    /// Anode's figures are read, and the app measures at a reader's pace, only while the menu is open.
    private func setStatsWanted(_ on: Bool) {
        guard on != statsWanted else { return }
        statsWanted = on
        onOpenChanged(on)
        statsTimer?.invalidate(); statsTimer = nil
        if on, statsInterval > 0 {
            statsTimer = Timer.scheduledTimer(withTimeInterval: statsInterval, repeats: true) { [weak self] _ in self?.refreshEnergyStats() }
        }
    }

    /// The figures beside the apps, read again (a measurement came in).
    func refreshEnergyStats() {
        guard statsWanted else { return }
        redraw()
    }

    /// Reads macOS's panel. What came back replaces what was known; the menu is redrawn (or opened, if it was waiting for this).
    private func readApple() {
        guard !readInFlight else { return }
        readInFlight = true
        driver.run(.battery, job: .read) { [weak self] outcome in
            guard let self else { return }
            self.readInFlight = false
            guard self.installed, self.pressesInFlight == 0, self.afterUltra == nil else { self.pendingAnchor = nil; return }
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
        if id == Self.ultraID { askForUltra(); return }
        guard var apple = reading, let mode = apple.modes.first(where: { $0.id == id }) else { return }
        let ultraRunning = ultra?.isOn == true && settings.ultraLowPowerEnabled
        // Already the mode in force: nothing to press. (While the mode runs macOS reads Low Power, which is not the person's choice.)
        guard ultraRunning || !mode.isSelected else { return }
        let before = reading
        // The check moves at once; macOS's answer decides whether it stays.
        apple.modes = apple.modes.map { var m = $0; m.isSelected = m.id == id; return m }
        reading = apple
        if ultraRunning, let ultra {
            // It ends first and puts everything back (it restores the person's own power mode); only then is the choice pressed.
            afterUltra = id
            ultra.turnOff()
            redraw()
            ultraChanged()
            return
        }
        redraw()
        send(modeID: id, title: mode.title, before: before)
    }

    private func send(modeID id: String, title: String, before: AppleBatteryPanel?) {
        let mine = generation
        pressesInFlight += 1
        driver.run(.battery, job: .press(SystemPanelRow(identifier: AppleBatteryPanel.modePrefix + id, description: title))) { [weak self] outcome in
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

    /// The menu goes first: the confirm box is above ordinary windows but not above this menu.
    private func askForUltra() {
        guard let ultra, settings.ultraLowPowerEnabled, ultra.isOff else { return }
        closeMenu()
        ultra.request()
    }

    /// The mode changed (it came on, went off, or finished putting things back).
    private func ultraChanged() {
        if let id = afterUltra, ultra?.isOff == true {
            afterUltra = nil
            if let title = reading?.modes.first(where: { $0.id == id })?.title { send(modeID: id, title: title, before: reading) }
        }
        redraw()
    }

    // ── The charge limit ────────────────────────────────────────────────────

    /// The slider was let go: the limit is written once (a write reaches the charger's helper, so a drag is not written step by step).
    func commitChargeLimit(_ value: Int) {
        guard let charge, settings.chargeControlEnabled else { return }
        charge.setLimit(min(max(value, charge.range.lowerBound), charge.range.upperBound))
        redraw()
    }

    /// A press of minus: Soft Drain to Limit starts, or stops. While Hard Drain runs the press stops that instead.
    func pressMinus() {
        guard let charge, settings.chargeControlEnabled else { return }
        if charge.hardDrainRunning { charge.pressHardDrain() } else { charge.pressSoftDrain() }
        redraw()
    }

    /// Minus held for three seconds: the box asks about Hard Drain. The menu goes first (the box would open behind it).
    func holdMinus() {
        guard let charge, settings.chargeControlEnabled, !charge.hardDrainRunning, let prompt = hardDrainPrompt else { return }
        closeMenu()
        guard charge.canHardDrain else { prompt.explainBlocked(); return }
        prompt.ask { [weak charge] yes in if yes { charge?.pressHardDrain() } }
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
