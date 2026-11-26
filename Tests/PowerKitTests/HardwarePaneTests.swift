import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Hardware tab's pane, built but NEVER put in a window: no window server is asked to show it.
final class HardwarePaneTests: XCTestCase {

    override func setUp() { _ = NSApplication.shared }

    private func make() -> HardwarePane {
        HardwarePane(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
    }

    private func fans() -> HardwareReadings {
        HardwareReadings(
            fans: [FanReading(index: 0, rpm: 3200, minRPM: 2000, maxRPM: 6000, targetRPM: nil, isManual: false),
                   FanReading(index: 1, rpm: 3100, minRPM: 2000, maxRPM: 6000, targetRPM: nil, isManual: false)],
            cpuTemp: .real(52),
            gpuTemp: .real(49))
    }

    private func push(_ pane: HardwarePane, family: MacFamily = .generic,
                      readings: HardwareReadings? = HardwareReadings(), history: HardwareHistory = HardwareHistory(),
                      charge: [Double?] = [1, 2], widgets: [MenuBarWidgetText] = []) {
        pane.update(layout: HardwareLayout.layout(for: family), readings: readings, history: history,
                    chargeHistory: charge, menuBarWidgets: widgets)
    }

    // MARK: Hosting the stage

    func testTheStageIsPinnedToTheBoundsWithConstraints() {
        let pane = make()
        XCTAssertTrue(pane.stage.superview === pane)
        XCTAssertFalse(pane.stage.translatesAutoresizingMaskIntoConstraints)
        let pins = pane.constraints.filter { ($0.firstItem as AnyObject?) === pane.stage }
        XCTAssertEqual(pins.count, 4)
        for pin in pins {
            XCTAssertTrue((pin.secondItem as AnyObject?) === pane)
            XCTAssertEqual(pin.relation, .equal)
            XCTAssertEqual(pin.constant, 0)
            XCTAssertEqual(pin.firstAttribute, pin.secondAttribute)
        }
        XCTAssertEqual(Set(pins.map { $0.firstAttribute.rawValue }),
                       Set([NSLayoutConstraint.Attribute.leading, .trailing, .top, .bottom].map { $0.rawValue }))
    }

    func testTheStageFollowsThePaneWhenItIsPinnedInAContainer() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let pane = HardwarePane(frame: .zero)
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.topAnchor.constraint(equalTo: container.topAnchor),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.frame.size, NSSize(width: 800, height: 600))
        XCTAssertEqual(pane.stage.frame, pane.bounds)
    }

    func testItIsAHostTheControllerCanDrive() {
        let host: HardwareViewHosting = make()
        XCTAssertNil(host.onFanSlider)
        XCTAssertNil(host.onInstallHelper)
        XCTAssertFalse(host.isDrawingNow)
    }

    // MARK: Drawable

    func testAPaneWithNoWindowIsNotDrawable() {
        let pane = make()
        XCTAssertNil(pane.window)
        XCTAssertFalse(pane.isDrawable(), "a pane that is in no window cannot be seen")
        XCTAssertFalse(pane.isDrawingNow)
        XCTAssertFalse(pane.stage.isDrawableNow())
    }

    func testIsDrawingNowFollowsTheInjectedRuleAndReachesTheStage() {
        let pane = make()
        pane.isDrawable = { true }
        XCTAssertTrue(pane.isDrawingNow)
        XCTAssertTrue(pane.stage.isDrawableNow())
        XCTAssertTrue(pane.stage.canvas.isDrawableNow())
        pane.isDrawable = { false }
        XCTAssertFalse(pane.isDrawingNow)
        XCTAssertFalse(pane.stage.isDrawableNow())
        XCTAssertFalse(pane.stage.canvas.isDrawableNow())
    }

    func testACoveredPaneNeitherDrawsNorTurnsItsFansOnUpdate() {
        _ = NSApplication.shared
        let pane = make()
        let canvas = pane.stage.canvas
        defer { pane.reset() }

        // Whether a drawable canvas then marks itself for display is the canvas's own test; the pane's part is to say whether
        // anyone can see it, and nothing may turn while nobody can.
        pane.isDrawable = { false }
        push(pane, family: .generic, readings: fans(), charge: [5, nil, 7])
        XCTAssertFalse(canvas.isDrawableNow(), "covered: nothing is drawn")
        XCTAssertFalse(canvas.isAnimatingFans, "covered: nothing turns")

        pane.isDrawable = { true }
        push(pane, family: .generic, readings: fans(), charge: [5, nil, 8])
        XCTAssertTrue(canvas.isDrawableNow(), "visible: the new reading is painted")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(canvas.isAnimatingFans, "visible with spinning fans: the blades turn")
        }

        pane.isDrawable = { false }
        push(pane, family: .generic, readings: fans(), charge: [5, nil, 9])
        XCTAssertFalse(canvas.isAnimatingFans, "covered again: they stop")
    }

    // MARK: Data

    func testUpdateStoresTheNewestDataWhetherOrNotItCanBeDrawn() {
        let pane = make()
        pane.isDrawable = { false }
        let history = HardwareHistory()
        let widgets = [MenuBarWidgetText(label: "CPU", value: "41")]
        push(pane, family: .macBookPro14ProMax, readings: HardwareReadings(helperInstalled: true),
             history: history, charge: [5, nil, 7], widgets: widgets)
        XCTAssertEqual(pane.hardwareLayout.family, .macBookPro14ProMax)
        XCTAssertEqual(pane.readings?.helperInstalled, true)
        XCTAssertTrue(pane.history === history)
        XCTAssertEqual(pane.chargeHistory.count, 3)
        XCTAssertEqual(pane.menuBarWidgets, widgets)
        XCTAssertEqual(pane.stage.canvas.hardwareLayout.family, .macBookPro14ProMax)
    }

    func testTheSlidersAndTheInstallPromptAreForwardedToTheStage() {
        let pane = make()
        var slid: [(Int, Double?)] = []
        var installs = 0
        pane.onFanSlider = { slid.append(($0, $1)) }
        pane.onInstallHelper = { installs += 1 }
        pane.stage.onFanSlider?(1, 4000)
        pane.stage.onFanSlider?(1, nil)
        pane.stage.onInstallHelper?()
        XCTAssertEqual(slid.count, 2)
        XCTAssertEqual(slid[0].0, 1)
        XCTAssertEqual(slid[0].1, 4000)
        XCTAssertNil(slid[1].1)
        XCTAssertEqual(installs, 1)
        XCTAssertNotNil(pane.onFanSlider)
        XCTAssertNotNil(pane.onInstallHelper)
        pane.onFanSlider = nil
        pane.onInstallHelper = nil
        XCTAssertNil(pane.stage.onFanSlider)
        XCTAssertNil(pane.stage.onInstallHelper)
    }

    // MARK: Reset

    func testResetUnpinsTheCardAndDropsWhatWasKept() throws {
        let pane = make()
        let layout = HardwareLayout.layout(for: .macBookPro14ProMax)
        pane.update(layout: layout, readings: fans(), history: HardwareHistory(), chargeHistory: [1, 2],
                    menuBarWidgets: [MenuBarWidgetText(label: "CPU", value: "41")])
        pane.layoutSubtreeIfNeeded()
        let fan = try XCTUnwrap(pane.stage.canvas.hardwareLayout.components.first { $0.kind == .fan(index: 0) })
        pane.stage.canvas.onClick?(fan, nil, NSPoint(x: 300, y: 300))
        XCTAssertEqual(pane.stage.pinnedID, fan.id)
        XCTAssertEqual(pane.stage.canvas.pinnedID, fan.id)

        pane.reset()
        XCTAssertNil(pane.stage.pinnedID)
        XCTAssertNil(pane.stage.canvas.pinnedID)
        XCTAssertTrue(pane.stage.pinnedCard.isHidden)
        XCTAssertTrue(pane.stage.tooltipCard.isHidden)
        XCTAssertNil(pane.readings)
        XCTAssertNil(pane.history)
        XCTAssertTrue(pane.chargeHistory.isEmpty)
        XCTAssertTrue(pane.menuBarWidgets.isEmpty)
        XCTAssertFalse(pane.stage.canvas.isAnimatingFans, "nothing is turning after the tab is left")
    }

    func testResetOfAFreshPaneChangesNothing() {
        let pane = make()
        pane.reset()
        pane.reset()
        XCTAssertNil(pane.stage.pinnedID)
        XCTAssertNil(pane.readings)
    }
}
