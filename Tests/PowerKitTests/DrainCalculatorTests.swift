import XCTest
@testable import PowerKit

/// THE regression suite. `ri_energy_nj` is cumulative since PROCESS start, not since
/// the last sweep. The shipped bug: a process absent from the prior sweep was diffed
/// against zero, so its entire lifetime energy landed in one 2-second window — a
/// long-lived browser showed up as a multi-hundred-watt phantom at the top of the
/// table the first time coverage picked it up. These tests make that unshippable.
final class DrainCalculatorTests: XCTestCase {

    // (a) First sight of a process must be a SKIP, not a diff-against-zero.
    func testProcessAbsentFromPriorSweepIsSkipped() {
        // Veteran: seen in both sweeps, burned 4 J in the window.
        let veteranA = makeProcess(pid: 1, start: 100, nJ: 100_000_000_000)
        let veteranB = makeProcess(pid: 1, start: 100, nJ: 104_000_000_000)
        // Newcomer: 500 J of LIFETIME energy, first seen in sweep B. Diffing it
        // against zero would report 250 W over this 2 s window.
        let newcomer = makeProcess(pid: 2, start: 500, nJ: 500_000_000_000)

        let a = makeSweep(at: 0, [veteranA])
        let b = makeSweep(at: 2, [veteranB, newcomer])
        let drains = DrainCalculator.between(a, b, scale: makeExactScale())

        XCTAssertEqual(drains.count, 1, "newcomer must be skipped on first sight")
        XCTAssertEqual(drains[0].pid, 1)
        // The phantom-spike assertion: total attributed is the veteran's 4 J, not 504.
        XCTAssertEqual(drains.reduce(0) { $0 + $1.joules }, 4.0)
    }

    // (b) From the second sight onward the newcomer is a normal row.
    func testProcessIsCountedFromSecondSightOnward() {
        let newcomerB = makeProcess(pid: 2, start: 500, nJ: 500_000_000_000)
        let newcomerC = makeProcess(pid: 2, start: 500, nJ: 506_000_000_000)

        let b = makeSweep(at: 2, [newcomerB])
        let c = makeSweep(at: 4, [newcomerC])
        let drains = DrainCalculator.between(b, c, scale: makeExactScale())

        XCTAssertEqual(drains.count, 1)
        XCTAssertEqual(drains[0].pid, 2)
        // Only the 6 J burned inside the window — lifetime history stays invisible.
        XCTAssertEqual(drains[0].joules, 6.0)
    }

    // (c) A counter that went BACKWARDS under the same key must not mint negative
    // joules (which would subtract from the ledger and un-sort the table).
    func testDecreasedCounterProducesNoNegativeJoules() {
        let before = makeProcess(pid: 3, start: 9, nJ: 80_000_000_000)
        let after = makeProcess(pid: 3, start: 9, nJ: 30_000_000_000)

        let drains = DrainCalculator.between(makeSweep(at: 0, [before]),
                                             makeSweep(at: 2, [after]),
                                             scale: makeExactScale())
        XCTAssertTrue(drains.isEmpty, "a rewound counter is unknowable, not negative")
        XCTAssertTrue(drains.allSatisfy { $0.joules >= 0 })
    }

    // (d) Identity is (pid, startAbsTime). A reused pid with a different start time
    // is a DIFFERENT process, so it gets newcomer treatment — skipped, never diffed
    // against the dead process's counter.
    func testReusedPidWithDifferentStartTimeIsADifferentProcess() {
        let original = makeProcess(pid: 500, start: 1_000, nJ: 50_000_000_000)
        let successor = makeProcess(pid: 500, start: 2_000, nJ: 999_000_000_000)

        let drains = DrainCalculator.between(makeSweep(at: 0, [original]),
                                             makeSweep(at: 2, [successor]),
                                             scale: makeExactScale())
        // Diffing successor against original would report 949 J in 2 s (~475 W).
        // Keyed correctly, the successor is a first sight and is skipped.
        XCTAssertTrue(drains.isEmpty)
    }

    // (e) The joules → watts → %/hr chain, bit-exact. All inputs are exactly
    // representable Doubles, so no tolerance is allowed to hide a unit slip.
    func testJoulesToWattsToPercentPerHourIsExact() {
        let before = makeProcess(pid: 7, start: 42, nJ: 10_000_000_000)
        let after = makeProcess(pid: 7, start: 42, nJ: 15_000_000_000)

        // dt = 2 s exactly; delta = 5e9 nJ = 5 J exactly.
        let drains = DrainCalculator.between(makeSweep(at: 0, [before]),
                                             makeSweep(at: 2, [after]),
                                             scale: makeExactScale())
        XCTAssertEqual(drains.count, 1)
        let d = drains[0]
        XCTAssertEqual(d.joules, 5.0)              // 5e9 nJ / 1e9
        XCTAssertEqual(d.watts, 2.5)               // 5 J / 2 s
        // Exact scale: joulesPerPercent == 3600, so %/hr == watts, exactly.
        XCTAssertEqual(d.percentPerHour, 2.5)
    }

    // A process that burned nothing in the window is not a row — the table lists
    // consumers, and zero rows would just bury the residual line.
    func testZeroDeltaProducesNoRow() {
        let p = makeProcess(pid: 9, start: 1, nJ: 77_000_000_000)
        let drains = DrainCalculator.between(makeSweep(at: 0, [p]),
                                             makeSweep(at: 2, [p]),
                                             scale: makeExactScale())
        XCTAssertTrue(drains.isEmpty)
    }

    // A zero or negative interval has no rate; the honest answer is nothing.
    func testNonPositiveIntervalYieldsNothing() {
        let before = makeProcess(pid: 1, start: 1, nJ: 1_000_000_000)
        let after = makeProcess(pid: 1, start: 1, nJ: 9_000_000_000)
        let a = makeSweep(at: 5, [before])
        let sameInstant = makeSweep(at: 5, [after])
        let earlier = makeSweep(at: 3, [after])

        XCTAssertTrue(DrainCalculator.between(a, sameInstant, scale: makeExactScale()).isEmpty)
        XCTAssertTrue(DrainCalculator.between(a, earlier, scale: makeExactScale()).isEmpty)
    }

    func testRowsAreSortedByPercentPerHourDescending() {
        let procs: [(pid_t, UInt64)] = [(1, 2), (2, 9), (3, 5), (4, 1), (5, 7)]
        let before = procs.map { makeProcess(pid: $0.0, start: 1, nJ: 100_000_000_000) }
        let after = procs.map { makeProcess(pid: $0.0, start: 1, nJ: 100_000_000_000 + $0.1 * 1_000_000_000) }

        let drains = DrainCalculator.between(makeSweep(at: 0, before),
                                             makeSweep(at: 2, after),
                                             scale: makeExactScale())
        XCTAssertEqual(drains.count, 5)
        XCTAssertEqual(drains.map(\.pid), [2, 5, 3, 1, 4])
        for i in 1..<drains.count {
            XCTAssertGreaterThanOrEqual(drains[i - 1].percentPerHour, drains[i].percentPerHour)
        }
    }
}
