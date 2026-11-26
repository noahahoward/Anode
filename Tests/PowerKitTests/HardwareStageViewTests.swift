import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The Hardware View's composed content: the narrow threshold, the chips, the REAL / EST / EXAMPLE tags, where the cards go,
/// and that the stage paints (wide and narrow, with a card open) without crashing.
final class HardwareStageViewTests: XCTestCase {

    // MARK: - Narrow

    func testNarrowIsStrictlyBelowSixHundredFortyPoints() {
        XCTAssertEqual(HardwareStageView.narrowThreshold, 640)
        XCTAssertTrue(HardwareStageView.isNarrow(width: 639.9))
        XCTAssertFalse(HardwareStageView.isNarrow(width: 640))
        XCTAssertFalse(HardwareStageView.isNarrow(width: 640.1))
        XCTAssertTrue(HardwareStageView.isNarrow(width: 0))
    }

    // MARK: - Chips

    private func labels(_ family: MacFamily) -> [String] {
        HardwareStageView.chipLabels(for: HardwareLayout.layout(for: family)).map { $0.label }
    }

    func testThePhotoLayoutHasOneChipPerPartInLayoutOrder() {
        let layout = HardwareLayout.layout(for: .macBookPro14ProMax)
        let chips = HardwareStageView.chipLabels(for: layout)
        XCTAssertEqual(chips.map { $0.label },
                       ["Display", "Fan 1", "Fan 2", "CPU · GPU", "Memory", "Storage", "Wi-Fi", "Power in", "Battery"])
        for chip in chips {
            let component = layout.components.first { $0.id == chip.id }
            XCTAssertNotNil(component, chip.label)
            XCTAssertNotNil(component?.jump, chip.label)
            XCTAssertEqual(component?.jumpLabel, chip.label)
        }
    }

    func testChipLabelsAreNotRepeated() {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro16ProMax, .macBookPro14Base, .macBookNeo, .macMiniM4, .generic] {
            let names = labels(family)
            XCTAssertEqual(names.count, Set(names).count, "\(family)")
        }
    }

    func testTheNeoHasNoFanChips() {
        let names = labels(.macBookNeo)
        XCTAssertFalse(names.contains { $0.hasPrefix("Fan") })
        XCTAssertEqual(Set(names), ["Display", "CPU · GPU", "Memory", "Wi-Fi", "Storage", "Power in", "Battery"])
    }

    func testTheMiniHasNoBatteryOrDisplayChips() {
        let names = labels(.macMiniM4)
        XCTAssertFalse(names.contains("Battery"))
        XCTAssertFalse(names.contains("Display"))
        XCTAssertTrue(names.contains("Fan"))
        XCTAssertTrue(names.contains("Power"))
    }

    // MARK: - Tags and text

    func testEachProvenanceHasItsTagAndNoProvenanceHasNone() {
        XCTAssertEqual(HardwarePinnedCard.tagText(.real), "REAL")
        XCTAssertEqual(HardwarePinnedCard.tagText(.estimate), "EST")
        XCTAssertEqual(HardwarePinnedCard.tagText(.example), "EXAMPLE")
        XCTAssertNil(HardwarePinnedCard.tagText(nil))
        XCTAssertEqual(HardwareTooltipCard.tagText(.estimate), "EST")
    }

    func testGraphValuesAreWrittenInTheirOwnUnit() {
        XCTAssertEqual(HardwareCardRenderer.valueText(4380, unit: " rpm", isRate: false, fractionDigits: 0), "4,380 rpm")
        XCTAssertEqual(HardwareCardRenderer.valueText(41.24, unit: " °C", isRate: false, fractionDigits: 1), "41.2 °C")
        XCTAssertEqual(HardwareCardRenderer.valueText(38_400_000, unit: "", isRate: true, fractionDigits: 1), "38.4 MB/s")
        XCTAssertEqual(HardwareCardRenderer.valueText(.nan, unit: " %", isRate: false, fractionDigits: 0), "—")
    }

    func testTheNowAndRangeLineSaysEstWhenTheNumbersAreEstimated() {
        XCTAssertEqual(HardwareCardRenderer.statText(now: "2.4 W", low: "2.0 W", high: "2.6 W", provenance: .real),
                       "now 2.4 W · range 2.0 W – 2.6 W")
        XCTAssertEqual(HardwareCardRenderer.statText(now: "2.4 W", low: "2.0 W", high: "2.6 W", provenance: .estimate),
                       "est. now 2.4 W · range 2.0 W – 2.6 W")
    }

    func testTheSparklineCaptionNamesWhereTheValuesCameFrom() {
        let buffer = HardwareDetail(title: "Fan 1", confidenceNote: "", rows: [],
                                    series: HardwareSeriesRef(name: "Speed · since opened", channel: .fanRPM(index: 0),
                                                              values: [], unit: " rpm"))
        XCTAssertEqual(HardwarePinnedCard.sparklineCaption(for: buffer), "SINCE YOU OPENED THIS VIEW")
        let charge = HardwareDetail(title: "Charge, last 24 hours", confidenceNote: "", rows: [])
        XCTAssertEqual(HardwarePinnedCard.sparklineCaption(for: charge), "LAST 24 HOURS")
    }

    // MARK: - Where the cards go

    func testTheTooltipSitsBesideThePointerAndFlipsAtTheEdges() {
        let stage = CGSize(width: 1000, height: 900)
        let size = CGSize(width: 300, height: 120)
        let beside = HardwareStageView.tooltipOrigin(size: size, pointer: NSPoint(x: 100, y: 100), stage: stage)
        XCTAssertEqual(beside.x, 116, accuracy: 0.001)
        XCTAssertEqual(beside.y, 116, accuracy: 0.001)

        let flipped = HardwareStageView.tooltipOrigin(size: size, pointer: NSPoint(x: 950, y: 880), stage: stage)
        XCTAssertEqual(flipped.x, 950 - 300 - 16, accuracy: 0.001)
        XCTAssertEqual(flipped.y, 880 - 120 - 16, accuracy: 0.001)
    }

    func testTheTooltipIsClampedInsideAStageSmallerThanIt() {
        let o = HardwareStageView.tooltipOrigin(size: CGSize(width: 300, height: 120), pointer: NSPoint(x: 5, y: 5),
                                                stage: CGSize(width: 200, height: 100))
        XCTAssertEqual(o.x, 8, accuracy: 0.001)
        XCTAssertEqual(o.y, 8, accuracy: 0.001)
    }

    func testThePinnedCardDocksRightOfAPartInAWideStageAndBelowItInANarrowOne() {
        let part = CGRect(x: 100, y: 200, width: 200, height: 100)
        let size = CGSize(width: 330, height: 260)
        let wide = HardwareStageView.dockOrigin(size: size, around: part, stage: CGSize(width: 1000, height: 900), narrow: false)
        XCTAssertEqual(wide.x, 312, accuracy: 0.001)
        XCTAssertEqual(wide.y, 200, accuracy: 0.001)

        let narrow = HardwareStageView.dockOrigin(size: size, around: part, stage: CGSize(width: 500, height: 800), narrow: true,
                                                  topInset: 48)
        XCTAssertEqual(narrow.x, 100, accuracy: 0.001)
        XCTAssertEqual(narrow.y, 312, accuracy: 0.001)
    }

    func testThePinnedCardMovesToTheOtherSideWhenThereIsNoRoom() {
        let size = CGSize(width: 330, height: 260)
        let atRightEdge = CGRect(x: 800, y: 200, width: 150, height: 100)
        let wide = HardwareStageView.dockOrigin(size: size, around: atRightEdge, stage: CGSize(width: 1000, height: 900), narrow: false)
        XCTAssertEqual(wide.x, 800 - 330 - 12, accuracy: 0.001)

        let atBottom = CGRect(x: 100, y: 700, width: 200, height: 100)
        let narrow = HardwareStageView.dockOrigin(size: size, around: atBottom, stage: CGSize(width: 500, height: 850), narrow: true)
        XCTAssertEqual(narrow.y, 700 - 260 - 12, accuracy: 0.001)
    }

    func testThePinnedCardIsAlwaysInsideTheStage() {
        let stage = CGSize(width: 400, height: 700)
        for x in stride(from: -50.0, through: 450.0, by: 50.0) {
            for y in stride(from: -50.0, through: 750.0, by: 50.0) {
                for narrow in [false, true] {
                    let o = HardwareStageView.dockOrigin(size: CGSize(width: 330, height: 260),
                                                         around: CGRect(x: x, y: y, width: 100, height: 80),
                                                         stage: stage, narrow: narrow)
                    XCTAssertGreaterThanOrEqual(o.x, 8)
                    XCTAssertGreaterThanOrEqual(o.y, 8)
                    XCTAssertLessThanOrEqual(o.x + 330, 400 - 8 + 0.001)
                    XCTAssertLessThanOrEqual(o.y + 260, 700 - 8 + 0.001)
                }
            }
        }
    }

    // MARK: - The stage on screen (offscreen)

    private let gibibyte: UInt64 = 1 << 30

    private func fullReadings() -> HardwareReadings {
        HardwareReadings(
            fans: [FanReading(index: 0, rpm: 3200, minRPM: 2000, maxRPM: 6000, targetRPM: nil, isManual: false),
                   FanReading(index: 1, rpm: 3100, minRPM: 2000, maxRPM: 6000, targetRPM: nil, isManual: false)],
            cpuTemp: .real(52),
            gpuTemp: .real(49),
            memory: MemoryReading(app: 8 * gibibyte, wired: 4 * gibibyte, compressed: 10 * gibibyte, free: 2 * gibibyte,
                                  total: 24 * gibibyte, pressure: 1, swapBytes: .real(1 * gibibyte)),
            network: (down: 38.4e6, up: 2.1e6),
            storage: StorageReading(freeBytes: 129_000_000_000, totalBytes: 994_000_000_000, readBPS: 63_100, writeBPS: 19_700,
                                    smartTempC: 33.9, wearPercent: 1, spare: 100, bytesWritten: nil),
            battery: BatteryReading(percent: 64, tempC: 31, amps: 1.2, isCharging: true, state: .charging,
                                    timeRemainingMin: .estimate(52), health: 92, cycles: 95, designCycles: 1000,
                                    systemDrawW: .real(9)),
            adapter: AdapterReading(ratedW: 68, drawnW: .estimate(4.4), isCharging: true),
            display: DisplayReading(brightness: 0.6, watts: .estimate(2.4)),
            helperInstalled: true)
    }

    private func stage(width: CGFloat, height: CGFloat, family: MacFamily = .macBookPro14ProMax) -> (HardwareStageView, HardwareHistory) {
        let layout = HardwareLayout.layout(for: family)
        let view = HardwareStageView(layout: layout)
        view.setFrameSize(NSSize(width: width, height: height))
        let history = HardwareHistory()
        let readings = fullReadings()
        for _ in 0..<5 { history.append(readings) }
        view.update(layout: layout, readings: readings, history: history,
                    chargeHistory: [60, 61, nil, 63, 64], menuBarWidgets: [MenuBarWidgetText(label: "CPU", value: "52°")])
        return (view, history)
    }

    private func render(_ view: NSView) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    func testAWideStageHidesTheChipsAndPaints() throws {
        let (view, _) = stage(width: 1000, height: 900)
        XCTAssertTrue(view.chipsBar.isHidden)
        XCTAssertFalse(view.canvas.isNarrow)
        XCTAssertNil(view.canvas.focusRect)
        XCTAssertEqual(view.canvas.frame.height, 900, accuracy: 0.001)
        try render(view)
    }

    func testANarrowStageShowsTheChipsAndZoomsToTheFirstOne() throws {
        let (view, _) = stage(width: 400, height: 700)
        XCTAssertFalse(view.chipsBar.isHidden)
        XCTAssertTrue(view.canvas.isNarrow)
        XCTAssertEqual(view.chipsBar.chips.map { $0.label }.first, "Display")
        XCTAssertEqual(view.chipsBar.selectedID, view.chipsBar.chips.first?.id)
        XCTAssertEqual(view.canvas.focusRect, view.canvas.hardwareLayout.components.first { $0.jumpLabel == "Display" }?.jump)
        XCTAssertEqual(view.canvas.frame.minY, HardwareChipsBar.height, accuracy: 0.001)
        try render(view)
    }

    func testTheChipsComeBackAndGoWithTheWidth() {
        let (view, _) = stage(width: 1000, height: 900)
        view.setFrameSize(NSSize(width: 639.9, height: 900))
        XCTAssertFalse(view.chipsBar.isHidden)
        view.setFrameSize(NSSize(width: 640, height: 900))
        XCTAssertTrue(view.chipsBar.isHidden)
        XCTAssertNil(view.canvas.focusRect)
    }

    func testHoverShowsTheTooltipAndLeavingHidesIt() throws {
        let (view, _) = stage(width: 1000, height: 900)
        let fan = try XCTUnwrap(view.canvas.hardwareLayout.components.first { $0.kind == .fan(index: 0) })
        view.canvas.onHover?(fan, NSPoint(x: 300, y: 300))
        XCTAssertFalse(view.tooltipCard.isHidden)
        XCTAssertGreaterThan(view.tooltipCard.frame.height, 0)
        XCTAssertLessThanOrEqual(view.tooltipCard.frame.width, HardwareTooltipCard.maxWidth)
        try render(view)
        view.canvas.onHover?(nil, NSPoint(x: 5, y: 5))
        XCTAssertTrue(view.tooltipCard.isHidden)
    }

    func testClickingAPartPinsItAndEscapeOrEmptySpaceOrTheCloseButtonUnpinsIt() throws {
        let (view, _) = stage(width: 1000, height: 900)
        let fan = try XCTUnwrap(view.canvas.hardwareLayout.components.first { $0.kind == .fan(index: 0) })
        view.canvas.onClick?(fan, nil, NSPoint(x: 300, y: 300))
        XCTAssertEqual(view.pinnedID, fan.id)
        XCTAssertEqual(view.canvas.pinnedID, fan.id)
        XCTAssertFalse(view.pinnedCard.isHidden)
        XCTAssertTrue(view.tooltipCard.isHidden)
        XCTAssertLessThanOrEqual(view.pinnedCard.frame.width, HardwarePinnedCard.maxWidth)
        try render(view)

        // A hover over the pinned part shows no second card.
        view.canvas.onHover?(fan, NSPoint(x: 300, y: 300))
        XCTAssertTrue(view.tooltipCard.isHidden)

        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "\u{1B}",
                                                    charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertNil(view.pinnedID)
        XCTAssertTrue(view.pinnedCard.isHidden)

        view.canvas.onClick?(fan, nil, NSPoint(x: 300, y: 300))
        view.canvas.onClick?(nil, nil, NSPoint(x: 5, y: 5))
        XCTAssertNil(view.pinnedID)

        view.canvas.onClick?(fan, nil, NSPoint(x: 300, y: 300))
        let close = view.pinnedCard.closeControl
        if let action = close.action { _ = close.target?.perform(action, with: close) }
        XCTAssertNil(view.pinnedID)
        XCTAssertEqual(view.pinnedCard.closeControl.accessibilityLabel(), "Close detail")
    }

    func testAPinnedBatteryGraphDrawsTheChargeHistoryInANarrowStage() throws {
        let (view, _) = stage(width: 400, height: 700)
        let battery = try XCTUnwrap(view.canvas.hardwareLayout.components.first { $0.kind == .battery })
        view.canvas.onClick?(battery, "graph", NSPoint(x: 200, y: 400))
        XCTAssertEqual(view.pinnedID, battery.id)
        XCTAssertFalse(view.pinnedCard.isHidden)
        XCTAssertLessThanOrEqual(view.pinnedCard.frame.maxX, 400)
        try render(view)
    }

    func testANewReadingRefreshesAnOpenCardWithoutAddingViews() throws {
        let (view, history) = stage(width: 1000, height: 900)
        let fan = try XCTUnwrap(view.canvas.hardwareLayout.components.first { $0.kind == .fan(index: 0) })
        view.canvas.onClick?(fan, nil, NSPoint(x: 300, y: 300))
        let subviews = view.subviews.count
        let pinnedSubviews = view.pinnedCard.subviews.count
        var faster = fullReadings()
        faster.fans[0].rpm = 4500
        history.append(faster)
        view.update(layout: view.canvas.hardwareLayout, readings: faster, history: history,
                    chargeHistory: [], menuBarWidgets: [])
        XCTAssertEqual(view.subviews.count, subviews)
        XCTAssertEqual(view.pinnedCard.subviews.count, pinnedSubviews)
        XCTAssertEqual(view.pinnedID, fan.id)
        try render(view)
    }

    func testEveryFamilyComposesWideAndNarrow() throws {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro16ProMax, .macBookPro14Base, .macBookNeo, .macMiniM4, .generic] {
            for width in [CGFloat(1000), 400] {
                let (view, _) = stage(width: width, height: 800, family: family)
                XCTAssertEqual(view.chipsBar.isHidden, width >= 640, "\(family) \(width)")
                try render(view)
            }
        }
    }
}
