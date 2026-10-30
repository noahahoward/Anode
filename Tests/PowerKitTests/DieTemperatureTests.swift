import XCTest
@testable import PowerKit

final class DieTemperatureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testASteadyMachineReadsItsOwnMeanAndPeak() {
        var f = DieTemperatureFilter()
        let r = f.update([("Tp01", 50), ("Tp02", 60), ("Tp03", 70)], now: t0)!
        XCTAssertEqual(r.mean, 60, accuracy: 0.001); XCTAssertEqual(r.peak, 70, accuracy: 0.001)
        for s in 1...30 {
            let x = f.update([("Tp01", 50), ("Tp02", 60), ("Tp03", 70)], now: at(Double(s)))!
            XCTAssertEqual(x.mean, 60, accuracy: 0.001, "no steadying needed, none applied")
        }
    }

    /// The reported swing: two of four sensors flicker in and out (a power-gated core), so the raw
    /// mean alternates between ~76 and ~62.
    func testSensorsThatFlickerInAndOutDoNotMoveTheFigure() {
        var f = DieTemperatureFilter()
        var raw: [Double] = [], steady: [Double] = []
        for s in 0..<40 {
            let hot: [(String, Double)] = [("Tp01", 80), ("Tp02", 78)]
            let cool: [(String, Double)] = [("Tp03", 48), ("Tp04", 46)]
            let sweep = s % 2 == 0 ? hot + cool : hot                      // the cool ones drop out every other sweep
            let present = sweep.map(\.1)
            raw.append(present.reduce(0, +) / Double(present.count))
            steady.append(f.update(sweep, now: at(Double(s) * 2))!.mean)
        }
        XCTAssertGreaterThan(raw.max()! - raw.min()!, 12, "the raw mean swings")
        let tail = Array(steady.suffix(20))
        XCTAssertLessThan(tail.max()! - tail.min()!, 0.5, "the steadied figure does not")
    }

    func testASensorThatReadsAsADeadSlotKeepsItsLastGoodValueBriefly() {
        var f = DieTemperatureFilter()
        _ = f.update([("Tp01", 60), ("Tp02", 60)], now: t0)
        let r = f.update([("Tp01", 60), ("Tp02", 3)], now: at(2))!      // Tp02 reads 3 °C: a dead slot
        XCTAssertEqual(r.mean, 60, accuracy: 0.001, "still counted at its last good value")
        let gone = f.update([("Tp01", 60)], now: at(DieTemperatureFilter.holdSeconds + 5))!
        XCTAssertEqual(gone.mean, 60, accuracy: 0.001, "dropped after the hold, mean of what is left")
    }

    func testOneSpikeBarelyMovesIt() {
        var f = DieTemperatureFilter()
        for s in 0..<10 { _ = f.update([("Tp01", 55), ("Tp02", 55)], now: at(Double(s) * 2)) }
        let spike = f.update([("Tp01", 118), ("Tp02", 55)], now: at(20))!
        XCTAssertLessThan(spike.peak, 80, "smoothed: the peak moved well under the spike's 118")
    }

    func testImpossibleReadingsAreIgnored() {
        var f = DieTemperatureFilter()
        let r = f.update([("Tp01", 50), ("Tp02", 3_000), ("Tp03", -300)], now: t0)!
        XCTAssertEqual(r.mean, 50, accuracy: 0.001)
        var g = DieTemperatureFilter()
        XCTAssertNil(g.update([("Tp01", 2), ("Tp02", 9_999)], now: t0), "nothing that is a die: no figure")
    }

    func testAGapRestartsTheAverageAtTheNewReading() {
        var f = DieTemperatureFilter()
        _ = f.update([("Tp01", 40)], now: t0)
        let later = f.update([("Tp01", 70)], now: at(600))!               // the window was closed for ten minutes
        XCTAssertEqual(later.mean, 70, accuracy: 0.001)
    }

    // ── The alarm ──

    func testAFirstReadingOverNinetyDoesNotSoundTheAlarm() {
        var a = TemperatureAlarm()
        XCTAssertFalse(a.update(96, now: t0), "the app has just opened")
        XCTAssertFalse(a.update(96, now: at(5)))
    }

    func testTheAlarmNeedsTheHeatToStayAndClearsWithAMargin() {
        var a = TemperatureAlarm()
        _ = a.update(95, now: t0)
        XCTAssertTrue(a.update(95, now: at(TemperatureAlarm.sustain + 1)))
        XCTAssertTrue(a.update(88, now: at(TemperatureAlarm.sustain + 2)), "still on: not yet below the margin")
        XCTAssertFalse(a.update(84, now: at(TemperatureAlarm.sustain + 3)))
    }

    func testADipResetsTheWaitAndNoReadingTurnsItOff() {
        var a = TemperatureAlarm()
        _ = a.update(95, now: t0)
        _ = a.update(70, now: at(6))                                       // cooled before the wait was up
        XCTAssertFalse(a.update(95, now: at(TemperatureAlarm.sustain + 1)), "the wait starts over")
        XCTAssertTrue(a.update(95, now: at(2 * TemperatureAlarm.sustain + 2)))
        XCTAssertFalse(a.update(nil, now: at(2 * TemperatureAlarm.sustain + 3)))
    }
}
