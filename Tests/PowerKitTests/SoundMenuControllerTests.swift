import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Sound menu's behaviour, with every input faked: outputs, macOS's own panel, the batteries, the menu bar and the
/// drawn menu.
final class SoundMenuControllerTests: XCTestCase {

    // ── Fakes ───────────────────────────────────────────────────────────────

    final class FakeOutputs: AudioOutputs {
        var devices: [OutputDevice] = [OutputDevice(id: "builtin", name: "MacBook Pro Speakers", kind: .speakers),
                                       OutputDevice(id: "pods", name: "Test AirPods Pro", kind: .airpodsPro)]
        var defaultDeviceID: String? = "pods"
        var volume = 0.5
        var muted = false
        var onChange: (() -> Void)?
        var started = false
        var setDefaults: [String] = [], setVolumes: [Double] = [], setMutes: [Bool] = []
        func setDefault(_ id: String) { setDefaults.append(id) }
        func setVolume(_ value: Double) { setVolumes.append(value); volume = value }
        func setMuted(_ m: Bool) { setMutes.append(m); muted = m }
        func start() { started = true }
        func stop() { started = false }
    }

    final class FakeDriver: SystemPanelDriving {
        var jobs: [(SystemPanelKind, SystemPanelPress.Job)] = []
        var completions: [(SystemPanelOutcome) -> Void] = []
        var cancelled = false
        func cancelAll() { cancelled = true }
        func run(_ kind: SystemPanelKind, job: SystemPanelPress.Job, done: @escaping (SystemPanelOutcome) -> Void) {
            jobs.append((kind, job)); completions.append(done)
        }
        func complete(_ index: Int, _ outcome: SystemPanelOutcome) { completions[index](outcome) }
    }

    final class FakeItem: StatusItemHandle {
        var symbolName = ""
        var onClick: (() -> Void)?
        var frame = CGRect(x: 1544, y: 8, width: 22, height: 22)
        var removed = false
        func remove() { removed = true }
    }

    final class FakeBar: StatusItemHosting {
        var items: [FakeItem] = []
        func makeItem() -> StatusItemHandle { let i = FakeItem(); items.append(i); return i }
    }

    final class FakeNative: NativeIconHosting {
        var frame: CGRect? = CGRect(x: 1544, y: 8, width: 22, height: 22)
        var onClick: ((CGRect) -> Void)?
        var running = false
        func currentFrame() -> CGRect? { frame }
        func start() { running = true }
        func stop() { running = false }
    }

    final class FakePresenter: SoundMenuPresenting {
        var isOpen = false
        var shown: [SoundMenuModel] = []
        var lastAnchor: CGRect?
        var closeCount = 0
        func show(_ model: SoundMenuModel, below frame: CGRect) { isOpen = true; lastAnchor = frame; shown.append(model) }
        func update(_ model: SoundMenuModel) { shown.append(model) }
        func close() { isOpen = false; closeCount += 1 }
    }

    // ── Rig ─────────────────────────────────────────────────────────────────

    struct Rig {
        let controller: SoundMenuController
        let outputs: FakeOutputs, driver: FakeDriver, bar: FakeBar, presenter: FakePresenter, native: FakeNative
        let settings: Settings
        let cleanup: () -> Void
        var model: SoundMenuModel { controller.model }
    }

    private func batteriesBoth() -> [AccessoryBattery] {
        AccessoryBattery.parse([
            ["Type": "Accessory Source", "Part Identifier": "Left", "Group Identifier": "G", "Current Capacity": 100],
            ["Type": "Accessory Source", "Part Identifier": "Right", "Group Identifier": "G", "Current Capacity": 66]])
    }

    private func tree(listening: String = "Transparency", buttons: Bool = false) -> AXNode {
        func box(_ id: String, _ desc: String, _ on: Bool) -> AXNode {
            AXNode(role: "AXCheckBox", subrole: "AXToggle", identifier: id, description: desc, value: on ? "1" : "0")
        }
        let pods = "sound-device-Test AirPods Pro"
        return AXNode(role: "AXWindow", children: [AXNode(role: "AXGroup", children: [
            AXNode(role: "AXSlider", identifier: "controlcenter-volume-slider", value: "0.5"),
            AXNode(role: "AXScrollArea", children: [
                AXNode(role: "AXHeading", description: "Output"),
                box("sound-device-MacBook Pro Speakers", "MacBook Pro Speakers", false),
                AXNode(role: "AXDisclosureTriangle", identifier: pods, description: "Go Down", value: "1"),
                box(pods, "Test AirPods Pro, 100%, 66%", true),
                AXNode(role: "AXHeading", identifier: pods, description: "Listening Mode"),
                box(pods, "Transparency", listening == "Transparency"), box(pods, "Adaptive", listening == "Adaptive"),
                box(pods, "Noise Cancellation", listening == "Noise Cancellation"),
                AXNode(role: "AXHeading", identifier: pods, description: "Conversation Awareness"),
                box(pods, "Off", true), box(pods, "On", false),
                box("sound-device-Living Room Speaker", "Living Room Speaker", false),
            ])] + (buttons ? [AXNode(role: "AXButton", description: "Test AirPods Pro Settings…"),
                              AXNode(role: "AXButton", description: "Sound Settings…")] : []))])
    }

    private func rig(enabled: Bool = true, trusted: Bool = true, batteries: [AccessoryBattery]? = nil, native useNative: Bool = false) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "SoundMenuController", test: name)
        let settings = Settings(defaults: defaults)
        settings.soundMenuEnabled = enabled
        settings.soundMenuUsesNativeIcon = useNative
        let outputs = FakeOutputs(), driver = FakeDriver(), bar = FakeBar(), presenter = FakePresenter(), native = FakeNative()
        let list = batteries ?? batteriesBoth()
        let c = SoundMenuController(settings: settings, outputs: outputs, driver: driver, batteries: { list },
                                    accessibility: { trusted }, statusBar: bar, presenter: presenter, native: native, pollInterval: 0)
        c.start()
        return Rig(controller: c, outputs: outputs, driver: driver, bar: bar, presenter: presenter, native: native, settings: settings,
                   cleanup: { c.stop(); TestDefaults.destroy(defaults, suite) })
    }

    private func openAndRead(_ r: Rig, listening: String = "Transparency") {
        r.controller.openMenu()
        r.driver.complete(0, .tree(tree(listening: listening)))
    }

    // ── Tests ───────────────────────────────────────────────────────────────

    func testStartsOnlyWhenEnabled() throws {
        let off = try rig(enabled: false); defer { off.cleanup() }
        XCTAssertTrue(off.bar.items.isEmpty)
        XCTAssertFalse(off.outputs.started)
        let on = try rig(); defer { on.cleanup() }
        XCTAssertEqual(on.bar.items.count, 1)
        XCTAssertTrue(on.outputs.started)
    }

    func testTurningTheSettingOnAndOffStartsAndStops() throws {
        let r = try rig(enabled: false); defer { r.cleanup() }
        r.settings.soundMenuEnabled = true
        XCTAssertEqual(r.bar.items.count, 1)
        r.settings.soundMenuEnabled = false
        XCTAssertTrue(r.bar.items[0].removed)
        XCTAssertFalse(r.outputs.started)
    }

    func testIconFollowsOutputAndVolume() throws {
        let r = try rig(); defer { r.cleanup() }
        XCTAssertEqual(r.bar.items[0].symbolName, "airpods.pro")
        r.outputs.defaultDeviceID = "builtin"; r.outputs.volume = 0.9
        r.outputs.onChange?()
        XCTAssertEqual(r.bar.items[0].symbolName, "speaker.wave.3.fill")
    }

    func testOpenReadsAppleOnce() throws {
        let r = try rig(); defer { r.cleanup() }
        r.controller.openMenu()
        XCTAssertEqual(r.driver.jobs.count, 1)
        XCTAssertEqual(r.driver.jobs[0].0, .sound)
        XCTAssertEqual(r.driver.jobs[0].1, .read)
        XCTAssertTrue(r.presenter.isOpen)
        r.driver.complete(0, .tree(tree()))
        XCTAssertEqual(r.model.listening.map(\.title), ["Transparency", "Adaptive", "Noise Cancellation"])
        XCTAssertTrue(r.model.appleAvailable)
    }

    func testPickingOutputSetsDefault() throws {
        let r = try rig(); defer { r.cleanup() }
        openAndRead(r)
        r.controller.pickOutput(r.model.devices[0])
        XCTAssertEqual(r.outputs.setDefaults, ["builtin"])
        XCTAssertEqual(r.driver.jobs.count, 1)   // only the read: no press of macOS's panel
    }

    func testListeningPressIsOptimisticThenConfirmed() throws {
        let r = try rig(); defer { r.cleanup() }
        openAndRead(r)
        let noise = r.model.listening[2]
        r.controller.pickChoice(noise)
        XCTAssertEqual(r.model.listening.map(\.isOn), [false, false, true])
        XCTAssertEqual(r.driver.jobs.last?.1, .press(SystemPanelRow(identifier: "sound-device-Test AirPods Pro", description: "Noise Cancellation")))
        r.driver.complete(1, .pressed)
        XCTAssertEqual(r.model.listening.map(\.isOn), [false, false, true])
        XCTAssertNil(r.model.notice)
    }

    func testRefusalPutsCheckBackAndShowsLine() throws {
        let r = try rig(); defer { r.cleanup() }
        openAndRead(r)
        r.controller.pickChoice(r.model.listening[1])
        r.driver.complete(1, .refused("Failed to set listening mode / Put Test AirPods Pro in both ears to use Adaptive Audio."))
        XCTAssertEqual(r.model.listening.map(\.isOn), [true, false, false])
        XCTAssertEqual(r.model.notice, "Put Test AirPods Pro in both ears to use Adaptive Audio.")
    }

    func testAdaptiveNotPressedWhenTheBudsAreNotBothThere() throws {
        let one = AccessoryBattery.parse([["Type": "Accessory Source", "Part Identifier": "Right", "Group Identifier": "G", "Current Capacity": 66]])
        let r = try rig(batteries: one); defer { r.cleanup() }
        openAndRead(r)
        r.controller.pickChoice(r.model.listening[1])
        XCTAssertEqual(r.driver.jobs.count, 1)   // the read only
        XCTAssertEqual(r.model.listening.map(\.isOn), [true, false, false])
        XCTAssertEqual(r.model.notice, "Put both AirPods in to use Adaptive.")
    }

    func testAirPlayRowPressesApple() throws {
        let r = try rig(); defer { r.cleanup() }
        openAndRead(r)
        let speaker = try XCTUnwrap(r.model.devices.first { $0.name == "Living Room Speaker" })
        XCTAssertNil(speaker.id)
        r.controller.pickOutput(speaker)
        XCTAssertTrue(r.outputs.setDefaults.isEmpty)
        XCTAssertEqual(r.driver.jobs.last?.1, .press(SystemPanelRow(identifier: "sound-device-Living Room Speaker", description: "Living Room Speaker")))
    }

    func testDeviceRemovedWhileOpenDropsRowAndSelection() throws {
        let r = try rig(); defer { r.cleanup() }
        openAndRead(r)
        r.outputs.devices.removeAll { $0.id == "pods" }
        r.outputs.defaultDeviceID = "builtin"
        r.outputs.onChange?()
        XCTAssertFalse(r.model.devices.contains { $0.name == "Test AirPods Pro" })
        XCTAssertEqual(r.model.devices.filter(\.isSelected).map(\.name), ["MacBook Pro Speakers"])
        XCTAssertTrue(r.model.listening.isEmpty)
    }

    func testWithoutAccessibilityAppleRowsAreUnavailable() throws {
        let r = try rig(trusted: false); defer { r.cleanup() }
        r.controller.openMenu()
        XCTAssertTrue(r.driver.jobs.isEmpty)
        XCTAssertFalse(r.model.appleAvailable)
        XCTAssertTrue(r.model.notice?.contains("Accessibility") == true)
        r.controller.setVolume(0.3)
        XCTAssertEqual(r.outputs.setVolumes, [0.3])
    }

    func testAirPodsSettingsPressedOnlyWhenApplesPanelListsIt() throws {
        let listed = try rig(); defer { listed.cleanup() }
        listed.controller.openMenu()
        listed.driver.complete(0, .tree(tree(buttons: true)))
        listed.controller.pressSettings(0)
        XCTAssertEqual(listed.driver.jobs.last?.1, .press(SystemPanelRow(identifier: "", description: "Test AirPods Pro Settings…")))

        let unlisted = try rig(); defer { unlisted.cleanup() }
        openAndRead(unlisted)
        unlisted.controller.pressSettings(0)
        XCTAssertEqual(unlisted.driver.jobs.count, 1, "no button named in the panel, nothing to press")
    }

    // ── macOS's own icon ────────────────────────────────────────────────────

    func testNativeModeHasNoIconOfItsOwnWhileMacOSsIsThere() throws {
        let r = try rig(native: true); defer { r.cleanup() }
        XCTAssertTrue(r.bar.items.isEmpty)
        XCTAssertTrue(r.native.running)
    }

    func testNativeOffUsesAnIconOfItsOwn() throws {
        let r = try rig(native: false); defer { r.cleanup() }
        XCTAssertEqual(r.bar.items.count, 1)
        XCTAssertFalse(r.native.running)
    }

    func testAClickOnMacOSsIconOpensTheMenuUnderIt() throws {
        let r = try rig(native: true); defer { r.cleanup() }
        let frame = CGRect(x: 1544, y: 8, width: 22, height: 22)
        r.native.onClick?(frame)
        XCTAssertTrue(r.presenter.isOpen)
        XCTAssertEqual(r.presenter.lastAnchor, frame)
        r.native.onClick?(frame)
        XCTAssertFalse(r.presenter.isOpen, "a second click closes it")
    }

    func testAnIconOfItsOwnComesBackWhenMacOSsIsRemovedAndGoesAgainWhenItReturns() throws {
        let r = try rig(native: true); defer { r.cleanup() }
        r.native.frame = nil
        r.controller.refreshNativeIcon()
        XCTAssertEqual(r.bar.items.count, 1)
        XCTAssertFalse(r.bar.items[0].removed)
        XCTAssertFalse(r.native.running)
        r.native.frame = CGRect(x: 1544, y: 8, width: 22, height: 22)
        r.controller.refreshNativeIcon()
        XCTAssertTrue(r.bar.items[0].removed)
        XCTAssertTrue(r.native.running)
    }

    func testSwitchingTheSettingMovesTheIcon() throws {
        let r = try rig(native: false); defer { r.cleanup() }
        r.settings.soundMenuUsesNativeIcon = true
        XCTAssertTrue(r.bar.items[0].removed)
        XCTAssertTrue(r.native.running)
        r.settings.soundMenuUsesNativeIcon = false
        XCTAssertEqual(r.bar.items.count, 2)
        XCTAssertFalse(r.native.running)
    }

    // ── Not showing what is out of date ─────────────────────────────────────

    func testStaleAppleRowsAreNotShownAfterTheOutputsChange() throws {
        let r = try rig(); defer { r.cleanup() }
        openAndRead(r)
        XCTAssertFalse(r.model.listening.isEmpty)
        r.controller.closeMenu()
        // the AirPods were taken out while the menu was closed
        r.outputs.devices.removeAll { $0.id == "pods" }
        r.outputs.defaultDeviceID = "builtin"
        XCTAssertTrue(r.model.listening.isEmpty, "the listening rows belong to AirPods that are not there")
        XCTAssertFalse(r.model.devices.contains { $0.name == "Test AirPods Pro" })
        XCTAssertNil(r.model.expandedDevice)
    }

    func testTheMenuOpensAtOnceEvenWhenWhatItKnowsIsOutOfDate() throws {
        let r = try rig(); defer { r.cleanup() }
        r.controller.openMenu()
        XCTAssertTrue(r.presenter.isOpen, "the first click after a long while must take as long as any other")
        XCTAssertTrue(r.presenter.shown[0].listening.isEmpty, "nothing has been read yet")
        r.driver.complete(0, .tree(tree()))
        XCTAssertFalse(r.presenter.shown.last?.listening.isEmpty ?? true, "the reading fills it in when it arrives")
    }

    func testTheMenuShowsAtOnceWhenWhatItKnowsIsStillCurrent() throws {
        let r = try rig(); defer { r.cleanup() }
        r.controller.openMenu(); r.driver.complete(0, .tree(tree()))
        r.controller.closeMenu()
        r.controller.openMenu()
        XCTAssertTrue(r.presenter.isOpen)
        XCTAssertFalse(r.presenter.shown[1].listening.isEmpty)
        XCTAssertEqual(r.driver.jobs.count, 2, "and it reads again behind it")
    }

    func testASecondClickCloses() throws {
        let r = try rig(); defer { r.cleanup() }
        r.controller.toggleMenu()
        r.controller.toggleMenu()
        XCTAssertFalse(r.presenter.isOpen)
        r.driver.complete(0, .tree(tree()))
        XCTAssertFalse(r.presenter.isOpen, "a reading that arrives late does not open it again")
    }

    func testVolumeAndMuteGoToTheOutput() throws {
        let r = try rig(); defer { r.cleanup() }
        r.controller.setVolume(0.7)
        r.controller.toggleMute()
        XCTAssertEqual(r.outputs.setVolumes, [0.7])
        XCTAssertEqual(r.outputs.setMutes, [true])
    }

    func testStopRemovesItemAndClosesMenu() throws {
        let r = try rig(); defer { r.cleanup() }
        r.controller.openMenu()
        r.controller.stop()
        XCTAssertTrue(r.bar.items[0].removed)
        XCTAssertFalse(r.presenter.isOpen)
        XCTAssertFalse(r.outputs.started)
        XCTAssertTrue(r.driver.cancelled)   // macOS's own panel is closed and nothing is left running
    }
}
