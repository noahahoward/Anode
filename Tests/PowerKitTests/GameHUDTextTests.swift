import XCTest
@testable import PowerKit

/// What the Game Mode strip says: seven readings in a fixed order, a dash for any that is missing, and the battery drain
/// signed the way the owner reads it.
final class GameHUDTextTests: XCTestCase {

    private func value(_ text: String, label: String? = nil) -> MetricValue {
        MetricValue(value: 0, text: text, isEstimate: false, label: label)
    }

    private func line(_ readings: [MetricID: MetricValue]) -> String {
        GameHUDText.line { readings[$0] }
    }

    func testReadingsAreTheSevenInTheAgreedOrder() {
        XCTAssertEqual(GameHUDText.metrics,
                       [.cpuTemperature, .cpuUsage, .gpuTemperature, .gpuUsage, .memoryUsage, .batteryPercent, .batteryDrain])
        XCTAssertFalse(GameHUDText.metrics.contains(.batteryTimeLeft))
    }

    func testFullLine() {
        let text = line([.cpuTemperature: value("62°"), .cpuUsage: value("41%"),
                         .gpuTemperature: value("58°"), .gpuUsage: value("77%"),
                         .memoryUsage: value("63%"), .batteryPercent: value("84%"),
                         .batteryDrain: value("31 %/hr")])
        XCTAssertEqual(text, "CPU 62° 41%   GPU 58° 77%   RAM 63%   BAT 84% \u{2212}31 %/hr")
    }

    func testMissingReadingsShowDash() {
        XCTAssertEqual(line([.memoryUsage: value("63%")]), "CPU \u{2014} \u{2014}   GPU \u{2014} \u{2014}   RAM 63%   BAT \u{2014} \u{2014}")
    }

    func testChargingKeepsItsPlus() {
        let text = line([.batteryPercent: value("84%"), .batteryDrain: value("+12 %/hr", label: "Charge")])
        XCTAssertTrue(text.hasSuffix("BAT 84% +12 %/hr"), text)
    }

    func testOnACShowsTheMachinesOwnText() {
        let text = line([.batteryPercent: value("84%"), .batteryDrain: value("AC", label: "Power")])
        XCTAssertTrue(text.hasSuffix("BAT 84% AC"), text)
    }

    /// The used/supplied watts are the machine's own text too: no minus is put before them.
    func testTheWattsOnTheChargerAreShownAsTheyAre() {
        let text = line([.batteryPercent: value("84%"),
                         .batteryDrain: value("12/0.5W", label: MetricValue.usedAndSuppliedLabel)])
        XCTAssertTrue(text.hasSuffix("BAT 84% 12/0.5W"), text)
    }

    func testDrainWithoutBatteryPercentStillShows() {
        let text = line([.batteryDrain: value("31 %/hr")])
        XCTAssertTrue(text.hasSuffix("BAT \u{2014} \u{2212}31 %/hr"), text)
    }
}
