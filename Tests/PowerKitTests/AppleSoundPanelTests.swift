import XCTest
@testable import PowerKit

/// Apple's Sound panel, read through Accessibility, turned into rows. The fixture is the tree measured on a Mac with
/// AirPods connected and expanded, with neutral names.
final class AppleSoundPanelTests: XCTestCase {

    private func node(_ role: String, id: String = "", desc: String = "", value: String = "", sub: String = "",
                      enabled: Bool = true, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, subrole: sub, identifier: id, description: desc, value: value, enabled: enabled,
               frame: .zero, children: children)
    }

    private func device(_ name: String, desc: String? = nil, on: Bool) -> AXNode {
        node("AXCheckBox", id: "sound-device-\(name)", desc: desc ?? name, value: on ? "1" : "0", sub: "AXToggle")
    }

    private func choice(_ device: String, _ title: String, on: Bool, enabled: Bool = true) -> AXNode {
        node("AXCheckBox", id: "sound-device-\(device)", desc: title, value: on ? "1" : "0", sub: "AXToggle", enabled: enabled)
    }

    private func heading(_ title: String, device: String? = nil) -> AXNode {
        node("AXHeading", id: device.map { "sound-device-\($0)" } ?? "", desc: title)
    }

    /// Speakers, expanded AirPods (Transparency on, spatial unavailable, conversation off), then two AirPlay receivers.
    private var tree: AXNode {
        let pods = "Test AirPods Pro"
        return node("AXWindow", children: [node("AXGroup", children: [
            node("AXButton", desc: "Volume Lower"),
            node("AXSlider", id: "controlcenter-volume-slider", desc: "sound volume", value: "0.5"),
            node("AXButton", desc: "Volume Higher"),
            node("AXScrollArea", children: [
                heading("Output"),
                device("MacBook Pro Speakers", on: false),
                node("AXDisclosureTriangle", id: "sound-device-\(pods)", desc: "Go Down", value: "1"),
                device(pods, desc: "\(pods), 100%, 66%, 77%", on: true),
                heading("Listening Mode", device: pods),
                choice(pods, "Transparency", on: true), choice(pods, "Adaptive", on: false),
                choice(pods, "Noise Cancellation", on: false),
                heading("Spatial Audio", device: pods),
                choice(pods, "Not Available", on: false, enabled: false),
                heading("Conversation Awareness", device: pods),
                choice(pods, "Off", on: true), choice(pods, "On", on: false),
                device("Living Room Speaker", on: false),
                device("Den TV", on: false),
            ]),
            node("AXButton", desc: "\(pods) Settings…"),
            node("AXButton", desc: "Sound Settings…"),
        ])])
    }

    func testParsesVolume() {
        XCTAssertEqual(AppleSoundPanel.parse(tree).volume, 0.5)
    }

    func testParsesDevicesInOrderWithSelection() {
        let p = AppleSoundPanel.parse(tree)
        XCTAssertEqual(p.devices.map(\.name), ["MacBook Pro Speakers", "Test AirPods Pro", "Living Room Speaker", "Den TV"])
        XCTAssertEqual(p.devices.map(\.isSelected), [false, true, false, false])
    }

    func testDeviceBatteryTextIsWhatFollowsTheName() {
        let p = AppleSoundPanel.parse(tree)
        XCTAssertEqual(p.devices[1].batteryText, "100%, 66%, 77%")
        XCTAssertNil(p.devices[0].batteryText)
    }

    func testListeningRowsBelongToTheirSection() {
        let p = AppleSoundPanel.parse(tree)
        XCTAssertEqual(p.listening.map(\.title), ["Transparency", "Adaptive", "Noise Cancellation"])
        XCTAssertEqual(p.listening.map(\.isOn), [true, false, false])
        XCTAssertEqual(Set(p.listening.map(\.device)), ["Test AirPods Pro"])
        XCTAssertEqual(p.conversation.map(\.title), ["Off", "On"])
        XCTAssertEqual(p.conversation.map(\.isOn), [true, false])
    }

    func testDisabledSpatialRow() {
        let p = AppleSoundPanel.parse(tree)
        XCTAssertEqual(p.spatial.map(\.title), ["Not Available"])
        XCTAssertEqual(p.spatial.map(\.enabled), [false])
    }

    func testAirPlayRowsAfterTheOpenedSectionAreStillDevices() {
        let p = AppleSoundPanel.parse(tree)
        XCTAssertFalse(p.conversation.contains { $0.title == "Den TV" })
        XCTAssertTrue(p.devices.contains { $0.name == "Den TV" })
    }

    func testExpandedDeviceFromTheDisclosureTriangle() {
        XCTAssertEqual(AppleSoundPanel.parse(tree).expandedDevice, "Test AirPods Pro")
    }

    func testSettingsButtons() {
        XCTAssertEqual(AppleSoundPanel.parse(tree).settingsButtons, ["Test AirPods Pro Settings…", "Sound Settings…"])
    }

    /// A row whose label is not what its id says (an AirPlay speaker with extra words in its label) must not become a
    /// pressable choice of the open section just because it follows that section's rows.
    func testAnOddDeviceRowAfterTheSectionsIsNotAChoice() {
        var t = tree
        let odd = device("Odd Speaker", desc: "Odd Speaker (AirPlay)", on: false)
        t.children[0].children[3].children.insert(odd, at: 12)     // right after the Conversation Awareness rows
        let p = AppleSoundPanel.parse(t)
        XCTAssertEqual(p.conversation.map(\.title), ["Off", "On"])
        XCTAssertFalse(p.listening.contains { $0.device == "Odd Speaker" })
    }

    func testChoicesOfADeviceThatIsNotExpandedAreIgnored() {
        var t = tree
        let stray = choice("Living Room Speaker", "Adaptive", on: false)
        t.children[0].children[3].children.insert(stray, at: 6)    // among the listening rows
        let p = AppleSoundPanel.parse(t)
        XCTAssertEqual(p.listening.map(\.device), ["Test AirPods Pro", "Test AirPods Pro", "Test AirPods Pro"])
    }

    func testUnknownTreeYieldsNoAppleRows() {
        let other = node("AXWindow", children: [node("AXGroup", children: [node("AXCheckBox", id: "something-else", desc: "X", value: "1")])])
        let p = AppleSoundPanel.parse(other)
        XCTAssertNil(p.volume)
        XCTAssertTrue(p.devices.isEmpty && p.listening.isEmpty && p.spatial.isEmpty && p.conversation.isEmpty)
    }

    // ── The Adaptive Audio slider ───────────────────────────────────────────
    // Measured on macOS 27.3 with Adaptive on: between the Adaptive and Noise Cancellation rows macOS draws three pictures, and offers
    // nothing else (no slider, no value, no action): an end icon each side ("Dotted Circle" left, "Circle" right, 11 pt) and the knob
    // ("Person And Sparkles, Filled", 40 x 24) between them. Where the knob is drawn is the level. The names may be translated, so the
    // pictures are told apart by where they are, not by what they are called.

    private func image(_ device: String, _ desc: String, _ frame: CGRect) -> AXNode {
        AXNode(role: "AXImage", identifier: "sound-device-\(device)", description: desc, frame: frame)
    }

    private func adaptiveTree(knobX: CGFloat?, extraImage: Bool = false, imagesOf owner: String = "Test AirPods Pro") -> AXNode {
        let pods = "Test AirPods Pro"
        var rows: [AXNode] = [
            node("AXDisclosureTriangle", id: "sound-device-\(pods)", desc: "Go Down", value: "1"),
            device(pods, desc: "\(pods), 100%", on: true),
            heading("Listening Mode", device: pods),
            choice(pods, "Transparency", on: knobX == nil), choice(pods, "Adaptive", on: knobX != nil),
        ]
        if let knobX {
            rows += [image(owner, "Dotted Circle", CGRect(x: 1328, y: 293, width: 11, height: 11)),
                     image(owner, "Person And Sparkles, Filled", CGRect(x: knobX - 20, y: 286.5, width: 40, height: 24)),
                     image(owner, "Circle", CGRect(x: 1531, y: 293, width: 11, height: 11))]
            if extraImage { rows.append(image(owner, "Something Else", CGRect(x: 1400, y: 293, width: 11, height: 11))) }
        }
        rows += [choice(pods, "Noise Cancellation", on: false), heading("Conversation Awareness", device: pods), choice(pods, "Off", on: true)]
        return node("AXWindow", children: [node("AXScrollArea", children: rows)])
    }

    func testTheAdaptiveLevelIsWhereTheKnobIsDrawn() throws {
        // As measured: the knob's middle at 1435, between the end icons' inner edges (1339 and 1531): half way.
        XCTAssertEqual(try XCTUnwrap(AppleSoundPanel.parse(adaptiveTree(knobX: 1435)).adaptiveLevel), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(AppleSoundPanel.parse(adaptiveTree(knobX: 1339)).adaptiveLevel), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(AppleSoundPanel.parse(adaptiveTree(knobX: 1531)).adaptiveLevel), 1, accuracy: 0.001)
    }

    func testALevelOutsideTheEndsIsHeldToThem() throws {
        XCTAssertEqual(try XCTUnwrap(AppleSoundPanel.parse(adaptiveTree(knobX: 1300)).adaptiveLevel), 0, accuracy: 0.001)
    }

    func testWithoutAdaptiveThereIsNoLevel() {
        XCTAssertNil(AppleSoundPanel.parse(adaptiveTree(knobX: nil)).adaptiveLevel)
    }

    func testPicturesThatAreNotTheThreeOfTheSliderGiveNoLevel() {
        // Nothing here guesses: a fourth picture, or pictures of another device, and there is no slider.
        XCTAssertNil(AppleSoundPanel.parse(adaptiveTree(knobX: 1435, extraImage: true)).adaptiveLevel)
        XCTAssertNil(AppleSoundPanel.parse(adaptiveTree(knobX: 1435, imagesOf: "Other Pods")).adaptiveLevel)
    }

    func testTheRestOfThePanelIsReadAsBeforeWithTheSliderThere() {
        let p = AppleSoundPanel.parse(adaptiveTree(knobX: 1435))
        XCTAssertEqual(p.listening.map(\.title), ["Transparency", "Adaptive", "Noise Cancellation"])
        XCTAssertEqual(p.listening.map(\.isOn), [false, true, false])
        XCTAssertEqual(p.adaptiveRow, "Adaptive", "the row the slider is drawn under, by place")
    }
}
