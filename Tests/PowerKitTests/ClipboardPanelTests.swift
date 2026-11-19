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

    func testThePanelOpensCentredWithItsTopWhereTheSystemsDoes() {
        // The system's panel, on a 1800 x 1169 screen: x 640, top edge 282 down from the screen's top.
        let screen = NSRect(x: 0, y: 0, width: 1800, height: 1169)
        let f = ClipboardPlacement.defaultFrame(height: 200, on: screen)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(f.minX, 640, accuracy: 0.01)
        XCTAssertEqual(f.width, ClipboardPanelMetrics.width)
        XCTAssertEqual(screen.maxY - f.maxY, 282, accuracy: 0.5)
        XCTAssertEqual(f.height, 200)
    }

    func testTheTopEdgeStaysPutWhateverTheHeight() {
        let screen = NSRect(x: 0, y: 0, width: 1800, height: 1169)
        XCTAssertEqual(ClipboardPlacement.defaultFrame(height: 87, on: screen).maxY, ClipboardPlacement.defaultFrame(height: 507, on: screen).maxY)
    }

    func testOnASecondDisplayItSitsInThatDisplaysOwnArea() {
        let screen = NSRect(x: 1800, y: 100, width: 1440, height: 800)
        let f = ClipboardPlacement.defaultFrame(height: 300, on: screen)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 0.01)
        XCTAssertGreaterThan(f.minX, 1800)
        XCTAssertLessThan(f.maxY, screen.maxY)
    }

    // ── Dragging ────────────────────────────────────────────────────────────

    private let screen = NSRect(x: 0, y: 0, width: 1800, height: 1169)
    private var visible: NSRect { NSRect(x: 0, y: 0, width: 1800, height: 1130) }

    private func drag(height: CGFloat = 311, from: NSRect? = nil) -> (ClipboardPlacement.Drag, NSPoint) {
        let panel = from ?? ClipboardPlacement.defaultFrame(height: height, on: screen)
        let pointer = NSPoint(x: panel.minX + 200, y: panel.maxY - 12)
        return (ClipboardPlacement.Drag(panel: panel, pointer: pointer, screen: screen, visible: visible), pointer)
    }

    func testADragFollowsThePointerOneForOne() {
        var (d, p) = drag(from: NSRect(x: 300, y: 500, width: 520, height: 311))
        d.moved(to: NSPoint(x: p.x + 100, y: p.y - 60))
        XCTAssertEqual(d.frame.minX, 400, accuracy: 0.01)
        XCTAssertEqual(d.frame.minY, 440, accuracy: 0.01)
    }

    func testItCatchesOnTheMiddleWithinAFewPointsAndTicks() {
        var (d, p) = drag(from: NSRect(x: 400, y: 600, width: 520, height: 311))
        XCTAssertFalse(d.moved(to: NSPoint(x: p.x + 220, y: p.y)), "20 points short of the middle: free")
        XCTAssertEqual(d.frame.minX, 620, accuracy: 0.01)
        XCTAssertTrue(d.moved(to: NSPoint(x: p.x + 237, y: p.y)), "3 points short: caught")
        XCTAssertEqual(d.frame.minX, 640, accuracy: 0.01)
        XCTAssertFalse(d.moved(to: NSPoint(x: p.x + 238, y: p.y)), "no second tick while it is held")
    }

    func testItHoldsTheMiddleUntilPulledAwayThenLetsGo() {
        var (d, p) = drag(from: NSRect(x: 640, y: 600, width: 520, height: 311))
        d.moved(to: NSPoint(x: p.x + 2, y: p.y))                      // caught at once, 2 points off
        XCTAssertEqual(d.frame.minX, 640, accuracy: 0.01)
        d.moved(to: NSPoint(x: p.x + 20, y: p.y))
        XCTAssertEqual(d.frame.minX, 640, accuracy: 0.01, "20 points away: still held (let go beyond 24)")
        d.moved(to: NSPoint(x: p.x + 26, y: p.y))
        XCTAssertEqual(d.frame.minX, 666, accuracy: 0.01, "26 points away: free, and it jumps to the pointer")
        XCTAssertFalse(d.moved(to: NSPoint(x: p.x + 22, y: p.y)), "coming back to 22 away does not catch again (5 points does)")
        XCTAssertEqual(d.frame.minX, 662, accuracy: 0.01)
    }

    func testItCatchesOnTheDefaultHeightAndHoldsItLessFar() {
        let top = ClipboardPlacement.defaultFrame(height: 311, on: screen).maxY
        var (d, p) = drag(from: NSRect(x: 100, y: top - 311 - 80, width: 520, height: 311))      // 80 points below the default
        XCTAssertFalse(d.moved(to: NSPoint(x: p.x, y: p.y + 60)), "20 points below it: free")
        XCTAssertTrue(d.moved(to: NSPoint(x: p.x, y: p.y + 77)), "3 points below it: caught")
        XCTAssertEqual(d.frame.maxY, top, accuracy: 0.01)
        d.moved(to: NSPoint(x: p.x, y: p.y + 90))                       // 10 above: held
        XCTAssertEqual(d.frame.maxY, top, accuracy: 0.01)
        d.moved(to: NSPoint(x: p.x, y: p.y + 100))                      // 20 above: let go (16)
        XCTAssertEqual(d.frame.maxY, top + 20, accuracy: 0.01)
    }

    func testItStopsAtTheScreensEdgesAndComesBackWhenThePointerDoes() {
        var (d, p) = drag(from: NSRect(x: 1200, y: 600, width: 520, height: 311))
        d.moved(to: NSPoint(x: p.x + 500, y: p.y))
        XCTAssertEqual(d.frame.maxX, 1800, accuracy: 0.01, "against the right edge")
        d.moved(to: NSPoint(x: p.x + 250, y: p.y))
        XCTAssertEqual(d.frame.maxX, 1800, accuracy: 0.01, "the pointer is still past where it would be")
        d.moved(to: NSPoint(x: p.x + 40, y: p.y))
        XCTAssertEqual(d.frame.minX, 1240, accuracy: 0.01, "now it follows again")
        d.moved(to: NSPoint(x: p.x - 2000, y: p.y))
        XCTAssertEqual(d.frame.minX, 0, accuracy: 0.01)
    }

    func testItStopsUnderTheMenuBarAndAboveTheBottom() {
        var (d, p) = drag(from: NSRect(x: 100, y: 600, width: 520, height: 311))
        d.moved(to: NSPoint(x: p.x, y: p.y + 2000))
        XCTAssertEqual(d.frame.maxY, 1130, accuracy: 0.01, "the top edge at the menu bar")
        d.moved(to: NSPoint(x: p.x, y: p.y - 2000))
        XCTAssertEqual(d.frame.minY, 0, accuracy: 0.01, "the bottom edge at the bottom of the screen")
    }

    func testItOpensWhereItWasLeft() {
        let left = NSRect(x: 300, y: 500, width: 520, height: 311)
        let offset = ClipboardPlacement.offset(of: left, on: screen)
        let again = ClipboardPlacement.opening(height: 137, screen: screen, visible: visible, remembered: offset)
        XCTAssertEqual(again.minX, 300, accuracy: 0.01)
        XCTAssertEqual(again.maxY, left.maxY, accuracy: 0.01, "the top edge, whatever the height now")
        XCTAssertEqual(ClipboardPlacement.opening(height: 137, screen: screen, visible: visible, remembered: .zero),
                       ClipboardPlacement.defaultFrame(height: 137, on: screen))
    }

    func testWhatIsRememberedIsKeptInsideTheScreenItOpensOn() {
        let far = CGSize(width: 5000, height: 5000)
        let f = ClipboardPlacement.opening(height: 200, screen: screen, visible: visible, remembered: far)
        XCTAssertLessThanOrEqual(f.maxX, 1800)
        XCTAssertLessThanOrEqual(f.maxY, 1130)
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
        XCTAssertEqual(ClipboardPlacement.centreFraction, 0.30)
        XCTAssertEqual(ClipboardPlacement.referenceHeight, 137, "the system's window with nothing typed: the bar and 50 points")
    }

    /// The tint over the glass was fitted to the system panel's measured transparency over a black and white striped backdrop: the bar
    /// is fully black at its top and lets about a third of the backdrop through at its bottom; the card lets a third through at its
    /// top and a half at its bottom. Each shape has a rim of its own where the system's does: the bar at its bottom edge only.
    func testTheTintIsBlackAtTheTopOfTheBarAndLightensDownTheBarAndTheCard() {
        typealias M = ClipboardPanelMetrics
        let bar = M.tintStops(card: false, height: 87)
        XCTAssertEqual(bar.first?.alpha, 1.0, "fully opaque black at the top: nothing of the backdrop")
        XCTAssertEqual(bar.first?.gray, 0)
        XCTAssertEqual(bar.first { $0.y == 87 - 6 }!.alpha, M.barTintAlpha(81, height: 87), accuracy: 0.001)
        XCTAssertEqual(M.barTintAlpha(87, height: 87), 0.61, accuracy: 0.001, "0.61 at the bottom: it is what lets 0.31 of the backdrop through")
        XCTAssertEqual(bar.last?.gray, 1.0, "the rim along the bar's bottom edge is light")
        XCTAssertEqual(bar.last?.y, 87)
        XCTAssertFalse(bar.dropFirst().prefix(2).contains { $0.gray > 0.5 }, "no rim along the bar's top")

        let card = M.tintStops(card: true, height: 410)
        XCTAssertGreaterThan(card.first?.gray ?? 0, 0.5, "a bright rim along the card's top")
        let cardTop = card.first { $0.y == 6 }!
        XCTAssertEqual(cardTop.alpha, 0.55, accuracy: 0.01)
        XCTAssertEqual(cardTop.gray, 0)
        let cardBottom = card.first { $0.y == 410 - 6 }!
        XCTAssertEqual(cardBottom.alpha, 0.55 - 0.252 * (404.0 / 410), accuracy: 0.01)
        XCTAssertLessThan(cardBottom.alpha, cardTop.alpha, "lighter, more of the backdrop, lower down")
        XCTAssertEqual(card.last?.gray, 1.0, "a rim along the card's bottom too")
    }

    /// The rims are hard steps of a pixel or two: stops at the same place with different colours. Every stop is inside the shape.
    func testTheRimsAreStepsAtTheEdgesAndTheStopsStayInsideTheShape() {
        for (card, height) in [(false, CGFloat(87)), (true, 410), (true, 200), (true, 96)] {
            let stops = ClipboardPanelMetrics.tintStops(card: card, height: height)
            let places = stops.map { $0.y < 0 ? height + $0.y : $0.y }
            XCTAssertEqual(places, places.sorted(), "in order, so the gradient is what is meant (card \(card), \(height))")
            XCTAssertTrue(places.allSatisfy { $0 >= 0 && $0 <= height }, "inside the shape (card \(card), \(height))")
        }
        let bar = ClipboardPanelMetrics.tintStops(card: false, height: 87)
        XCTAssertEqual(bar.filter { $0.y == -0.5 }.count, 2, "a step between the last two pixels")
    }

    /// A short card (few entries) is the same curve cut off where it ends, not stretched.
    func testAShortCardIsTheSameCurveCutShort() {
        typealias M = ClipboardPanelMetrics
        let tall = M.tintStops(card: true, height: 410)
        let short = M.tintStops(card: true, height: 200)
        XCTAssertEqual(tall.first { $0.y == 6 }!.alpha, short.first { $0.y == 6 }!.alpha, accuracy: 0.001)
        XCTAssertGreaterThan(short.first { $0.y == 200 - 6 }!.alpha, tall.first { $0.y == 410 - 6 }!.alpha, "it has not got as far down the curve")
    }

    /// The system's panel casts a much darker and wider shadow than a window's own: it is drawn in a margin round the panel.
    func testTheShadowIsDrawnInAMarginRoundThePanel() {
        typealias M = ClipboardPanelMetrics
        let panel = NSRect(x: 640, y: 400, width: M.width, height: 300)
        let window = ClipboardPanel.windowFrame(forPanel: panel)
        XCTAssertEqual(window.width, M.width + 2 * M.shadowMargin)
        XCTAssertEqual(window.height, 300 + 2 * M.shadowMargin)
        XCTAssertEqual(window.midX, panel.midX, accuracy: 0.001)
        XCTAssertEqual(window.midY, panel.midY, accuracy: 0.001)
        XCTAssertGreaterThan(M.shadowMargin, M.shadowRadius, "the margin holds the whole blur")
        XCTAssertGreaterThan(M.shadowOpacity, 0.5)
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

    /// The crash: the field editor was made at launch and trapped in `init(frame:textContainer:)`, taking the whole app with it.
    func testTheFieldEditorAndThePanelCanBeMadeAndKeepWhatIsTyped() {
        _ = NSApplication.shared
        let editor = ClipboardFieldEditor()
        XCTAssertTrue(editor.isFieldEditor)
        editor.string = "typed"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(editor.string, "typed", "an editor with no text system keeps nothing")
        XCTAssertNotNil(ClipboardFieldEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 20)).textContainer)
        let panel = ClipboardPanel()
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpen)
    }

    /// Nothing of the window is made until the panel is first opened: with the feature off, launching makes none of it.
    func testThePanelIsMadeOnlyWhenFirstOpened() {
        let lazy = LazyClipboardPanel()
        XCTAssertFalse(lazy.isOpen)
        var done = false
        lazy.hide { done = true }
        XCTAssertTrue(done, "putting away a panel that was never made answers at once")
        lazy.refresh()
    }

    /// The window is bigger than the panel, for the shadow: only the bar and the card are the panel. A click anywhere else in the window
    /// (the margin, the gap between them) is a click away from it.
    func testOnlyTheBarAndTheCardAreThePanelAndTheMarginAndTheGapAreNot() {
        _ = NSApplication.shared
        typealias M = ClipboardPanelMetrics
        let content = ClipboardContentView()
        let host = ClipboardShadowHost(content: content)
        host.frame = NSRect(x: 0, y: 0, width: M.width + 2 * M.shadowMargin, height: M.pillHeight + 2 * M.shadowMargin)
        host.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        let bar = host.shapeRectsInHost().first!.rect
        XCTAssertEqual(bar.width, M.width)
        XCTAssertEqual(bar.height, M.pillHeight)
        XCTAssertTrue(host.isOnAShape(NSPoint(x: bar.midX, y: bar.midY)))
        XCTAssertFalse(host.isOnAShape(NSPoint(x: 10, y: 10)), "the shadow's margin is not the panel")
        XCTAssertFalse(host.isOnAShape(NSPoint(x: bar.midX, y: bar.minY - 5)), "just under the bar")
        XCTAssertFalse(host.isOnAShape(NSPoint(x: bar.minX - 5, y: bar.midY)), "just beside it")
        XCTAssertEqual(host.shapeRectsInHost().count, 1, "no card: nothing was listed or typed")
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
