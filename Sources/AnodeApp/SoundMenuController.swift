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

/// macOS's own Sound icon in the menu bar, when Anode lets a click on it open Anode's menu instead of showing a second icon.
protocol NativeIconHosting: AnyObject {
    /// The icon's frame now (top-left global points); nil when macOS's Sound icon is not in the bar.
    func currentFrame() -> CGRect?
    /// A click that was taken, with the icon's frame. Called on the main queue.
    var onClick: ((CGRect) -> Void)? { get set }
    func start()
    func stop()
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
    private let native: NativeIconHosting
    private let pollInterval: TimeInterval

    private var item: StatusItemHandle?
    private var installed = false
    private var nativeRunning = false
    private var clickAnchor: CGRect?
    private var pollTimer: Timer?
    private var settingObserver: AnyObject?
    private var reading: AppleReading?
    private var notice: String?
    private var collapsed = Set<String>()
    private var generation = 0

    init(settings: Settings, outputs: AudioOutputs, driver: SystemPanelDriving, batteries: @escaping () -> [AccessoryBattery],
         accessibility: @escaping () -> Bool, statusBar: StatusItemHosting, presenter: SoundMenuPresenting,
         native: NativeIconHosting, pollInterval: TimeInterval = 1) {
        self.settings = settings; self.outputs = outputs; self.driver = driver; self.batteries = batteries
        self.accessibility = accessibility; self.statusBar = statusBar; self.presenter = presenter
        self.native = native; self.pollInterval = pollInterval
    }

    /// What macOS's panel last said, less whatever has left since (AirPods taken out take their rows with them). It is what the
    /// menu opens with, so the first picture is the full one; the reading behind the opening then corrects it in place.
    private var currentApple: AppleSoundPanel? {
        reading?.current(outputNames: Set(outputs.devices.map(\.name)))
    }

    var isMenuOpen: Bool { presenter.isOpen }

    /// What the menu shows now.
    var model: SoundMenuModel {
        let known = currentApple
        let open = known?.expandedDevice.flatMap { collapsed.contains($0) ? "" : $0 }
        var m = SoundMenuModel.merge(outputs: outputs.devices, defaultID: outputs.defaultDeviceID, volume: outputs.volume,
                                     muted: outputs.muted, batteries: batteries(), apple: known, expanded: open)
        m.notice = notice
        return m
    }

    // ── Starting and stopping ───────────────────────────────────────────────

    /// Follows the setting from here on: the icon is there while it is on.
    func start() {
        if settingObserver == nil {
            settingObserver = [settings.observe(Settings.Key.soundMenuEnabled) { [weak self] in self?.apply() },
                               settings.observe(Settings.Key.soundMenuUsesNativeIcon) { [weak self] in self?.apply() }] as AnyObject
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
        if !installed {
            installed = true
            outputs.onChange = { [weak self] in self?.outputsChanged() }
            outputs.start()
            reading = settings.soundMenuLastReading.flatMap { try? JSONDecoder().decode(AppleReading.self, from: $0) }
            native.onClick = { [weak self] frame in self?.nativeClicked(frame) }
        }
        refreshNativeIcon()
    }

    /// Which icon the menu opens from: macOS's own when the person chose that and it is in the bar, otherwise one of Anode's.
    /// Called again every second while macOS's is in use, so removing it in System Settings brings Anode's back.
    func refreshNativeIcon() {
        guard installed else { return }
        let useNative = settings.soundMenuUsesNativeIcon && native.currentFrame() != nil
        if useNative {
            if let item { item.remove(); self.item = nil }
            if !nativeRunning { native.start(); nativeRunning = true }
        } else {
            if nativeRunning { native.stop(); nativeRunning = false }
            if item == nil {
                let handle = statusBar.makeItem()
                handle.onClick = { [weak self] in self?.toggleMenu() }
                item = handle
            }
        }
        refreshIcon()
        pollTimer?.invalidate(); pollTimer = nil
        if settings.soundMenuUsesNativeIcon && pollInterval > 0 {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.refreshNativeIcon() }
        }
    }

    private func tearDown() {
        generation += 1
        presenter.close()
        driver.cancelAll()
        pollTimer?.invalidate(); pollTimer = nil
        if nativeRunning { native.stop(); nativeRunning = false }
        outputs.onChange = nil
        outputs.stop()
        item?.remove()
        item = nil
        installed = false
        reading = nil
        notice = nil
    }

    private func nativeClicked(_ frame: CGRect) {
        clickAnchor = frame
        toggleMenu()
    }

    // ── The menu ────────────────────────────────────────────────────────────

    func toggleMenu() { isMenuOpen ? closeMenu() : openMenu() }

    /// Opens at once, every time: with a cold or out-of-date reading the first click would otherwise be slower than the rest.
    /// What macOS's panel says arrives a moment later and fills in the rows only it knows.
    func openMenu() {
        guard !presenter.isOpen else { return }
        let anchor: CGRect? = nativeRunning ? (clickAnchor ?? native.currentFrame()) : item?.frame
        guard let anchor else { return }
        notice = nil
        collapsed.removeAll()
        presenter.show(model, below: anchor)
        readApple()
    }

    func closeMenu() {
        generation += 1
        presenter.close()
    }

    /// Reads macOS's panel, when Accessibility allows. What came back replaces what was known; the model is redrawn.
    private func readApple() {
        guard accessibility() else {
            reading = nil
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
                let names = Set(self.outputs.devices.map(\.name))
                self.reading = parsed.devices.isEmpty ? nil
                    : AppleReading(panel: parsed, coreBacked: parsed.devices.map(\.name).filter { names.contains($0) })
                self.settings.soundMenuLastReading = self.reading.flatMap { try? JSONEncoder().encode($0) }
            }
            self.redraw()
        }
    }

    private func outputsChanged() {
        refreshIcon()
        // A speaker came or went: `currentApple` already leaves out what has gone, and the reading below corrects the rest.
        // A line about the one that was there ("Put both AirPods in…") no longer applies.
        notice = nil
        guard presenter.isOpen else { return }
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
        let before = reading
        if let choice, var a = reading {
            // The check moves at once; macOS's answer decides whether it stays.
            func moved(_ rows: [AppleChoiceRow]) -> [AppleChoiceRow] {
                rows.map { var r = $0; if r.section == choice.section { r.isOn = r.title == choice.title }; return r }
            }
            a.panel.listening = moved(a.panel.listening); a.panel.spatial = moved(a.panel.spatial)
            a.panel.conversation = moved(a.panel.conversation)
            reading = a
        }
        redraw()
        let mine = generation
        driver.run(.sound, job: .press(row)) { [weak self] outcome in
            guard let self, mine == self.generation else { return }
            switch outcome {
            case .pressed, .tree: break
            case .refused(let text):
                self.reading = before
                self.notice = text.components(separatedBy: " / ").last ?? text
            case .failed:
                self.reading = before
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
        } else if reading?.panel.settingsButtons.contains(titles[index]) == true {
            // Only a button macOS's panel itself listed is pressed (these have no id to match on, only their label).
            press(SystemPanelRow(identifier: "", description: titles[index]), optimistic: nil)
        }
        closeMenu()
    }
}
