import XCTest
@testable import AnodeApp
@testable import PowerKit

// Everything this app measures was measured on `Mac17,9` (M5 Pro, 3S pack). A
// second machine — `Mac17,5`, Apple A18 Pro, macOS 26.6, fanless, 1S pack — showed
// what that cost: three defects, all of them the same mistake in different places,
// which is reading ONE model's field names or ONE model's pack topology as if it
// were the hardware.
//
// The numbers in this file are the second machine's, read off it over SSH while it
// ran on battery. They are fixtures, not hypotheses.

// ── The charge basis ────────────────────────────────────────────────────────

/// `Battery.scale()` tried three key names across two dicts; `Battery.state()`
/// read exactly one, with no fallback. On `Mac17,5` that one is absent and the
/// whole drain estimator went down with it.
final class CapacityBasisTests: XCTestCase {

    /// `Mac17,9`, as this app has always read it. The first pair answers, so
    /// nothing about this machine moves.
    func testMac17_9UsesTheFirstPairUnchanged() {
        let props: [String: Any] = [
            "BatteryData": ["RemainingCapacity": 4666, "FullChargeCapacity": 5939,
                            "DesignCapacity": 6249, "NominalChargeCapacity": 6091],
        ]
        let r = Battery.resolveCapacity(props)
        XCTAssertEqual(r?.remaining_mAh, 4666)
        XCTAssertEqual(r?.full_mAh, 5939)
    }

    /// `Mac17,5`: no `RemainingCapacity` anywhere, and the halves of the pair that
    /// DOES answer live in different dicts — `TrueRemainingCapacity` is nested,
    /// `NominalChargeCapacity` is top level.
    func testMac17_5FallsToTheTrueNominalPairAcrossBothDicts() {
        let r = Battery.resolveCapacity(Self.mac17_5)
        XCTAssertEqual(r?.remaining_mAh, 7399)
        XCTAssertEqual(r?.full_mAh, 9340)
        // 79.2%, and the machine's own integer CurrentCapacity read 80.
        XCTAssertEqual(r!.remaining_mAh / r!.full_mAh * 100, 79.2, accuracy: 0.1)
    }

    /// THE POINT OF THE TABLE. Resolving the halves independently would take
    /// `TrueRemainingCapacity` (first remaining available) with `AppleRawMaxCapacity`
    /// (a full that is also available) and print 77.6% — a real-looking number 1.6
    /// points off, from two real fields. Both halves come from one pair or neither.
    func testHalvesAreNeverCrossedBetweenPairs() {
        let r = Battery.resolveCapacity(Self.mac17_5)!
        let crossed = 7399.0 / 9530.0 * 100          // True over AppleRawMax
        let alsoCrossed = 7528.0 / 9340.0 * 100      // AppleRawCurrent over Nominal
        XCTAssertEqual(crossed, 77.6, accuracy: 0.1)
        XCTAssertEqual(alsoCrossed, 80.6, accuracy: 0.1)
        let chosen = r.remaining_mAh / r.full_mAh * 100
        XCTAssertNotEqual(chosen, crossed, accuracy: 0.5)
        XCTAssertNotEqual(chosen, alsoCrossed, accuracy: 0.5)
    }

    /// A pair that answers only its full half is not a basis and must not be used
    /// for one — otherwise the next pair's remaining gets crossed with this one's full.
    func testAPairAnsweringOnlyOneHalfIsSkipped() {
        let props: [String: Any] = [
            "BatteryData": ["FullChargeCapacity": 5939,        // half of pair 1
                            "TrueRemainingCapacity": 7399],    // half of pair 2
            "AppleRawCurrentCapacity": 7528, "AppleRawMaxCapacity": 9530,
        ]
        let r = Battery.resolveCapacity(props)
        XCTAssertEqual(r?.remaining_mAh, 7528, "should fall through to the pair that answers BOTH")
        XCTAssertEqual(r?.full_mAh, 9530)
    }

    func testNoPairAtAllIsNilRatherThanZero() {
        XCTAssertNil(Battery.resolveCapacity(["BatteryData": ["DesignCapacity": 9516]]))
    }

    static let mac17_5: [String: Any] = [
        "BatteryData": ["TrueRemainingCapacity": 7399, "DesignCapacity": 9516,
                        "MaxCapacity": 100, "StateOfCharge": 79],
        "NominalChargeCapacity": 9340,
        "AppleRawCurrentCapacity": 7528,
        "AppleRawMaxCapacity": 9530,
        "Voltage": 4186,
        "CurrentCapacity": 80,
    ]
}

// ── The pack topology ───────────────────────────────────────────────────────

/// `seedNominalVoltage_V` = 11.58 was applied to every machine. It is a 3S
/// constant, and it is wrong by a whole factor on a pack that is not 3S.
final class NominalVoltageTests: XCTestCase {

    /// THE SAFETY PROPERTY. `Mac17,9` reads 12111 mV, resolves to 3 cells, and
    /// lands on exactly the old constant — so every measurement in this repo,
    /// all of which were taken on that machine, still holds to the last digit.
    func testThreeCellPackIsExactlyTheOldSeed() {
        XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: 12111),
                       BatteryScale.seedNominalVoltage_V, accuracy: 1e-12)
    }

    /// `Mac17,5` reads 4186 mV — one cell. MEASURED consequence of getting this
    /// wrong: 9340 mAh x 11.58 V = 108.2 Wh for a 36.0 Wh pack, so every %/hr off
    /// the power tier came out 3.01x too small.
    func testOneCellPackIsOneThirdOfIt() {
        let v = BatteryScale.nominalVoltage(measured_mV: 4186)
        XCTAssertEqual(v, BatteryScale.seedNominalVoltage_V / 3, accuracy: 1e-12)

        let wrong = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                 isCalibrated: false)
        let right = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: v, isCalibrated: false)
        XCTAssertEqual(wrong.energyFull_Wh, 108.2, accuracy: 0.2)
        XCTAssertEqual(right.energyFull_Wh, 36.0, accuracy: 0.2)
        XCTAssertEqual(wrong.energyFull_Wh / right.energyFull_Wh, 3.01, accuracy: 0.02)
    }

    /// The measured draw, through both scales, against what macOS said the same
    /// minute (10:11 at 78.9%).
    func testTheNeoDrainFigureLandsOnTheGaugeRatherThanThreeTimesUnderIt() {
        let W = 2.821, soc = 78.9
        func pctHr(_ s: BatteryScale) -> Double { 3600 * W / s.joulesPerPercent }
        let right = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: BatteryScale.nominalVoltage(measured_mV: 4186),
                                 isCalibrated: false)
        let wrong = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                 nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                 isCalibrated: false)
        XCTAssertEqual(pctHr(right), 7.83, accuracy: 0.15)
        XCTAssertEqual(soc / pctHr(right), 10.1, accuracy: 0.4, "macOS said 10:11")
        XCTAssertEqual(soc / pctHr(wrong), 30.3, accuracy: 1.0, "what it used to claim")
    }

    /// Unreadable, absent or implausible: keep the seed. Scaling by a wrong
    /// integer is worse than the constant this replaces.
    func testImplausibleReadingsFallBackToTheSeed() {
        for mV in [nil, Optional(0.0), Optional(-1.0), Optional(60_000.0),
                   Optional(Double.nan), Optional(Double.infinity)] {
            XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: mV),
                           BatteryScale.seedNominalVoltage_V, "mV = \(String(describing: mV))")
        }
    }

    /// A charged 3S pack reads well above nominal and must not round to 4 cells.
    func testTerminalVoltageSwingDoesNotChangeTheCellCount() {
        for mV in [11_400.0, 12_111.0, 12_600.0, 11_000.0] {
            XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: mV),
                           BatteryScale.seedNominalVoltage_V, accuracy: 1e-12, "mV = \(mV)")
        }
        for mV in [3_700.0, 4_186.0, 4_400.0] {
            XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: mV),
                           BatteryScale.seedNominalVoltage_V / 3, accuracy: 1e-12, "mV = \(mV)")
        }
    }
}

// ── The fan question ────────────────────────────────────────────────────────

/// Hiding the Fans tab is a claim about the hardware, so `.fanless` is reached
/// only on evidence. The old rule could never reach it on a machine that
/// publishes no `FNum`, because "no fan key decoded" could not be told apart from
/// "the decoder cannot read this type" — which is the Intel `fpe2` case.
final class FanPresenceOnFanlessHardwareTests: XCTestCase {

    /// `Mac17,5`: SMC opens, publishes 2334 keys, and not one begins with `F`.
    /// A connection answering for thousands of keys while holding no fan key is
    /// evidence of absence, and the tab goes away.
    func testAnsweringSMCWithNoFanKeyIsFanless() {
        let s = FanPresence.decide(smcReachable: true, reportedCount: nil,
                                   respondingFans: 0, smcAnswering: true)
        XCTAssertEqual(s, .fanless)
        XCTAssertFalse(FanPresence.showsFanTab(s))
    }

    /// The distinction that keeps this honest: an SMC that opened but is not
    /// answering has measured nothing, and nothing is not zero.
    func testOpenButSilentSMCIsStillUnknownAndKeepsTheTab() {
        let s = FanPresence.decide(smcReachable: true, reportedCount: nil,
                                   respondingFans: 0, smcAnswering: false)
        XCTAssertEqual(s, .unknown)
        XCTAssertTrue(FanPresence.showsFanTab(s))
    }

    /// The Intel case, and why `detect` now counts keys that EXIST rather than
    /// keys that decode: `F<n>Ac` is `fpe2` there, so the old count was 0 on a
    /// machine with two fans. Counted by existence it is 2, and this branch is
    /// never reached.
    func testAnExistingFanKeyOutranksAMissingCountEvenWhenAnswering() {
        let s = FanPresence.decide(smcReachable: true, reportedCount: nil,
                                   respondingFans: 2, smcAnswering: true)
        XCTAssertEqual(s, .fans(2))
        XCTAssertTrue(FanPresence.showsFanTab(s))
    }

    /// An unreachable SMC has measured nothing, whatever else is passed.
    func testUnreachableSMCIsNeverFanless() {
        XCTAssertEqual(FanPresence.decide(smcReachable: false, reportedCount: nil,
                                          respondingFans: 0, smcAnswering: true), .unknown)
    }

    /// The rail on a fanless machine drops the tab and keeps every other lens,
    /// in order.
    func testFanlessRailOffersEveryOtherLens() {
        let rail = SidebarView.Lens.order(whenFans: .fanless)
        XCTAssertFalse(rail.contains(.fans))
        XCTAssertEqual(rail.count, SidebarView.Lens.allCases.count - 1)
        XCTAssertEqual(rail, SidebarView.Lens.order(whenFans: .unknown)
                          .filter { $0 != SidebarView.Lens.fans })
    }
}
