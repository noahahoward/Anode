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

/// Where the apps with a volume of their own, and what the person does to them, come from (the per-app audio engine).
protocol AppVolumeControlling: AnyObject {
    var apps: [AppVolumeRow] { get }
    func setVolume(_ value: Double, forBundleID id: String)
    func setMuted(_ muted: Bool, forBundleID id: String)
}

final class SoundMenuController {

    /// Nil while per-app volume is off: the menu then has no Apps section.
    var appVolume: AppVolumeControlling?


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
    /// macOS's panel finds AirPlay speakers and Macs for a moment after it opens: the menu reads it once more this many seconds
    /// after opening, if it is still open (0: not at all).
    private let followUpDelay: TimeInterval

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
    /// Counts openings, so that a timer set for one opening does nothing in another.
    private var openCount = 0
    /// A read of macOS's panel is already out: another is not asked for, however often the menu is opened and closed.
    private var readInFlight = false
    /// Presses not yet answered: a reading that finishes meanwhile is from before them and is not used.
    private var pressesInFlight = 0
    /// Which outputs there were when the outputs last changed: only a different list is worth reading macOS's panel for.
    private var outputsSignature = ""
    /// How many looks in a row found macOS's own icon missing.
    private var missedLooks = 0

    init(settings: Settings, outputs: AudioOutputs, driver: SystemPanelDriving, batteries: @escaping () -> [AccessoryBattery],
         accessibility: @escaping () -> Bool, statusBar: StatusItemHosting, presenter: SoundMenuPresenting,
         native: NativeIconHosting, pollInterval: TimeInterval = 3, followUpDelay: TimeInterval = 1.5) {
        self.settings = settings; self.outputs = outputs; self.driver = driver; self.batteries = batteries
        self.accessibility = accessibility; self.statusBar = statusBar; self.presenter = presenter
        self.native = native; self.pollInterval = pollInterval; self.followUpDelay = followUpDelay
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
        m.apps = appVolume?.apps ?? []
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
        if settings.soundMenuEnabled { install() } else { settings.soundMenuLastReading = nil; tearDown() }
    }

    private func install() {
        if !installed {
            installed = true
            outputs.onChange = { [weak self] in self?.outputsChanged() }
            outputs.start()
            outputsSignature = currentOutputsSignature()
            reading = settings.soundMenuLastReading.flatMap { try? JSONDecoder().decode(AppleReading.self, from: $0) }
            native.onClick = { [weak self] frame in self?.nativeClicked(frame) }
        }
        refreshNativeIcon()
    }

    /// Which icon the menu opens from: macOS's own when the person chose that and it is in the bar, otherwise one of Anode's.
    /// Called again every second while macOS's is in use, so removing it in System Settings brings Anode's back.
    func refreshNativeIcon() {
        guard installed else { return }
        // One look that finds nothing is often a slow answer from Accessibility, not a removed icon: it takes two in a row.
        let seen = native.currentFrame() != nil
        missedLooks = seen ? 0 : missedLooks + 1
        let useNative = settings.soundMenuUsesNativeIcon && (seen || (nativeRunning && missedLooks < 2))
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
        openCount += 1
        presenter.show(model, below: anchor)
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
        presenter.close()
    }

    /// Reads macOS's panel, when Accessibility allows. What came back replaces what was known; the model is redrawn.
    private func readApple() {
        guard accessibility() else {
            reading = nil
            settings.soundMenuLastReading = nil   // what was read before is not shown, and is not kept
            notice = Self.needsAccessibility
            presenter.update(model)
            return
        }
        guard !readInFlight else { return }
        readInFlight = true
        driver.run(.sound, job: .read) { [weak self] outcome in
            guard let self else { return }
            self.readInFlight = false
            // After teardown, or with a press still to be answered (this reading is from before it), the answer is not used.
            guard self.installed, self.pressesInFlight == 0 else { return }
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

    /// The outputs there are and which is playing: what makes macOS's panel worth reading again.
    private func currentOutputsSignature() -> String {
        (outputs.devices.map(\.id).sorted() + ["default=\(outputs.defaultDeviceID ?? "")"]).joined(separator: "|")
    }

    private func outputsChanged() {
        refreshIcon()
        // The volume changes this callback too (a drag on the slider is dozens of them): macOS's panel is read again only when the
        // outputs or the one playing changed.
        let signature = currentOutputsSignature()
        let outputsMoved = signature != outputsSignature
        outputsSignature = signature
        guard presenter.isOpen else { return }
        if outputsMoved {
            // A speaker came or went: `currentApple` already leaves out what has gone, and the reading below corrects the rest.
            // A line about the one that was there ("Put both AirPods in…") no longer applies.
            notice = nil
            redraw()
            readApple()
        } else {
            redraw()
        }
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

    /// The apps that can be controlled came or went (an app opened or quit, a tap failed): the open menu shows it.
    func appsChanged() { redraw() }

    func setAppVolume(bundleID: String, _ value: Double) {
        appVolume?.setVolume(value, forBundleID: bundleID)
        if appVolume?.apps.first(where: { $0.bundleID == bundleID })?.muted == true, value > 0 { appVolume?.setMuted(false, forBundleID: bundleID) }
        redraw()
    }

    func toggleAppMute(bundleID: String) {
        guard let app = appVolume?.apps.first(where: { $0.bundleID == bundleID }) else { return }
        appVolume?.setMuted(!app.muted, forBundleID: bundleID)
        redraw()
    }

    /// A volume key pressed while the menu is open: the level moves a sixteenth, as macOS's own keys would move it, or the mute switches.
    /// The speaker icons at the two ends of the slider: ten points a press, as macOS's (the volume keys move by a sixteenth).
    func stepVolumeFromIcon(up: Bool) {
        let level = outputs.muted ? 0 : outputs.volume
        setVolume(min(1, max(0, level + (up ? 0.1 : -0.1))))
    }

    func volumeKey(_ key: MediaKeyEvent.Key) {
        guard presenter.isOpen else { return }
        if let level = VolumeKeys.next(volume: outputs.muted ? 0 : outputs.volume, key: key) { setVolume(level) } else { toggleMute() }
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
        let mine = AccessoryBattery.selected(forDeviceNamed: row.device, in: batteries())
        if row.title == "Adaptive", let group = mine.first?.group,
           !AccessoryBattery.bothBudsPresent(in: mine, group: group) {
            notice = Self.adaptiveNeedsBothBuds
            redraw()
            return
        }
        press(SystemPanelRow(identifier: AppleSoundPanel.devicePrefix + row.device, description: row.title, section: row.section), optimistic: row)
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
        pressesInFlight += 1
        driver.run(.sound, job: .press(row)) { [weak self] outcome in
            guard let self else { return }
            self.pressesInFlight = max(0, self.pressesInFlight - 1)
            guard mine == self.generation else { return }
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
            // How it ended is read from macOS's panel, not assumed: a change that did not hold shows as it is.
            if self.presenter.isOpen { self.readApple() }
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
