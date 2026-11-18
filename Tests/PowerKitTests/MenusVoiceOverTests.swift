import XCTest
@testable import PowerKit
@testable import AnodeApp

/// What VoiceOver finds in the Sound and Battery menus: macOS's own rows are buttons and checkboxes with a name, sliders with a value.
final class MenusVoiceOverTests: XCTestCase {

    private let frame = NSRect(x: 0, y: 0, width: 280, height: 32)

    /// The rows read NSApp (their appearance). In a process of its own, with no other test run first, it does not exist yet.
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testAModeRowIsACheckboxWithItsNameAndWhetherItIsOn() {
        let on = ModeRow(frame: frame, mode: .init(id: "low", title: "Low Power", isSelected: true))
        XCTAssertTrue(on.isAccessibilityElement())
        XCTAssertEqual(on.accessibilityRole(), .checkBox)
        XCTAssertEqual(on.accessibilityLabel(), "Low Power")
        XCTAssertEqual(on.accessibilityValue() as? Int, 1)
        let off = ModeRow(frame: frame, mode: .init(id: "high", title: "High Power", isSelected: false))
        XCTAssertEqual(off.accessibilityValue() as? Int, 0)
    }

    func testPressingARowWithVoiceOverDoesWhatClickingItDoes() {
        var pressed = 0
        let row = ModeRow(frame: frame, mode: .init(id: "low", title: "Low Power", isSelected: false))
        row.onPick = { pressed += 1 }
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
    }

    func testARowThatCannotBePressedSaysSo() {
        let row = ChoiceRow(frame: frame, choice: AppleChoiceRow(section: "Spatial Audio", title: "Not Available", isOn: false, enabled: false, device: "Pods"))
        row.onPick = { XCTFail("a disabled row is not pressed") }
        XCTAssertFalse(row.accessibilityPerformPress())
    }

    func testAnOutputRowIsACheckboxNamedForTheDevice() {
        let row = DeviceRow(frame: frame, device: .init(id: "a", name: "MacBook Pro Speakers", kind: .speakers, isSelected: true), expanded: false, expandable: false)
        XCTAssertEqual(row.accessibilityLabel(), "MacBook Pro Speakers")
        XCTAssertEqual(row.accessibilityRole(), .checkBox)
        XCTAssertEqual(row.accessibilityValue() as? Int, 1)
    }

    func testAnAppRowReadsItsFigures() {
        let row = EnergyAppRow(frame: frame, name: "Safari", stats: EnergyStats(pctPerHour: 0.9, cpuPercent: 3, memoryBytes: 1, minutesBack: nil))
        let said = row.accessibilityLabel() ?? ""
        XCTAssertTrue(said.hasPrefix("Safari, "), said)
        XCTAssertTrue(said.contains("percent per hour"), said)
        XCTAssertFalse(said.contains("%"), "a percent sign is read out badly: \(said)")
    }

    func testTheFooterAndTextButtonsAreButtons() {
        XCTAssertEqual(FooterRow(frame: frame, title: "Battery Settings…").accessibilityLabel(), "Battery Settings…")
        var done = false
        let b = TextButton(frame: frame, title: "Sound Settings…") { done = true }
        XCTAssertEqual(b.accessibilityRole(), .button)
        XCTAssertTrue(b.accessibilityPerformPress()); XCTAssertTrue(done)
    }

    func testASliderHasANameAValueAndStepsUpAndDown() {
        let s = MenuSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        XCTAssertFalse(s.isAccessibilityElement(), "no name, no element")
        s.spokenLabel = "Volume"
        s.value = 0.5
        var changes: [Double] = []
        s.onChange = { changes.append($0) }
        XCTAssertEqual(s.accessibilityRole(), .slider)
        XCTAssertEqual(s.accessibilityValue() as? String, "50 percent")
        XCTAssertTrue(s.accessibilityPerformIncrement())
        XCTAssertEqual(s.value, 0.55, accuracy: 0.0001)
        XCTAssertTrue(s.accessibilityPerformDecrement()); XCTAssertTrue(s.accessibilityPerformDecrement())
        XCTAssertEqual(s.value, 0.45, accuracy: 0.0001)
        XCTAssertEqual(changes.count, 3)
        s.value = 0.98
        _ = s.accessibilityPerformIncrement()
        XCTAssertEqual(s.value, 1, "it stops at the end")
    }

    func testTheCapsuleButtonsAreButtons_AndADimOneIsNotPressed() {
        var pressed = 0
        let topUp = PillButton(title: "Top Up", running: false, holdable: false)
        topUp.onPress = { pressed += 1 }
        XCTAssertEqual(topUp.accessibilityLabel(), "Top Up")
        XCTAssertTrue(topUp.accessibilityPerformPress()); XCTAssertEqual(pressed, 1)
        topUp.isEnabled = false
        XCTAssertFalse(topUp.accessibilityPerformPress()); XCTAssertEqual(pressed, 1)
        XCTAssertNil(topUp.accessibilityValue())
        XCTAssertEqual(PillButton(title: "Drain", running: true, holdable: true).accessibilityValue() as? String, "On")
    }
}
