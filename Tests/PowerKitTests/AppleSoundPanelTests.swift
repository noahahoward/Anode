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

    func testUnknownTreeYieldsNoAppleRows() {
        let other = node("AXWindow", children: [node("AXGroup", children: [node("AXCheckBox", id: "something-else", desc: "X", value: "1")])])
        let p = AppleSoundPanel.parse(other)
        XCTAssertNil(p.volume)
        XCTAssertTrue(p.devices.isEmpty && p.listening.isEmpty && p.spatial.isEmpty && p.conversation.isEmpty)
    }
}
