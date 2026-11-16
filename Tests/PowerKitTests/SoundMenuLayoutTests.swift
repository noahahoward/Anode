import XCTest
@testable import PowerKit

/// The Sound menu's model and layout. The numbers are what was measured on macOS's own panel with AirPods open.
final class SoundMenuLayoutTests: XCTestCase {

    private func choice(_ section: String, _ title: String, on: Bool = false) -> AppleChoiceRow {
        AppleChoiceRow(section: section, title: title, isOn: on, enabled: true, device: "Test AirPods Pro")
    }

    private let outputs = [
        OutputDevice(id: "pods", name: "Test AirPods Pro", kind: .airpodsPro),
        OutputDevice(id: "builtin", name: "MacBook Pro Speakers", kind: .speakers),
    ]

    private var apple: AppleSoundPanel {
        var p = AppleSoundPanel()
        p.volume = 0.5
        p.devices = [AppleDeviceRow(name: "MacBook Pro Speakers", isSelected: false),
                     AppleDeviceRow(name: "Test AirPods Pro", isSelected: true, batteryText: "100%, 66%, 77%"),
                     AppleDeviceRow(name: "Living Room Speaker", isSelected: false),
                     AppleDeviceRow(name: "Den TV", isSelected: false)]
        p.expandedDevice = "Test AirPods Pro"
        p.listening = [choice("Listening Mode", "Transparency", on: true), choice("Listening Mode", "Adaptive"),
                       choice("Listening Mode", "Noise Cancellation")]
        p.spatial = [AppleChoiceRow(section: "Spatial Audio", title: "Not Available", isOn: false, enabled: false, device: "Test AirPods Pro")]
        p.conversation = [choice("Conversation Awareness", "Off", on: true), choice("Conversation Awareness", "On")]
        return p
    }

    private let batteries = AccessoryBattery.parse([
        ["Type": "Accessory Source", "Part Identifier": "Left", "Group Identifier": "G", "Current Capacity": 100],
        ["Type": "Accessory Source", "Part Identifier": "Right", "Group Identifier": "G", "Current Capacity": 66],
        ["Type": "Accessory Source", "Part Identifier": "Case", "Group Identifier": "G", "Current Capacity": 77]])

    private func model(apple: AppleSoundPanel?, expanded: String? = nil) -> SoundMenuModel {
        SoundMenuModel.merge(outputs: outputs, defaultID: "pods", volume: 0.5, muted: false, batteries: batteries, apple: apple, expanded: expanded)
    }

    private func y(_ result: SoundMenuLayout.Result, _ kind: SoundMenuLayout.RowKind) -> CGFloat? {
        result.rows.first { $0.kind == kind }?.frame.minY
    }

    func testMergeOrdersRowsLikeApple() {
        XCTAssertEqual(model(apple: apple).devices.map(\.name),
                       ["MacBook Pro Speakers", "Test AirPods Pro", "Living Room Speaker", "Den TV"])
    }

    func testWithoutApplesPanelOnlyCoreAudioOutputsShowBuiltInFirst() {
        let m = model(apple: nil)
        XCTAssertEqual(m.devices.map(\.name), ["MacBook Pro Speakers", "Test AirPods Pro"])
        XCTAssertFalse(m.appleAvailable)
        XCTAssertTrue(m.listening.isEmpty)
    }

    func testAirPlayRowsOnlyFromApple() {
        XCTAssertNil(model(apple: apple).devices[2].id)
        XCTAssertNotNil(model(apple: apple).devices[1].id)
        XCTAssertFalse(model(apple: nil).devices.contains { $0.name == "Den TV" })
    }

    func testSelectionFollowsTheDefaultOutput() {
        XCTAssertEqual(model(apple: apple).devices.map(\.isSelected), [false, true, false, false])
    }

    func testAirPodsGetTheirBatteries() {
        let b = model(apple: apple).devices[1].battery
        XCTAssertEqual(b?.left, 100); XCTAssertEqual(b?.right, 66); XCTAssertEqual(b?.case_, 77)
        XCTAssertNil(model(apple: apple).devices[0].battery)
    }

    func testFooterNamesTheSelectedAirPods() {
        XCTAssertEqual(model(apple: apple).footerTitles, ["Test AirPods Pro Settings…", "Sound Settings…"])
    }

    func testFramesMatchMeasured() {
        let r = SoundMenuLayout.frames(for: model(apple: apple))
        XCTAssertEqual(y(r, .volumeSlider), 37)
        XCTAssertEqual(y(r, .heading("Output")), 73)
        XCTAssertEqual(y(r, .device(0)), 91)
        XCTAssertEqual(y(r, .device(1)), 123)
        XCTAssertEqual(y(r, .heading("Listening Mode")), 175)
        XCTAssertEqual(y(r, .choice(section: "Listening Mode", index: 0)), 192)
        XCTAssertEqual(y(r, .choice(section: "Listening Mode", index: 2)), 240)
        XCTAssertEqual(y(r, .heading("Spatial Audio")), 280)
        XCTAssertEqual(y(r, .choice(section: "Spatial Audio", index: 0)), 297)
        XCTAssertEqual(y(r, .heading("Conversation Awareness")), 337)
        XCTAssertEqual(y(r, .choice(section: "Conversation Awareness", index: 1)), 378)
        XCTAssertEqual(y(r, .device(2)), 414)
        XCTAssertEqual(y(r, .device(3)), 446)
        XCTAssertEqual(y(r, .footer(0)), 490)
        XCTAssertEqual(y(r, .footer(1)), 512)
        XCTAssertEqual(r.height, 537.5, accuracy: 0.01)
    }

    func testANoticeAddsOneLineAboveTheFooterAndNothingElseMoves() {
        let plain = SoundMenuLayout.frames(for: model(apple: apple))
        var m = model(apple: apple); m.notice = "Put both AirPods in to use Adaptive."
        let r = SoundMenuLayout.frames(for: m)
        XCTAssertEqual(y(r, .device(3)), y(plain, .device(3)))
        XCTAssertEqual(y(r, .notice), 478 + SoundMenuMetrics.noticeGap)
        XCTAssertEqual(y(r, .footer(0)), 490 + SoundMenuMetrics.noticeGap + SoundMenuMetrics.noticeHeight)
        XCTAssertEqual(r.height, plain.height + SoundMenuMetrics.noticeGap + SoundMenuMetrics.noticeHeight, accuracy: 0.01)
    }

    func testCollapsedAirPodsHasNoListeningRows() {
        var a = apple; a.expandedDevice = nil
        let m = model(apple: a)
        XCTAssertNil(m.expandedDevice)
        XCTAssertTrue(m.listening.isEmpty)
        let r = SoundMenuLayout.frames(for: m)
        XCTAssertNil(y(r, .heading("Listening Mode")))
        XCTAssertEqual(y(r, .device(2)), 155)
    }
}
