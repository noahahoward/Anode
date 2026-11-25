import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The Hardware View canvas: how layout units map into the view, what a point hits, and that it paints every family.
final class HardwareCanvasViewTests: XCTestCase {

    private func view(_ family: MacFamily, width: CGFloat = 550, height: CGFloat = 1205) -> HardwareCanvasView {
        let v = HardwareCanvasView(layout: HardwareLayout.layout(for: family))
        v.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return v
    }

    func testTheLayoutIsScaledToFitAndCentred() {
        // The photo layout is 1100 x 1205 units. In 550 x 1205 points the width limits: half a point per unit, centred up and down.
        let v = view(.macBookPro14ProMax)
        XCTAssertEqual(v.layoutScale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(v.layoutOffset.x, 0, accuracy: 0.001)
        XCTAssertEqual(v.layoutOffset.y, (1205 - 602.5) / 2, accuracy: 0.001)
        XCTAssertTrue(v.isFlipped)
    }

    func testViewPointsConvertBackToLayoutUnits() {
        let v = view(.macBookPro14ProMax)
        let p = v.layoutPoint(fromView: NSPoint(x: 275, y: v.layoutOffset.y + 100))
        XCTAssertEqual(p.x, 550, accuracy: 0.001)
        XCTAssertEqual(p.y, 200, accuracy: 0.001)
        let back = v.viewPoint(fromLayout: p)
        XCTAssertEqual(back.x, 275, accuracy: 0.001)
        XCTAssertEqual(back.y, v.layoutOffset.y + 100, accuracy: 0.001)
    }

    func testALayoutWithAnOriginIsPlacedByIt() {
        // The Mac mini's drawing starts at x 130: its own top left lands at the centred offset, not at the view's corner.
        let v = view(.macMiniM4, width: 840, height: 800)
        XCTAssertEqual(v.layoutScale, 1, accuracy: 0.0001)
        let corner = v.viewPoint(fromLayout: HWPoint(x: 130, y: 0))
        XCTAssertEqual(corner.x, 0, accuracy: 0.001)
        XCTAssertEqual(corner.y, 0, accuracy: 0.001)
    }

    func testNothingIsHitOutsideTheDrawing() {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro14Base, .macBookNeo, .macMiniM4, .generic] {
            let v = view(family)
            XCTAssertNil(v.component(atLayoutPoint: HWPoint(x: -500, y: -500)), "\(family)")
        }
    }

    func testTheGenericFrameAndNotesAreNeverTheTarget() {
        let v = view(.generic)
        let size = v.hardwareLayout.size
        var x = size.x
        while x <= size.x + size.w {
            var y = size.y
            while y <= size.y + size.h {
                if let hit = v.component(atLayoutPoint: HWPoint(x: x, y: y)) {
                    XCTAssertNotEqual(hit.kind, .board)
                    XCTAssertNotEqual(hit.kind, .note)
                }
                y += 20
            }
            x += 20
        }
    }

    func testABatteryCellWithThreeReadingsSplitsTopToBottom() throws {
        let layouts = [MacFamily.macBookPro14Base, .macBookNeo, .generic].map { HardwareLayout.layout(for: $0) }
        var found = false
        for layout in layouts {
            let v = HardwareCanvasView(layout: layout)
            guard let battery = layout.components.first(where: { $0.kind == .battery }),
                  let cell = battery.parts.first(where: { $0.roles.count == 3 }) else { continue }
            found = true
            let r = cell.rect
            let x = r.x + r.w / 2
            XCTAssertEqual(v.batteryRole(atLayoutPoint: HWPoint(x: x, y: r.y + r.h * 0.1), in: battery), cell.roles[0])
            XCTAssertEqual(v.batteryRole(atLayoutPoint: HWPoint(x: x, y: r.y + r.h * 0.55), in: battery), cell.roles[1])
            XCTAssertEqual(v.batteryRole(atLayoutPoint: HWPoint(x: x, y: r.y + r.h * 0.9), in: battery), cell.roles[2])
            XCTAssertNil(v.batteryRole(atLayoutPoint: HWPoint(x: r.x - 500, y: r.y - 50), in: battery))
        }
        XCTAssertTrue(found, "no layout has a three-reading battery cell, so this checked nothing")
    }

    /// Windows the hosted canvases live in. Never ordered front, so nothing is shown, but a view in a window answers
    /// `needsDisplay` the way it does on screen.
    private var hostWindows: [NSWindow] = []

    private func hosted(_ family: MacFamily, width: CGFloat = 550, height: CGFloat = 1205) -> HardwareCanvasView {
        _ = NSApplication.shared
        let v = view(family, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(v)
        hostWindows.append(window)
        return v
    }

    override func tearDown() {
        hostWindows.forEach { $0.contentView = nil }
        hostWindows.removeAll()
        super.tearDown()
    }

    func testReadingsRepaintOnlyWhenTheOwnerSaysItIsDrawable() {
        let v = hosted(.macBookNeo)
        v.needsDisplay = false
        v.isDrawableNow = { false }
        v.readingsChanged()
        XCTAssertFalse(v.needsDisplay)
        v.isDrawableNow = { true }
        v.readingsChanged()
        XCTAssertTrue(v.needsDisplay)
    }

    func testTheWidgetsAndTheChargeHistoryRepaintNothingWhileCovered() {
        let v = hosted(.macBookNeo)
        v.isDrawableNow = { false }
        v.needsDisplay = false
        v.menuBarWidgets = [MenuBarWidgetText(label: "CPU", value: "41")]
        XCTAssertFalse(v.needsDisplay, "a covered window repaints nothing for a new widget")
        v.chargeHistory = [10, 20, nil, 40]
        XCTAssertFalse(v.needsDisplay, "nor for a new charge history")
        // The values are kept, so the repaint that comes when it is uncovered shows them.
        XCTAssertEqual(v.menuBarWidgets.count, 1)
        XCTAssertEqual(v.chargeHistory.count, 4)

        v.isDrawableNow = { true }
        v.menuBarWidgets = []
        XCTAssertTrue(v.needsDisplay)
        v.needsDisplay = false
        v.chargeHistory = []
        XCTAssertTrue(v.needsDisplay)
    }

    // MARK: Paint order, culling and the narrow caption

    func testComponentsArePaintedInRankOrderWithTheLayoutsOrderKeptWithinARank() throws {
        let v = view(.macBookPro14ProMax)
        let layout = v.hardwareLayout
        let order = v.drawOrder
        XCTAssertEqual(order.count, layout.components.count)
        let ranks = order.map { HardwareCanvasView.drawRank($0.kind) }
        XCTAssertEqual(ranks, ranks.sorted(), "lower ranks are painted first")
        // The layout data lists the pipe before memory, storage, Wi-Fi, power and the battery: the picture paints it on top.
        let dataIDs = layout.components.map { $0.id }
        let drawnIDs = order.map { $0.id }
        let pipeData = try XCTUnwrap(dataIDs.firstIndex(of: "pipe"))
        let memData = try XCTUnwrap(dataIDs.firstIndex(of: "mem"))
        XCTAssertLessThan(pipeData, memData, "the layout data is unchanged")
        XCTAssertGreaterThan(try XCTUnwrap(drawnIDs.firstIndex(of: "pipe")), try XCTUnwrap(drawnIDs.firstIndex(of: "mem")))
        XCTAssertEqual(drawnIDs.last, "pipe")
        // Within one rank the layout's own order stands (the two fans keep theirs).
        let fans = drawnIDs.filter { $0.hasPrefix("fan") }
        XCTAssertEqual(fans, dataIDs.filter { $0.hasPrefix("fan") })
        // A new layout gives a new order.
        v.hardwareLayout = HardwareLayout.layout(for: .macMiniM4)
        XCTAssertEqual(v.drawOrder.map { $0.id }.sorted(), v.hardwareLayout.components.map { $0.id }.sorted())
    }

    func testTheRankOfEachKind() {
        XCTAssertEqual(HardwareCanvasView.drawRank(.board), 1)
        for kind in [HardwareComponentKind.antenna, .speaker, .trackpad] { XCTAssertEqual(HardwareCanvasView.drawRank(kind), 2) }
        XCTAssertEqual(HardwareCanvasView.drawRank(.soc), 3)
        XCTAssertEqual(HardwareCanvasView.drawRank(.fan(index: 0)), 4)
        for kind in [HardwareComponentKind.display, .memory, .storage, .wifi, .powerIn, .battery, .psu] {
            XCTAssertEqual(HardwareCanvasView.drawRank(kind), 5)
        }
        XCTAssertEqual(HardwareCanvasView.drawRank(.heatPipe), 6)
        XCTAssertEqual(HardwareCanvasView.drawRank(.note), 6)
    }

    func testAFanFramesRepaintSkipsTheOtherDrawers() throws {
        let v = view(.macBookPro14ProMax)
        let layout = v.hardwareLayout
        let fan = try XCTUnwrap(layout.components.first { $0.kind == .fan(index: 0) })
        let r = try XCTUnwrap(fan.rect)
        let dirty = CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
        let touched = layout.components.filter { c in
            guard let box = v.cullBox(of: c) else { return true }
            return box.intersects(dirty)
        }.map { $0.kind }
        XCTAssertTrue(touched.contains(.fan(index: 0)))
        XCTAssertFalse(touched.contains(.fan(index: 1)), "the other fan is far away")
        XCTAssertFalse(touched.contains(.display), "the screen is not repainted for a fan blade")
        XCTAssertFalse(touched.contains(.battery), "nor the battery cells")
        XCTAssertLessThan(touched.count, layout.components.count)
        // The cull box covers the fan's speed control, which is not inside the fan's own rectangle.
        let box = try XCTUnwrap(v.cullBox(of: fan))
        let geometry = try XCTUnwrap(v.fanSliderGeometry(for: fan))
        XCTAssertTrue(box.contains(geometry.plate))
    }

    private static let allFamilies: [MacFamily] = [.macBookPro14ProMax, .macBookPro16ProMax, .macBookPro14Base, .macBookNeo,
                                                   .macMiniM4, .generic]

    func testEveryRealNoteIsNeverCulled() throws {
        var notes = 0
        for family in Self.allFamilies {
            let v = view(family)
            for note in v.hardwareLayout.components where note.kind == .note {
                notes += 1
                XCTAssertNil(v.cullBox(of: note), "\(family): a note's rectangle has no size, its words run outside it")
            }
        }
        XCTAssertGreaterThan(notes, 0, "no layout has a note, so this checked nothing")
    }

    func testTheGenericNoteIsPaintedWhenANarrowWindowIsFocusedOnAnotherPart() throws {
        let v = view(.generic, width: 420, height: 480)
        v.isNarrow = true
        v.focusRect = HWRect(x: 320, y: 350, w: 220, h: 100)   // the Wi-Fi chip's jump rectangle
        let r = v.bounds
        let a = v.layoutPoint(fromView: NSPoint(x: r.minX, y: r.minY))
        let b = v.layoutPoint(fromView: NSPoint(x: r.maxX, y: r.maxY))
        let dirty = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let note = try XCTUnwrap(v.hardwareLayout.components.first { $0.kind == .note }, "the generic layout has a note")
        if let box = v.cullBox(of: note) {
            XCTAssertTrue(box.intersects(dirty), "the note is skipped on a full repaint of the focused view")
        }
    }

    func testAComponentWithNoAreaIsNeverCulled() {
        let v = view(.macBookPro14ProMax)
        let note = HardwareComponent(id: "n", kind: .note, confidence: .verified, text: ["words"])
        XCTAssertNil(v.cullBox(of: note))
        let withRect = HardwareComponent(id: "d", kind: .display, rect: HWRect(x: 100, y: 100, w: 50, h: 20),
                                         confidence: .verified)
        let box = v.cullBox(of: withRect)
        XCTAssertEqual(box, CGRect(x: 60, y: 60, width: 130, height: 100))
    }

    func testAPartialRepaintAndAFullOneBothPaint() throws {
        // `drawComponents` still takes no dirty rectangle (everything paints) or one (only what touches it).
        for family in Self.allFamilies {
            let v = view(family, width: 400, height: 400)
            // A repaint of the whole drawing skips nothing.
            let whole = CGRect(x: v.hardwareLayout.size.x, y: v.hardwareLayout.size.y,
                               width: v.hardwareLayout.size.w, height: v.hardwareLayout.size.h)
            for component in v.hardwareLayout.components {
                if let box = v.cullBox(of: component) {
                    XCTAssertTrue(box.intersects(whole), "\(family): \(component.id) would be skipped on a full repaint")
                }
            }
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 400,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let gc = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = gc
            v.drawComponents(in: gc.cgContext, scale: 1)
            v.drawComponents(in: gc.cgContext, scale: 1, dirty: CGRect(x: 0, y: 0, width: 10, height: 10))
            let size = v.hardwareLayout.size
            v.drawComponents(in: gc.cgContext, scale: 1,
                             dirty: CGRect(x: size.x, y: size.y, width: size.w, height: size.h))
            NSGraphicsContext.current = saved
            XCTAssertEqual(rep.pixelsWide, 400, "\(family)")
        }
    }

    func testANarrowWindowNamesTheStandInPhotoUnderThePicture() {
        let v = view(.macBookPro14ProMax, width: 400, height: 700)
        XCTAssertEqual(HardwareCanvasView.narrowPhotoCaption, "STAND-IN PHOTO \u{00B7} NOT AN APPLE SILICON BOARD")
        XCTAssertNil(v.narrowPhotoCaptionPlate(), "a wide window has the credit line under the picture itself")
        v.isNarrow = true
        let photoFound = HardwarePhoto.image(named: "macbook-pro-teardown") != nil
        if photoFound {
            let plate = v.narrowPhotoCaptionPlate()
            XCTAssertNotNil(plate)
            if let plate {
                XCTAssertTrue(v.bounds.contains(plate))
                XCTAssertGreaterThan(plate.midY, v.bounds.midY, "at the bottom of the view")
                XCTAssertEqual(plate.midX, v.bounds.midX, accuracy: 0.5)
            }
        } else {
            XCTAssertNil(v.narrowPhotoCaptionPlate(), "no picture, no caption")
        }
        // A layout with no photo has nothing to name.
        let mini = view(.macMiniM4, width: 400, height: 700)
        mini.isNarrow = true
        XCTAssertNil(mini.narrowPhotoCaptionPlate())
    }

    func testEveryFamilyPaintsWithoutAPicture() throws {
        // A smoke test: draw each family into a bitmap. The photo may or may not be found from here; either must work.
        for family in [MacFamily.macBookPro14ProMax, .macBookPro16ProMax, .macBookPro14Base, .macBookNeo, .macMiniM4, .generic] {
            let v = view(family, width: 400, height: 400)
            let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds), "\(family)")
            v.cacheDisplay(in: v.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0, "\(family)")
        }
    }

    func testAMissingPhotoIsNotAnError() {
        XCTAssertNil(HardwarePhoto.image(named: "no-such-picture"))
        XCTAssertNil(HardwarePhoto.image(named: "no-such-picture"))   // and the miss is remembered
    }
}
