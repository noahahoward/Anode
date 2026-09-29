import XCTest
@testable import PowerKit

// The lifetime model learns two things from every awake minute on battery: what
// this machine usually draws, and how long a departure from that usually lasts.
// Every rule it applies to decide what counts is pinned here, on synthetic time.
final class LifetimeDrainModelTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var awake: TimeInterval = 10_000
    private var now: Date = Date(timeIntervalSince1970: 1_700_000_000)

    private func fresh() -> LifetimeDrainModel {
        LifetimeDrainModel(machineModel: "Mac17,9", designCapacity_mAh: 6251, osBuild: "26A428")
    }

    /// Feed `seconds` of battery ticks at `watts`, every 2 s, advancing both clocks.
    private func feed(_ m: inout LifetimeDrainModel, watts: Double, seconds: Int,
                      onBattery: Bool = true, topApp: LifetimeDrainModel.TopApp? = nil) {
        for _ in 0..<(seconds / 2) {
            awake += 2; now += 2
            m.observe(batteryWatts: watts, onBattery: onBattery, interval: 2,
                      awake: awake, now: now, topApp: topApp)
        }
    }

    /// Past the unplug settle and into a warm baseline at `watts`.
    private func warm(_ m: inout LifetimeDrainModel, watts: Double = 10) {
        feed(&m, watts: watts, seconds: 120 + 2 * 3600 + 2)
    }

    // ── baseline ─────────────────────────────────────────────────────────────

    func testColdModelHasNoOpinion() {
        var m = fresh()
        feed(&m, watts: 10, seconds: 600)
        XCTAssertNil(m.prior(awake: awake))
    }

    func testBaselineIsTheTimeWeightedMeanOfBatteryDraw() throws {
        var m = fresh()
        feed(&m, watts: 8, seconds: 120)              // settle, ignored
        feed(&m, watts: 8, seconds: 3600)
        feed(&m, watts: 14, seconds: 3600)
        let b = try XCTUnwrap(m.baseline_W)
        XCTAssertEqual(b, 11, accuracy: 0.05)
    }

    func testTheFirstTwoMinutesAfterUnplugAreIgnored() throws {
        var m = fresh()
        feed(&m, watts: 100, seconds: 118)            // the unplug transient
        feed(&m, watts: 10, seconds: 2 * 3600 + 10)
        XCTAssertEqual(try XCTUnwrap(m.baseline_W), 10, accuracy: 0.01)
    }

    func testChargingAndGapsTeachNothing() throws {
        var m = fresh()
        warm(&m)
        let before = try XCTUnwrap(m.baseline_W)
        feed(&m, watts: 60, seconds: 3600, onBattery: false)
        awake += 2; now += 2
        m.observe(batteryWatts: 60, onBattery: true, interval: 0, awake: awake, now: now, topApp: nil)
        XCTAssertEqual(try XCTUnwrap(m.baseline_W), before, accuracy: 1e-9)
    }

    /// A dark wake — awake, on battery, display off, doing maintenance — is not
    /// anyone using the machine. A night holds hundreds of them, and at a watt
    /// or two each they would drag "typical use" down toward idle.
    func testDisplayOffTimeTeachesNothing() throws {
        var m = fresh()
        warm(&m, watts: 10)
        for _ in 0..<(3600 / 2) {
            awake += 2; now += 2
            m.observe(batteryWatts: 1.5, onBattery: true, displayOn: false, interval: 2,
                      awake: awake, now: now, topApp: nil)
        }
        XCTAssertEqual(try XCTUnwrap(m.baseline_W), 10, accuracy: 0.01)
    }

    func testThirtyDaysHalvesTheOldWeight() throws {
        var m = fresh()
        warm(&m, watts: 10)
        now += 30 * 86_400                             // a month on the shelf
        feed(&m, watts: 20, seconds: 120)             // new unplug settle
        // Same awake time at 20 W as the old 10 W history, which now counts half.
        feed(&m, watts: 20, seconds: 2 * 3600 + 2)
        let b = try XCTUnwrap(m.baseline_W)
        XCTAssertEqual(b, (10 * 0.5 + 20 * 1) / 1.5, accuracy: 0.1)
    }

    func testAClockSetBackwardsDoesNotAddWeight() throws {
        var m = fresh()
        warm(&m, watts: 10)
        now -= 5 * 86_400
        feed(&m, watts: 10, seconds: 60)
        XCTAssertEqual(try XCTUnwrap(m.baseline_W), 10, accuracy: 1e-9)
    }

    /// A long rest must not make a learned machine forget it is learned: decay
    /// changes how much old data COUNTS, not whether there is any.
    func testAWarmModelStaysWarmAfterAMonthUnused() {
        var m = fresh()
        warm(&m)
        now += 60 * 86_400
        feed(&m, watts: 10, seconds: 130)
        XCTAssertNotNil(m.prior(awake: awake))
    }

    // ── OS updates ───────────────────────────────────────────────────────────

    func testAnOSUpdateRebuildsTheBaselineAndTheOldOneFillsIn() throws {
        var m = fresh()
        warm(&m, watts: 10)
        m.adopt(osBuild: "26B100")
        XCTAssertEqual(m.osBuild, "26B100")
        // Until the new build has its own two hours, the old baseline answers.
        feed(&m, watts: 20, seconds: 600)
        XCTAssertEqual(try XCTUnwrap(m.lifetimeBaseline_W), 10, accuracy: 1e-9)
        feed(&m, watts: 20, seconds: 2 * 3600)
        XCTAssertEqual(try XCTUnwrap(m.lifetimeBaseline_W), 20, accuracy: 0.05)
    }

    func testTheSameBuildIsNotAnUpdate() throws {
        var m = fresh()
        warm(&m, watts: 10)
        m.adopt(osBuild: "26A428")
        XCTAssertEqual(try XCTUnwrap(m.baseline_W), 10, accuracy: 1e-9)
    }

    func testExcursionHistorySurvivesAnOSUpdate() {
        var m = fresh()
        warm(&m, watts: 10)
        for _ in 0..<3 { feed(&m, watts: 30, seconds: 1200); feed(&m, watts: 10, seconds: 900) }
        let learned = m.excursionStat(high: true)
        m.adopt(osBuild: "26B100")
        XCTAssertEqual(m.excursionStat(high: true), learned)
    }

    // ── this session ─────────────────────────────────────────────────────────

    /// The lifetime baseline is where a session is expected to settle, but a
    /// long session that has consistently drawn something else is evidence too.
    /// It pulls the target toward itself, reaching halfway after an hour.
    func testALongSessionPullsTheTargetTowardItself() throws {
        var m = fresh()
        warm(&m, watts: 10)
        feed(&m, watts: 5, seconds: 10, onBattery: false)      // lid closed, new session
        feed(&m, watts: 6, seconds: 120)                         // unplug settle
        feed(&m, watts: 6, seconds: 3600)
        // The lifetime figure has absorbed this hour too, so read it back.
        let lifetime = try XCTUnwrap(m.lifetimeBaseline_W)
        let p = try XCTUnwrap(m.prior(awake: awake))
        XCTAssertEqual(p.baseline_W, (lifetime + 6) / 2, accuracy: 0.05)
    }

    func testAFreshSessionTrustsTheLifetime() throws {
        var m = fresh()
        warm(&m, watts: 10)
        feed(&m, watts: 5, seconds: 10, onBattery: false)
        feed(&m, watts: 6, seconds: 130)
        let p = try XCTUnwrap(m.prior(awake: awake))
        XCTAssertEqual(p.baseline_W, 10, accuracy: 0.1)
    }

    /// A render is not what the session "normally" draws; it is the excursion
    /// the forecast already handles separately.
    func testHeavyStretchesDoNotCountAsTheSessionsLevel() throws {
        var m = fresh()
        warm(&m, watts: 10)
        feed(&m, watts: 5, seconds: 10, onBattery: false)
        feed(&m, watts: 10, seconds: 120)
        feed(&m, watts: 10, seconds: 3600)
        feed(&m, watts: 40, seconds: 3600)
        // The lifetime has absorbed the heavy hour (that is what a lifetime
        // average is), but the SESSION'S level is 10 W, so it pulls the target
        // down. Counted as the session's level, the heavy hour would push it up.
        let lifetime = try XCTUnwrap(m.lifetimeBaseline_W)
        let p = try XCTUnwrap(m.prior(awake: awake))
        XCTAssertLessThan(p.baseline_W, lifetime)
    }

    // ── excursions ───────────────────────────────────────────────────────────

    func testAHeavyStretchIsLearnedWithItsLength() throws {
        var m = fresh()
        warm(&m, watts: 10)
        feed(&m, watts: 30, seconds: 1200)
        feed(&m, watts: 10, seconds: 900)
        let s = try XCTUnwrap(m.excursionStat(high: true))
        XCTAssertEqual(s.count, 1)
        // Detected from a 5-minute mean, so the edges blur by a few minutes each side.
        XCTAssertEqual(s.mean_s, 1200, accuracy: 360)
    }

    func testABlipIsNotAnExcursion() {
        var m = fresh()
        warm(&m, watts: 10)
        feed(&m, watts: 60, seconds: 20)
        feed(&m, watts: 10, seconds: 900)
        XCTAssertNil(m.excursionStat(high: true))
    }

    func testTheNormalBandGivesTheBaselineQuickly() throws {
        var m = fresh()
        warm(&m, watts: 10)
        let p = try XCTUnwrap(m.prior(awake: awake))
        XCTAssertEqual(p.band, .normal)
        XCTAssertEqual(p.tau_s, LifetimeDrainModel.normalTau)
    }

    func testAnUnlearnedHeavyLoadIsAssumedToContinue() throws {
        var m = fresh()
        warm(&m, watts: 10)
        feed(&m, watts: 30, seconds: 600)
        let p = try XCTUnwrap(m.prior(awake: awake))
        XCTAssertEqual(p.band, .heavy)
        XCTAssertEqual(p.tau_s, .infinity)
    }

    func testALearnedHeavyLoadFadesAfterItsUsualLength() throws {
        var m = fresh()
        warm(&m, watts: 10)
        for _ in 0..<3 { feed(&m, watts: 30, seconds: 1200); feed(&m, watts: 10, seconds: 900) }
        feed(&m, watts: 30, seconds: 400)
        let p = try XCTUnwrap(m.prior(awake: awake))
        XCTAssertTrue(p.band == .elevated || p.band == .heavy, "\(p.band)")
        XCTAssertEqual(p.tau_s, try XCTUnwrap(m.excursionStat(high: true)).mean_s, accuracy: 1)
    }

    /// A render that has already outlasted every render before it is expected to
    /// keep going for at least as long again — so a three-hour job converges on
    /// "the current load continues", which is what it is doing.
    func testALoadOutlastingItsHistoryIsExpectedToKeepGoing() throws {
        var m = fresh()
        warm(&m, watts: 10)
        for _ in 0..<3 { feed(&m, watts: 30, seconds: 600); feed(&m, watts: 10, seconds: 900) }
        feed(&m, watts: 30, seconds: 3 * 3600)
        let p = try XCTUnwrap(m.prior(awake: awake))
        XCTAssertGreaterThanOrEqual(p.tau_s, 3 * 3600 - 400)
    }

    // ── per app ──────────────────────────────────────────────────────────────

    private let render = LifetimeDrainModel.TopApp(key: "com.apple.FinalCut", name: "Final Cut Pro", share: 0.8)

    func testAnAppNeedsThreeRunsBeforeItsOwnLengthIsUsed() throws {
        var m = fresh()
        warm(&m, watts: 10)
        // The band learns short heavy stretches from something else.
        for _ in 0..<3 { feed(&m, watts: 30, seconds: 400); feed(&m, watts: 10, seconds: 900) }
        for run in 1...3 {
            feed(&m, watts: 30, seconds: 2400, topApp: render)
            feed(&m, watts: 10, seconds: 900)
            feed(&m, watts: 30, seconds: 170, topApp: render)   // a probe, under minExcursion
            let p = try XCTUnwrap(m.prior(awake: awake))
            XCTAssertEqual(p.appName, "Final Cut Pro", "named as soon as it is seen")
            let expected = run < 3 ? try XCTUnwrap(m.excursionStat(high: true)).mean_s
                                   : try XCTUnwrap(m.appStat("com.apple.FinalCut")).mean_s
            XCTAssertEqual(p.tau_s, expected, accuracy: 1, "run \(run)")
            feed(&m, watts: 10, seconds: 900)
        }
    }

    func testAMinorityAppIsNotBlamedForTheLoad() {
        var m = fresh()
        warm(&m, watts: 10)
        let bystander = LifetimeDrainModel.TopApp(key: "com.example.Mail", name: "Mail", share: 0.2)
        feed(&m, watts: 30, seconds: 1200, topApp: bystander)
        feed(&m, watts: 10, seconds: 900)
        XCTAssertNil(m.appStat("com.example.Mail"))
    }

    func testAnAppSeenLongBeforeTheLoadIsNotBlamed() {
        var m = fresh()
        warm(&m, watts: 10)
        feed(&m, watts: 10, seconds: 4, topApp: render)   // seen, then not again
        feed(&m, watts: 10, seconds: 300)
        feed(&m, watts: 30, seconds: 1200)
        feed(&m, watts: 10, seconds: 900)
        XCTAssertNil(m.appStat("com.apple.FinalCut"))
    }

    func testTheAppTableStaysSmall() {
        var m = fresh()
        warm(&m, watts: 10)
        for i in 0..<40 {
            let app = LifetimeDrainModel.TopApp(key: "app.\(i)", name: "App \(i)", share: 0.9)
            feed(&m, watts: 30, seconds: 400, topApp: app)
            feed(&m, watts: 10, seconds: 300)
        }
        XCTAssertLessThanOrEqual(m.appCount, LifetimeDrainModel.maxApps)
        XCTAssertNotNil(m.appStat("app.39"), "the most recent survives")
        XCTAssertNil(m.appStat("app.0"), "the least recently used goes")
    }
}

// ── what the tick feeds it ──────────────────────────────────────────────────

final class LifetimeDrainInputsTests: XCTestCase {

    private func state(mA: Int, mV: Int) -> Battery.State {
        Battery.State(percent: 60, isCharging: false, onAC: false, cycleCount: 10,
                      voltage_mV: mV, amperage_mA: mA,
                      remainingCapacity_mAh: 3000, timeRemaining_min: nil)
    }

    /// Battery-side watts — what actually leaves the pack, the same thing the
    /// discharge tier measures — ahead of either system-side figure.
    func testBatteryWattsComeFromThePackFirst() {
        XCTAssertEqual(LifetimeDrainModel.batteryWatts(state: state(mA: -1000, mV: 12_000),
                                                       measured_W: 9, smoothed_W: 8), 12, accuracy: 1e-9)
        XCTAssertEqual(LifetimeDrainModel.batteryWatts(state: state(mA: 0, mV: 12_000),
                                                       measured_W: 9, smoothed_W: 8), 9)
        XCTAssertEqual(LifetimeDrainModel.batteryWatts(state: nil, measured_W: nil, smoothed_W: 8), 8)
    }

    /// The gauge's 60 s window first, when it is fresh: on battery it IS the
    /// pack's discharge, where instantaneous current × voltage read 9 % high
    /// over the recorded run-down.
    func testAFreshGaugeWindowBeatsThePacksInstantReading() {
        XCTAssertEqual(LifetimeDrainModel.batteryWatts(state: state(mA: -1000, mV: 12_000),
                                                       measured_W: 11, measuredAge: 30,
                                                       smoothed_W: 8), 11)
        // Stale: the gauge stopped publishing, so the live pack reading wins.
        XCTAssertEqual(LifetimeDrainModel.batteryWatts(state: state(mA: -1000, mV: 12_000),
                                                       measured_W: 11, measuredAge: 600,
                                                       smoothed_W: 8), 12, accuracy: 1e-9)
    }

    func testTheTopAppIsTheLargestShareOfAttributedPower() throws {
        func drain(_ name: String, _ id: String?, _ w: Double) -> AppDrain {
            AppDrain(identity: AppIdentity(name: name, bundleID: id, isApp: true), joules: w, over: 1)
        }
        let top = try XCTUnwrap(LifetimeDrainModel.TopApp.dominant(in: [
            drain("Mail", "com.apple.mail", 1), drain("Final Cut Pro", "com.apple.FinalCut", 6),
            drain("kernel_task", nil, 3)]))
        XCTAssertEqual(top.key, "com.apple.FinalCut")
        XCTAssertEqual(top.name, "Final Cut Pro")
        XCTAssertEqual(top.share, 0.6, accuracy: 1e-9)
        XCTAssertNil(LifetimeDrainModel.TopApp.dominant(in: []))
    }
}
