import XCTest
@testable import PowerKit

/// When a wallpaper should be paused, the delay on the one reason that flickers, and the pool that shares players.
final class WallpaperPolicyTests: XCTestCase {

    private func reason(_ prefs: WallpaperPrefs = WallpaperPrefs(), _ g: WallpaperGlobalConditions = WallpaperGlobalConditions(),
                        covered: Bool = false) -> WallpaperPauseReason? {
        WallpaperPolicy.pauseReason(prefs: prefs, global: g, display: WallpaperDisplayConditions(covered: covered))
    }

    // MARK: policy

    func testNothingSetPlays() {
        XCTAssertNil(reason())
    }

    func testEachPrefTurnsItsOwnReasonOnAndOff() {
        var p = WallpaperPrefs()
        var g = WallpaperGlobalConditions()

        g.onBattery = true
        XCTAssertEqual(reason(p, g), .onBattery)
        p.pauseOnBattery = false
        XCTAssertNil(reason(p, g))

        p = WallpaperPrefs(); g = WallpaperGlobalConditions()
        g.lowPowerMode = true
        XCTAssertEqual(reason(p, g), .lowPowerMode)
        p.pauseInLowPower = false
        XCTAssertNil(reason(p, g))

        p = WallpaperPrefs(); g = WallpaperGlobalConditions()
        g.thermalHot = true
        XCTAssertEqual(reason(p, g), .tooHot)
        p.pauseWhenHot = false
        XCTAssertNil(reason(p, g))

        p = WallpaperPrefs(); g = WallpaperGlobalConditions()
        XCTAssertEqual(reason(p, g, covered: true), .covered)
        p.pauseWhenCovered = false
        XCTAssertNil(reason(p, g, covered: true))
    }

    func testSleepLockAndUserPauseApplyWhateverThePrefsSay() {
        var p = WallpaperPrefs()
        p.pauseOnBattery = false; p.pauseInLowPower = false; p.pauseWhenCovered = false; p.pauseWhenHot = false
        var g = WallpaperGlobalConditions()
        g.displaysAsleep = true
        XCTAssertEqual(reason(p, g), .displaysAsleep)
        g = WallpaperGlobalConditions(); g.screenLocked = true
        XCTAssertEqual(reason(p, g), .screenLocked)
        g = WallpaperGlobalConditions(); g.userPaused = true
        XCTAssertEqual(reason(p, g), .userPaused)
    }

    /// The mode turns macOS's Low Power Mode on too, and the owner may have switched every "pause when" off: the wallpaper
    /// stands still all the same, and the reason given is the mode's. Sleep, lock and the owner's own pause still come first.
    func testWallpaperPausesForUltraLowPowerWhateverThePreferences() {
        var p = WallpaperPrefs()
        p.pauseOnBattery = false; p.pauseInLowPower = false; p.pauseWhenCovered = false; p.pauseWhenHot = false
        var g = WallpaperGlobalConditions(ultraLowPower: true)
        XCTAssertEqual(reason(p, g), .ultraLowPower)
        p = WallpaperPrefs()
        g.lowPowerMode = true; g.onBattery = true; g.thermalHot = true
        XCTAssertEqual(reason(p, g, covered: true), .ultraLowPower)
        g.screenLocked = true
        XCTAssertEqual(reason(p, g, covered: true), .screenLocked)
        g.ultraLowPower = false; g.screenLocked = false
        XCTAssertEqual(reason(p, g, covered: true), .lowPowerMode, "without the mode the rules are as they were")
    }

    func testPriorityWhenSeveralHold() {
        var g = WallpaperGlobalConditions(onBattery: true, lowPowerMode: true, thermalHot: true,
                                          displaysAsleep: true, screenLocked: true, userPaused: true)
        let p = WallpaperPrefs()
        XCTAssertEqual(reason(p, g, covered: true), .userPaused)
        g.userPaused = false;     XCTAssertEqual(reason(p, g, covered: true), .displaysAsleep)
        g.displaysAsleep = false; XCTAssertEqual(reason(p, g, covered: true), .screenLocked)
        g.screenLocked = false;   XCTAssertEqual(reason(p, g, covered: true), .lowPowerMode)
        g.lowPowerMode = false;   XCTAssertEqual(reason(p, g, covered: true), .onBattery)
        g.onBattery = false;      XCTAssertEqual(reason(p, g, covered: true), .tooHot)
        g.thermalHot = false;     XCTAssertEqual(reason(p, g, covered: true), .covered)
    }

    // MARK: gate

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testDefaultDelayIsOneSecondBecauseASpaceSlideHidesTheWindowForHalfASecond() {
        // Measured 2026-11-06: occlusionState reads "hidden" for ~0.54 s during every Space switch.
        var gate = PauseGate()
        XCTAssertNil(gate.update(.covered, now: t0))
        XCTAssertNil(gate.update(.covered, now: t0.addingTimeInterval(0.6)), "longer than a Space slide, still not paused")
        XCTAssertEqual(gate.update(.covered, now: t0.addingTimeInterval(1.0)), .covered)
    }

    func testCoveredIsReturnedOnlyAfterTheDelay() {
        var gate = PauseGate(delay: 0.5)
        XCTAssertNil(gate.update(.covered, now: t0))
        XCTAssertNil(gate.update(.covered, now: t0.addingTimeInterval(0.4)))
        XCTAssertEqual(gate.update(.covered, now: t0.addingTimeInterval(0.5)), .covered)
        XCTAssertEqual(gate.update(.covered, now: t0.addingTimeInterval(9)), .covered, "and it stays")
    }

    func testAnyOtherReasonIsReturnedAtOnce() {
        let others: [WallpaperPauseReason] = [.userPaused, .displaysAsleep, .screenLocked, .lowPowerMode, .onBattery, .tooHot]
        for r in others {
            var gate = PauseGate(delay: 0.5)
            XCTAssertEqual(gate.update(r, now: t0), r)
        }
    }

    func testClearingIsReturnedAtOnce() {
        var gate = PauseGate(delay: 0.5)
        _ = gate.update(.covered, now: t0)
        XCTAssertEqual(gate.update(.covered, now: t0.addingTimeInterval(0.6)), .covered)
        XCTAssertNil(gate.update(nil, now: t0.addingTimeInterval(0.61)))
    }

    func testAFlickerRestartsTheClock() {
        var gate = PauseGate(delay: 0.5)
        _ = gate.update(.covered, now: t0)
        _ = gate.update(nil, now: t0.addingTimeInterval(0.3))
        XCTAssertNil(gate.update(.covered, now: t0.addingTimeInterval(0.4)))
        XCTAssertNil(gate.update(.covered, now: t0.addingTimeInterval(0.8)), "only 0.4 s since it came back")
        XCTAssertEqual(gate.update(.covered, now: t0.addingTimeInterval(0.9)), .covered)
    }

    func testAnImmediateReasonDuringAPendingCoverDropsThePending() {
        var gate = PauseGate(delay: 0.5)
        _ = gate.update(.covered, now: t0)
        XCTAssertEqual(gate.update(.onBattery, now: t0.addingTimeInterval(0.2)), .onBattery)
        XCTAssertNil(gate.nextCheck(now: t0.addingTimeInterval(0.2)))
    }

    func testNextCheckIsWhenAPendingReasonTakesEffect() {
        var gate = PauseGate(delay: 0.5)
        XCTAssertNil(gate.nextCheck(now: t0), "nothing pending")
        _ = gate.update(.covered, now: t0)
        XCTAssertEqual(gate.nextCheck(now: t0.addingTimeInterval(0.1)), t0.addingTimeInterval(0.5))
        _ = gate.update(.covered, now: t0.addingTimeInterval(0.5))
        XCTAssertNil(gate.nextCheck(now: t0.addingTimeInterval(0.5)), "taken effect, nothing pending")
        _ = gate.update(nil, now: t0.addingTimeInterval(1))
        XCTAssertNil(gate.nextCheck(now: t0.addingTimeInterval(1)))
    }

    // MARK: pool

    private final class Counter { var made = 0; var disposed: [Int] = [] }

    func testAcquireTwiceMakesOneValueAndTheSecondReleaseDisposesItOnce() throws {
        let c = Counter()
        let pool = RefCountedPool<String, Int>(make: { _ in c.made += 1; return c.made }, dispose: { c.disposed.append($0) })
        let a = try pool.acquire("k"), b = try pool.acquire("k")
        XCTAssertEqual(a, b)
        XCTAssertEqual(c.made, 1)
        XCTAssertEqual(pool.liveKeys, ["k"])
        pool.release("k")
        XCTAssertEqual(c.disposed, [], "still held once")
        XCTAssertEqual(pool.liveKeys, ["k"])
        pool.release("k")
        XCTAssertEqual(c.disposed, [1])
        XCTAssertEqual(pool.liveKeys, [])
        pool.release("k")
        XCTAssertEqual(c.disposed, [1], "an extra release does not dispose twice")
    }

    func testAMakeThatThrowsLeavesNothingRegistered() {
        struct Boom: Error {}
        let pool = RefCountedPool<String, Int>(make: { _ in throw Boom() }, dispose: { _ in XCTFail("nothing to dispose") })
        XCTAssertThrowsError(try pool.acquire("k"))
        XCTAssertEqual(pool.liveKeys, [])
        pool.release("k")
    }

    func testReleasingAnUnknownKeyIsANoOp() {
        let pool = RefCountedPool<String, Int>(make: { _ in 1 }, dispose: { _ in XCTFail("nothing to dispose") })
        pool.release("never")
        XCTAssertEqual(pool.liveKeys, [])
    }

    func testDifferentKeysAreIndependent() throws {
        let c = Counter()
        let pool = RefCountedPool<String, Int>(make: { _ in c.made += 1; return c.made }, dispose: { c.disposed.append($0) })
        _ = try pool.acquire("a"); _ = try pool.acquire("b")
        XCTAssertEqual(pool.liveKeys, ["a", "b"])
        pool.release("a")
        XCTAssertEqual(c.disposed, [1])
        XCTAssertEqual(pool.liveKeys, ["b"])
    }
}
