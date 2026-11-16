import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Per-app volume is on only while the Sound menu and its own switch are both on; any other time every app is itself.
final class AppAudioWiringTests: XCTestCase {

    private final class Counting: AppAudioBackend {
        var onProcessesChanged: (() -> Void)?
        var onOutputChanged: (() -> Void)?
        func processes() -> [AudioProcessInfo] { [] }
        func defaultOutputUID() -> String? { "speakers" }
        func permission() -> AudioCapturePermission { .granted }
        var canTapAppsNotYetRunning: Bool { true }
        func start(bundleID: String, processObjectIDs: [UInt32], outputUID: String, muteOriginal: Bool, gain: GainStage,
                   onFailure: @escaping () -> Void) throws -> AppAudioSessionHandle { fatalError("not used") }
    }

    private func rig(_ name: String = #function) throws -> (AppAudioCoordinator, Settings, () -> [AppAudioRouter?], () -> Void) {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudioWiring", test: name)
        let settings = Settings(defaults: defaults)
        var attached: [AppAudioRouter?] = []
        let store = AppAudioStore(defaults: defaults)
        let coordinator = AppAudioCoordinator(settings: settings, makeRouter: {
            AppAudioRouter(settings: settings, store: store, backend: Counting(), bundleID: { _ in nil }, name: { $0 })
        }, attach: { attached.append($0) })
        return (coordinator, settings, { attached }, { coordinator.stop(); TestDefaults.destroy(defaults, suite) })
    }

    func testNothingIsRunningWhileEitherSwitchIsOff() throws {
        let (c, s, attached, done) = try rig(); defer { done() }
        c.start()
        XCTAssertNil(attached().last ?? nil)
        s.appAudioEnabled = true      // the menu itself is off
        XCTAssertNil(attached().last ?? nil)
        s.soundMenuEnabled = true
        s.appAudioEnabled = false
        XCTAssertNil(attached().last ?? nil)
    }

    func testBothOnGivesTheMenuItsApps_AndOffTakesThemAwayAgain() throws {
        let (c, s, attached, done) = try rig(); defer { done() }
        c.start()
        s.soundMenuEnabled = true
        s.appAudioEnabled = true
        let router = attached().last ?? nil
        XCTAssertNotNil(router)
        s.appAudioEnabled = false
        XCTAssertNil(attached().last ?? router, "the menu has no apps any more")
        XCTAssertTrue(router?.apps.isEmpty ?? false)
    }

    func testTheMenuBeingTurnedOffEndsItToo() throws {
        let (c, s, attached, done) = try rig(); defer { done() }
        c.start()
        s.soundMenuEnabled = true; s.appAudioEnabled = true
        s.soundMenuEnabled = false
        XCTAssertNil(attached().last ?? attached().first ?? nil)
    }

    func testStopEndsItForGood() throws {
        let (c, s, attached, done) = try rig(); defer { done() }
        c.start()
        s.soundMenuEnabled = true; s.appAudioEnabled = true
        c.stop()
        XCTAssertNil(attached().last ?? nil)
        s.appAudioEnabled = false; s.appAudioEnabled = true
        XCTAssertNil(attached().last ?? nil, "after stop, a change of the setting starts nothing")
    }
}
