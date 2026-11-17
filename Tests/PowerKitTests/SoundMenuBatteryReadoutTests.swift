import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The battery line under an AirPods output: macOS draws a reading for each bud that reports, also when both say the same (measured with
/// both at 100%), and one for the pair only when it lists one reading for the buds.
final class SoundMenuBatteryReadoutTests: XCTestCase {

    private func readings(_ battery: SoundMenuModel.Battery, kind: OutputKind = .airpodsPro) -> [String] {
        let device = SoundMenuModel.Device(id: "a", name: "AirPods", kind: kind, isSelected: true, battery: battery)
        let row = DeviceRow(frame: NSRect(x: 0, y: 0, width: 280, height: 40), device: device, expanded: false, expandable: false)
        return row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.filter { $0.hasSuffix("%") }
    }

    func testBothBudsAndTheCaseAreThreeReadings_EvenWhenTheBudsAgree() {
        XCTAssertEqual(readings(.init(left: 100, right: 100, case_: 81)), ["100%", "100%", "81%"])
        XCTAssertEqual(readings(.init(left: 97, right: 100, case_: 81)), ["97%", "100%", "81%"])
    }

    func testOneListedReadingForTheBudsIsDrawnAsTheirPair() {
        XCTAssertEqual(readings(.init(left: 90, right: nil, case_: 40)), ["90%", "40%"])
    }

    func testAirPodsMaxHasOneReading() {
        XCTAssertEqual(readings(.init(left: 55, right: nil, case_: nil), kind: .airpodsMax), ["55%"])
    }

    func testABudThatDoesNotReportIsLeftOut() {
        XCTAssertEqual(readings(.init(left: nil, right: 100, case_: 81)), ["100%", "81%"])
    }
}
