import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The controller that maps displays to surfaces and decides when each plays. Everything real is replaced: a fake factory
/// and surfaces, a hand-held clock, hand-set conditions and displays. No window, no player, no timer that matters.
final class LiveWallpaperControllerTests: XCTestCase {

    final class Box<T> { var value: T; init(_ v: T) { value = v } }
    final class NetworkProbe { var callbacks: [() -> Void] = []; var cancelled = 0 }

    final class FakeSurface: WallpaperSurface {
        let displayUUID: String
        let itemName: String
        var pausable: Bool
        var onCoveredChange: ((Bool) -> Void)?
        var onFailure: ((String) -> Void)?
        var playingCalls: [Bool] = []
        var applied: [WallpaperPrefs] = []
        var frames: [NSRect] = []
        var closeCount = 0
        init(displayUUID: String, itemName: String, pausable: Bool) { self.displayUUID = displayUUID; self.itemName = itemName; self.pausable = pausable }
        func setPlaying(_ playing: Bool) { playingCalls.append(playing) }
        func apply(_ prefs: WallpaperPrefs) { applied.append(prefs) }
        func updateFrame(_ frame: NSRect) { frames.append(frame) }
        func close() { closeCount += 1 }
        var lastPlaying: Bool? { playingCalls.last }
    }

    final class FakeFactory: WallpaperSurfaceFactory {
        struct Refused: Error {}
        var made: [FakeSurface] = []
        var makeCalls = 0
        var refuse: Set<String> = []        // item names the factory throws for
        func makeSurface(for display: DisplayInfo, item: WallpaperItem, library: WallpaperLibrary, prefs: WallpaperPrefs) throws -> WallpaperSurface {
            makeCalls += 1
            if refuse.contains(item.name) { throw Refused() }
            let s = FakeSurface(displayUUID: display.uuid, itemName: item.name, pausable: item.kind != .image)
            made.append(s)
            return s
        }
        func surfaces(for uuid: String) -> [FakeSurface] { made.filter { $0.displayUUID == uuid } }
        func live(for uuid: String) -> FakeSurface? { surfaces(for: uuid).last { $0.closeCount == 0 } }
    }

    private struct Rig {
        let controller: LiveWallpaperController
        let library: WallpaperLibrary
        let store: WallpaperPrefsStore
        let settings: Settings
        let factory: FakeFactory
        let clock: Box<Date>
        let conditions: Box<WallpaperGlobalConditions>
        let displays: Box<[DisplayInfo]>
        let defaults: UserDefaults
        let suite: String
        let dir: URL
        let net: NetworkProbe
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
    private func display(_ id: String, x: CGFloat = 0) -> DisplayInfo {
        DisplayInfo(uuid: id, name: id, frame: NSRect(x: x, y: 0, width: 1000, height: 600), pixelSize: CGSize(width: 2000, height: 1200))
    }

    private func rig(enabled: Bool = true, displays ds: [DisplayInfo]? = nil) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "LiveWallpaperController", test: name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LWC-\(UUID().uuidString)")
        let settings = Settings(defaults: defaults)
        settings.liveWallpaperEnabled = enabled
        let library = WallpaperLibrary(directory: dir)
        let store = WallpaperPrefsStore(defaults: defaults)
        let factory = FakeFactory()
        let clock = Box(t0)
        let conditions = Box(WallpaperGlobalConditions())
        let displays = Box(ds ?? [display("D1"), display("D2", x: 1000)])
        let net = NetworkProbe()
        let controller = LiveWallpaperController(settings: settings, library: library, prefsStore: store,
                                                 displays: { displays.value }, factory: factory,
                                                 conditions: { conditions.value }, now: { clock.value },
                                                 watchNetwork: { onReturn in
            net.callbacks.append(onReturn)
            return { net.cancelled += 1 }
        })
        return Rig(controller: controller, library: library, store: store, settings: settings, factory: factory, clock: clock,
                   conditions: conditions, displays: displays, defaults: defaults, suite: suite, dir: dir, net: net)
    }

    private func done(_ r: Rig) {
        r.controller.shutdown()
        try? FileManager.default.removeItem(at: r.dir)
        TestDefaults.destroy(r.defaults, r.suite)
    }

    @discardableResult
    private func addItem(_ r: Rig, _ name: String, kind: WallpaperKind = .video, source: WallpaperSource? = nil) throws -> WallpaperItem {
        let it = WallpaperItem(name: name, kind: kind, source: source ?? .remote(URL(string: "https://example.com/\(name).mp4")!),
                               posterFilename: nil, thumbnailFilename: nil, durationSeconds: nil, pixelWidth: nil, pixelHeight: nil,
                               codec: nil, hasAudio: nil, hardwareDecodable: nil)
        try r.library.add(it)
        return it
    }

    private func assign(_ r: Rig, default d: WallpaperItem? = nil, _ per: [String: DisplayChoice] = [:]) {
        var p = r.store.prefs
        p.assignments.defaultItem = d?.id
        for (k, v) in per { p.assignments.setChoice(v, forDisplay: k) }
        r.store.prefs = p
    }

    // MARK: creation

    func testOffMeansNoSurfaces() throws {
        let r = try rig(enabled: false); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        XCTAssertEqual(r.factory.makeCalls, 0)
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .noWallpaper)
    }

    func testOnCreatesOneSurfacePerAssignedDisplay() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A")
        assign(r, [ "D1": .item(a.id) ])
        r.controller.reconcile()
        XCTAssertNotNil(r.factory.live(for: "D1"))
        XCTAssertNil(r.factory.live(for: "D2"), "a display that resolves to nothing gets nothing")
        XCTAssertEqual(r.factory.makeCalls, 1)
    }

    func testDefaultAndPerDisplayOverrideAndNone() throws {
        let r = try rig(displays: [display("D1"), display("D2"), display("D3")]); defer { done(r) }
        let a = try addItem(r, "A"), b = try addItem(r, "B")
        assign(r, default: a, ["D2": .item(b.id), "D3": .none])
        r.controller.reconcile()
        XCTAssertEqual(r.factory.live(for: "D1")?.itemName, "A")
        XCTAssertEqual(r.factory.live(for: "D2")?.itemName, "B")
        XCTAssertNil(r.factory.live(for: "D3"))
    }

    func testChangingOneDisplaysAssignmentReplacesOnlyThatSurface() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"), b = try addItem(r, "B")
        assign(r, default: a)
        r.controller.reconcile()
        let d1 = try XCTUnwrap(r.factory.live(for: "D1")), d2 = try XCTUnwrap(r.factory.live(for: "D2"))
        var p = r.store.prefs
        p.assignments.setChoice(.item(b.id), forDisplay: "D2")
        r.store.prefs = p
        r.controller.reconcile()
        XCTAssertEqual(d1.closeCount, 0, "untouched")
        XCTAssertEqual(d2.closeCount, 1, "replaced")
        XCTAssertEqual(r.factory.live(for: "D2")?.itemName, "B")
        XCTAssertTrue(r.factory.live(for: "D1") === d1)
    }

    func testRemovingTheItemFromTheLibraryClosesItsSurfacesAndClearsAssignments() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"), b = try addItem(r, "B")
        assign(r, default: a, ["D2": .item(b.id)])
        r.controller.reconcile()
        let d1 = try XCTUnwrap(r.factory.live(for: "D1"))
        try r.library.remove(id: a.id)
        r.controller.reconcile()
        XCTAssertEqual(d1.closeCount, 1)
        XCTAssertNil(r.factory.live(for: "D1"))
        XCTAssertNil(r.store.prefs.assignments.defaultItem, "the assignment to the removed item is cleared")
        XCTAssertEqual(r.factory.live(for: "D2")?.itemName, "B", "the other display carries on")
    }

    // MARK: failures

    func testMissingFileIsReportedAndOthersCarryOn() throws {
        let r = try rig(); defer { done(r) }
        let ok = try addItem(r, "OK")
        let gone = try addItem(r, "Gone", source: .file("gone.mov"))
        assign(r, default: ok, ["D2": .item(gone.id)])
        r.controller.reconcile()
        guard case .failed(let why) = r.controller.status(forDisplay: "D2") else { return XCTFail("expected failed") }
        XCTAssertTrue(why.contains("missing"), why)
        XCTAssertNil(r.factory.live(for: "D2"))
        XCTAssertNotNil(r.factory.live(for: "D1"))
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .playing(itemName: "OK"))
    }

    func testFactoryFailureIsRecordedAndNotRetriedWithoutATrigger() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "Bad")
        r.factory.refuse = ["Bad"]
        assign(r, default: a)
        r.controller.reconcile()
        guard case .failed = r.controller.status(forDisplay: "D1") else { return XCTFail("expected failed") }
        let calls = r.factory.makeCalls
        r.controller.reconcile(); r.controller.conditionsChanged(); r.controller.reconcile()
        XCTAssertEqual(r.factory.makeCalls, calls, "nothing happened to justify another try")
    }

    func testSurfaceOnFailureFallsBackAndIsReported() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        s.onFailure?("The page didn't load")
        XCTAssertEqual(s.closeCount, 1, "the system wallpaper shows through")
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .failed("The page didn't load"))
        XCTAssertNotNil(r.factory.live(for: "D2"), "the other display is unaffected")
    }

    func testReloadRetriesAFailedDisplay() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "Flaky")
        r.factory.refuse = ["Flaky"]       // before the assignment: setting prefs reconciles at once
        assign(r, default: a)
        r.controller.reconcile()
        r.factory.refuse = []
        r.controller.reconcile()
        XCTAssertNil(r.factory.live(for: "D1"), "still waiting for a trigger")
        r.controller.reload(displayUUID: "D1")
        XCTAssertNotNil(r.factory.live(for: "D1"))
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .playing(itemName: "Flaky"))
    }

    func testChangingTheAssignmentOfAFailedDisplayTriesAgain() throws {
        let r = try rig(); defer { done(r) }
        let bad = try addItem(r, "Bad"), good = try addItem(r, "Good")
        r.factory.refuse = ["Bad"]
        assign(r, default: bad)
        r.controller.reconcile()
        var p = r.store.prefs; p.assignments.defaultItem = good.id; r.store.prefs = p
        r.controller.reconcile()
        XCTAssertEqual(r.factory.live(for: "D1")?.itemName, "Good")
    }

    func testARemotePageThatFailedIsRetriedWhenTheNetworkReturns() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "Remote")          // a link
        r.factory.refuse = ["Remote"]
        assign(r, default: a)
        r.controller.reconcile()
        XCTAssertEqual(r.net.callbacks.count, 1, "one watch, started because a link failed")
        r.controller.reconcile(); r.controller.conditionsChanged()
        XCTAssertEqual(r.net.callbacks.count, 1, "not one per event")
        r.factory.refuse = []
        r.net.callbacks[0]()                       // the network came back
        XCTAssertNotNil(r.factory.live(for: "D1"))
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .playing(itemName: "Remote"))
        XCTAssertEqual(r.net.cancelled, 1, "and the watch ends once nothing is waiting")
    }

    func testASurfaceThatFailsAfterShowingARemotePageIsAlsoRetriedOnNetworkReturn() throws {
        let r = try rig(displays: [display("D1")]); defer { done(r) }
        let a = try addItem(r, "Remote"); assign(r, default: a)
        r.controller.reconcile()
        XCTAssertEqual(r.net.callbacks.count, 0, "nothing failed, nothing watched")
        r.factory.live(for: "D1")?.onFailure?("The Internet connection appears to be offline.")
        XCTAssertEqual(r.net.callbacks.count, 1)
        r.net.callbacks[0]()
        XCTAssertNotNil(r.factory.live(for: "D1"))
    }

    func testALocalFileThatFailedDoesNotStartANetworkWatch() throws {
        let r = try rig(); defer { done(r) }
        let gone = try addItem(r, "Gone", source: .file("gone.mov")); assign(r, default: gone)
        r.controller.reconcile()
        XCTAssertEqual(r.net.callbacks.count, 0)
    }

    func testShutdownEndsTheNetworkWatch() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "Remote")
        r.factory.refuse = ["Remote"]
        assign(r, default: a)
        r.controller.reconcile()
        r.controller.shutdown()
        XCTAssertEqual(r.net.cancelled, 1)
    }

    func testEveryStateChangeIsLoggedAndNothingElseIs() throws {
        let r = try rig(); defer { done(r) }
        var lines: [String] = []
        r.controller.log = { lines.append($0) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        XCTAssertTrue(lines.contains { $0.contains("D1") && $0.contains("show") && $0.contains("A") }, lines.description)
        lines.removeAll()
        r.controller.conditionsChanged(); r.controller.conditionsChanged()
        XCTAssertEqual(lines, [], "an event that changes nothing writes nothing")
        r.conditions.value.onBattery = true; r.controller.conditionsChanged()
        XCTAssertTrue(lines.contains { $0.contains("D1") && $0.contains("pause") && $0.contains("onBattery") }, lines.description)
        lines.removeAll()
        r.conditions.value.onBattery = false; r.controller.conditionsChanged()
        XCTAssertTrue(lines.contains { $0.contains("D1") && $0.contains("play") }, lines.description)
        lines.removeAll()
        r.factory.live(for: "D1")?.onFailure?("boom")
        XCTAssertTrue(lines.contains { $0.contains("D1") && $0.contains("fail") && $0.contains("boom") }, lines.description)
    }

    // MARK: displays

    func testDisplayAddedOrRemovedReconciles() throws {
        let r = try rig(displays: [display("D1")]); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        XCTAssertNil(r.factory.live(for: "D2"))
        r.displays.value = [display("D1"), display("D2", x: 1000)]
        r.controller.conditionsChanged()
        XCTAssertNotNil(r.factory.live(for: "D2"), "a new display gets its wallpaper")
        let d2 = try XCTUnwrap(r.factory.live(for: "D2"))
        r.displays.value = [display("D1")]
        r.controller.conditionsChanged()
        XCTAssertEqual(d2.closeCount, 1, "an unplugged display's surface is closed, not left behind")
    }

    func testReplugKeepsTheAssignmentByUUID() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"), b = try addItem(r, "B")
        assign(r, default: a, ["D2": .item(b.id)])
        r.controller.reconcile()
        r.displays.value = [display("D1")]
        r.controller.reconcile()
        r.displays.value = [display("D1"), display("D2", x: 1000)]
        r.controller.reconcile()
        XCTAssertEqual(r.factory.live(for: "D2")?.itemName, "B")
    }

    func testAMovedDisplayGetsItsFrameUpdatedNotANewSurface() throws {
        let r = try rig(displays: [display("D1")]); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        let moved = DisplayInfo(uuid: "D1", name: "D1", frame: NSRect(x: 50, y: 0, width: 1000, height: 600), pixelSize: CGSize(width: 2000, height: 1200))
        r.displays.value = [moved]
        r.controller.conditionsChanged()
        XCTAssertEqual(s.frames.last, moved.frame)
        XCTAssertEqual(r.factory.makeCalls, 1)
    }

    // MARK: pausing

    func testOnBatteryPausesAndACResumes() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        XCTAssertEqual(s.lastPlaying, true)
        r.conditions.value.onBattery = true
        r.controller.conditionsChanged()
        XCTAssertEqual(s.lastPlaying, false)
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .paused(.onBattery, itemName: "A"))
        r.conditions.value.onBattery = false
        r.controller.conditionsChanged()
        XCTAssertEqual(s.lastPlaying, true)
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .playing(itemName: "A"))
    }

    func testPrefOffKeepsPlaying() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        var p = r.store.prefs; p.pauseOnBattery = false; r.store.prefs = p
        r.controller.reconcile()
        r.conditions.value.onBattery = true
        r.controller.conditionsChanged()
        XCTAssertEqual(r.factory.live(for: "D1")?.lastPlaying, true)
    }

    func testImageSurfaceIsNeverPausedAndReportsShowing() throws {
        let r = try rig(); defer { done(r) }
        let img = try addItem(r, "Pic", kind: .image, source: .remote(URL(string: "https://example.com/p.png")!))
        assign(r, default: img)
        r.controller.reconcile()
        r.conditions.value.onBattery = true; r.conditions.value.lowPowerMode = true
        r.controller.conditionsChanged()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        XCTAssertFalse(s.playingCalls.contains(false), "never told to stop")
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .showing(itemName: "Pic"))
    }

    func testCoveredPausesOnlyAfterTheGateAndResumesAtOnce() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        s.onCoveredChange?(true)                       // covered at t0
        XCTAssertEqual(s.lastPlaying, true)
        r.clock.value = t0.addingTimeInterval(0.6)     // longer than a Space slide
        r.controller.gateTimerFired()
        XCTAssertEqual(s.lastPlaying, true, "a Space switch must not pause it")
        r.clock.value = t0.addingTimeInterval(1.0)
        r.controller.gateTimerFired()
        XCTAssertEqual(s.lastPlaying, false)
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .paused(.covered, itemName: "A"))
        s.onCoveredChange?(false)                      // uncovered
        XCTAssertEqual(s.lastPlaying, true, "resumes at once")
    }

    func testACoverThatEndsBeforeTheGateNeverPauses() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        s.onCoveredChange?(true)
        r.clock.value = t0.addingTimeInterval(0.54)
        s.onCoveredChange?(false)
        r.clock.value = t0.addingTimeInterval(5)
        r.controller.gateTimerFired()
        XCTAssertFalse(s.playingCalls.contains(false))
    }

    func testCoveringOneDisplayLeavesTheOtherPlaying() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let d1 = try XCTUnwrap(r.factory.live(for: "D1")), d2 = try XCTUnwrap(r.factory.live(for: "D2"))
        d1.onCoveredChange?(true)
        r.clock.value = t0.addingTimeInterval(2)
        r.controller.gateTimerFired()
        XCTAssertEqual(d1.lastPlaying, false)
        XCTAssertEqual(d2.lastPlaying, true)
    }

    func testUserPauseSurvivesConditionsClearing() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        r.controller.toggleUserPaused()
        XCTAssertTrue(r.controller.userPaused)
        XCTAssertEqual(s.lastPlaying, false)
        r.conditions.value.onBattery = true; r.controller.conditionsChanged()
        r.conditions.value.onBattery = false; r.controller.conditionsChanged()
        XCTAssertEqual(s.lastPlaying, false, "the user's pause outlasts every other condition")
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .paused(.userPaused, itemName: "A"))
        r.controller.toggleUserPaused()
        XCTAssertEqual(s.lastPlaying, true)
    }

    func testWakeAndUnlockAlwaysTellTheSurfaceToPlayAgain() throws {
        // Sleep/wake and lock/unlock were not verified on hardware, and the system can stop a player without telling it.
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        r.conditions.value.displaysAsleep = true; r.controller.conditionsChanged()
        XCTAssertEqual(s.lastPlaying, false)
        let before = s.playingCalls.filter { $0 }.count
        r.conditions.value.displaysAsleep = false; r.controller.conditionsChanged()
        XCTAssertEqual(s.playingCalls.filter { $0 }.count, before + 1)

        r.conditions.value.screenLocked = true; r.controller.conditionsChanged()
        let beforeUnlock = s.playingCalls.filter { $0 }.count
        r.conditions.value.screenLocked = false; r.controller.conditionsChanged()
        XCTAssertEqual(s.lastPlaying, true)
        XCTAssertGreaterThan(s.playingCalls.filter { $0 }.count, beforeUnlock)
    }

    func testAWakeWhilePlayingStillRePlays() throws {
        // A sleep that never produced a "paused" state (the notification was missed) still ends with a fresh play().
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let s = try XCTUnwrap(r.factory.live(for: "D1"))
        // Nothing the controller can see changed, but the system woke: a playing surface is still told to play.
        let before = s.playingCalls.count
        r.controller.conditionsChanged(refresh: true)
        XCTAssertEqual(Array(s.playingCalls.dropFirst(before)), [true])
        // An ordinary change with nothing different does not nag it.
        r.controller.conditionsChanged()
        XCTAssertEqual(s.playingCalls.count, before + 1)
        // A paused surface is not woken by a refresh.
        r.controller.setUserPaused(true)
        let paused = s.playingCalls.count
        r.controller.conditionsChanged(refresh: true)
        XCTAssertEqual(s.playingCalls.count, paused)
    }

    // MARK: prefs, lifecycle, status

    func testPrefsChangeIsAppliedToEverySurfaceWithoutRecreatingThem() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let made = r.factory.makeCalls
        var p = r.store.prefs; p.muted = false; p.speed = 1.5; r.store.prefs = p
        for id in ["D1", "D2"] {
            XCTAssertEqual(r.factory.live(for: id)?.applied.last?.speed, 1.5, id)
            XCTAssertEqual(r.factory.live(for: id)?.applied.last?.muted, false, id)
        }
        XCTAssertEqual(r.factory.makeCalls, made, "no surface was recreated")
    }

    func testPrefsAreAppliedToANewSurfaceBeforeItIsPlayed() throws {
        let r = try rig(); defer { done(r) }
        var p = r.store.prefs; p.speed = 0.5; r.store.prefs = p
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        XCTAssertEqual(r.factory.live(for: "D1")?.applied.last?.speed, 0.5)
    }

    func testTurningTheSettingOffClosesEverythingAndOnBringsItBack() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let d1 = try XCTUnwrap(r.factory.live(for: "D1")), d2 = try XCTUnwrap(r.factory.live(for: "D2"))
        r.settings.liveWallpaperEnabled = false
        r.controller.reconcile()
        XCTAssertEqual(d1.closeCount, 1); XCTAssertEqual(d2.closeCount, 1)
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .noWallpaper)
        r.settings.liveWallpaperEnabled = true
        r.controller.reconcile()
        XCTAssertNotNil(r.factory.live(for: "D1"))
    }

    func testDisablingAndShutdownCloseEverySurfaceExactlyOnce() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        r.settings.liveWallpaperEnabled = false
        r.controller.reconcile()
        r.controller.shutdown()
        r.controller.shutdown()
        XCTAssertTrue(r.factory.made.allSatisfy { $0.closeCount == 1 }, r.factory.made.map(\.closeCount).description)
    }

    func testShutdownClosesLiveSurfacesAndStopsReacting() throws {
        let r = try rig(); defer { done(r) }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        r.controller.shutdown()
        XCTAssertTrue(r.factory.made.allSatisfy { $0.closeCount == 1 })
        let calls = r.factory.makeCalls
        r.controller.reconcile(); r.controller.conditionsChanged()
        XCTAssertEqual(r.factory.makeCalls, calls, "after shutdown nothing is made")
    }

    func testStatusFollowsTheState() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .noWallpaper)
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .playing(itemName: "A"))
        r.conditions.value.thermalHot = true; r.controller.conditionsChanged()
        XCTAssertEqual(r.controller.status(forDisplay: "D1"), .paused(.tooHot, itemName: "A"))
        XCTAssertEqual(r.controller.status(forDisplay: "not-a-display"), .noWallpaper)
    }

    func testOnChangeFiresWhenTheStateShownCouldHaveChanged() throws {
        let r = try rig(); defer { done(r) }
        var fired = 0
        r.controller.onChange = { fired += 1 }
        let a = try addItem(r, "A"); assign(r, default: a)
        r.controller.reconcile()
        let afterReconcile = fired
        XCTAssertGreaterThan(afterReconcile, 0)
        r.conditions.value.onBattery = true; r.controller.conditionsChanged()
        XCTAssertGreaterThan(fired, afterReconcile)
    }

    func testIsHotIsTrueForSeriousAndCriticalOnly() {
        XCTAssertFalse(WallpaperConditionsSource.isHot(.nominal))
        XCTAssertFalse(WallpaperConditionsSource.isHot(.fair))
        XCTAssertTrue(WallpaperConditionsSource.isHot(.serious))
        XCTAssertTrue(WallpaperConditionsSource.isHot(.critical))
    }
}
