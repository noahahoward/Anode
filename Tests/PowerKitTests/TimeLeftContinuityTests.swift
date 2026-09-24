import XCTest
@testable import PowerKit

/// The displayed time-to-empty must move while the gauge is silent.
///
/// ## The complaint
/// The headline sat at "7h 03m" for over a minute. That is structural, not a
/// rendering artifact: on the winning `.discharge` tier BOTH inputs to
/// `timeToEmpty` come from the gas gauge, which publishes in ~60-tick batches
/// about once a minute. `BatteryDischargeTrend.record` deliberately advances
/// only on a new batch, and `remainingPct` reads `last.mAh`, which likewise
/// moves only on a publish. Between publishes the quoted time CANNOT change.
///
/// ## Why counting it down asserts nothing new
/// At an unchanged rate `r` from a charge `p0`,
///
///     t(tau) = (p0 - r*tau/3600) / r * 3600 = t0 - tau
///
/// exactly. So a display that counts down in real time is not approximating the
/// model — it is the model's own prediction, delivered continuously instead of
/// in one lump per publish. The rate never moves without new information, which
/// is the rule `DischargeTrend.record` states; the CLOCK does.
final class TimeLeftContinuityTests: XCTestCase {

    // ── The arithmetic identity the whole design rests on ────────────────────

    /// Not "approximately a minute per minute" — exactly a second per second,
    /// at every rate and every charge. If this ever fails, the projection has
    /// stopped being the anchor's own prediction and has become a second
    /// estimator, which is the thing this must never be.
    func testProjectingIsExactlySubtractingElapsedTime() {
        for rate in [0.5, 3.0, 8.16, 15.0, 47.0] {
            for charge in [5.0, 22.5, 59.2, 100.0] {
                guard let t0 = DrainEstimate.timeToEmpty(chargePercent: charge,
                                                         ratePctHr: rate) else { continue }
                for elapsed: TimeInterval in [1, 2, 30, 60, 300] where elapsed < t0 {
                    let projected = DrainEstimate.projected(chargePercent: charge,
                                                            ratePctHr: rate,
                                                            elapsedAwake: elapsed)
                    XCTAssertEqual(projected ?? -1, t0 - elapsed, accuracy: 1e-6,
                                   "rate \(rate) charge \(charge) after \(elapsed)s")
                }
            }
        }
    }

    /// At the anchor the projector must be a no-op, bit for bit. Every scored
    /// metric in `TrendSweepHarness` samples at publishes, so this is what makes
    /// "the sweep numbers are unchanged" a real regression guard rather than a
    /// tolerance.
    func testAtTheAnchorTheProjectorChangesNothing() {
        let direct = DrainEstimate.timeToEmpty(chargePercent: 59.2, ratePctHr: 8.16)
        let projected = DrainEstimate.projected(chargePercent: 59.2, ratePctHr: 8.16,
                                                elapsedAwake: 0)
        XCTAssertEqual(direct, projected)
    }

    // ── The bug this fixes ───────────────────────────────────────────────────

    /// THE SLIDING DEATH CLOCK.
    ///
    /// `GlanceCardView.at()` rendered `Date().addingTimeInterval(hours * 3600)`
    /// from a FROZEN `hours`, re-drawn every 2 s — so the "dies at 3:41 PM"
    /// figure slid one second later per second of real time, beside a headline
    /// that was not moving at all. The two halves of one row disagreed about
    /// whether time was passing.
    ///
    /// Anchored, the wall clock it names is a fixed instant, which is what a
    /// prediction about when something happens has to be.
    func testTheProjectedDeathInstantDoesNotSlide() {
        let charge = 59.2, rate = 8.16
        let anchorWall = Date(timeIntervalSince1970: 1_000_000)
        var instants: [Date] = []
        for elapsed: TimeInterval in stride(from: 0, through: 120, by: 2) {
            guard let left = DrainEstimate.projected(chargePercent: charge,
                                                     ratePctHr: rate,
                                                     elapsedAwake: elapsed) else {
                return XCTFail("the anchor died mid-window")
            }
            instants.append(anchorWall.addingTimeInterval(elapsed + left))
        }
        let spread = instants.map(\.timeIntervalSince1970).max()!
            - instants.map(\.timeIntervalSince1970).min()!
        XCTAssertEqual(spread, 0, accuracy: 1e-6,
                       "the instant the battery is predicted to die must not move "
                       + "while the prediction behind it is unchanged")
    }

    /// The failure restated as the caller shape that caused it, so nobody
    /// reintroduces it: adding a held `hours` to a live `Date()` slides.
    func testTheOldUnanchoredShapeSlidesAndIsWhyThisFileExists() {
        let heldHours = 7.05
        let a = Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(heldHours * 3600)
        let b = Date(timeIntervalSince1970: 1_000_060).addingTimeInterval(heldHours * 3600)
        XCTAssertEqual(b.timeIntervalSince(a), 60,
                       "a frozen duration added to the current time moves with the "
                       + "current time — this is the bug, pinned")
    }

    // ── Where the projection must refuse ─────────────────────────────────────

    /// The anchor's own prediction runs out. `timeToEmpty` already guards
    /// `chargePercent > 0`, so the projector inherits the refusal rather than
    /// clamping to zero and asserting a dead battery is still alive.
    func testTheProjectionEndsWhenTheAnchorSaysThePackIsEmpty() {
        // 1% left at 10 %/hr is 360 s.
        XCTAssertNotNil(DrainEstimate.projected(chargePercent: 1, ratePctHr: 10,
                                                elapsedAwake: 359))
        XCTAssertNil(DrainEstimate.projected(chargePercent: 1, ratePctHr: 10,
                                             elapsedAwake: 360))
        XCTAssertNil(DrainEstimate.projected(chargePercent: 1, ratePctHr: 10,
                                             elapsedAwake: 3600))
    }

    /// Garbage elapsed time must not produce a garbage projection. A negative
    /// interval means the two clocks disagreed; fall back to the anchor rather
    /// than adding time to the battery.
    func testNonsenseElapsedFallsBackToTheAnchor() {
        let anchor = DrainEstimate.timeToEmpty(chargePercent: 59.2, ratePctHr: 8.16)
        for bad: TimeInterval in [-1, -3600, .nan, .infinity] {
            XCTAssertEqual(DrainEstimate.projected(chargePercent: 59.2, ratePctHr: 8.16,
                                                   elapsedAwake: bad),
                           anchor, "elapsed \(bad) must not extend the battery")
        }
    }

    /// The plausibility guards `timeToEmpty` enforces are not bypassed by going
    /// through the projector — it is the same function, and this pins that.
    func testTheProjectorInheritsTheRefusals() {
        XCTAssertNil(DrainEstimate.projected(chargePercent: 59.2, ratePctHr: 0.05,
                                             elapsedAwake: 10),
                     "below 0.1 %/hr is 'not meaningfully draining'")
        XCTAssertNil(DrainEstimate.projected(chargePercent: 0, ratePctHr: 8,
                                             elapsedAwake: 0))
    }

    // ── The published anchor ─────────────────────────────────────────────────

    /// What the renderers actually hold. One publish, read 60 s later, must
    /// answer 60 s less — this is the user-visible claim of the whole change.
    func testAHeldAnchorCountsDown() {
        let anchor = DisplayedRate(pctHr: 8.16, chargePercent: 59.2, anchorAwake: 500,
                                   source: .discharge, windowSpan: 1800)
        let atAnchor = anchor.timeRemaining_hr(now: 500)
        let aMinuteLater = anchor.timeRemaining_hr(now: 560)
        XCTAssertNotNil(atAnchor)
        XCTAssertEqual((atAnchor! - aMinuteLater!) * 3600, 60, accuracy: 1e-6)
    }

    /// The RATE is not a function of the clock. Only the charge is.
    func testHoldingAnAnchorNeverMovesTheRate() {
        let anchor = DisplayedRate(pctHr: 8.16, chargePercent: 59.2, anchorAwake: 500,
                                   source: .discharge, windowSpan: 1800)
        XCTAssertEqual(anchor.pctHr, 8.16)
    }

    /// An anchor with no charge behind it (the `.insufficient` tier, and the
    /// on-AC case) has nothing to project and must say so rather than counting
    /// down from a number it does not have.
    func testAnAnchorWithoutAChargeQuotesNothing() {
        let anchor = DisplayedRate(pctHr: 0, chargePercent: nil, anchorAwake: 500,
                                   source: .insufficient, windowSpan: 0)
        XCTAssertNil(anchor.timeRemaining_hr(now: 500))
        XCTAssertNil(anchor.timeRemaining_hr(now: 900))
    }

    /// A machine that slept must not be billed for the sleep. `awakeSeconds`
    /// stands still while asleep, so an anchor read after a wake projects only
    /// the awake time — and the estimator has separately reset the trend, so
    /// this is belt and braces rather than the primary defence.
    func testSleepIsNotProjectedAsDrain() {
        let anchor = DisplayedRate(pctHr: 8.16, chargePercent: 59.2, anchorAwake: 500,
                                   source: .discharge, windowSpan: 1800)
        // Eight hours of wall clock, two seconds of it awake.
        let afterSleep = anchor.timeRemaining_hr(now: 502)
        XCTAssertEqual((anchor.timeRemaining_hr(now: 500)! - afterSleep!) * 3600,
                       2, accuracy: 1e-6,
                       "only awake seconds may be subtracted from the pack")
    }

    /// The anchor still publishes the charge it divided, which is what makes the
    /// displayed time checkable at all.
    ///
    /// The check is no longer a bare division. `MetricUnit.minutes`' comment
    /// defends the property that "charge / rate and the displayed time can be
    /// checked against each other by hand", and the constant-power correction
    /// puts a factor between them — deliberately, because the rate is a rate NOW
    /// and the time projects across a falling voltage. The charge is still
    /// published, so the check survives with the factor in it; what is gone is
    /// being able to do it in your head.
    func testTheAnchorPublishesTheChargeItDivided() {
        let anchor = DisplayedRate(pctHr: 8.16, chargePercent: 59.2, anchorAwake: 0,
                                   source: .discharge, windowSpan: 1800)
        let f = BatteryScale.constantPowerFactor(atSoCPercent: 59.2)
        XCTAssertEqual(anchor.chargePercent! / anchor.pctHr * f,
                       anchor.timeRemaining_hr(now: 0)!, accuracy: 1e-9)
        XCTAssertLessThan(anchor.timeRemaining_hr(now: 0)!,
                          anchor.chargePercent! / anchor.pctHr)
    }
}
