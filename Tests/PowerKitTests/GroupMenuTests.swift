import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The expandable menu-bar panel: every metric with its reading, built by
/// `MenuBarWidgetController.buildGroupMenu`.
///
/// Its rows are deliberately disabled — they are readings, not commands, and must
/// not highlight as clickable. Two rendering routes were tried before this one:
/// plain attributed titles (rendered wholesale in disabledControlTextColor), then
/// attributed titles with explicit colors (STILL dimmed — on this machine's macOS
/// the menu recolors a disabled item's entire title, named colors included; the
/// panel stayed gray through a fix that should have worked). Rows are therefore
/// custom VIEWS, the one surface AppKit renders untouched, in a straight
/// white-on-dark / black-on-light ink at full opacity — requested from the field
/// after two rounds of gray, and deliberately not the ~85 %-opacity `labelColor`.
///
/// These tests pin the route and the ink, because both regressions arrive
/// silently: a revert to attributed titles compiles, passes every other test,
/// and shows up only as a gray panel on a screen someone happens to look at.
final class GroupMenuTests: XCTestCase {

    private func buildMenu() -> NSMenu { MenuBarWidgetController.buildGroupMenu() }

    /// Rows are the items with a tab in the title (name TAB value — also what
    /// VoiceOver reads); headers are bare category words.
    private func rows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && $0.title.contains("\t") }
    }

    private func headers(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && !$0.title.contains("\t") }
    }

    private func resolved(_ color: NSColor, in appearanceName: NSAppearance.Name) -> NSColor? {
        var out: NSColor?
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out
    }

    /// The regression this file exists for: every row must render through a
    /// view, because any attributed-title route hands the ink back to the
    /// menu's disabled-item dimming.
    func testEveryRowRendersThroughAViewAppKitCannotDim() {
        let rows = rows(buildMenu())
        XCTAssertGreaterThan(rows.count, 5,
                             "an empty menu would pass every per-row assertion "
                             + "below vacuously")
        for row in rows {
            let view = row.view as? MetricRowView
            XCTAssertNotNil(view, "\"\(row.title)\" has no MetricRowView: its text "
                            + "is back in the menu's dimmed rendering path")
            guard let view else { continue }
            XCTAssertFalse(view.allowsVibrancy,
                           "vibrancy desaturates the ink into the menu material")
        }
    }

    /// The ink itself: straight white on dark, straight black on light, full
    /// opacity both ways. `labelColor` would compile and look almost right — and
    /// is exactly the ~85 % gray the field report complained about.
    func testRowInkIsStraightWhiteOnDarkAndBlackOnLight() {
        for (appearance, want): (NSAppearance.Name, CGFloat) in
            [(.darkAqua, 1), (.aqua, 0)] {
            guard let c = resolved(MenuBarWidgetController.rowInk, in: appearance) else {
                XCTFail("row ink did not resolve in \(appearance.rawValue)"); continue
            }
            for component in [c.redComponent, c.greenComponent, c.blueComponent] {
                XCTAssertEqual(component, want, accuracy: 0.01,
                               "row ink in \(appearance.rawValue) is not straight")
            }
            XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.001,
                           "row ink in \(appearance.rawValue) is not full opacity")
        }
    }

    /// Every row's fields carry that ink — a reading in the straight ink, a
    /// missing reading (the em-dash placeholder) at 45 % of the same ink, so it
    /// dims relative to its row and not into the menu material.
    func testRowFieldsCarryTheStraightInk() {
        for row in rows(buildMenu()) {
            guard let view = row.view as? MetricRowView else { continue }
            XCTAssertEqual(view.nameField.textColor, MenuBarWidgetController.rowInk,
                           "name of \"\(row.title)\" lost the straight ink")
            let expected = view.valueField.stringValue == "\u{2014}"
                ? MenuBarWidgetController.placeholderInk
                : MenuBarWidgetController.rowInk
            XCTAssertEqual(view.valueField.textColor, expected,
                           "value of \"\(row.title)\" has the wrong ink")
        }
    }

    /// Section headers stay on the system convention (`secondaryLabelColor`
    /// attributed titles): they are labels for structure, not readings, and the
    /// field complaint was about the rows.
    func testHeadersKeepTheSystemConvention() {
        let headers = headers(buildMenu())
        XCTAssertGreaterThan(headers.count, 3)
        for header in headers {
            guard let a = header.attributedTitle, a.length > 0 else {
                XCTFail("header \"\(header.title)\" has no attributed title"); continue
            }
            let c = a.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            XCTAssertEqual(c, NSColor.secondaryLabelColor,
                           "header \"\(header.title)\" lost its section-header color")
        }
    }

    /// Rows stay disabled: they are readings, not commands. The view carries the
    /// ink, so disabling costs nothing — and enabled rows would highlight on
    /// hover and read as buttons that do nothing.
    func testRowsRemainDisabled() {
        for item in buildMenu().items where !item.isSeparatorItem {
            XCTAssertFalse(item.isEnabled, "\"\(item.title)\" became enabled")
        }
    }
}
