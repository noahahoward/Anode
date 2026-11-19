import XCTest
@testable import PowerKit

/// The "Now" widget showed a dash whenever the Mac was not draining: at Anode's charge limit, at 100 %, and while
/// charging, all day on the charger, beside a Drain widget that shows the Used/Charger pair there. It now says what the
/// battery is doing: Charging, Holding, Full, or On AC when nothing more is known.
final class NowWidgetStatusTests: XCTestCase {

    private func state(percent: Int, charging: Bool = false, amps: Int = 0, notCharging: Int = 0, full: Bool = false) -> Battery.State {
        var s = Battery.State(percent: percent, isCharging: charging, onAC: true, cycleCount: 1, voltage_mV: 12000,
                              amperage_mA: amps, remainingCapacity_mAh: 3000, timeRemaining_min: nil)
        s.notChargingReason = notCharging
        s.fullyCharged = full
        return s
    }

    private func reading(_ direction: PowerMonitor.Snapshot.Direction, _ state: Battery.State?, held: Bool = false,
                         draining: Double? = nil) -> MetricValue? {
        MetricValue.chargerReading(direction: direction, state: state, isHeldAtChargeLimit: held, dischargingRate_pctHr: draining)
    }

    func testWhileTheBatteryFillsItSaysCharging() {
        let v = reading(.charging, state(percent: 50, charging: true, amps: 2000))
        XCTAssertEqual(v?.text, "Charging")
        XCTAssertFalse(v?.isEstimate ?? true)
    }

    /// Held at the limit Anode (or macOS) keeps: plugged in, not charging, and the gauge says why. This was the dash.
    func testHeldAtALimitItSaysHolding() {
        XCTAssertEqual(reading(.acIdle, state(percent: 80, notCharging: 4), held: true)?.text, "Holding")
        // A hold Anode's own limit makes may not have been learned as the Mac's: the gauge's reason is enough.
        XCTAssertEqual(reading(.acIdle, state(percent: 64, notCharging: 4))?.text, "Holding")
    }

    func testAtTheTopItSaysFull() {
        XCTAssertEqual(reading(.acIdle, state(percent: 100, full: true))?.text, "Full")
        XCTAssertEqual(reading(.acIdle, state(percent: 99))?.text, "Full")
        // At a limit of 100 the gauge may still give a reason; the battery is full, and that is the word for it.
        XCTAssertEqual(reading(.acIdle, state(percent: 100, notCharging: 4), held: true)?.text, "Full")
    }

    func testPluggedInWithNothingElseKnownItSaysOnAC() {
        XCTAssertEqual(reading(.acIdle, state(percent: 60))?.text, "On AC")
        XCTAssertEqual(reading(.acIdle, nil)?.text, "On AC")
    }

    /// Losing charge on the charger (a drain to the limit, an adapter too small for the load) is a rate, as Drain shows it.
    func testLosingChargeOnTheChargerItIsTheRate() {
        let v = reading(.acIdle, state(percent: 85, amps: -500), draining: -4.9)
        XCTAssertEqual(v?.value ?? 0, 4.9, accuracy: 1e-9)
        XCTAssertEqual(v?.text, MetricUnit.percentPerHour.format(4.9))
    }

    func testOnBatteryThereIsNoStatusAndTheRateIsTheRegistrys() {
        XCTAssertNil(reading(.draining, state(percent: 70)))
    }

    /// A status is a word and no number: it plots as a flat line and never as a gap or a rate.
    func testAStatusIsAWordWithAValueOfZero() {
        let v = MetricValue.status("Holding")
        XCTAssertEqual(v.value, 0)
        XCTAssertEqual(v.text, "Holding")
        XCTAssertFalse(v.isOnACReading)
    }
}
