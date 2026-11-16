import XCTest
@testable import PowerKit

/// Each app's own volume (0 to 100 %) and mute, remembered by bundle id; and the switch that turns the feature on.
final class AppAudioSettingTests: XCTestCase {

    private func rig(_ name: String = #function) throws -> (AppAudioStore, UserDefaults, String) {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudio", test: name)
        return (AppAudioStore(defaults: defaults), defaults, suite)
    }

    func testTheSwitchIsOffByDefaultAndRemembered() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudioSwitch", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.appAudioEnabled)
        s.appAudioEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).appAudioEnabled)
    }

    func testAnAppAtItsDefaultIsFullVolumeAndNotMuted() {
        XCTAssertTrue(AppAudioSetting.flat.isDefault)
        XCTAssertEqual(AppAudioSetting.flat.gain, 1)
        XCTAssertEqual(AppAudioSetting.flat.effectiveGain, 1)
    }

    func testMutedIsSilentButKeepsItsLevel() {
        let s = AppAudioSetting(gain: 0.6, muted: true)
        XCTAssertFalse(s.isDefault)
        XCTAssertEqual(s.effectiveGain, 0)
        XCTAssertEqual(s.gain, 0.6, accuracy: 0.0001, "unmuting comes back to it")
        XCTAssertFalse(AppAudioSetting(gain: 1, muted: true).isDefault, "muted at 100 % is still a change")
    }

    func testTheLevelIsKeptBetweenZeroAndOne() throws {
        XCTAssertEqual(AppAudioSetting(gain: 1.7, muted: false).gain, 1)
        XCTAssertEqual(AppAudioSetting(gain: -3, muted: false).gain, 0)
        let (store, defaults, suite) = try rig(); defer { TestDefaults.destroy(defaults, suite) }
        store.set(AppAudioSetting(gain: 9, muted: false), for: "com.x")   // 9 clamps to 1: the default, so nothing is kept
        XCTAssertTrue(store.customised.isEmpty)
    }

    func testASettingSurvivesARestart() throws {
        let (store, defaults, suite) = try rig(); defer { TestDefaults.destroy(defaults, suite) }
        store.set(AppAudioSetting(gain: 0.4, muted: true), for: "com.example.player")
        let again = AppAudioStore(defaults: defaults)
        XCTAssertEqual(again.setting(for: "com.example.player"), AppAudioSetting(gain: 0.4, muted: true))
        XCTAssertEqual(again.setting(for: "com.other"), .flat, "an app never seen is at its default")
    }

    func testSettingTheDefaultForgetsTheApp() throws {
        let (store, defaults, suite) = try rig(); defer { TestDefaults.destroy(defaults, suite) }
        store.set(AppAudioSetting(gain: 0.4, muted: false), for: "com.x")
        XCTAssertEqual(store.customised.count, 1)
        store.set(.flat, for: "com.x")
        XCTAssertTrue(store.customised.isEmpty)
        store.set(AppAudioSetting(gain: 0.4, muted: false), for: "com.y")
        store.reset("com.y")
        XCTAssertTrue(store.customised.isEmpty)
    }

    func testAChangeIsAnnouncedOnceAndOnlyWhenItIsReal() throws {
        let (store, defaults, suite) = try rig(); defer { TestDefaults.destroy(defaults, suite) }
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: AppAudioStore.didChange, object: store, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.set(AppAudioSetting(gain: 0.5, muted: false), for: "com.x"); XCTAssertEqual(count, 1)
        store.set(AppAudioSetting(gain: 0.5, muted: false), for: "com.x"); XCTAssertEqual(count, 1, "the same again is no change")
        store.set(AppAudioSetting(gain: 0.5, muted: true), for: "com.x"); XCTAssertEqual(count, 2)
    }

    func testDamagedStoredDataIsIgnoredNotACrash() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudioDamaged", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        defaults.set(Data("not json".utf8), forKey: "anode.appAudio.v1")
        XCTAssertTrue(AppAudioStore(defaults: defaults).customised.isEmpty)
        defaults.set(Data(#"{"com.x":{"gain":0.3,"muted":false,"eq":[1,2,3]}}"#.utf8), forKey: "anode.appAudio.v1")
        XCTAssertEqual(AppAudioStore(defaults: defaults).setting(for: "com.x").gain, 0.3, accuracy: 0.0001, "an old field is ignored")
    }
}
