import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Which apps get a tap, and that none is ever left muting an app it cannot serve.
final class AppAudioRouterTests: XCTestCase {

    final class FakeSession: AppAudioSessionHandle {
        var stopped = false
        func stop() { stopped = true }
    }

    final class FakeBackend: AppAudioBackend {
        var list: [AudioProcessInfo] = []
        var output: String? = "speakers"
        var perm: AudioCapturePermission = .granted
        var canTapBeforeLaunch = true
        var started: [(bundleID: String, ids: [UInt32], output: String, muting: Bool, gain: GainStage, fail: () -> Void)] = []
        var sessions: [FakeSession] = []
        var onProcessesChanged: (() -> Void)?
        var onOutputChanged: (() -> Void)?
        var failNext = false
        func processes() -> [AudioProcessInfo] { list }
        func defaultOutputUID() -> String? { output }
        func permission() -> AudioCapturePermission { perm }
        var canTapAppsNotYetRunning: Bool { canTapBeforeLaunch }
        func start(bundleID: String, processObjectIDs: [UInt32], outputUID: String, muteOriginal: Bool, gain: GainStage,
                   onFailure: @escaping () -> Void) throws -> AppAudioSessionHandle {
            if failNext { failNext = false; throw NSError(domain: "fake", code: 1) }
            started.append((bundleID, processObjectIDs, outputUID, muteOriginal, gain, onFailure))
            let s = FakeSession(); sessions.append(s); return s
        }
    }

    private let player = AudioProcessInfo(objectID: 10, pid: 100, executablePath: "/Applications/Player.app/Contents/MacOS/Player", isRunningOutput: true)
    private let playerHelper = AudioProcessInfo(objectID: 11, pid: 101, executablePath: "/Applications/Player.app/Contents/Helpers/H.app/Contents/MacOS/H", isRunningOutput: false)

    private func rig(enabled: Bool = true, running: [AudioProcessInfo]? = nil, _ name: String = #function) throws
    -> (AppAudioRouter, FakeBackend, AppAudioStore, Settings, () -> Void) {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudioRouter", test: name)
        let settings = Settings(defaults: defaults); settings.appAudioEnabled = enabled
        let store = AppAudioStore(defaults: defaults)
        let backend = FakeBackend(); backend.list = running ?? [player]
        let router = AppAudioRouter(settings: settings, store: store, backend: backend,
                                    bundleID: { $0.contains("Player") ? "com.example.player" : nil }, name: { _ in "Player" })
        return (router, backend, store, settings, { router.shutdown(); TestDefaults.destroy(defaults, suite) })
    }

    func testNoTapWhileEveryAppIsAtItsDefaults() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        router.reconcile()
        XCTAssertTrue(backend.started.isEmpty)
        XCTAssertEqual(router.activeSessionCount, 0)
    }

    func testEveryOpenAppIsListedAtFullVolumeWhetherOrNotItIsPlaying() throws {
        let (router, _, _, _, done) = try rig(running: [AudioProcessInfo(objectID: 5, pid: 5, executablePath: "/Applications/Player.app/Contents/MacOS/Player", isRunningOutput: false)])
        defer { done() }
        let rows = router.apps
        XCTAssertEqual(rows.map(\.bundleID), ["com.example.player"])
        XCTAssertEqual(rows[0].volume, 1); XCTAssertFalse(rows[0].muted)
    }

    func testAnAppStaysListedWhileItIsOpenEvenWhenItIsNoLongerConnectedToTheSoundSystem() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        XCTAssertEqual(router.apps.map(\.bundleID), ["com.example.player"])
        backend.list = []   // a browser with no tab using sound is not an audio client at that moment
        XCTAssertEqual(router.apps.map(\.bundleID), ["com.example.player"], "it was seen using sound, and it is still open")
    }

    func testAnAppTheUserChangedIsListedWhileOpenEvenIfNothingHasSeenItYet() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudioRouterChanged", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults); settings.appAudioEnabled = true
        let store = AppAudioStore(defaults: defaults)
        store.set(AppAudioSetting(gain: 1, muted: true), for: "com.example.browser")
        let router = AppAudioRouter(settings: settings, store: store, backend: FakeBackend(), bundleID: { _ in nil }, name: { $0 },
                                    isListable: { $0 == "com.example.browser" }, displayName: { $0 == "com.example.browser" ? "Browser" : nil })
        XCTAssertEqual(router.apps.map(\.name), ["Browser"])
        XCTAssertTrue(router.apps[0].muted)
        router.shutdown()
    }

    func testAnAppThatWasNeverSeenUsingSoundIsNotListed() throws {
        let (router, backend, _, _, done) = try rig(running: []); defer { done() }
        XCTAssertTrue(router.apps.isEmpty)
        backend.list = []
        XCTAssertTrue(router.apps.isEmpty)
    }

    func testAnAppThatHasBeenClosedIsNotListedAnyMore() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudioRouterClosed", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults); settings.appAudioEnabled = true
        let backend = FakeBackend(); backend.list = [player]
        var open = true
        let router = AppAudioRouter(settings: settings, store: AppAudioStore(defaults: defaults), backend: backend,
                                    bundleID: { $0.contains("Player") ? "com.example.player" : nil }, name: { _ in "Player" },
                                    isListable: { _ in open })
        XCTAssertEqual(router.apps.count, 1)
        backend.list = []; open = false
        XCTAssertTrue(router.apps.isEmpty)
        router.shutdown()
    }

    func testWhatWasSeenIsRememberedAcrossARestart() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "AppAudioRouterKnown", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults); settings.appAudioEnabled = true
        func make(_ list: [AudioProcessInfo]) -> AppAudioRouter {
            let backend = FakeBackend(); backend.list = list
            return AppAudioRouter(settings: settings, store: AppAudioStore(defaults: defaults), backend: backend,
                                  bundleID: { $0.contains("Player") ? "com.example.player" : nil }, name: { _ in "Player" })
        }
        let first = make([player]); _ = first.apps; first.shutdown()
        let second = make([])   // Anode started again; the app is open but not connected yet
        XCTAssertEqual(second.apps.map(\.name), ["Player"])
        second.shutdown()
    }

    func testChangingAnAppStartsOneSessionForAllItsProcesses() throws {
        let (router, backend, _, _, done) = try rig(running: [player, playerHelper]); defer { done() }
        router.setVolume(0.5, forBundleID: "com.example.player")
        XCTAssertEqual(backend.started.count, 1)
        XCTAssertEqual(backend.started[0].bundleID, "com.example.player")
        XCTAssertEqual(backend.started[0].ids.sorted(), [10, 11])
        XCTAssertEqual(backend.started[0].output, "speakers")
        XCTAssertTrue(backend.started[0].muting)
    }

    func testTheSessionFollowsTheStoredGainAndMute() throws {
        let (router, backend, store, _, done) = try rig(); defer { done() }
        router.setVolume(0.5, forBundleID: "com.example.player")
        let gain = backend.started[0].gain
        func target(_ g: GainStage) -> Float {
            let input = [Float](repeating: 1, count: 4800), mutable = UnsafeMutablePointer<Float>.allocate(capacity: 4800)
            defer { mutable.deallocate() }
            input.withUnsafeBufferPointer { g.render(input: $0.baseAddress!, output: mutable, frames: 4800) }
            return mutable[4799]
        }
        XCTAssertEqual(target(gain), 0.5, accuracy: 0.001)
        router.setMuted(true, forBundleID: "com.example.player")
        XCTAssertEqual(target(gain), 0, accuracy: 0.001)
        XCTAssertEqual(store.setting(for: "com.example.player").gain, 0.5, accuracy: 0.001, "the level is kept")
        router.setMuted(false, forBundleID: "com.example.player")
        XCTAssertEqual(target(gain), 0.5, accuracy: 0.001)
        XCTAssertEqual(backend.started.count, 1, "one session throughout")
    }

    func testBackToTheDefaultEndsTheSession() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        router.setVolume(0.5, forBundleID: "com.example.player")
        router.setVolume(1, forBundleID: "com.example.player")
        XCTAssertTrue(backend.sessions[0].stopped)
        XCTAssertEqual(router.activeSessionCount, 0)
    }

    func testAMutedAppThatIsNotRunningIsStillTappedSoItsFirstSoundIsSilent() throws {
        let (router, backend, _, _, done) = try rig(running: []); defer { done() }
        router.setMuted(true, forBundleID: "com.example.player")
        XCTAssertEqual(backend.started.count, 1, "the tap waits for the app")
        XCTAssertEqual(backend.started[0].ids, [])
    }

    func testWithoutTheAbilityToTapBeforeLaunchAnAppNotRunningGetsNoSessionUntilItAppears() throws {
        let (router, backend, _, _, done) = try rig(running: []); defer { done() }
        backend.canTapBeforeLaunch = false
        router.setMuted(true, forBundleID: "com.example.player")
        XCTAssertTrue(backend.started.isEmpty)
        backend.list = [player]; backend.onProcessesChanged?()
        XCTAssertEqual(backend.started.count, 1)
    }

    func testANewHelperRestartsTheSessionWithTheNewIdsWhenTheBackendNeedsThem() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        backend.canTapBeforeLaunch = false
        router.setVolume(0.5, forBundleID: "com.example.player")
        backend.list = [player, playerHelper]; backend.onProcessesChanged?()
        XCTAssertEqual(backend.started.count, 2)
        XCTAssertTrue(backend.sessions[0].stopped)
        XCTAssertEqual(backend.started[1].ids.sorted(), [10, 11])
    }

    func testAChangeOfOutputRestartsEverySessionOnTheNewOne() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        router.setVolume(0.5, forBundleID: "com.example.player")
        backend.output = "airpods"; backend.onOutputChanged?()
        XCTAssertEqual(backend.started.count, 2)
        XCTAssertEqual(backend.started[1].output, "airpods")
        XCTAssertTrue(backend.sessions[0].stopped)
    }

    func testNoOutputMeansNoSession() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        backend.output = nil
        router.setVolume(0.5, forBundleID: "com.example.player")
        XCTAssertTrue(backend.started.isEmpty)
    }

    func testAFailureToStartIsReportedTheSettingKeptAndNotRetriedInALoop() throws {
        let (router, backend, store, _, done) = try rig(); defer { done() }
        backend.failNext = true
        router.setVolume(0.5, forBundleID: "com.example.player")
        XCTAssertNotNil(router.failures["com.example.player"])
        XCTAssertEqual(store.setting(for: "com.example.player").gain, 0.5, accuracy: 0.001)
        router.reconcile()
        XCTAssertTrue(backend.started.isEmpty, "no retry without a reason")
    }

    func testASessionThatFailsLaterIsRemovedAndReported() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        router.setVolume(0.5, forBundleID: "com.example.player")
        backend.started[0].fail()
        XCTAssertEqual(router.activeSessionCount, 0)
        XCTAssertNotNil(router.failures["com.example.player"])
    }

    func testTurningTheFeatureOffReturnsEveryAppToNormal() throws {
        let (router, backend, _, settings, done) = try rig(); defer { done() }
        router.setVolume(0.5, forBundleID: "com.example.player")
        settings.appAudioEnabled = false
        router.reconcile()
        XCTAssertTrue(backend.sessions[0].stopped)
        XCTAssertTrue(router.apps.isEmpty, "and the menu has nothing to show")
    }

    func testADeniedPermissionStartsNothingAndLeavesNoAppMuted() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        backend.perm = .denied
        router.setMuted(true, forBundleID: "com.example.player")
        XCTAssertTrue(backend.started.isEmpty)
        XCTAssertEqual(router.permission, .denied)
    }

    func testBeforeThePermissionIsAnsweredTheTapDoesNotMuteTheApp() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        backend.perm = .undetermined
        router.setMuted(true, forBundleID: "com.example.player")
        XCTAssertEqual(backend.started.count, 1, "the tap is made to bring up the system's question")
        XCTAssertFalse(backend.started[0].muting, "but the app is not silenced by something that cannot play it")
        backend.perm = .granted
        router.reconcile()
        XCTAssertEqual(backend.started.count, 2)
        XCTAssertTrue(backend.started[1].muting)
        XCTAssertTrue(backend.sessions[0].stopped)
    }

    func testShutdownStopsEverythingAndLaterEventsDoNothing() throws {
        let (router, backend, _, _, done) = try rig(); defer { done() }
        router.setVolume(0.5, forBundleID: "com.example.player")
        router.shutdown()
        XCTAssertTrue(backend.sessions[0].stopped)
        backend.list = [player, playerHelper]; backend.onProcessesChanged?(); backend.onOutputChanged?()
        router.setMuted(true, forBundleID: "com.example.player")
        XCTAssertEqual(backend.started.count, 1)
    }
}

/// The device a tap plays back through is Anode's own plumbing: it must never be listed as somewhere to send the sound.
final class OwnAudioDevicesTests: XCTestCase {
    func testADeviceAnodeMadeIsRecognisedUntilItIsGone() {
        XCTAssertFalse(OwnAudioDevices.contains(uid: "x-1"))
        OwnAudioDevices.add(uid: "x-1")
        XCTAssertTrue(OwnAudioDevices.contains(uid: "x-1"))
        XCTAssertFalse(OwnAudioDevices.contains(uid: "x-2"))
        OwnAudioDevices.remove(uid: "x-1")
        XCTAssertFalse(OwnAudioDevices.contains(uid: "x-1"))
    }

    func testADeviceThatOnlyHasTheNameIsNotHiddenFromTheList() {
        // Recognised by the id Anode gave it, never by a name any device can carry.
        XCTAssertFalse(OwnAudioDevices.contains(uid: "someone-elses-device"))
    }
}
