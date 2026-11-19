import XCTest
@testable import PowerKit

/// macOS's Adaptive Audio slider can only be moved by a real drag on macOS's own panel (measured). So while the pointer is over the
/// slider in Anode's menu, macOS's panel is opened under it, moved so its slider lies exactly under Anode's, and Anode's menu lets the
/// pointer through there: the drag is on macOS's slider itself. Measured in a throwaway test (2026-11-18): the panel can be moved and its
/// slider moves with it; a drag through a hole in a window above it moves the knob; a click anywhere else closes macOS's panel. So it
/// is opened only while the pointer is on the slider, and put away as it leaves.
final class AdaptiveSliderArmingTests: XCTestCase {

    // ── Where macOS's panel goes ────────────────────────────────────────────

    func testThePanelIsMovedByWhatPutsItsLeftIconOnAnodes() {
        // Top-left global points. macOS's left end icon at (1328, 293); Anode draws its own at (1371, 413).
        let d = AdaptiveSliderAlignment.offset(macLeftIcon: CGRect(x: 1328, y: 293, width: 11, height: 11),
                                               anodeLeftIcon: CGRect(x: 1371, y: 413, width: 11, height: 11))
        XCTAssertEqual(d.dx, 43); XCTAssertEqual(d.dy, 120)
    }

    func testItCountsAsInPlaceWithinThreeQuartersOfAPoint() {
        let anode = CGRect(x: 1371, y: 413, width: 11, height: 11)
        XCTAssertTrue(AdaptiveSliderAlignment.inPlace(macLeftIcon: anode.offsetBy(dx: 0.5, dy: -0.5), anodeLeftIcon: anode))
        XCTAssertFalse(AdaptiveSliderAlignment.inPlace(macLeftIcon: anode.offsetBy(dx: 0, dy: 2), anodeLeftIcon: anode))
    }

    func testTheLevelOfThePicturesIsReadAsTheMenuReadsIt() {
        XCTAssertEqual(AppleSoundPanel.adaptiveLevel(pictures: [CGRect(x: 1328, y: 293, width: 11, height: 11),
                                                               CGRect(x: 1415, y: 286.5, width: 40, height: 24),
                                                               CGRect(x: 1531, y: 293, width: 11, height: 11)]) ?? -1, 0.5, accuracy: 0.001)
    }

    // ── When it is opened and put away ──────────────────────────────────────

    func testThePointerOnTheSliderOpensItOnce() {
        var a = AdaptiveSliderArming()
        XCTAssertEqual(a.pointerEntered(), .arm)
        XCTAssertEqual(a.pointerEntered(), .none, "already on its way")
        XCTAssertEqual(a.state, .arming)
    }

    func testWhenItIsInPlaceTheHoleOpens() {
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered()
        XCTAssertEqual(a.armFinished(ok: true, pointerInside: true), .showHole)
        XCTAssertEqual(a.state, .armed)
    }

    func testThePointerGoneByTheTimeItIsInPlacePutsItAway() {
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered()
        XCTAssertEqual(a.armFinished(ok: true, pointerInside: false), .disarm)
        XCTAssertEqual(a.state, .idle)
    }

    func testWhenItCouldNotBePutInPlaceItIsNotTriedAgainThisOpening() {
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered()
        XCTAssertEqual(a.armFinished(ok: false, pointerInside: true), .none)
        XCTAssertEqual(a.state, .failed)
        XCTAssertEqual(a.pointerEntered(), .none, "no loop of tries while the pointer wanders on and off it")
        XCTAssertTrue(a.handsOverOnPress, "a press then opens macOS's own menu, as before")
    }

    func testWhileItIsOutItStaysAsLongAsThePointerIsOnItOrTheButtonIsDown() {
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered(); _ = a.armFinished(ok: true, pointerInside: true)
        XCTAssertEqual(a.tick(pointerInside: true, buttonDown: false, panelOpen: true), .none)
        XCTAssertEqual(a.tick(pointerInside: false, buttonDown: true, panelOpen: true), .none, "a drag that strays off the row")
        XCTAssertEqual(a.tick(pointerInside: false, buttonDown: false, panelOpen: true), .disarm)
        XCTAssertEqual(a.state, .idle)
    }

    func testMacOSClosingItsPanelPutsTheHoleAway() {
        // A click anywhere else closes macOS's panel (measured): the hole must not stay open on nothing.
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered(); _ = a.armFinished(ok: true, pointerInside: true)
        XCTAssertEqual(a.tick(pointerInside: true, buttonDown: false, panelOpen: false), .disarm)
    }

    func testClosingTheMenuOrPressingSomethingElsePutsItAway() {
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered(); _ = a.armFinished(ok: true, pointerInside: true)
        XCTAssertEqual(a.menuClosing(), .disarm)
        var b = AdaptiveSliderArming()
        _ = b.pointerEntered()
        XCTAssertEqual(b.menuClosing(), .disarm, "on its way counts too")
        var c = AdaptiveSliderArming()
        XCTAssertEqual(c.menuClosing(), .none)
    }

    func testANewOpeningOfTheMenuStartsAfresh() {
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered(); _ = a.armFinished(ok: false, pointerInside: true)
        a = AdaptiveSliderArming()
        XCTAssertEqual(a.pointerEntered(), .arm)
    }

    func testAPressBeforeItIsInPlaceDoesNothing() {
        var a = AdaptiveSliderArming()
        _ = a.pointerEntered()
        XCTAssertFalse(a.handsOverOnPress, "it is on its way: macOS's own menu is not opened over it")
    }
}
