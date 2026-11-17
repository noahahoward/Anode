import XCTest
@testable import PowerKit

/// The Battery menu's model and layout. The numbers are what was measured on macOS's own panel (macOS 27, 14" MacBook Pro, dark):
/// panel 308 wide and 277.5 tall with Visual Studio Code using significant energy; rows 280 wide set in 14.
final class BatteryMenuLayoutTests: XCTestCase {

    private func model(apps: [String] = ["Visual Studio Code"], source: String = "Battery", selected: String = "high") -> BatteryMenuModel {
        BatteryMenuModel(powerSource: source,
                         modes: [.init(id: "automatic", title: "Automatic", isSelected: selected == "automatic"),
                                 .init(id: "low", title: "Low Power", isSelected: selected == "low"),
                                 .init(id: "high", title: "High Power", isSelected: selected == "high")],
                         energyApps: apps.map { BatteryMenuModel.EnergyApp(name: $0) })
    }

    private func y(_ r: BatteryMenuLayout.Result, _ kind: BatteryMenuLayout.RowKind) -> CGFloat? { r.rows.first { $0.kind == kind }?.frame.minY }

    func testFramesMatchMeasured() {
        let r = BatteryMenuLayout.frames(for: model())
        XCTAssertEqual(y(r, .title), 12)
        XCTAssertEqual(y(r, .powerSource), 37.5)
        XCTAssertEqual(r.rows.filter { $0.kind == .divider }.map(\.frame.minY), [59.5, 188.5, 243.5])
        XCTAssertEqual(y(r, .heading("Energy Mode")), 68.5)
        XCTAssertEqual([0, 1, 2].map { y(r, .mode($0)) }, [87, 119, 151])
        XCTAssertEqual(y(r, .heading("Using Significant Energy")), 197.5)
        XCTAssertEqual(y(r, .app(0)), 216)
        XCTAssertEqual(y(r, .footer), 249)
        XCTAssertEqual(r.height, 277.5, accuracy: 0.01)
    }

    func testEverythingSitsInFourteenFromTheSidesAndRowsAre280Wide() {
        let r = BatteryMenuLayout.frames(for: model())
        for row in r.rows { XCTAssertEqual(row.frame.minX, 14, "\(row.kind)"); XCTAssertEqual(row.frame.width, 280, "\(row.kind)") }
        XCTAssertEqual(BatteryMenuMetrics.width, 308)
    }

    func testRowHeights() {
        let r = BatteryMenuLayout.frames(for: model())
        XCTAssertEqual(r.rows.first { $0.kind == .mode(0) }?.frame.height, 32)
        XCTAssertEqual(r.rows.first { $0.kind == .app(0) }?.frame.height, 22)
        XCTAssertEqual(r.rows.first { $0.kind == .footer }?.frame.height, 22)
        XCTAssertEqual(r.rows.first { $0.kind == .heading("Energy Mode") }?.frame.height, 15)
    }

    // Not measured on macOS's panel (nothing else was using significant energy): the section and its line go, and the footer moves up.
    func testWithNoAppUsingSignificantEnergyTheSectionIsLeftOut() {
        let r = BatteryMenuLayout.frames(for: model(apps: []))
        XCTAssertNil(y(r, .heading("Using Significant Energy")))
        XCTAssertEqual(r.rows.filter { $0.kind == .divider }.map(\.frame.minY), [59.5, 188.5])
        XCTAssertEqual(y(r, .footer), 194)
        XCTAssertEqual(r.height, 222.5, accuracy: 0.01)
    }

    // Measured with two apps listed (macOS 27): the footer's text and the line above it are 22 pt lower than with one; each further
    // app takes another row of the same height.
    func testEachFurtherAppAddsARow() {
        let one = BatteryMenuLayout.frames(for: model(apps: ["A"]))
        let three = BatteryMenuLayout.frames(for: model(apps: ["A", "B", "C"]))
        XCTAssertEqual(y(three, .app(2)), 216 + 2 * BatteryMenuMetrics.appRowPitch)
        XCTAssertEqual(three.height - one.height, 2 * BatteryMenuMetrics.appRowPitch, accuracy: 0.01)
        let two = BatteryMenuLayout.frames(for: model(apps: ["A", "B"]))
        XCTAssertEqual((y(two, .footer) ?? 0) - (y(one, .footer) ?? 0), 22, "the measured step from one app to two")
    }

    func testTheModelFindsTheSelectedMode() {
        XCTAssertEqual(model(selected: "low").selectedModeID, "low")
        XCTAssertNil(BatteryMenuModel(powerSource: "Battery", modes: [], energyApps: []).selectedModeID)
    }
}
