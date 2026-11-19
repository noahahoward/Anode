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
    /// `fade`: as macOS's panel closes (a straight-line fade); not when another panel takes its place, which is one frame.
    func close(fade: Bool)
    /// Where the Adaptive slider is drawn now, in top-left global points; nil while there is none.
    func adaptiveSliderPlacement() -> AdaptiveSliderPlacement?
    /// Cuts a hole over the slider, where macOS's own slider lies under the menu (nil closes it again).
    func setAdaptiveSliderHole(_ hole: CGRect?)
}

extension SoundMenuPresenting {
    func close() { close(fade: true) }
    func adaptiveSliderPlacement() -> AdaptiveSliderPlacement? { nil }
    func setAdaptiveSliderHole(_ hole: CGRect?) {}
}

/// Where Anode's Adaptive slider is on the screen (top-left global points): its left end icon (which macOS's is lined up on), the hole
/// to cut over it (the capsule), the menu (what macOS's panel is hidden under), and its whole row (the pointer anywhere on it counts as
/// on the slider: one that comes onto the row from its left end must not miss it).
struct AdaptiveSliderPlacement: Equatable {
    var leftIcon: CGRect
    var hole: CGRect
    var menu: CGRect
    var row: CGRect
}

/// One of macOS's own icons in the menu bar (Sound, Battery), when Anode lets a click on it open Anode's menu instead of showing a second icon.
protocol NativeIconHosting: AnyObject {
    /// The icon's frame now (top-left global points); nil when macOS's icon is not in the bar.
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
    /// Called as the menu is about to open: the Battery menu is closed then, as macOS closes one menu bar menu for the next.
    var onWillOpen: (() -> Void)?


    static let needsAccessibility = "Needs Accessibility for the listening mode, Conversation Awareness and AirPlay rows."

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
    /// What the gear does: shows Beta Features, where this menu is switched.
    private let openBetaFeatures: () -> Void

    init(settings: Settings, outputs: AudioOutputs, driver: SystemPanelDriving, batteries: @escaping () -> [AccessoryBattery],
         accessibility: @escaping () -> Bool, statusBar: StatusItemHosting, presenter: SoundMenuPresenting,
         native: NativeIconHosting, pollInterval: TimeInterval = 3, followUpDelay: TimeInterval = 1.5,
         openBetaFeatures: @escaping () -> Void = {}) {
        self.openBetaFeatures = openBetaFeatures
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
        m.showsGear = true
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
        onWillOpen?()
        driver.closePanelOpenedByPerson()
        notice = nil
        refused = nil
        putSliderAway()
        sliderArming = AdaptiveSliderArming()   // a new opening tries afresh
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

    func closeMenu(fade: Bool = true) {
        putSliderAway()
        generation += 1
        refused = nil
        presenter.close(fade: fade)
    }

    /// The choice macOS refused in this opening of the menu. macOS's panel, read again just after a refusal, can still show the
    /// choice it refused (seen: Adaptive with one AirPod out showed as checked while Transparency was the mode); such a reading is
    /// not taken for that section. A new choice, or a new opening, forgets it: from then on what macOS shows is shown.
    private var refused: AppleChoiceRow?

    /// `read` with the refused choice's section as it was (`kept`) when `read` shows that choice on. Pure.
    static func notShowingRefused(_ refused: AppleChoiceRow?, read: AppleSoundPanel, kept: AppleSoundPanel?) -> AppleSoundPanel {
        guard let refused, let kept else { return read }
        var out = read
        switch refused.section {
        case AppleSoundPanel.listeningHeading:
            if read.listening.contains(where: { $0.title == refused.title && $0.isOn }) { out.listening = kept.listening }
        case AppleSoundPanel.spatialHeading:
            if read.spatial.contains(where: { $0.title == refused.title && $0.isOn }) { out.spatial = kept.spatial }
        default:
            if read.conversation.contains(where: { $0.title == refused.title && $0.isOn }) { out.conversation = kept.conversation }
        }
        return out
    }

    /// Reads macOS's panel, when Accessibility allows. What came back replaces what was known; the model is redrawn.
    private func readApple() {
        // A reading would take macOS's panel from under the slider while the pointer is on it: it waits for the next opening.
        guard sliderArming.state != .armed, sliderArming.state != .arming else { readSkippedForSlider = true; return }
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
                let parsed = Self.notShowingRefused(self.refused, read: AppleSoundPanel.parse(tree), kept: self.reading?.panel)
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
        putSliderAway()
        notice = nil
        if let id = device.id {
            outputs.setDefault(id)
        } else {
            // An AirPlay speaker: only macOS's panel can switch to it.
            press(SystemPanelRow(identifier: AppleSoundPanel.devicePrefix + device.name, description: device.name), optimistic: nil)
        }
    }

    /// Every choice is asked of macOS, Adaptive too: whether it can be had (both AirPods in the ears) is macOS's to say, and its
    /// refusal is shown with its reason. Anode's own guess, from the battery list, was wrong both ways: that list cannot tell an ear
    /// from the case, and comes and goes.
    func pickChoice(_ row: AppleChoiceRow) {
        guard row.enabled, !row.isOn else { return }
        putSliderAway()
        notice = nil
        refused = nil
        press(SystemPanelRow(identifier: AppleSoundPanel.devicePrefix + row.device, description: row.title, section: row.section), optimistic: row)
    }

    func toggleExpanded(_ name: String) {
        putSliderAway()
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        redraw()
    }

    private func press(_ row: SystemPanelRow, optimistic choice: AppleChoiceRow?) {
        putSliderAway()
        guard accessibility() else { notice = Self.needsAccessibility; redraw(); return }
        let before = reading
        if let choice, var a = reading {
            // The check moves at once; macOS's answer decides whether it stays.
            func moved(_ rows: [AppleChoiceRow]) -> [AppleChoiceRow] {
                rows.map { var r = $0; if r.section == choice.section { r.isOn = r.title == choice.title }; return r }
            }
            a.panel.listening = moved(a.panel.listening); a.panel.spatial = moved(a.panel.spatial)
            a.panel.conversation = moved(a.panel.conversation)
            // Adaptive Audio's slider belongs to Adaptive: another mode takes it away with the check. (macOS's answer brings it back.)
            if choice.section == AppleSoundPanel.listeningHeading { a.panel.adaptiveLevel = nil }
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
                self.refused = choice
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

    // ── Adaptive Audio's slider: macOS's own, under Anode's ─────────────────
    // While the pointer is on the slider, macOS's panel is opened under the menu and moved so its slider lies exactly under Anode's,
    // and the menu has a hole there: the drag is on macOS's slider itself (the only thing that moves it, measured). See
    // `AdaptiveSliderArming` for when it comes and goes.

    private var sliderArming = AdaptiveSliderArming()
    private var sliderWatch: Timer?
    private var armedPlacement: AdaptiveSliderPlacement?
    /// Which arm a driver's answer belongs to: an answer from one that was put away (a quick close and reopen) is not this one's.
    private var armGeneration = 0
    private var hoverTimer: Timer?
    /// A reading skipped while macOS's panel was under the slider, made up for once it is put away.
    private var readSkippedForSlider = false

    /// How long the pointer stays on the slider's row before macOS's panel is put under it: crossing the row on the way to another
    /// row does not open and close macOS's panel (two screen pictures and a fraction of a second each time).
    var hoverDwell: TimeInterval = 0.15
    /// Where the pointer is and whether its button is down; replaced in tests.
    var pointerIn: (CGRect) -> Bool = { rect in
        guard let screen = NSScreen.screens.first else { return false }
        let p = NSEvent.mouseLocation
        return rect.contains(CGPoint(x: p.x, y: screen.frame.height - p.y))
    }
    var buttonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// The pointer came onto the slider's row. Once it has rested there `hoverDwell`, and macOS's panel is free (Anode reads it as the
    /// menu opens, and uses it for a press), macOS's slider is put under Anode's; for as long as the pointer stays on the row.
    func adaptiveSliderHovered() {
        guard presenter.isOpen, model.adaptiveLevel != nil, sliderArming.state == .idle, hoverTimer == nil else { return }
        let began = Date()
        let check = { [weak self] () -> Bool in   // true when there is nothing more to wait for
            guard let self else { return true }
            guard self.presenter.isOpen, self.sliderArming.state == .idle,
                  let place = self.presenter.adaptiveSliderPlacement(), self.pointerIn(place.row) else { return true }
            guard Date().timeIntervalSince(began) >= self.hoverDwell, self.pressesInFlight == 0, !self.readInFlight,
                  self.driver.panelIsFree else { return false }
            self.arm(place)
            return true
        }
        if check() { return }
        // Looked at again until `check` says there is nothing more to wait for.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self, check() else { return }
            t.invalidate(); self.hoverTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func arm(_ place: AdaptiveSliderPlacement) {
        guard sliderArming.pointerEntered() == .arm else { return }
        armGeneration += 1
        let mine = armGeneration
        driver.armAdaptiveSlider(leftIcon: place.leftIcon, cover: place.menu.insetBy(dx: -24, dy: -24), hole: place.hole) { [weak self] ok in
            guard let self, mine == self.armGeneration else { return }
            let still = self.presenter.adaptiveSliderPlacement()
            let inside = still.map { self.pointerIn($0.row) } ?? false
            switch self.sliderArming.armFinished(ok: ok && still == place, pointerInside: inside) {
            case .showHole:
                self.armedPlacement = place
                self.presenter.setAdaptiveSliderHole(place.hole)
                self.watchSlider()
            case .disarm:
                self.finishSlider()
            case .none, .arm:
                if ok, still != place { self.finishSlider() }   // the slider moved while macOS's was put under it
            }
        }
    }

    /// A press that reached Anode's own drawing of the slider (macOS's was not in place under it).
    func adaptiveSliderPressed() {
        if sliderArming.handsOverOnPress { openAdaptiveInMacOS() }
    }

    private func watchSlider() {
        sliderWatch?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.checkSlider()
        }
        RunLoop.main.add(timer, forMode: .common)
        sliderWatch = timer
    }

    /// While macOS's slider is under Anode's: it is put away once the pointer has left the row with the button up, or macOS closed its
    /// panel (any click elsewhere does), or the slider moved in the menu.
    func checkSlider() {
        let now = presenter.adaptiveSliderPlacement()
        let inside = now.map { pointerIn($0.row.insetBy(dx: 0, dy: -4)) } ?? false
        let open = driver.adaptiveSliderPanelOpen && now == armedPlacement
        if sliderArming.tick(pointerInside: inside, buttonDown: buttonDown(), panelOpen: open) == .disarm { finishSlider() }
    }

    /// Puts macOS's panel away, takes the level its knob was left at, and draws Anode's slider at it again.
    private func finishSlider() {
        sliderWatch?.invalidate(); sliderWatch = nil
        armedPlacement = nil
        armGeneration += 1
        let level = driver.disarmAdaptiveSlider()
        presenter.setAdaptiveSliderHole(nil)
        if let level, var a = reading, a.panel.adaptiveLevel != nil {
            a.panel.adaptiveLevel = level
            reading = a
            redraw()
        }
        if readSkippedForSlider {
            readSkippedForSlider = false
            if presenter.isOpen { readApple() }
        }
    }

    /// Before anything else uses macOS's panel, or the menu goes.
    private func putSliderAway() {
        hoverTimer?.invalidate(); hoverTimer = nil
        if sliderArming.menuClosing() == .disarm { finishSlider() }
    }

    /// Adaptive Audio's slider when macOS's own could not be put under Anode's: Anode's menu goes and macOS's own Sound menu opens,
    /// where it is dragged.
    func openAdaptiveInMacOS() {
        closeMenu(fade: false)
        driver.cancelAll()
        driver.showPanelToPerson(.sound)
    }

    /// The gear: the menu goes, and Beta Features opens.
    func pressGear() {
        closeMenu()
        openBetaFeatures()
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
