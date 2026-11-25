import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Memory, storage, Wi-Fi, power in and the battery cells: the text they write, and that each paints on the photograph's layout
/// and on drawn layouts, with full readings and with none.
final class HardwareComponentDrawingTests: XCTestCase {

    private let gibibyte: UInt64 = 1 << 30

    // MARK: - Readings

    private func memory(pressure: Int32? = 1, swap: Tagged<UInt64>? = nil) -> MemoryReading {
        MemoryReading(app: 8 * gibibyte, wired: 4 * gibibyte, compressed: 10 * gibibyte, free: 2 * gibibyte,
                      total: 24 * gibibyte, pressure: pressure, swapBytes: swap ?? .real(9_126_805_504))
    }

    private func storage(free: UInt64? = 129_000_000_000, total: UInt64? = 994_000_000_000) -> StorageReading {
        StorageReading(freeBytes: free, totalBytes: total, readBPS: 63_100, writeBPS: 19_700, smartTempC: 33.9,
                       wearPercent: 1, spare: 100, bytesWritten: nil)
    }

    private func battery(percent: Int = 64,
                         tempC: Double? = 31,
                         amps: Double = 1.2,
                         charging: Bool = true,
                         state: BatteryChargeState = .charging,
                         time: Tagged<Int> = .estimate(52),
                         health: Double? = 92,
                         design: Int? = 1000,
                         draw: Tagged<Double> = .real(9)) -> BatteryReading {
        BatteryReading(percent: percent, tempC: tempC, amps: amps, isCharging: charging, state: state,
                       timeRemainingMin: time, health: health, cycles: 95, designCycles: design, systemDrawW: draw)
    }

    private func full() -> HardwareReadings {
        HardwareReadings(memory: memory(),
                         network: (down: 38.4e6, up: 2.1e6),
                         storage: storage(),
                         battery: battery(),
                         adapter: AdapterReading(ratedW: 68, drawnW: .estimate(4.4), isCharging: false))
    }

    // MARK: - Number and text helpers

    func testRateBoundaries() {
        XCTAssertEqual(HardwareCanvasView.rateText(999_900), "999.9 KB/s")
        XCTAssertEqual(HardwareCanvasView.rateText(1_000_000), "1.0 MB/s")
        XCTAssertEqual(HardwareCanvasView.rateText(999_900_000), "999.9 MB/s")
        XCTAssertEqual(HardwareCanvasView.rateText(1_000_000_000), "1.00 GB/s")
        XCTAssertEqual(HardwareCanvasView.rateText(1_234_567_890), "1.23 GB/s")
        XCTAssertEqual(HardwareCanvasView.rateText(38_400_000), "38.4 MB/s")
        XCTAssertEqual(HardwareCanvasView.rateText(3_500), "3.5 KB/s")
        XCTAssertEqual(HardwareCanvasView.rateText(0), "0.0 KB/s")
    }

    func testAMissingRateIsADashAndNeverZero() {
        XCTAssertEqual(HardwareCanvasView.rateText(nil), "—")
        XCTAssertEqual(HardwareCanvasView.rateText(Double.nan), "—")
        XCTAssertEqual(HardwareCanvasView.rateText(Double.infinity), "—")
    }

    func testNumbersAreWrittenWithTheMockupsDecimalsAndSeparators() {
        XCTAssertEqual(HardwareCanvasView.readoutNumber(1234.56), "1,234.6")
        XCTAssertEqual(HardwareCanvasView.readoutNumber(21.84), "21.8")
        XCTAssertEqual(HardwareCanvasView.readoutNumber(994, digits: 0), "994")
        XCTAssertEqual(HardwareCanvasView.readoutNumber(0.2, digits: 2), "0.20")
        XCTAssertEqual(HardwareCanvasView.readoutNumber(Double.nan), "—")
    }

    func testMemoryInUseIsAppPlusWiredPlusCompressedInGigabytes() {
        let m = memory()
        XCTAssertEqual(HardwareCanvasView.memoryUsedBytes(m), 22 * gibibyte)
        XCTAssertEqual(HardwareCanvasView.memoryUsedText(m), "22.0")
        XCTAssertEqual(HardwareCanvasView.memoryTotalText(m.total), "24")
        XCTAssertEqual(HardwareCanvasView.memoryTotalText(gibibyte * 3 / 2), "1.5")
        XCTAssertEqual(HardwareCanvasView.memoryTotalLabel(m.total), "24 GB")
        XCTAssertEqual(HardwareCanvasView.memoryTotalLabel(0), "—", "a Mac that reported no total is never \"of 0 GB\"")
    }

    func testTheCompositionBarHasFourSegmentsInTheMockupsColours() throws {
        let segments = HardwareCanvasView.memorySegments(memory())
        XCTAssertEqual(segments.map { $0.name }, ["App", "Wired", "Compressed", "Free"])
        XCTAssertEqual(segments.map { $0.bytes }, [8 * gibibyte, 4 * gibibyte, 10 * gibibyte, 2 * gibibyte])
        XCTAssertEqual(try rgb(segments[0].color), [0x4C, 0x8D, 0xFF])
        XCTAssertEqual(try rgb(segments[1].color), [0x8A, 0x7C, 0xF0])
        XCTAssertEqual(try rgb(segments[2].color), [0xE0, 0xA2, 0x4C])
        XCTAssertEqual(try rgb(segments[3].color), [0x3B, 0x46, 0x56])
    }

    func testPressureHasAWordAndAColourPerKernelLevel() throws {
        XCTAssertEqual(HardwareCanvasView.memoryPressureName(1), "Normal")
        XCTAssertEqual(HardwareCanvasView.memoryPressureName(2), "Warning")
        XCTAssertEqual(HardwareCanvasView.memoryPressureName(4), "Critical")
        XCTAssertEqual(HardwareCanvasView.memoryPressureName(nil), "—")
        XCTAssertEqual(HardwareCanvasView.memoryPressureName(3), "—")
        XCTAssertEqual(try rgb(HardwareCanvasView.memoryPressureColor(1)), [0x30, 0xD1, 0x58])
        XCTAssertEqual(try rgb(HardwareCanvasView.memoryPressureColor(2)), [0xFF, 0xD6, 0x0A])
        XCTAssertEqual(try rgb(HardwareCanvasView.memoryPressureColor(4)), [0xFF, 0x45, 0x3A])
        // No answer is neither green, yellow nor red.
        let none = try rgb(HardwareCanvasView.memoryPressureColor(nil))
        for level: Int32 in [1, 2, 4] {
            XCTAssertNotEqual(none, try rgb(HardwareCanvasView.memoryPressureColor(level)))
        }
    }

    func testSwapShowsItsProvenanceAndADashWhenUnknown() {
        XCTAssertEqual(HardwareCanvasView.swapText(.real(9_126_805_504)), "Swap 8.5 GB")
        XCTAssertEqual(HardwareCanvasView.swapText(.estimate(9_126_805_504)), "Swap ≈ 8.5 GB")
        XCTAssertEqual(HardwareCanvasView.swapText(.real(nil)), "Swap —")
        XCTAssertEqual(HardwareCanvasView.swapText(.real(0)), "Swap 0.0 GB")
    }

    func testStorageIsWrittenInDecimalGigabytesAndTheBarFillsWithUse() throws {
        XCTAssertEqual(HardwareCanvasView.storageGigabytesText(129_000_000_000), "129")
        XCTAssertEqual(HardwareCanvasView.storageGigabytesText(994_000_000_000), "994")
        XCTAssertEqual(HardwareCanvasView.storageGigabytesText(nil), "—")
        let used = try XCTUnwrap(HardwareCanvasView.storageUsedFraction(storage()))
        XCTAssertEqual(used, 1 - 129.0 / 994.0, accuracy: 0.0001)
        XCTAssertNil(HardwareCanvasView.storageUsedFraction(storage(free: nil)))
        XCTAssertNil(HardwareCanvasView.storageUsedFraction(storage(total: nil)))
        XCTAssertNil(HardwareCanvasView.storageUsedFraction(storage(free: 0, total: 0)))
        XCTAssertEqual(try XCTUnwrap(HardwareCanvasView.storageUsedFraction(storage(free: 0, total: 500_000_000_000))), 1, accuracy: 0.0001)
    }

    func testPowerInSaysApproximatelyOnlyForAnEstimate() {
        let estimate = AdapterReading(ratedW: 68, drawnW: .estimate(4.4), isCharging: false)
        XCTAssertEqual(HardwareCanvasView.powerInReadout(estimate).value, "≈ 4.4 W")
        XCTAssertEqual(HardwareCanvasView.powerInReadout(estimate).note, "in · not charging")

        let real = AdapterReading(ratedW: 68, drawnW: .real(62), isCharging: true)
        XCTAssertEqual(HardwareCanvasView.powerInReadout(real).value, "62.0 W")
        XCTAssertEqual(HardwareCanvasView.powerInReadout(real).note, "in · charging")
    }

    func testPowerInWithNothingToReadIsADash() {
        let unknownDraw = AdapterReading(ratedW: 68, drawnW: .estimate(nil), isCharging: true)
        XCTAssertEqual(HardwareCanvasView.powerInReadout(unknownDraw).value, "—")
        XCTAssertEqual(HardwareCanvasView.powerInReadout(unknownDraw).note, "in · charging")
        XCTAssertEqual(HardwareCanvasView.powerInReadout(nil).value, "—")
        XCTAssertEqual(HardwareCanvasView.powerInReadout(nil).note, "")
    }

    func testBatteryStateAndCurrentWording() {
        XCTAssertEqual(HardwareCanvasView.batteryStateText(.charging), "Charging")
        XCTAssertEqual(HardwareCanvasView.batteryStateText(.full), "Full · holding")
        XCTAssertEqual(HardwareCanvasView.batteryStateText(.pluggedNotCharging), "Plugged in")
        XCTAssertEqual(HardwareCanvasView.batteryStateText(.discharging), "Discharging")
        XCTAssertEqual(HardwareCanvasView.batteryCurrentText(0), "0 mA")
        XCTAssertEqual(HardwareCanvasView.batteryCurrentText(0.0004), "0 mA")
        XCTAssertEqual(HardwareCanvasView.batteryCurrentText(6.1), "+6.1 A")
        XCTAssertEqual(HardwareCanvasView.batteryCurrentText(-0.25), "-250 mA")
        XCTAssertEqual(HardwareCanvasView.batteryCurrentText(Double.nan), "—")
    }

    func testEveryStateWordFitsTheNarrowestStateCellAtFullSize() throws {
        // The photograph's state cell is ps(430) wide (read from the layout); the text starts 16 in from each side.
        let layout = HardwareLayout.layout(for: .macBookPro14ProMax)
        let battery = try XCTUnwrap(layout.components.first { $0.kind == .battery })
        let cell = try XCTUnwrap(battery.parts.first { $0.roles == ["state"] })
        XCTAssertEqual(cell.rect.w, PhotoWarp.straightened.drawingLength(430), accuracy: 0.001)
        let room = CGFloat(cell.rect.w) - 32
        let states: [BatteryChargeState] = [.charging, .full, .pluggedNotCharging, .discharging]
        for state in states {
            let word = HardwareCanvasView.batteryStateText(state)
            let width = NSAttributedString(string: word, attributes: [.font: Palette.Font.sans(19, .semibold)]).size().width
            XCTAssertLessThanOrEqual(width, room, "\(state): \(word)")
            let fitted = HardwareCanvasView.fittedText(word, width: room, startSize: 19, weight: .semibold)
            XCTAssertEqual(fitted.text, word)
            XCTAssertEqual(fitted.size, 19)
        }
    }

    func testTextThatDoesNotFitShrinksThenIsCut() {
        let long = "Plugged in · not charging, held at the charge limit"
        let measure = { (t: String, size: CGFloat) -> CGFloat in
            NSAttributedString(string: t, attributes: [.font: Palette.Font.sans(size, .semibold)]).size().width
        }
        // Wide enough only at a smaller size: shrinks, keeps every character.
        let room = measure(long, 16) + 0.5
        let shrunk = HardwareCanvasView.fittedText(long, width: room, startSize: 19, weight: .semibold)
        XCTAssertEqual(shrunk.text, long)
        XCTAssertLessThan(shrunk.size, 19)
        XCTAssertGreaterThanOrEqual(shrunk.size, 14)
        XCTAssertLessThanOrEqual(measure(shrunk.text, shrunk.size), room)
        // Too narrow even at 14 pt: cut with an ellipsis at 14 pt, and the cut text fits.
        let cut = HardwareCanvasView.fittedText(long, width: 100, startSize: 19, weight: .semibold)
        XCTAssertEqual(cut.size, 14)
        XCTAssertTrue(cut.text.hasSuffix("…"))
        XCTAssertLessThan(cut.text.count, long.count)
        XCTAssertLessThanOrEqual(measure(cut.text, 14), 100)
    }

    func testBatteryTimeIsAnEstimateOrADash() {
        XCTAssertEqual(HardwareCanvasView.batteryTimeText(battery(time: .estimate(52))), "≈ 0:52 to full")
        XCTAssertEqual(HardwareCanvasView.batteryTimeText(battery(charging: false, state: .discharging, time: .estimate(200))), "≈ 3:20 left")
        XCTAssertEqual(HardwareCanvasView.batteryTimeText(battery(charging: false, state: .discharging, time: .real(65))), "1:05 left")
        XCTAssertEqual(HardwareCanvasView.batteryTimeText(battery(time: .estimate(nil))), "time to full —")
        XCTAssertEqual(HardwareCanvasView.batteryTimeText(battery(charging: false, state: .full, time: .estimate(nil))), "time left —")
    }

    func testBatteryCyclesAreStackedOrOnOneLine() {
        XCTAssertEqual(HardwareCanvasView.batteryCyclesText(battery(), stacked: false), "95 / 1000 cycles")
        XCTAssertEqual(HardwareCanvasView.batteryCyclesText(battery(), stacked: true), "95 of 1000 cycles")
        XCTAssertEqual(HardwareCanvasView.batteryCyclesText(battery(design: nil), stacked: false), "95 / — cycles")
    }

    // MARK: - Painting

    private let layoutFamilies: [MacFamily] = [.macBookPro14ProMax, .macBookPro14Base, .macBookNeo]

    private enum Piece: CaseIterable {
        case memory, storage, wifi, powerIn, battery

        var kind: HardwareComponentKind {
            switch self {
            case .memory: return .memory
            case .storage: return .storage
            case .wifi: return .wifi
            case .powerIn: return .powerIn
            case .battery: return .battery
            }
        }
    }

    private func canvas(_ family: MacFamily, readings: HardwareReadings?, history: [Double?] = []) -> HardwareCanvasView {
        let v = HardwareCanvasView(layout: HardwareLayout.layout(for: family))
        v.frame = NSRect(x: 0, y: 0, width: 1100, height: 1205)
        v.readings = readings
        v.chargeHistory = history
        return v
    }

    private func component(_ piece: Piece, in v: HardwareCanvasView) throws -> HardwareComponent {
        try XCTUnwrap(v.hardwareLayout.components.first { $0.kind == piece.kind }, "\(v.hardwareLayout.family) has no \(piece)")
    }

    private func drawPiece(_ piece: Piece, _ v: HardwareCanvasView, _ ctx: CGContext, _ c: HardwareComponent) {
        switch piece {
        case .memory: v.drawMemory(in: ctx, scale: 1, component: c)
        case .storage: v.drawStorage(in: ctx, scale: 1, component: c)
        case .wifi: v.drawWifi(in: ctx, scale: 1, component: c)
        case .powerIn: v.drawPowerIn(in: ctx, scale: 1, component: c)
        case .battery: v.drawBattery(in: ctx, scale: 1, component: c)
        }
    }

    /// A 1100 x 1205 bitmap, mid grey, with the drawing run in a context whose y runs down (as the canvas's does) so a layout
    /// unit is a pixel and layout row y is pixel row y.
    private func paint(_ draw: (CGContext) -> Void) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 1205,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let base = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let cg = base.cgContext
        cg.setFillColor(CGColor(gray: 0.5, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: 1100, height: 1205))
        cg.translateBy(x: 0, y: 1205)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = flipped
        draw(cg)
        NSGraphicsContext.current = saved
        return rep
    }

    private func paintPiece(_ piece: Piece, _ v: HardwareCanvasView) throws -> (rep: NSBitmapImageRep, rect: HWRect) {
        let c = try component(piece, in: v)
        let rep = try paint { ctx in self.drawPiece(piece, v, ctx, c) }
        return (rep, try XCTUnwrap(c.rect))
    }

    /// How many pixels in `rect` (grown by `margin`) differ from the grey the bitmap started as.
    private func changedPixels(_ rep: NSBitmapImageRep, in rect: HWRect, margin: Double = 8) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bytesPerRow = rep.bytesPerRow
        let reference = (data[0], data[1], data[2])
        let x0 = max(0, Int(rect.x - margin)), x1 = min(rep.pixelsWide, Int(rect.x + rect.w + margin))
        let y0 = max(0, Int(rect.y - margin)), y1 = min(rep.pixelsHigh, Int(rect.y + rect.h + margin))
        guard x0 < x1, y0 < y1 else { return 0 }
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = data + y * bytesPerRow + x * 4
                if abs(Int(p[0]) - Int(reference.0)) > 3 || abs(Int(p[1]) - Int(reference.1)) > 3 || abs(Int(p[2]) - Int(reference.2)) > 3 {
                    count += 1
                }
            }
        }
        return count
    }

    private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        guard let data = rep.bitmapData else { return (0, 0, 0) }
        let p = data + y * rep.bytesPerRow + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    private func rgb(_ color: NSColor) throws -> [Int] {
        let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return [Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())]
    }

    func testEveryPartPaintsOnEveryLayoutWithFullReadings() throws {
        let history: [Double?] = [100, 94, nil, nil, 52, 47, 68, 80, 100]
        for family in layoutFamilies {
            for piece in Piece.allCases {
                let v = canvas(family, readings: full(), history: history)
                let painted = try paintPiece(piece, v)
                XCTAssertGreaterThan(changedPixels(painted.rep, in: painted.rect), 0, "\(family) \(piece)")
            }
        }
    }

    func testWithNoReadingsThePartsAreOutlinesOrDashesAndNeverCrash() throws {
        for readings in [HardwareReadings(), nil] as [HardwareReadings?] {
            for family in layoutFamilies {
                for piece in Piece.allCases {
                    let v = canvas(family, readings: readings)
                    let painted = try paintPiece(piece, v)
                    let changed = changedPixels(painted.rep, in: painted.rect)
                    if piece == .battery {
                        // No battery reading (a desktop) draws nothing at all.
                        XCTAssertEqual(changed, 0, "\(family) \(piece)")
                    } else {
                        // Outlines (memory, storage) and plates with "—" (Wi-Fi, power in) still mark where the part is.
                        XCTAssertGreaterThan(changed, 0, "\(family) \(piece)")
                    }
                }
            }
        }
    }

    func testAReadingWithMissingFieldsStillPaints() throws {
        let sparse = HardwareReadings(
            memory: MemoryReading(app: 0, wired: 0, compressed: 0, free: 0, total: 0, pressure: nil, swapBytes: .real(nil)),
            network: nil,
            storage: StorageReading(freeBytes: nil, totalBytes: nil, readBPS: nil, writeBPS: nil, smartTempC: nil,
                                    wearPercent: nil, spare: nil, bytesWritten: nil),
            battery: battery(percent: 15, tempC: nil, amps: -0.25, charging: false, state: .discharging,
                             time: .estimate(nil), health: nil, design: nil, draw: .real(nil)),
            adapter: AdapterReading(ratedW: nil, drawnW: .estimate(nil), isCharging: false))
        for family in layoutFamilies {
            for piece in Piece.allCases {
                let v = canvas(family, readings: sparse, history: [nil, nil, nil])
                let painted = try paintPiece(piece, v)
                XCTAssertGreaterThan(changedPixels(painted.rep, in: painted.rect), 0, "\(family) \(piece)")
            }
        }
    }

    func testEveryPressureLevelAndEveryChargeStatePaints() throws {
        for level in [1, 2, 4, nil] as [Int32?] {
            for family in layoutFamilies {
                let v = canvas(family, readings: HardwareReadings(memory: memory(pressure: level, swap: .estimate(0))))
                _ = try paintPiece(.memory, v)
            }
        }
        let states: [(BatteryChargeState, Bool)] = [(.charging, true), (.full, false), (.pluggedNotCharging, false), (.discharging, false)]
        for (state, charging) in states {
            for percent in [0, 20, 21, 100] {
                let readings = HardwareReadings(battery: battery(percent: percent, charging: charging, state: state))
                for family in layoutFamilies {
                    _ = try paintPiece(.battery, canvas(family, readings: readings, history: [Double(percent)]))
                }
            }
        }
    }

    func testThePressureColourOutlinesTheMemoryDie() throws {
        // The base layout's left die is at (344, 584): its top edge, well clear of any text, takes the pressure colour.
        let normal = try paintPiece(.memory, canvas(.macBookPro14Base, readings: HardwareReadings(memory: memory(pressure: 1))))
        let critical = try paintPiece(.memory, canvas(.macBookPro14Base, readings: HardwareReadings(memory: memory(pressure: 4))))
        let green = pixel(normal.rep, x: 400, y: 584)
        let red = pixel(critical.rep, x: 400, y: 584)
        XCTAssertGreaterThan(green.g, green.r)
        XCTAssertGreaterThan(red.r, red.g)
    }

    func testTheChargeGraphDrawsOnlyWhenThereAreSamples() throws {
        // The base layout's graph cell.
        let cell = HWRect(x: 410, y: 992, w: 280, h: 100)
        let history: [Double?] = [100, 94, 79, nil, nil, 52, 47, 68, 80, 100]
        let readings = HardwareReadings(battery: battery())
        let without = try paintPiece(.battery, canvas(.macBookPro14Base, readings: readings, history: []))
        let allGaps = try paintPiece(.battery, canvas(.macBookPro14Base, readings: readings, history: [nil, nil, nil]))
        let with = try paintPiece(.battery, canvas(.macBookPro14Base, readings: readings, history: history))
        let none = changedPixels(without.rep, in: cell, margin: 0)
        XCTAssertEqual(changedPixels(allGaps.rep, in: cell, margin: 0), none)
        XCTAssertGreaterThan(changedPixels(with.rep, in: cell, margin: 0), none)
    }

    func testTheWholeLayoutPaintsThroughTheCanvasDispatch() throws {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro14Base, .macBookNeo, .macMiniM4, .generic] {
            let v = canvas(family, readings: full(), history: [100, 90, 80])
            _ = try paint { ctx in v.drawComponents(in: ctx, scale: 1) }
            let empty = canvas(family, readings: nil)
            _ = try paint { ctx in empty.drawComponents(in: ctx, scale: 1) }
        }
    }
}
