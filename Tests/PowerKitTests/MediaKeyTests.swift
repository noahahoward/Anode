import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The volume keys while Anode's Sound menu is open: Anode takes them, so macOS does not draw its own volume bubble beside the menu.
final class MediaKeyTests: XCTestCase {

    /// `data1` of a system-defined event as the keyboard makes it: key code in the top half, state in the next byte.
    private func data1(key: Int, down: Bool, repeating: Bool = false) -> Int {
        (key << 16) | ((down ? 0xA : 0xB) << 8) | (repeating ? 1 : 0)
    }

    func testTheThreeVolumeKeysAreRecognised() {
        XCTAssertEqual(MediaKeyEvent(data1: data1(key: 0, down: true))?.key, .volumeUp)
        XCTAssertEqual(MediaKeyEvent(data1: data1(key: 1, down: true))?.key, .volumeDown)
        XCTAssertEqual(MediaKeyEvent(data1: data1(key: 7, down: true))?.key, .mute)
    }

    func testPressAndReleaseAndRepeatAreTold() {
        XCTAssertEqual(MediaKeyEvent(data1: data1(key: 0, down: true))?.isDown, true)
        XCTAssertEqual(MediaKeyEvent(data1: data1(key: 0, down: false))?.isDown, false)
        XCTAssertEqual(MediaKeyEvent(data1: data1(key: 0, down: true, repeating: true))?.isRepeat, true)
        XCTAssertEqual(MediaKeyEvent(data1: data1(key: 0, down: true))?.isRepeat, false)
    }

    func testOtherMediaKeysAreNotOurs() {
        // brightness (2, 3), play/pause (16), next (17), keyboard illumination (21, 22)
        for key in [2, 3, 16, 17, 21, 22] { XCTAssertNil(MediaKeyEvent(data1: data1(key: key, down: true)), "key \(key)") }
    }
}

final class VolumeKeyControllerTests: XCTestCase {
    func testTheKeysMoveTheVolumeInSixteenthsAndMuteToggles() {
        XCTAssertEqual(VolumeKeys.step, 1.0 / 16)
        XCTAssertEqual(VolumeKeys.next(volume: 0.5, key: .volumeUp) ?? -1, 0.5 + 1.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(VolumeKeys.next(volume: 0.5, key: .volumeDown) ?? -1, 0.5 - 1.0 / 16, accuracy: 1e-9)
        XCTAssertEqual(VolumeKeys.next(volume: 0.98, key: .volumeUp), 1)
        XCTAssertEqual(VolumeKeys.next(volume: 0.02, key: .volumeDown), 0)
        XCTAssertNil(VolumeKeys.next(volume: 0.5, key: .mute), "mute is not a level")
    }
}

/// The menu's answer to a volume key.
final class SoundMenuVolumeKeyTests: XCTestCase {
    func testAVolumeKeyMovesTheVolumeOfTheOpenMenu_AndMuteSwitches() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "VolumeKeys", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults); settings.soundMenuEnabled = true
        let outputs = SoundMenuControllerTests.FakeOutputs()
        let presenter = SoundMenuControllerTests.FakePresenter()
        let c = SoundMenuController(settings: settings, outputs: outputs, driver: SoundMenuControllerTests.FakeDriver(), batteries: { [] },
                                    accessibility: { true }, statusBar: SoundMenuControllerTests.FakeBar(), presenter: presenter,
                                    native: SoundMenuControllerTests.FakeNative(), pollInterval: 0, followUpDelay: 0)
        c.start(); defer { c.stop() }
        c.volumeKey(.volumeUp)
        XCTAssertTrue(outputs.setVolumes.isEmpty, "with the menu closed the keys are macOS's")
        c.openMenu()
        c.volumeKey(.volumeUp)
        XCTAssertEqual(outputs.setVolumes.last ?? 0, 0.5 + 1.0 / 16, accuracy: 1e-9)
        c.volumeKey(.volumeDown); c.volumeKey(.volumeDown)
        XCTAssertEqual(outputs.setVolumes.last ?? 0, 0.5 - 1.0 / 16, accuracy: 1e-9)
        c.volumeKey(.mute)
        XCTAssertEqual(outputs.setMutes.last, true)
    }
}

/// The speaker icons at the two ends of the slider step the volume by ten points, as macOS's do (measured: 33 -> 23 and 43, 3 -> 0 and 13).
final class SoundMenuIconStepTests: XCTestCase {
    private func rig(volume: Double) throws -> (SoundMenuController, SoundMenuControllerTests.FakeOutputs, () -> Void) {
        let (defaults, suite) = try TestDefaults.make(owner: "IconStep", test: name)
        let settings = Settings(defaults: defaults); settings.soundMenuEnabled = true
        let outputs = SoundMenuControllerTests.FakeOutputs(); outputs.volume = volume
        let c = SoundMenuController(settings: settings, outputs: outputs, driver: SoundMenuControllerTests.FakeDriver(), batteries: { [] },
                                    accessibility: { true }, statusBar: SoundMenuControllerTests.FakeBar(), presenter: SoundMenuControllerTests.FakePresenter(),
                                    native: SoundMenuControllerTests.FakeNative(), pollInterval: 0, followUpDelay: 0)
        c.start()
        return (c, outputs, { c.stop(); TestDefaults.destroy(defaults, suite) })
    }

    func testTheSpeakerIconsStepByTenPoints() throws {
        let (c, outputs, done) = try rig(volume: 0.33); defer { done() }
        c.stepVolumeFromIcon(up: true)
        XCTAssertEqual(outputs.setVolumes.last ?? 0, 0.43, accuracy: 1e-9)
        outputs.volume = 0.33
        c.stepVolumeFromIcon(up: false)
        XCTAssertEqual(outputs.setVolumes.last ?? 0, 0.23, accuracy: 1e-9)
    }

    func testTheStepsStopAtTheEnds() throws {
        let (c, outputs, done) = try rig(volume: 0.03); defer { done() }
        c.stepVolumeFromIcon(up: false)
        XCTAssertEqual(outputs.setVolumes.last ?? 1, 0, accuracy: 1e-9)
        outputs.volume = 0.95
        c.stepVolumeFromIcon(up: true)
        XCTAssertEqual(outputs.setVolumes.last ?? 0, 1, accuracy: 1e-9)
    }
}
