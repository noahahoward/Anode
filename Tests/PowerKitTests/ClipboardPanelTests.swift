import XCTest
import AppKit
@testable import PowerKit
@testable import AnodeApp

/// The parts of the Clipboard History panel that can be decided without a screen: what each key does, where the panel sits, how a
/// row reads, the black fade, and the choices of the section.
final class ClipboardPanelTests: XCTestCase {

    private func action(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], _ chars: String? = nil) -> ClipboardPanel.KeyAction? {
        ClipboardPanel.action(keyCode: code, modifiers: mods, characters: chars)
    }

    // ── Keys ────────────────────────────────────────────────────────────────

    func testTheArrowsMoveAndThePageKeysMoveFive() {
        // A real arrow key carries the numeric-pad and function flags: they are not a modifier anybody chose.
        XCTAssertEqual(action(126, [.numericPad, .function]), .move(-1))
        XCTAssertEqual(action(125, [.numericPad, .function]), .move(1))
        XCTAssertEqual(action(116), .move(-5))
        XCTAssertEqual(action(121), .move(5))
        XCTAssertNil(action(125, .command), "⌘↓ is not ours")
    }

    func testReturnPastesOptionOrShiftReturnPastesPlainAndCommandReturnOnlyCopies() {
        XCTAssertEqual(action(36), .choose(.paste))
        XCTAssertEqual(action(76), .choose(.paste), "the keypad's Enter too")
        XCTAssertEqual(action(36, .option), .choose(.plainText))
        XCTAssertEqual(action(36, .shift), .choose(.plainText))
        XCTAssertEqual(action(36, .command), .choose(.copyOnly))
        XCTAssertNil(action(36, [.command, .option]), "a combination that means nothing here is left to the field")
    }

    func testCommandDigitsChooseTheRowAndTheOtherCommandKeysDeleteAndPin() {
        for n in 1...9 { XCTAssertEqual(action(0, .command, "\(n)"), .chooseRow(n - 1), "⌘\(n)") }
        XCTAssertNil(action(0, .command, "0"))
        XCTAssertNil(action(0, [], "1"), "a bare digit is typed into the search")
        XCTAssertEqual(action(51, .command), .delete)
        XCTAssertNil(action(51), "a bare delete edits the search text")
        XCTAssertEqual(action(35, .command), .pin)
        XCTAssertNil(action(35), "a bare P is typed")
    }

    func testEscapeIsEscapeAndOnlyWithNoModifier() {
        XCTAssertEqual(action(53), .escape)
        XCTAssertNil(action(53, .command))
    }

    func testCapsLockChangesNothing() {
        XCTAssertEqual(action(36, .capsLock), .choose(.paste))
        XCTAssertEqual(action(0, [.command, .capsLock], "3"), .chooseRow(2))
    }

    // ── Where it sits ───────────────────────────────────────────────────────

    func testThePanelIsCentredAndItsTopEdgeIsAFifthOfTheWayDown() {
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1130)
        let f = ClipboardPanel.frame(height: 200, in: visible)
        XCTAssertEqual(f.midX, visible.midX, accuracy: 0.01)
        XCTAssertEqual(f.width, ClipboardPanelMetrics.width)
        XCTAssertEqual(visible.maxY - f.maxY, visible.height * ClipboardPanelMetrics.topFraction, accuracy: 0.01)
        XCTAssertEqual(f.height, 200)
    }

    func testOnASecondDisplayItSitsInThatDisplaysOwnVisibleArea() {
        let visible = NSRect(x: 1800, y: 100, width: 1440, height: 800)
        let f = ClipboardPanel.frame(height: 300, in: visible)
        XCTAssertEqual(f.midX, visible.midX, accuracy: 0.01)
        XCTAssertGreaterThan(f.minX, 1800)
        XCTAssertLessThan(f.maxY, visible.maxY)
    }

    // ── Rows ────────────────────────────────────────────────────────────────

    private func entry(_ preview: String, kind: ClipboardKind = .text, detail: String? = nil, source: String? = "Editor",
                       date: Date = Date()) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), kind: kind, text: preview, preview: preview, detail: detail, parts: [], date: date, pinned: false,
                       sourceBundleID: nil, sourceName: source, byteSize: 1, fingerprint: UUID().uuidString)
    }

    func testARowSaysWhatItIsWhereItCameFromAndHowLongAgo() {
        let now = Date()
        let row = ClipboardRowModel.make(entry("hello", detail: "3 lines", date: now.addingTimeInterval(-300)), index: 0, now: now)
        XCTAssertEqual(row.title, "hello")
        XCTAssertEqual(row.subtitle, "3 lines · Editor · 5 min ago")
        XCTAssertEqual(row.hint, "⌘1")
    }

    func testOnlyTheFirstNineRowsHaveANumber() {
        XCTAssertEqual(ClipboardRowModel.make(entry("x"), index: 8).hint, "⌘9")
        XCTAssertNil(ClipboardRowModel.make(entry("x"), index: 9).hint)
    }

    func testARowWithNothingToSayStillHasAWordAndNoStraySeparator() {
        let row = ClipboardRowModel.make(entry("", kind: .image, source: nil), index: 0)
        XCTAssertEqual(row.title, "Image")
        XCTAssertEqual(row.subtitle, "now", "no source and no detail: no dangling dots")
    }

    // ── The look ────────────────────────────────────────────────────────────

    /// The fade is black at the top and the darker of the two in a dark appearance; it is only a hint in a light one, so the search
    /// text stays readable.
    func testTheBlackFadeIsStrongerInTheDarkAppearance() {
        XCTAssertEqual(ClipboardFadeView.topAlpha(dark: true), ClipboardPanelMetrics.fadeAlphaDark)
        XCTAssertEqual(ClipboardFadeView.topAlpha(dark: false), ClipboardPanelMetrics.fadeAlphaLight)
        XCTAssertGreaterThan(ClipboardFadeView.topAlpha(dark: true), ClipboardFadeView.topAlpha(dark: false))
        XCTAssertLessThan(ClipboardFadeView.topAlpha(dark: false), 0.35)
    }

    func testTheFadeTakesNoClicks() {
        _ = NSApplication.shared
        let fade = ClipboardFadeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(fade.hitTest(NSPoint(x: 50, y: 50)))
    }

    /// The panel's own size is its search row, a divider, its rows (at most eight, then it scrolls) and the footer.
    func testTheMetricsAreWhatTheLayoutIsBuiltFrom() {
        typealias M = ClipboardPanelMetrics
        XCTAssertEqual(M.width, 680)
        XCTAssertEqual(M.maxVisibleRows, 8)
        XCTAssertGreaterThan(M.fadeInDuration, M.fadeOutDuration, "it comes in a little slower than it goes")
        XCTAssertLessThan(M.fadeInDuration, 0.4)
    }

    // ── The section ─────────────────────────────────────────────────────────

    func testTheKeepChoicesIncludeForeverAndAStoredValueFindsItsNearest() {
        XCTAssertEqual(ClipboardKeepChoices.all.map(\.minutes), [30, 60, 480, 1440, 10_080, 43_200, 129_600, 0])
        XCTAssertEqual(ClipboardKeepChoices.all.last?.title, "Forever")
        XCTAssertEqual(ClipboardKeepChoices.index(forMinutes: 1440), 3)
        XCTAssertEqual(ClipboardKeepChoices.index(forMinutes: 0), 7, "0 is for ever")
        XCTAssertEqual(ClipboardKeepChoices.index(forMinutes: 1500), 3, "set by hand to a number the popup lacks: the nearest")
        XCTAssertEqual(ClipboardKeepChoices.index(forMinutes: 525_600), 6)
    }

    func testTheSectionIsInTheBetaFeaturesList() {
        let settings = Settings(defaults: TestDefaults.throwaway("clipboardFeatureList"))
        let titles = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false, settings: settings).map(\.title)
        XCTAssertTrue(titles.contains("Clipboard History"), "\(titles)")
        XCTAssertEqual(titles.filter { $0 == "Clipboard History" }.count, 1)
    }

    func testTheSectionShowsTheStateOfTheSettings() {
        _ = NSApplication.shared
        let settings = Settings(defaults: TestDefaults.throwaway("clipboardFeature"))
        let feature = ClipboardHistoryFeature(settings: settings, accessibility: { true })
        _ = feature.makeView()
        XCTAssertEqual(feature.enableCheckbox.state, .off)
        XCTAssertFalse(feature.keepPopup.isEnabled, "nothing to set while it is off")
        XCTAssertEqual(feature.keepPopup.indexOfSelectedItem, 3, "a day, by default")
        XCTAssertEqual(feature.maxLabel.stringValue, "500 entries")
        settings.clipboardHistoryEnabled = true
        settings.clipboardHistoryKeepMinutes = 10_080
        settings.clipboardHistoryMaxEntries = 120
        feature.refresh()
        XCTAssertEqual(feature.enableCheckbox.state, .on)
        XCTAssertTrue(feature.keepPopup.isEnabled)
        XCTAssertEqual(feature.keepPopup.indexOfSelectedItem, 4)
        XCTAssertEqual(feature.maxLabel.stringValue, "120 entries")
        XCTAssertTrue(feature.shortcutLabel.stringValue.contains("🌐Space"), feature.shortcutLabel.stringValue)
        XCTAssertTrue(feature.accessibilityLabel.isHidden, "Accessibility is there: nothing to ask")
    }

    func testTheSectionAsksForAccessibilityWhenItIsMissing() {
        _ = NSApplication.shared
        let settings = Settings(defaults: TestDefaults.throwaway("clipboardFeatureAX"))
        settings.clipboardHistoryEnabled = true
        let feature = ClipboardHistoryFeature(settings: settings, accessibility: { false })
        _ = feature.makeView()
        XCTAssertFalse(feature.accessibilityLabel.isHidden)
        XCTAssertFalse(feature.accessibilityButton.isHidden)
        XCTAssertTrue(feature.openButton.isEnabled, "recording and the Open button need no Accessibility")
    }

    func testTheSectionWritesItsControlsToTheSettings() {
        _ = NSApplication.shared
        let settings = Settings(defaults: TestDefaults.throwaway("clipboardFeatureWrites"))
        settings.clipboardHistoryEnabled = true
        let feature = ClipboardHistoryFeature(settings: settings, accessibility: { true })
        _ = feature.makeView()
        feature.keepPopup.selectItem(at: 7)
        _ = feature.keepPopup.target?.perform(feature.keepPopup.action, with: feature.keepPopup)
        XCTAssertEqual(settings.clipboardHistoryKeepMinutes, 0)
        feature.pauseCheckbox.state = .on
        _ = feature.pauseCheckbox.target?.perform(feature.pauseCheckbox.action, with: feature.pauseCheckbox)
        XCTAssertTrue(settings.clipboardHistoryPaused)
        feature.imagesCheckbox.state = .off
        _ = feature.imagesCheckbox.target?.perform(feature.imagesCheckbox.action, with: feature.imagesCheckbox)
        XCTAssertFalse(settings.clipboardHistoryKeepImages)
    }
}
