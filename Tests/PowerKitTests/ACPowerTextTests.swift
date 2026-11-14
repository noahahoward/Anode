import XCTest
@testable import PowerKit

final class ACPowerTextTests: XCTestCase {
    private func state(onAC: Bool = true, amps: Int, input: Double?) -> Battery.State {
        var s = Battery.State(percent: 50, isCharging: true, onAC: onAC, cycleCount: 1,
                              voltage_mV: 11000, amperage_mA: amps,
                              remainingCapacity_mAh: 3000, timeRemaining_min: nil)
        s.adapterInput_mW = input
        return s
    }

    func testUsedIsSuppliedMinusPackPower() {
        // Discharging 500 mA at 11 V = 5.5 W out of the pack: used = 18.8 + 5.5.
        XCTAssertEqual(state(amps: -500, input: 18800).acPowerText, "24/19W")
        // Charging 600 mA = 6.6 W into the pack: used = 20 - 6.6.
        XCTAssertEqual(state(amps: 600, input: 20000).acPowerText, "13/20W")
        XCTAssertEqual(state(amps: 1500, input: 20000).acPowerText, "3.5/20W")
    }

    func testDrainingNeverShowsUsedBelowSupplied() {
        // The reported contradiction: draining 4.9 %/hr beside 12/19W.
        XCTAssertEqual(state(amps: -280, input: 19000).acPowerText, "22/19W")
    }

    func testUnmeasuredInputShowsDashes() {
        XCTAssertEqual(state(amps: 300, input: 0).acPowerText, "--/--W")
    }

    func testNilOffACOrWithoutInput() {
        XCTAssertNil(state(onAC: false, amps: 0, input: 5000).acPowerText)
        XCTAssertNil(state(amps: 0, input: nil).acPowerText)
    }

    /// "12/0.5W" under the caption "Power" named neither number, and was read as the battery being charged while it
    /// was being drained to its limit. The caption says which is which, in the order and shape of the pair.
    func testThePairIsCaptionedWithWhichNumberIsWhich() {
        // A drain to the limit: the Mac runs on the pack (8.4 W out of it) and the charger idles at half a watt.
        let draining = MetricValue.onAC(state(amps: -764, input: 490), value: 0)
        XCTAssertEqual(draining.text, "8.9/0.5W")
        XCTAssertEqual(draining.label, "Used/Charger")
        XCTAssertEqual(MetricValue.usedAndSuppliedLabel.split(separator: "/").count,
                       draining.text.split(separator: "/").count, "one word over each number")
        XCTAssertTrue(draining.isOnACReading)
        XCTAssertFalse(draining.isEstimate)
        XCTAssertEqual(draining.value, 0)
    }

    /// With the charger's power not read there is no pair to caption: "AC", under "Power", as before.
    func testWithoutThePairItIsACUnderPower() {
        for unread in [state(amps: 0, input: nil), nil] {
            let v = MetricValue.onAC(unread, value: .nan)
            XCTAssertEqual(v.text, "AC")
            XCTAssertEqual(v.label, "Power")
            XCTAssertTrue(v.isOnACReading)
            XCTAssertTrue(v.value.isNaN)
        }
    }

    /// A rate is not one of these, whatever its caption.
    func testARateIsNotAnOnACReading() {
        XCTAssertFalse(MetricValue(value: 12, text: "+12 %/hr", isEstimate: false, label: "Charge").isOnACReading)
        XCTAssertFalse(MetricValue(value: 12, text: "12 %/hr", isEstimate: false).isOnACReading)
    }
}
