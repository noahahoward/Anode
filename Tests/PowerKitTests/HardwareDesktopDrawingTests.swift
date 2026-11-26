import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The display drawn as a macOS desktop: the widget widths, the clock text, and that every reading shape paints.
final class HardwareDesktopDrawingTests: XCTestCase {

    private func canvas(readings: HardwareReadings?, widgets: [MenuBarWidgetText] = []) -> HardwareCanvasView {
        let v = HardwareCanvasView(layout: HardwareLayout.layout(for: .macBookPro14Base))
        v.frame = NSRect(x: 0, y: 0, width: 1100, height: 440)
        v.readings = readings
        v.menuBarWidgets = widgets
        return v
    }

    private var displayComponent: HardwareComponent {
        HardwareLayout.layout(for: .macBookPro14Base).components.first { $0.kind == .display }!
    }

    /// Draws the display into a 1100 x 440 bitmap and returns it.
    private func paint(_ v: HardwareCanvasView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 440,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let gc = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        v.drawDesktop(in: gc.cgContext, scale: 1, component: displayComponent)
        NSGraphicsContext.current = saved
        return rep
    }

    private func brightnessOf(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> CGFloat {
        let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return c.redComponent + c.greenComponent + c.blueComponent
    }

    func testAWidgetIsAtLeast24WideAndGrowsWithItsText() {
        XCTAssertEqual(HardwareCanvasView.menuWidgetWidth(MenuBarWidgetText(label: "CPU", value: "5%")), 24, accuracy: 0.001)
        // "Used/Charger" is 12 characters (4.0 each = 48) and its value is shorter (5 x 5.9 = 29.5): 48 + 5.
        XCTAssertEqual(HardwareCanvasView.menuWidgetWidth(MenuBarWidgetText(label: "Used/Charger", value: "9/70W")), 53, accuracy: 0.001)
        // The value can be the wider line: "+38%/hr" is 7 characters at 5.9 = 41.3, plus 5.
        XCTAssertEqual(HardwareCanvasView.menuWidgetWidth(MenuBarWidgetText(label: "Now", value: "+38%/hr")), 46.3, accuracy: 0.001)
        // No label: only the value counts.
        XCTAssertEqual(HardwareCanvasView.menuWidgetWidth(MenuBarWidgetText(label: nil, value: "12:00:00")), 52.2, accuracy: 0.001)
    }

    func testTheClockReadsLikeTheMenuBar() {
        // 1_795_358_460 is 2026-11-22 14:41:00 UTC, a Sunday: 20,779 days after 1970-01-01 (56 years of 365 days plus 14 leap
        // days = 20,454, plus 325 days into 2026) = 1,795,305,600 s, plus 14 h 41 min = 52,860 s. 20,779 mod 7 = 3, and
        // 1970-01-01 was a Thursday, so the day is a Sunday.
        let date = Date(timeIntervalSince1970: 1_795_358_460)
        let text = HardwareCanvasView.clockText(date, locale: Locale(identifier: "en_US_POSIX"),
                                                timeZone: TimeZone(identifier: "UTC"))
        XCTAssertEqual(text, "Sun 2:41 PM")
    }

    func testEveryReadingShapePaints() throws {
        let measured = DisplayReading(brightness: 0.6, watts: .real(1.4))
        let noBrightness = DisplayReading(brightness: nil, watts: .estimate(nil))
        let example = DisplayReading(brightness: 0.4, watts: Tagged(value: 2.5, provenance: .example))
        let battery = BatteryReading(percent: 64, tempC: 31, amps: 1.2, isCharging: true, state: .charging,
                                     timeRemainingMin: .estimate(40), health: 92, cycles: 100, designCycles: 1000,
                                     systemDrawW: .real(9))
        let widgets = [MenuBarWidgetText(label: "CPU", value: "5%"), MenuBarWidgetText(label: nil, value: "78%")]
        let history = HardwareHistory(capacity: 10)
        for d in [measured, noBrightness, example] {
            history.append(HardwareReadings(display: d))
        }
        for readings in [HardwareReadings(display: measured, helperInstalled: false),
                         HardwareReadings(battery: battery, display: noBrightness),
                         HardwareReadings(battery: battery, display: example),
                         HardwareReadings(),     // no display reading: no glass widget
                         nil] as [HardwareReadings?] {
            let v = canvas(readings: readings, widgets: widgets)
            v.history = history
            let rep = try paint(v)
            XCTAssertEqual(rep.pixelsWide, 1100)
        }
        // And with no widgets and no history at all.
        let bare = canvas(readings: HardwareReadings(display: measured))
        XCTAssertEqual(try paint(bare).pixelsHigh, 440)
    }

    func testTooManyWidgetsAndAGlassWidgetWithNoWattsStillPaint() throws {
        // Far more widgets than the bar has room for: the ones that would reach the Wi-Fi and battery icons are not drawn
        // (a drawing test: that it paints without trouble is what is checked here; the cut-off is the line in the drawer).
        let many = (0..<12).map { MenuBarWidgetText(label: "Widget \($0)", value: "\($0 * 11)%") }
        let noWatts = DisplayReading(brightness: 0.5, watts: .real(nil))
        let battery = BatteryReading(percent: 64, tempC: 31, amps: 1.2, isCharging: true, state: .charging,
                                     timeRemainingMin: .estimate(40), health: 92, cycles: 100, designCycles: 1000,
                                     systemDrawW: .real(9))
        let v = canvas(readings: HardwareReadings(battery: battery, display: noWatts), widgets: many)
        XCTAssertEqual(try paint(v).pixelsWide, 1100)
    }

    func testBrightnessReallyDimsThePicture() throws {
        let full = try paint(canvas(readings: HardwareReadings(display: DisplayReading(brightness: 1, watts: .real(1)))))
        let dark = try paint(canvas(readings: HardwareReadings(display: DisplayReading(brightness: 0, watts: .real(1)))))
        // A wallpaper point well clear of the menu bar, the notch and the glass widget.
        let lit = try brightnessOf(full, x: 150, y: 220)
        let dimmed = try brightnessOf(dark, x: 150, y: 220)
        XCTAssertGreaterThan(lit, dimmed + 0.05)
    }
}
