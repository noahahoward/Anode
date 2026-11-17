import XCTest
@testable import PowerKit

/// Which apps the Battery menu lists under "Using Significant Energy". macOS lists an app once it has used about 0.3 to 0.55 W for a
/// minute or two (measured 2026-11-17 with a test app: listed at a steady 0.55 W or more, never at 0.25 W or less; the power is
/// what counts, not the CPU time). On this battery that is about 0.4 to 0.73 %/hr; Anode's minimum is 0.5 %/hr.
final class SignificantEnergyTests: XCTestCase {

    private func app(_ name: String, _ pct: Double, isApp: Bool = true) -> SignificantEnergy.Candidate {
        .init(name: name, isApp: isApp, stats: EnergyStats(pctPerHour: pct, cpuPercent: 1, memoryBytes: 0, minutesBack: nil))
    }

    func testTheMinimumIsHalfAPercentAnHour() {
        XCTAssertEqual(SignificantEnergy.minimumPercentPerHour, 0.5)
    }

    func testAnAppAtOrAboveTheMinimumIsListed_OneBelowIsNot() {
        let listed = SignificantEnergy.apps(from: [app("A", 0.5), app("B", 0.49), app("C", 0.9)], alreadyListed: [])
        XCTAssertEqual(listed.map(\.name), ["C", "A"])
    }

    func testTheBiggestDrainComesFirst() {
        let listed = SignificantEnergy.apps(from: [app("Small", 0.6), app("Big", 4.2), app("Middle", 1.1)], alreadyListed: [])
        XCTAssertEqual(listed.map(\.name), ["Big", "Middle", "Small"])
    }

    func testOnlyApplicationsAreListed_NotDaemonsOrToolsWithoutABundle() {
        let listed = SignificantEnergy.apps(from: [app("kernel_task", 9, isApp: false), app("Safari", 1)], alreadyListed: [])
        XCTAssertEqual(listed.map(\.name), ["Safari"])
    }

    func testAnAppAlreadyListedStaysUntilItFallsWellBelowTheMinimum() {
        // Hovering at the minimum must not make rows come and go.
        let still = SignificantEnergy.apps(from: [app("A", 0.4)], alreadyListed: ["A"])
        XCTAssertEqual(still.map(\.name), ["A"])
        let gone = SignificantEnergy.apps(from: [app("A", 0.34)], alreadyListed: ["A"])
        XCTAssertTrue(gone.isEmpty)
        let notYet = SignificantEnergy.apps(from: [app("B", 0.4)], alreadyListed: ["A"])
        XCTAssertTrue(notYet.isEmpty, "an app not listed before needs the full minimum")
    }

    func testTheFiguresComeWithTheRow() {
        let listed = SignificantEnergy.apps(from: [app("A", 0.8)], alreadyListed: [])
        XCTAssertEqual(listed.first?.stats?.pctPerHour, 0.8)
    }

    func testAtMostSixAreListed() {
        let many = (1...9).map { app("App\($0)", Double($0)) }
        XCTAssertEqual(SignificantEnergy.apps(from: many, alreadyListed: []).count, 6)
        XCTAssertEqual(SignificantEnergy.apps(from: many, alreadyListed: []).first?.name, "App9")
    }

    func testNothingAboveTheMinimumListsNothing() {
        XCTAssertTrue(SignificantEnergy.apps(from: [app("A", 0.03)], alreadyListed: []).isEmpty)
        XCTAssertTrue(SignificantEnergy.apps(from: [], alreadyListed: []).isEmpty)
    }
}
