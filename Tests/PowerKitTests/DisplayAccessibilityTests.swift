import XCTest
@testable import PowerKit

/// What the Sound and Battery menus do when the person has turned on Reduce Transparency, Increase Contrast or Reduce Motion in
/// System Settings > Accessibility > Display. macOS's own panels follow all three; these are the decisions, apart from the drawing.
final class DisplayAccessibilityTests: XCTestCase {

    private let plain = DisplayAccessibility()

    func testWithNothingTurnedOnTheMenusAreAsTheyWere() {
        XCTAssertFalse(plain.glassIsSolid)
        XCTAssertEqual(plain.fadeSeconds(0.24), 0.24)
        XCTAssertTrue(plain.animates)
        XCTAssertEqual(plain.dividerAlpha, 0.15)
        XCTAssertEqual(plain.secondaryTextAlpha(dark: 0.40, light: 0.42, isDark: true), 0.40)
        XCTAssertEqual(plain.secondaryTextAlpha(dark: 0.40, light: 0.42, isDark: false), 0.42)
    }

    func testReduceTransparencyMakesTheGlassSolid() {
        XCTAssertTrue(DisplayAccessibility(reduceTransparency: true).glassIsSolid)
    }

    func testReduceMotionRemovesTheFadeAndTheSprings() {
        let still = DisplayAccessibility(reduceMotion: true)
        XCTAssertEqual(still.fadeSeconds(0.24), 0, "the menu goes at once")
        XCTAssertFalse(still.animates)
    }

    func testIncreaseContrastMakesLinesAndSecondaryTextStronger() {
        let strong = DisplayAccessibility(increaseContrast: true)
        XCTAssertGreaterThan(strong.dividerAlpha, plain.dividerAlpha)
        XCTAssertGreaterThan(strong.secondaryTextAlpha(dark: 0.40, light: 0.42, isDark: true), 0.40)
        XCTAssertGreaterThan(strong.secondaryTextAlpha(dark: 0.40, light: 0.42, isDark: false), 0.42)
        XCTAssertLessThanOrEqual(strong.secondaryTextAlpha(dark: 0.40, light: 0.42, isDark: true), 1)
    }

    func testTheThreeAreIndependent() {
        let t = DisplayAccessibility(reduceTransparency: true)
        XCTAssertTrue(t.animates); XCTAssertEqual(t.dividerAlpha, 0.15)
        let m = DisplayAccessibility(reduceMotion: true)
        XCTAssertFalse(m.glassIsSolid)
    }
}
