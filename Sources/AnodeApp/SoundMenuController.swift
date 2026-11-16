import AppKit
import PowerKit

// ── Anode's Sound menu: what it does ────────────────────────────────────────
//
// Joins the Mac's own readings (`AudioOutputs`, the accessory batteries) with what macOS's own panel says (`SystemPanelDriving`)
// into one `SoundMenuModel`, hands that to the drawn menu, and turns what the person presses into the right call: Core Audio for
// the volume and the outputs, macOS's panel for the rows only it can drive. Every dependency is a protocol so all of it is tested
// with fakes; the drawn menu and the real status item are in SoundMenuPanel.swift.

/// The icon in the menu bar.
protocol StatusItemHandle: AnyObject {
    /// An SF Symbol name.
    var symbolName: String { get set }
    var onClick: (() -> Void)? { get set }
    /// Where the icon is on the screen (top-left global points).
    var frame: CGRect { get }
    func remove()
}

protocol StatusItemHosting: AnyObject {
    func makeItem() -> StatusItemHandle
}

/// The drawn menu.
protocol SoundMenuPresenting: AnyObject {
    var isOpen: Bool { get }
    func show(_ model: SoundMenuModel, below frame: CGRect)
    func update(_ model: SoundMenuModel)
    func close()
}

final class SoundMenuController {

    static let needsAccessibility = "Needs Accessibility for the listening mode, Conversation Awareness and AirPlay rows."
    static let adaptiveNeedsBothBuds = "Put both AirPods in to use Adaptive."

    private let settings: Settings
    private let outputs: AudioOutputs
    private let driver: SystemPanelDriving
    private let batteries: () -> [AccessoryBattery]
    private let accessibility: () -> Bool
    private let statusBar: StatusItemHosting
    private let presenter: SoundMenuPresenting

    private var item: StatusItemHandle?
    private var settingObserver: AnyObject?
    private var apple: AppleSoundPanel?
    private var notice: String?
    private var collapsed = Set<String>()
    private var generation = 0

    init(settings: Settings, outputs: AudioOutputs, driver: SystemPanelDriving, batteries: @escaping () -> [AccessoryBattery],
         accessibility: @escaping () -> Bool, statusBar: StatusItemHosting, presenter: SoundMenuPresenting) {
        self.settings = settings; self.outputs = outputs; self.driver = driver; self.batteries = batteries
        self.accessibility = accessibility; self.statusBar = statusBar; self.presenter = presenter
    }

    var isMenuOpen: Bool { presenter.isOpen }

    /// What the menu shows now.
    var model: SoundMenuModel {
        let open = apple?.expandedDevice.flatMap { collapsed.contains($0) ? "" : $0 }
        var m = SoundMenuModel.merge(outputs: outputs.devices, defaultID: outputs.defaultDeviceID, volume: outputs.volume,
                                     muted: outputs.muted, batteries: batteries(), apple: apple, expanded: open)
        m.notice = notice
        return m
    }

    // ── Starting and stopping ───────────────────────────────────────────────

    /// Follows the setting from here on: the icon is there while it is on.
    func start() {
        if settingObserver == nil {
            settingObserver = settings.observe(Settings.Key.soundMenuEnabled) { [weak self] in self?.apply() }
        }
        apply()
    }

    func stop() {
        settingObserver = nil
        tearDown()
    }

    private func apply() {
        if settings.soundMenuEnabled { install() } else { tearDown() }
    }

    private func install() {
        guard item == nil else { return }
        let handle = statusBar.makeItem()
        handle.onClick = { [weak self] in self?.toggleMenu() }
        item = handle
        outputs.onChange = { [weak self] in self?.outputsChanged() }
        outputs.start()
        refreshIcon()
    }

    private func tearDown() {
        generation += 1
        presenter.close()
        outputs.onChange = nil
        outputs.stop()
        item?.remove()
        item = nil
        apple = nil
        notice = nil
    }

    // ── The menu ────────────────────────────────────────────────────────────

    func toggleMenu() { isMenuOpen ? closeMenu() : openMenu() }

    func openMenu() {
        guard let item, !presenter.isOpen else { return }
        notice = nil
        collapsed.removeAll()
        presenter.show(model, below: item.frame)
        readApple()
    }

    func closeMenu() { presenter.close() }

    /// Reads macOS's panel, when Accessibility allows. What came back replaces what was known; the model is redrawn.
    private func readApple() {
        guard accessibility() else {
            apple = nil
            notice = Self.needsAccessibility
            presenter.update(model)
            return
        }
        generation += 1
        let mine = generation
        driver.run(.sound, job: .read) { [weak self] outcome in
            guard let self, mine == self.generation else { return }
            if case .tree(let tree) = outcome {
                let parsed = AppleSoundPanel.parse(tree)
                self.apple = parsed.devices.isEmpty ? nil : parsed
            }
            self.redraw()
        }
    }

    private func outputsChanged() {
        refreshIcon()
        guard presenter.isOpen else { return }
        // A speaker came or went: what macOS's panel said about it is out of date.
        apple = nil
        redraw()
        readApple()
    }

    private func redraw() {
        refreshIcon()
        if presenter.isOpen { presenter.update(model) }
    }

    private func refreshIcon() {
        let defaultKind = outputs.devices.first { $0.id == outputs.defaultDeviceID }?.kind ?? .speakers
        item?.symbolName = SoundIcon.symbol(volume: outputs.volume, muted: outputs.muted, output: defaultKind)
    }

    // ── What the person presses ─────────────────────────────────────────────

    func setVolume(_ value: Double) {
        outputs.setVolume(value)
        if outputs.muted && value > 0 { outputs.setMuted(false) }
        redraw()
    }

    func toggleMute() {
        outputs.setMuted(!outputs.muted)
        redraw()
    }

    func pickOutput(_ device: SoundMenuModel.Device) {
        notice = nil
        if let id = device.id {
            outputs.setDefault(id)
        } else {
            // An AirPlay speaker: only macOS's panel can switch to it.
            press(SystemPanelRow(identifier: AppleSoundPanel.devicePrefix + device.name, description: device.name), optimistic: nil)
        }
    }

    func pickChoice(_ row: AppleChoiceRow) {
        guard row.enabled, !row.isOn else { return }
        notice = nil
        if row.title == "Adaptive", let group = batteries().first?.group,
           !AccessoryBattery.bothBudsPresent(in: batteries(), group: group) {
            notice = Self.adaptiveNeedsBothBuds
            redraw()
            return
        }
        press(SystemPanelRow(identifier: AppleSoundPanel.devicePrefix + row.device, description: row.title), optimistic: row)
    }

    func toggleExpanded(_ name: String) {
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        redraw()
    }

    private func press(_ row: SystemPanelRow, optimistic choice: AppleChoiceRow?) {
        guard accessibility() else { notice = Self.needsAccessibility; redraw(); return }
        let before = apple
        if let choice, var a = apple {
            // The check moves at once; macOS's answer decides whether it stays.
            func moved(_ rows: [AppleChoiceRow]) -> [AppleChoiceRow] {
                rows.map { var r = $0; if r.section == choice.section { r.isOn = r.title == choice.title }; return r }
            }
            a.listening = moved(a.listening); a.spatial = moved(a.spatial); a.conversation = moved(a.conversation)
            apple = a
        }
        redraw()
        let mine = generation
        driver.run(.sound, job: .press(row)) { [weak self] outcome in
            guard let self, mine == self.generation else { return }
            switch outcome {
            case .pressed, .tree: break
            case .refused(let text):
                self.apple = before
                self.notice = text.components(separatedBy: " / ").last ?? text
            case .failed:
                self.apple = before
                self.notice = "Couldn't change that just now."
            }
            self.redraw()
        }
    }

    func pressSettings(_ index: Int) {
        let titles = model.footerTitles
        guard titles.indices.contains(index) else { return }
        // Sound Settings opens the pane; the AirPods' own settings are macOS's panel's to open.
        if index == titles.count - 1 {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
        } else {
            press(SystemPanelRow(identifier: "", description: titles[index]), optimistic: nil)
        }
        closeMenu()
    }
}
