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

    /// Tab moves on to the next chip (and Shift-Tab back), as it does in the system panel.
    func testTabCyclesTheChips() {
        XCTAssertEqual(action(48), .cycleFilter(1))
        XCTAssertEqual(action(48, .shift), .cycleFilter(-1))
        XCTAssertNil(action(48, .command))
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

    func testThePanelIsCentredAndItsTopEdgeIsAThirdOfTheWayDown() {
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

    /// What was measured on macOS 27.3's own panel stays what was measured: a change to these is a change of the likeness.
    func testTheMeasuredNumbersAreTheSystemPanelsOwn() {
        typealias M = ClipboardPanelMetrics
        XCTAssertEqual(M.width, 520)
        XCTAssertEqual(M.pillHeight, 87)
        XCTAssertEqual(M.gap, 10)
        XCTAssertEqual(M.cardMaxHeight, 410)
        XCTAssertEqual(M.rowHeight, 62)
        XCTAssertEqual(M.rowInset, 14.5)
        XCTAssertEqual(M.iconSize, 36)
        XCTAssertEqual(M.searchLeft, 39)
        XCTAssertEqual(M.topFraction, 0.30, accuracy: 0.001)
    }

    /// Black at the top of the bar and half that at its bottom; the card's is lighter, and lighter still at the bottom.
    func testTheBlackOverTheGlassFadesFromTopToBottom() {
        typealias M = ClipboardPanelMetrics
        XCTAssertEqual(M.pillTint.top, 1.0)
        XCTAssertLessThan(M.pillTint.bottom, M.pillTint.top)
        XCTAssertEqual(M.pillTint.bottom, 0.54, accuracy: 0.01)
        XCTAssertLessThan(M.cardTint.top, M.pillTint.bottom, "the card is lighter than the bar")
        XCTAssertLessThan(M.cardTint.bottom, M.cardTint.top)
    }

    /// Opacity read every few milliseconds on the system panel: about a tenth of a second in and the same out, evenly.
    func testItFadesInAndOutInAboutATenthOfASecond() {
        typealias M = ClipboardPanelMetrics
        XCTAssertEqual(M.fadeInDuration, 0.11, accuracy: 0.03)
        XCTAssertEqual(M.fadeOutDuration, 0.11, accuracy: 0.03)
    }

    func testTheCardIsAsTallAsItsRowsUpToTheMostAndIsNotThereForAnEmptyHistory() {
        typealias M = ClipboardPanelMetrics
        XCTAssertNil(M.cardHeight(rows: 0, hasQuery: false), "nothing typed and nothing kept: the bar alone")
        XCTAssertEqual(M.cardHeight(rows: 0, hasQuery: true), M.emptyCardHeight, "no match: a small card says so")
        XCTAssertEqual(M.cardHeight(rows: 2, hasQuery: false), M.rowsTop + 2 * M.rowHeight + M.bottomPadding)
        XCTAssertEqual(M.cardHeight(rows: 40, hasQuery: false), M.cardMaxHeight, "a long list scrolls inside the most it grows to")
    }

    func testThePanelIsTheBarAndUnderItTheGapAndTheCard() {
        typealias M = ClipboardPanelMetrics
        XCTAssertEqual(M.panelHeight(card: nil), M.pillHeight)
        XCTAssertEqual(M.panelHeight(card: 300), M.pillHeight + M.gap + 300)
        XCTAssertEqual(M.panelHeight(card: M.cardMaxHeight), 507, "the system panel's own full height, measured")
    }

    func testTheCaretIsAThickBarWithAGlow() {
        XCTAssertEqual(ClipboardFieldEditor.caretWidth, 2.5, accuracy: 0.5)
        XCTAssertGreaterThan(ClipboardFieldEditor.glowRadius, 0)
    }

    // ── The chips ───────────────────────────────────────────────────────────

    private func kindEntry(_ kind: ClipboardKind, pinned: Bool = false) -> ClipboardEntry {
        var e = entry("x", kind: kind)
        e.pinned = pinned
        return e
    }

    func testAChipIsOfferedOnlyForWhatIsThere() {
        let entries = [kindEntry(.text), kindEntry(.link), kindEntry(.text)]
        XCTAssertEqual(ClipboardFilter.available(in: entries), [.text, .link])
        XCTAssertEqual(ClipboardFilter.available(in: entries + [kindEntry(.image, pinned: true)]), [.text, .link, .image, .pinned])
        XCTAssertEqual(ClipboardFilter.available(in: []), [])
    }

    func testAChipNarrowsTheList() {
        let text = kindEntry(.text), link = kindEntry(.link), pinned = kindEntry(.text, pinned: true)
        let all = [text, link, pinned]
        XCTAssertEqual(ClipboardSearch.results(all, query: "", filter: .link).map(\.id), [link.id])
        XCTAssertEqual(ClipboardSearch.results(all, query: "", filter: .pinned).map(\.id), [pinned.id])
        XCTAssertEqual(Set(ClipboardSearch.results(all, query: "", filter: .text).map(\.id)), [text.id, pinned.id])
        XCTAssertEqual(ClipboardSearch.results(all, query: "", filter: nil).count, 3)
    }

    func testAChipSaysItsKindInTheWordsOfTheSystemsOwn() {
        XCTAssertEqual(ClipboardFilter.allCases.map(\.title), ["Text", "Links", "Images", "Files", "Pinned"])
    }

    func testAChipIsAButtonThatKnowsWhetherItIsOn() {
        _ = NSApplication.shared
        let off = ClipboardChipView(title: "Links", active: false), on = ClipboardChipView(title: "Links", active: true)
        XCTAssertFalse(off.isActive)
        XCTAssertTrue(on.isActive)
        XCTAssertGreaterThan(on.fittingWidth, 2 * ClipboardPanelMetrics.chipPadding)
        var clicked = false
        on.onClick = { clicked = true }
        on.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertTrue(clicked)
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
