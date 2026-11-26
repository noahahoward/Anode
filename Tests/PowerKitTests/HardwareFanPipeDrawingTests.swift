import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The heat pipe and the fans: the heat colours, the text, the fan speed control's mouse handling, and that every reading
/// shape paints.
final class HardwareFanPipeDrawingTests: XCTestCase {

    // MARK: - Heat colour

    /// The colour as 0...255 integers.
    private func rgb(_ color: NSColor) throws -> [Int] {
        let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return [Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())]
    }

    func testHeatColorAtTheStops() throws {
        XCTAssertEqual(try rgb(HardwareCanvasView.heatColor(30)), [58, 118, 240])
        XCTAssertEqual(try rgb(HardwareCanvasView.heatColor(65)), [242, 178, 74])
        XCTAssertEqual(try rgb(HardwareCanvasView.heatColor(95)), [255, 77, 58])
    }

    func testHeatColorHalfwayBetweenTheFirstTwoStops() throws {
        // 40 is the midpoint of 30 and 50: (58+79)/2 = 68.5 rounds to 69, (118+172)/2 = 145, (240+236)/2 = 238.
        XCTAssertEqual(try rgb(HardwareCanvasView.heatColor(40)), [69, 145, 238])
    }

    func testHeatColorClampsAtBothEnds() throws {
        XCTAssertEqual(try rgb(HardwareCanvasView.heatColor(10)), [58, 118, 240])
        XCTAssertEqual(try rgb(HardwareCanvasView.heatColor(120)), [255, 77, 58])
    }

    func testAMissingTemperatureIsNotAHeatColour() throws {
        let none = try rgb(HardwareCanvasView.pipeColor(nil))
        for t in stride(from: 10.0, through: 120.0, by: 1.0) {
            XCTAssertNotEqual(none, try rgb(HardwareCanvasView.heatColor(t)), "neutral grey must not be mistaken for \(t) °C")
        }
        XCTAssertEqual(try rgb(HardwareCanvasView.pipeColor(65)), [242, 178, 74])
    }

    // MARK: - Text

    func testTemperatureTextIsWholeDegreesOrADash() {
        XCTAssertEqual(HardwareCanvasView.temperatureText(41.4), "41°")
        XCTAssertEqual(HardwareCanvasView.temperatureText(41.6), "42°")
        XCTAssertEqual(HardwareCanvasView.temperatureText(nil), "—")
    }

    func testRPMTextHasThousandsSeparators() {
        XCTAssertEqual(HardwareCanvasView.rpmText(4380), "4,380")
        XCTAssertEqual(HardwareCanvasView.rpmText(2317), "2,317")
        XCTAssertEqual(HardwareCanvasView.rpmText(850), "850")
        XCTAssertEqual(HardwareCanvasView.rpmText(0), "0")
    }

    // MARK: - Fan speed control

    private func fan(_ index: Int, rpm: Double, manual: Bool = false) -> FanReading {
        FanReading(index: index, rpm: rpm, minRPM: 2000, maxRPM: 6000, targetRPM: nil, isManual: manual)
    }

    private func canvas(family: MacFamily = .generic, readings: HardwareReadings?) -> HardwareCanvasView {
        let v = HardwareCanvasView(layout: HardwareLayout.layout(for: family))
        v.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        v.readings = readings
        return v
    }

    private func geometry(_ v: HardwareCanvasView, fan index: Int) throws -> FanSliderGeometry {
        let component = try XCTUnwrap(v.hardwareLayout.components.first { $0.kind == .fan(index: index) })
        return try XCTUnwrap(v.fanSliderGeometry(for: component))
    }

    func testADragSendsOneSpeedWhenTheButtonComesUp() throws {
        let v = canvas(readings: HardwareReadings(fans: [fan(0, rpm: 3000), fan(1, rpm: 3000)], helperInstalled: true))
        var sent: [(Int, Double?)] = []
        v.onFanSlider = { sent.append(($0, $1)) }
        let g = try geometry(v, fan: 1)

        // Press on the track's left end, drag to the middle, then past the right end (clamped), then let go.
        XCTAssertTrue(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g.trackX), y: Double(g.trackY))))
        XCTAssertEqual(v.dragFanIndex, 1)
        XCTAssertEqual(try XCTUnwrap(v.dragRPM), 2000, accuracy: 0.5)
        XCTAssertTrue(v.fanControlMouseDragged(atLayoutPoint: HWPoint(x: Double(g.trackX + 80), y: Double(g.trackY))))
        XCTAssertEqual(try XCTUnwrap(v.dragRPM), 4000, accuracy: 0.5)
        XCTAssertTrue(v.fanControlMouseDragged(atLayoutPoint: HWPoint(x: Double(g.trackX + 400), y: Double(g.trackY + 50))))
        XCTAssertEqual(try XCTUnwrap(v.dragRPM), 6000, accuracy: 0.5)
        XCTAssertTrue(sent.isEmpty, "nothing is sent while dragging")

        XCTAssertTrue(v.fanControlMouseUp())
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, 1)
        XCTAssertEqual(try XCTUnwrap(sent.first?.1), 6000, accuracy: 0.5)
        XCTAssertNil(v.dragFanIndex)
        XCTAssertNil(v.dragRPM)
        XCTAssertFalse(v.fanControlMouseUp(), "a second release has nothing to send")
    }

    func testAPressStartsFromNoDragSoAStaleOneCannotSendASpeed() throws {
        let v = canvas(readings: HardwareReadings(fans: [fan(0, rpm: 3000)], helperInstalled: true))
        var sent: [(Int, Double?)] = []
        v.onFanSlider = { sent.append(($0, $1)) }
        let g = try geometry(v, fan: 0)
        // A drag left over from a button-up that never came.
        v.dragFanIndex = 0
        v.dragRPM = 5000
        // A press that is not on any speed control clears it, and the next button-up sends nothing.
        XCTAssertFalse(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: -500, y: -500)))
        XCTAssertNil(v.dragFanIndex)
        XCTAssertNil(v.dragRPM)
        XCTAssertFalse(v.fanControlMouseUp())
        XCTAssertTrue(sent.isEmpty)
        // A press on the chip (a click, not a drag) clears one too.
        v.dragFanIndex = 0
        v.dragRPM = 5000
        XCTAssertTrue(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g.chip.midX), y: Double(g.chip.midY))))
        XCTAssertNil(v.dragFanIndex)
        XCTAssertFalse(v.fanControlMouseUp())
        XCTAssertEqual(sent.count, 1)
        XCTAssertNil(sent[0].1)
    }

    func testDraggingLeftOfTheTrackClampsToTheMinimum() throws {
        let v = canvas(readings: HardwareReadings(fans: [fan(0, rpm: 3000)], helperInstalled: true))
        var sent: [(Int, Double?)] = []
        v.onFanSlider = { sent.append(($0, $1)) }
        let g = try geometry(v, fan: 0)
        XCTAssertTrue(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g.trackX + 40), y: Double(g.trackY))))
        XCTAssertTrue(v.fanControlMouseDragged(atLayoutPoint: HWPoint(x: Double(g.trackX - 300), y: Double(g.trackY))))
        XCTAssertTrue(v.fanControlMouseUp())
        XCTAssertEqual(try XCTUnwrap(sent.first?.1), 2000, accuracy: 0.5)
    }

    func testTheChipReleasesTheFanToAutomatic() throws {
        let v = canvas(readings: HardwareReadings(fans: [fan(0, rpm: 3000, manual: true)], helperInstalled: true))
        var sent: [(Int, Double?)] = []
        v.onFanSlider = { sent.append(($0, $1)) }
        let g = try geometry(v, fan: 0)
        XCTAssertTrue(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g.chip.midX), y: Double(g.chip.midY))))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, 0)
        XCTAssertNil(sent.first?.1)
        XCTAssertNil(v.dragFanIndex, "the chip is a click, not a drag")
    }

    func testTheInstallPromptAsksForTheHelperAndTheSliderIsGone() throws {
        let v = canvas(readings: HardwareReadings(fans: [fan(0, rpm: 3000)], helperInstalled: false))
        var installs = 0
        var sent = 0
        v.onInstallHelper = { installs += 1 }
        v.onFanSlider = { _, _ in sent += 1 }
        let g = try geometry(v, fan: 0)
        // Where the track would be, the prompt is: it asks for the helper and starts no drag.
        XCTAssertTrue(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g.prompt.midX), y: Double(g.prompt.midY))))
        XCTAssertEqual(installs, 1)
        XCTAssertNil(v.dragFanIndex)
        // The chip is not there without the helper.
        XCTAssertFalse(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g.chip.midX), y: Double(g.chip.midY))))
        XCTAssertEqual(sent, 0)
    }

    func testPressesElsewhereAreNotTheSpeedControls() throws {
        let v = canvas(readings: HardwareReadings(fans: [fan(0, rpm: 3000)], helperInstalled: true))
        XCTAssertFalse(v.fanControlMouseDown(atLayoutPoint: HWPoint(x: 5, y: 5)))
        XCTAssertFalse(v.fanControlMouseDragged(atLayoutPoint: HWPoint(x: 5, y: 5)))
        XCTAssertFalse(v.fanControlMouseUp())
    }

    func testFansThatAreNotMeasuredOrNotListedHaveNoControl() throws {
        let unmeasured = canvas(readings: HardwareReadings(fans: [], fansMeasured: false, helperInstalled: true))
        let g = try geometry(unmeasured, fan: 0)
        XCTAssertFalse(unmeasured.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g.trackX), y: Double(g.trackY))))
        // Only fan 0 is listed: fan 1's control is not there.
        let one = canvas(readings: HardwareReadings(fans: [fan(0, rpm: 3000)], helperInstalled: true))
        let g1 = try geometry(one, fan: 1)
        XCTAssertFalse(one.fanControlMouseDown(atLayoutPoint: HWPoint(x: Double(g1.trackX), y: Double(g1.trackY))))
    }

    func testThePhotoSliderBlockLiesInsideEachFansJumpRectangle() throws {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro16ProMax] {
            let v = canvas(family: family, readings: nil)
            for index in 0..<2 {
                let component = try XCTUnwrap(v.hardwareLayout.components.first { $0.kind == .fan(index: index) })
                let jump = try XCTUnwrap(component.jump)
                let g = try XCTUnwrap(v.fanSliderGeometry(for: component))
                let jumpRect = CGRect(x: jump.x, y: jump.y, width: jump.w, height: jump.h)
                // The plate may overhang the focus rect horizontally by a few units, as it does in the mockup; only its rows must be inside.
                XCTAssertGreaterThanOrEqual(g.plate.minY, jumpRect.minY, "fan \(index + 1)'s plate starts above its jump rect")
                XCTAssertLessThanOrEqual(g.plate.maxY, jumpRect.maxY, "fan \(index + 1)'s plate ends below its jump rect")
                XCTAssertTrue(jumpRect.contains(g.trackHit))
                XCTAssertTrue(jumpRect.contains(g.chip))
            }
        }
    }

    func testTheSliderGeometryMatchesTheMockup() throws {
        // Photo layouts: the block sits on a plate at the fixed row P(0, 735) + 32, where P is the warped point (about 816).
        let photo = canvas(family: .macBookPro14ProMax, readings: nil)
        let gp = try geometry(photo, fan: 0)
        XCTAssertTrue(gp.plated)
        XCTAssertEqual(Double(gp.sy), PhotoWarp.straightened.drawingPoint(photoX: 0, photoY: 735).y + 32, accuracy: 0.001)
        XCTAssertEqual(Double(gp.sy), 816.3, accuracy: 2, "P(0, 735) is about 784.3 with the real warp")
        XCTAssertEqual(gp.trackX, gp.centerX - 80, accuracy: 0.001)
        // Drawn layouts: under the housing, 42 below its lower edge (radius 78 + 16).
        let drawn = canvas(family: .macBookPro14Base, readings: nil)
        let gd = try geometry(drawn, fan: 0)
        let centre = try XCTUnwrap(drawn.hardwareLayout.components.first { $0.kind == .fan(index: 0) }?.points.first)
        XCTAssertFalse(gd.plated)
        XCTAssertEqual(Double(gd.sy), centre.y + 78 + 16 + 42, accuracy: 0.001)
    }

    // MARK: - Painting

    /// Draws every component of a canvas into a bitmap, as the canvas does (no crash is the test).
    private func paint(_ v: HardwareCanvasView) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 700,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let gc = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        v.drawComponents(in: gc.cgContext, scale: 1)
        NSGraphicsContext.current = saved
    }

    func testEveryFanAndPipeReadingShapePaintsOnEveryFamily() throws {
        let shapes: [HardwareReadings?] = [
            nil,
            HardwareReadings(),
            HardwareReadings(fans: [fan(0, rpm: 0), fan(1, rpm: 0)], cpuTemp: .real(41.4), gpuTemp: .real(41.2), helperInstalled: true),
            HardwareReadings(fans: [fan(0, rpm: 4380), fan(1, rpm: 4210, manual: true)], cpuTemp: .real(79.8), gpuTemp: .real(66.5), helperInstalled: true),
            HardwareReadings(fans: [fan(0, rpm: 4380)], cpuTemp: .real(nil), gpuTemp: .real(90), helperInstalled: false),
            HardwareReadings(fans: [], fansMeasured: false, cpuTemp: .real(nil), gpuTemp: .real(nil)),
        ]
        let families: [MacFamily] = [.macBookPro14ProMax, .macBookPro16ProMax, .macBookPro14Base, .macBookNeo, .macMiniM4, .generic]
        for family in families {
            for readings in shapes {
                let v = canvas(family: family, readings: readings)
                v.fanAngles = [0.4, 1.9]
                try paint(v)
            }
        }
    }

    func testTheImpellerPaintsAtAnyAngle() throws {
        let v = canvas(readings: nil)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 300,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let gc = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        for angle in [0.0, 0.5, 3.14, -2, 100] {
            v.drawImpeller(in: gc.cgContext, center: CGPoint(x: 150, y: 150), radius: 120, innerRadius: 60, angle: CGFloat(angle))
        }
        NSGraphicsContext.current = saved
        // The disc is dark but painted: the pixel at the centre of the blades' reach is no longer transparent.
        let c = try XCTUnwrap(rep.colorAt(x: 150, y: 60))
        XCTAssertGreaterThan(c.alphaComponent, 0.9)
    }
}
