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
}
