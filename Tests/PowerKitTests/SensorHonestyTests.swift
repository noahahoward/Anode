import XCTest
@testable import PowerKit

/// The three things the naming work handed to whoever owns the UI.
///
/// `SensorNaming` decides WHICH sensors we can vouch for; this file is about what
/// happens to the 140 we cannot. Their label is a bucket ordinal — "Thermal
/// sensor 37" — assigned by key sort order and meaning nothing physical, and on
/// screen it is indistinguishable from "GPU sensor 37", which is a real claim
/// backed by measurement. The raw SMC key is those sensors' only identity, so it
/// has to travel with them.
final class SensorHonestyTests: XCTestCase {

    private func reading(_ key: String, _ name: String, _ value: Double = 40,
                         _ confidence: SensorNaming.Confidence) -> SensorReading {
        SensorReading(key: key, name: name, kind: .temperature, value: value,
                      unit: "°C", confidence: confidence)
    }

    // ── (a) the key travels with the placeholder ────────────────────────────

    func testAHedgedTemperatureCarriesItsKey() {
        let r = reading("TVDc", "Thermal sensor 37", 63, .unidentified)
        XCTAssertEqual(r.qualifiedName, "Thermal sensor 37 (TVDc)")
        XCTAssertFalse(r.isIdentified)
    }

    /// A name we can defend does not need the key repeated after it. `TB0T` is
    /// "Battery sensor 1" on the strength of a cross-check against IOKit's own
    /// figure, and "Battery sensor 1 (TB0T)" is just noise.
    func testAnIdentifiedSensorDoesNotRepeatItsKey() {
        let r = reading("TB0T", "Battery sensor 1", 27, .identified)
        XCTAssertEqual(r.qualifiedName, "Battery sensor 1")
        XCTAssertTrue(r.isIdentified)
    }

    /// Non-temperature keys already have the key AS their name — see
    /// `SensorNaming.label`, which leaves an unidentified rail as `PZC0` rather
    /// than as "Power sensor 41". Qualifying it would produce "PZC0 (PZC0)".
    func testARawKeyNameIsNotDoubledUp() {
        let r = SensorReading(key: "PZC0", name: "PZC0", kind: .power, value: 3,
                              unit: "W", confidence: .unidentified)
        XCTAssertEqual(r.qualifiedName, "PZC0")
    }

    /// Every reading a real sweep produces must be printable without the caller
    /// having to remember the rule.
    func testEveryUnidentifiedTemperatureInARealSweepShowsItsKey() throws {
        let inv = Sensors.inventory()
        try XCTSkipIf(inv.temperatures.isEmpty, "no SMC on this machine")
        for r in inv.temperatures where !r.isIdentified {
            XCTAssertTrue(r.qualifiedName.contains(r.key),
                          "\(r.name) is a placeholder and must show \(r.key)")
        }
    }

    // ── (b) natural sort ────────────────────────────────────────────────────

    func testSensorTenSortsAfterSensorTwo() {
        XCTAssertTrue(NaturalOrder.precedes("Thermal sensor 2", "Thermal sensor 10"))
        XCTAssertFalse(NaturalOrder.precedes("Thermal sensor 10", "Thermal sensor 2"))
        XCTAssertTrue(NaturalOrder.precedes("GPU sensor 9", "GPU sensor 42"))
    }

    func testAWholeFamilySortsInReadingOrder() {
        let names = (1...12).map { "Thermal sensor \($0)" }
        XCTAssertEqual(names.shuffled().sorted(by: NaturalOrder.precedes), names)
        // The bug being fixed: plain lexicographic order does NOT produce this.
        XCTAssertNotEqual(names.sorted(), names)
    }

    func testDifferentFamiliesStillSortByTheirText() {
        XCTAssertTrue(NaturalOrder.precedes("Battery sensor 3", "CPU core sensor 1"))
        XCTAssertTrue(NaturalOrder.precedes("CPU core sensor 1", "Thermal sensor 1"))
    }

    /// Leading zeros are a spelling, not a value: "sensor 007" and "sensor 7" are
    /// the same number and must not straddle "sensor 8".
    func testLeadingZerosDoNotChangeANumbersPlace() {
        XCTAssertTrue(NaturalOrder.precedes("sensor 007", "sensor 8"))
        XCTAssertTrue(NaturalOrder.precedes("sensor 6", "sensor 007"))
    }

    /// A comparator that reports two different strings as equal lets `sorted(by:)`
    /// order them differently between runs, which would make the list flicker on
    /// every two-second tick.
    func testTheOrderIsTotalSoTheListCannotFlicker() {
        XCTAssertEqual(NaturalOrder.compare("Tp0A", "Tp0A"), .orderedSame)
        XCTAssertNotEqual(NaturalOrder.compare("Tp0A", "Tp0a"), .orderedSame)
        XCTAssertNotEqual(NaturalOrder.compare("Tp0a", "Tp0A"), .orderedSame)
        XCTAssertEqual(NaturalOrder.compare("sensor 2", "sensor 2x"), .orderedAscending)
        XCTAssertEqual(NaturalOrder.compare("", ""), .orderedSame)
        XCTAssertEqual(NaturalOrder.compare("", "a"), .orderedAscending)
    }

    func testReadingsSortNaturallyAndTiesBreakOnTheKey() {
        let rs = [reading("TVDc", "Thermal sensor 10", 50, .unidentified),
                  reading("TCMb", "Thermal sensor 2", 60, .unidentified),
                  reading("TS0P", "Ts0P", 33, .unidentified),
                  reading("Ts0P", "Ts0P", 27, .unidentified)]
        let sorted = rs.sortedByName()
        XCTAssertEqual(sorted.map(\.name),
                       ["Thermal sensor 2", "Thermal sensor 10", "Ts0P", "Ts0P"])
        // Two raw-key names that differ only in case share a display name, so the
        // key has to decide — otherwise the pair has no defined order.
        XCTAssertEqual(sorted.suffix(2).map(\.key), ["TS0P", "Ts0P"])
    }

    // ── (c) "hottest" must not present a placeholder as a fact ──────────────

    /// The case this exists for, and it is not hypothetical: the hottest sensor on
    /// this machine is `TVDc`/`TCMb`, and both are `.unidentified`.
    func testTheHottestSensorIsPrintableWithoutClaimingToKnowWhatItIs() throws {
        let inv = Sensors.Inventory(
            keysTotal: 3, keysDecoded: 3,
            readings: [reading("TB0T", "Battery sensor 1", 27, .identified),
                       reading("Tp00", "CPU core sensor 1", 45, .identified),
                       reading("TVDc", "Thermal sensor 37", 63, .unidentified)],
            fans: [], rejected: [])

        let hottest = try XCTUnwrap(inv.hottest)
        XCTAssertEqual(hottest.key, "TVDc")
        XCTAssertFalse(hottest.isIdentified)
        XCTAssertEqual(hottest.qualifiedName, "Thermal sensor 37 (TVDc)")
    }

    /// "The peak on this machine" and "the hottest thing we can attribute" are
    /// different questions with different answers here, and collapsing them would
    /// hide the peak whenever it lands on an unnamed sensor — which on this
    /// machine is always.
    func testTheHottestNAMEDSensorIsASeparateQuestionFromTheHottestOne() {
        let inv = Sensors.Inventory(
            keysTotal: 3, keysDecoded: 3,
            readings: [reading("TB0T", "Battery sensor 1", 27, .identified),
                       reading("Tp00", "CPU core sensor 1", 45, .identified),
                       reading("TVDc", "Thermal sensor 37", 63, .unidentified)],
            fans: [], rejected: [])

        XCTAssertEqual(inv.hottest?.key, "TVDc")
        XCTAssertEqual(inv.hottestIdentified?.key, "Tp00")
        XCTAssertEqual(inv.identified.count, 2)
        XCTAssertEqual(inv.unidentified.map(\.key), ["TVDc"])
    }

    func testThereIsNoHottestIdentifiedSensorWhenNothingIsIdentified() {
        let inv = Sensors.Inventory(
            keysTotal: 1, keysDecoded: 1,
            readings: [reading("TVDc", "Thermal sensor 1", 63, .unidentified)],
            fans: [], rejected: [])
        XCTAssertNotNil(inv.hottest)
        // nil, not the placeholder — "we cannot name the hottest thing we can
        // name" is the truth, and it renders as "—".
        XCTAssertNil(inv.hottestIdentified)
    }

    /// The partitions have to cover the readings exactly, or a pane that draws
    /// them as two groups silently loses sensors.
    func testTheTwoGroupsPartitionEveryReading() throws {
        let inv = Sensors.inventory()
        try XCTSkipIf(inv.readings.isEmpty, "no SMC on this machine")
        XCTAssertEqual(inv.identified.count + inv.unidentified.count, inv.readings.count)
        XCTAssertTrue(inv.identified.allSatisfy(\.isIdentified))
        XCTAssertTrue(inv.unidentified.allSatisfy { !$0.isIdentified })
    }
}
