import XCTest
@testable import PowerKit

/// Is a charger on the cable, told from `AdapterDetails` and not from
/// `ExternalConnected`.
///
/// MEASURED on `Mac17,9`, macOS 27.0, in the Plan 0 snapshots taken before the
/// first cut, before a discharge and during one:
///
///     state                         ExternalConnected  AdapterDetails
///     cable out                     No                 {"FamilyCode"=0}
///     on the charger                Yes                {"Watts"=100,"AdapterVoltage"=20000,
///                                                       "FamilyCode"=18446744073172697098,…}
///     CHIE = 08, cable in (48 s in) No                 the same as on the charger
///
/// `ExternalConnected` cannot tell a pulled cable from Anode's own cut, which
/// is why a discharge could not see the cable pulled. `AdapterDetails` can.
/// (The cut does not always read No: measured later, with a macOS charge limit
/// below the battery level in force, `ExternalConnected` stayed Yes through
/// 50 s of `CHIE` = 08. See `Battery.adapterPresent(fromProperties:)`.)
final class BatteryAdapterPresenceTests: XCTestCase {

    /// The `FamilyCode` this Mac publishes. Above `Int.max`, so `as? Int` on it
    /// is nil: a reader that took it that way would find no charger on the very
    /// machine this was measured on.
    private static let chargerFamilyCode = NSNumber(value: UInt64(18446744073172697098))

    // ── What AdapterDetails says ────────────────────────────────────────────

    func testCableOutIsNotPresent() {
        XCTAssertFalse(Battery.adapterPresent(fromProperties: ["AdapterDetails": ["FamilyCode": 0]]))
    }

    func testChargerDetailsMeanPresent() {
        let props: [String: Any] = ["AdapterDetails": ["Watts": 100, "AdapterVoltage": 20000,
                                                       "FamilyCode": Self.chargerFamilyCode]]
        XCTAssertTrue(Battery.adapterPresent(fromProperties: props))
    }

    /// Either field is enough. A charger that publishes one and not the other
    /// is still on the cable.
    func testFamilyCodeAloneMeansPresent() {
        let props: [String: Any] = ["AdapterDetails": ["FamilyCode": Self.chargerFamilyCode]]
        XCTAssertTrue(Battery.adapterPresent(fromProperties: props))
    }

    func testWattsAloneMeansPresent() {
        XCTAssertTrue(Battery.adapterPresent(fromProperties: ["AdapterDetails": ["Watts": 30]]))
    }

    /// The same code as a signed 64-bit number, which is how a registry that
    /// stores it as `SInt64` hands it over. Nonzero either way.
    func testFamilyCodeAsASignedNumberMeansPresent() {
        let signed = NSNumber(value: Int64(bitPattern: 18446744073172697098))
        XCTAssertLessThan(signed.int64Value, 0)
        XCTAssertTrue(Battery.adapterPresent(fromProperties: ["AdapterDetails": ["FamilyCode": signed]]))
    }

    func testMissingOrMalformedDetailsAreNotPresent() {
        XCTAssertFalse(Battery.adapterPresent(fromProperties: [:]))
        XCTAssertFalse(Battery.adapterPresent(fromProperties: ["ExternalConnected": true]))
        XCTAssertFalse(Battery.adapterPresent(fromProperties: ["AdapterDetails": "present"]))
        XCTAssertFalse(Battery.adapterPresent(fromProperties: ["AdapterDetails": [String: Any]()]))
        XCTAssertFalse(Battery.adapterPresent(fromProperties: ["AdapterDetails": [100, 20000]]))
        XCTAssertFalse(Battery.adapterPresent(fromProperties: ["AdapterDetails": NSNull()]))
    }

    /// A field that is there but is not a number says nothing, and neither does
    /// a number that says "none". A registry boolean bridges to a number, and
    /// `true` would read as 1 W.
    func testFieldsThatAreNotAChargerAreNotPresent() {
        let notChargers: [[String: Any]] = [
            ["Watts": 0, "FamilyCode": 0],
            ["Watts": -1],
            ["Watts": "100"],
            ["FamilyCode": "18446744073172697098"],
            ["Watts": true],
            ["FamilyCode": true],
            ["Watts": NSNull(), "FamilyCode": NSNull()],
            ["Watts": Double.nan],
            ["AdapterVoltage": 20000, "Current": 3000],
        ]
        for details in notChargers {
            XCTAssertFalse(Battery.adapterPresent(fromProperties: ["AdapterDetails": details]),
                           "\(details)")
        }
    }

    // ── What the helper makes of it ─────────────────────────────────────────

    /// The cut itself: the flag says No and the cable is in.
    func testPresenceTrueWhileCutWithCableIn() {
        XCTAssertEqual(ChargeAC.presence(externalConnected: false, adapterPresent: true), true)
    }

    /// The cable pulled, with or without a cut: nothing says a charger is there.
    func testPresenceFalseWhenCablePulled() {
        XCTAssertEqual(ChargeAC.presence(externalConnected: false, adapterPresent: false), false)
    }

    func testPresenceTrueOnTheChargerWhenEitherSaysSo() {
        XCTAssertEqual(ChargeAC.presence(externalConnected: true, adapterPresent: true), true)
        // A Mac whose AdapterDetails is empty on the charger is still on it.
        XCTAssertEqual(ChargeAC.presence(externalConnected: true, adapterPresent: false), true)
    }

    func testPresenceUnknownOnlyWhenNothingReads() {
        XCTAssertNil(ChargeAC.presence(externalConnected: nil, adapterPresent: nil))
        XCTAssertEqual(ChargeAC.presence(externalConnected: nil, adapterPresent: true), true)
        XCTAssertEqual(ChargeAC.presence(externalConnected: true, adapterPresent: nil), true)
    }

    /// One reading that says no, and none that say yes: the cable is out. That
    /// ends a discharge, the direction that cannot hurt. It does not arise on
    /// the hardware, where both come from the one `Battery.state()`.
    func testOneReadingThatSaysNoAndNoneThatSaysYesIsOut() {
        XCTAssertEqual(ChargeAC.presence(externalConnected: false, adapterPresent: nil), false)
        XCTAssertEqual(ChargeAC.presence(externalConnected: nil, adapterPresent: false), false)
    }

    // ── The state carries it ────────────────────────────────────────────────

    /// A construction written before the field existed describes a battery
    /// with no charger details, like the other defaulted fields.
    func testStateWithoutAnOpinionHasNoAdapter() {
        let s = Battery.State(percent: 52, isCharging: false, onAC: false, cycleCount: 82,
                              voltage_mV: 11610, amperage_mA: -1334,
                              remainingCapacity_mAh: 3075, timeRemaining_min: 187)
        XCTAssertFalse(s.adapterPresent)
    }

    /// LIVE. Only this proves `Battery.state()` fills the field from the
    /// registry. A Mac on the charger has `AdapterDetails` describing it; a
    /// Mac on its battery is not asserted either way, since a cable pulled a
    /// moment ago may not have cleared it.
    func testStateCarriesTheAdapterThisMachineIsOn() throws {
        guard let state = Battery.state() else { throw XCTSkip("no battery on this machine") }
        try XCTSkipUnless(state.onAC, "on battery: nothing to read")
        XCTAssertTrue(state.adapterPresent,
                      "on the charger, but AdapterDetails read as no charger")
    }
}
