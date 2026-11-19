import XCTest
@testable import PowerKit
@testable import AnodeApp

/// macOS's Sound menu shows a slider under Adaptive (how much of the world comes through), and Anode's did not. macOS offers it only as
/// pictures: its level can be read (where the knob is drawn) but not set, by Accessibility or by events sent to Control Center
/// (measured: only a real drag moves it). So Anode's menu shows it where macOS has it, and a click on it opens macOS's own menu, where
/// it is dragged.
final class AdaptiveSliderTests: XCTestCase {

    private typealias M = SoundMenuMetrics
    private let pods = "Test AirPods Pro"

    private func choice(_ section: String, _ title: String, on: Bool = false) -> AppleChoiceRow {
        AppleChoiceRow(section: section, title: title, isOn: on, enabled: true, device: pods)
    }

    private func apple(listeningOn: String, level: Double?) -> AppleSoundPanel {
        var p = AppleSoundPanel()
        p.volume = 0.5
        p.devices = [AppleDeviceRow(name: "MacBook Pro Speakers", isSelected: false), AppleDeviceRow(name: pods, isSelected: true)]
        p.expandedDevice = pods
        p.listening = ["Transparency", "Adaptive", "Noise Cancellation"].map { choice(AppleSoundPanel.listeningHeading, $0, on: $0 == listeningOn) }
        p.conversation = [choice(AppleSoundPanel.conversationHeading, "Off", on: true), choice(AppleSoundPanel.conversationHeading, "On")]
        p.adaptiveLevel = level
        p.adaptiveRow = level == nil ? nil : "Adaptive"
        return p
    }

    private func model(_ p: AppleSoundPanel?, expanded: String? = nil) -> SoundMenuModel {
        SoundMenuModel.merge(outputs: [OutputDevice(id: "pods", name: pods, kind: .airpodsPro),
                                       OutputDevice(id: "builtin", name: "MacBook Pro Speakers", kind: .speakers)],
                             defaultID: "pods", volume: 0.5, muted: false, batteries: [], apple: p, expanded: expanded)
    }

    private func frame(_ r: SoundMenuLayout.Result, _ kind: SoundMenuLayout.RowKind) -> CGRect? { r.rows.first { $0.kind == kind }?.frame }
    private let adaptive = SoundMenuLayout.RowKind.choice(section: AppleSoundPanel.listeningHeading, index: 1)
    private let noise = SoundMenuLayout.RowKind.choice(section: AppleSoundPanel.listeningHeading, index: 2)

    // ── The model ───────────────────────────────────────────────────────────

    func testTheLevelReachesTheMenuWhileTheAirPodsAreOpen() {
        XCTAssertEqual(model(apple(listeningOn: "Adaptive", level: 0.5)).adaptiveLevel, 0.5)
        XCTAssertNil(model(apple(listeningOn: "Adaptive", level: 0.5), expanded: "MacBook Pro Speakers").adaptiveLevel,
                     "not while another device's section is the one open")
    }

    // ── The layout: where macOS has it ──────────────────────────────────────

    func testTheSliderSitsUnderAdaptiveAndPushesTheRowsBelowDown() throws {
        let with = SoundMenuLayout.frames(for: model(apple(listeningOn: "Adaptive", level: 0.5)))
        let without = SoundMenuLayout.frames(for: model(apple(listeningOn: "Adaptive", level: nil)))
        let slider = try XCTUnwrap(frame(with, .adaptiveSlider))
        let a = try XCTUnwrap(frame(with, adaptive))
        // Measured on macOS 27.3: Adaptive at 257.5 (26 tall), the knob centred at 298.5, Noise Cancellation at 313.5.
        XCTAssertEqual(slider.minY, a.minY + 26, accuracy: 0.01)
        XCTAssertEqual(slider.height, 30, accuracy: 0.01)
        XCTAssertEqual(slider.midY, a.minY + 41, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(frame(with, noise)).minY, a.minY + 56, accuracy: 0.01)
        XCTAssertEqual(with.height - without.height, 32, accuracy: 0.01, "the menu grows by what the slider takes")
        XCTAssertNil(frame(without, .adaptiveSlider))
    }

    func testThereIsNoSliderUnderAnotherMode() {
        // A level read while Adaptive was on, and another mode chosen since (the check moves before macOS answers).
        XCTAssertNil(frame(SoundMenuLayout.frames(for: model(apple(listeningOn: "Transparency", level: 0.5))), .adaptiveSlider))
    }

    // (What the controller does with it is in SoundMenuControllerTests, beside its fake driver.)

    // ── The drawing ─────────────────────────────────────────────────────────

    func testTheKnobIsDrawnAtTheLevelBetweenTheEnds() {
        _ = NSApplication.shared
        let row = AdaptiveSliderRow(frame: NSRect(x: 0, y: 0, width: M.rowWidth, height: 30), level: 0)
        let low = row.knobFrame.midX
        row.level = 1
        let high = row.knobFrame.midX
        row.level = 0.5
        XCTAssertEqual(row.knobFrame.midX, (low + high) / 2, accuracy: 0.5)
        // macOS's ends, measured from the row's left edge: icons at 59 and 262, 11 pt each, the knob between their inner edges.
        XCTAssertEqual(low, 70, accuracy: 0.5)
        XCTAssertEqual(high, 262, accuracy: 0.5)
    }

    func testTheTrackIsMacOSsCapsuleWithTheEndIconsInside() {
        // Measured from macOS's own menu (2x capture): a capsule 246 x 24 pt from 43 pt into the row, the end icons centred 21.5 pt in
        // from its ends, the knob as tall as the capsule.
        _ = NSApplication.shared
        let row = AdaptiveSliderRow(frame: NSRect(x: 0, y: 0, width: M.rowWidth, height: 30), level: 0.5)
        XCTAssertEqual(row.trackFrame.minX, 43, accuracy: 0.5)
        XCTAssertEqual(row.trackFrame.width, 246, accuracy: 0.5)
        XCTAssertEqual(row.trackFrame.height, 24, accuracy: 0.5)
        XCTAssertEqual(row.trackFrame.midY, 15, accuracy: 0.5, "in the middle of the row")
        XCTAssertEqual(M.adaptiveSliderLeftIconX + M.adaptiveSliderIconSize / 2 - row.trackFrame.minX, 21.5, accuracy: 0.5)
        XCTAssertEqual(row.trackFrame.maxX - (M.adaptiveSliderRightIconX + M.adaptiveSliderIconSize / 2), 21.5, accuracy: 0.5)
        XCTAssertEqual(row.knobFrame.height, row.trackFrame.height, accuracy: 0.5)
        XCTAssertEqual(row.knobFrame.midY, row.trackFrame.midY, accuracy: 0.5)
    }

    func testAPressOnTheKnobIsAPressOnTheSlider() throws {
        // Seen: the slider "doesn't work". The knob is a picture over the row, and a press on it went to the picture, which kept it:
        // pressing (or dragging) the knob, the thing one reaches for, did nothing.
        _ = NSApplication.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: M.rowWidth, height: 30))
        let row = AdaptiveSliderRow(frame: host.bounds, level: 0.5)
        host.addSubview(row)
        let onKnob = NSPoint(x: row.knobFrame.midX, y: row.knobFrame.midY)
        XCTAssertTrue(host.hitTest(onKnob) === row, "the row takes it")
        let onTrack = NSPoint(x: row.trackFrame.minX + 10, y: row.trackFrame.midY)
        XCTAssertTrue(host.hitTest(onTrack) === row)
    }

    func testTheSliderSaysWhatItIsAndWhatAClickDoes() {
        _ = NSApplication.shared
        let row = AdaptiveSliderRow(frame: NSRect(x: 0, y: 0, width: M.rowWidth, height: 30), level: 0.5)
        XCTAssertEqual(row.accessibilityLabel(), "Adaptive Audio level")
        XCTAssertEqual(row.accessibilityValue() as? String, "50%")
        XCTAssertEqual(row.accessibilityRole(), .button, "it is pressed to open macOS's own menu, not dragged here")
    }
}
