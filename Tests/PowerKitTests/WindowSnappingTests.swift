import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

final class WindowSnappingTests: XCTestCase {
    /// A 1800 x 1169 display with a 39 pt menu bar, in the window server's coordinates.
    private let area = CGRect(x: 0, y: 39, width: 1800, height: 1130)
    private let any = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func f(_ a: WindowAction, from frame: CGRect? = nil, in r: CGRect? = nil) -> CGRect {
        WindowGeometry.frame(for: a, from: frame ?? any, in: r ?? area)!
    }

    // ── The rectangles ──

    func testHalvesFillTheAreaAndMeet() {
        XCTAssertEqual(f(.leftHalf), CGRect(x: 0, y: 39, width: 900, height: 1130))
        XCTAssertEqual(f(.rightHalf), CGRect(x: 900, y: 39, width: 900, height: 1130))
        XCTAssertEqual(f(.topHalf), CGRect(x: 0, y: 39, width: 1800, height: 565))
        XCTAssertEqual(f(.bottomHalf), CGRect(x: 0, y: 604, width: 1800, height: 565))
        XCTAssertEqual(f(.bottomHalf).maxY, area.maxY, "the bottom half reaches the bottom of the screen")
    }

    func testQuartersMeetInTheMiddle() {
        XCTAssertEqual(f(.topLeft), CGRect(x: 0, y: 39, width: 900, height: 565))
        XCTAssertEqual(f(.topRight), CGRect(x: 900, y: 39, width: 900, height: 565))
        XCTAssertEqual(f(.bottomLeft), CGRect(x: 0, y: 604, width: 900, height: 565))
        XCTAssertEqual(f(.bottomRight), CGRect(x: 900, y: 604, width: 900, height: 565))
    }

    /// An odd width: three thirds must still add up to it exactly, the last taking the remainder.
    func testThirdsAddUpToAnOddWidthWithNoGap() {
        let odd = CGRect(x: 0, y: 39, width: 1511, height: 1000)
        let a = f(.firstThird, in: odd), b = f(.centerThird, in: odd), c = f(.lastThird, in: odd)
        XCTAssertEqual(a.maxX, b.minX); XCTAssertEqual(b.maxX, c.minX); XCTAssertEqual(c.maxX, 1511)
        XCTAssertEqual(a.minX, 0)
        let halfL = f(.leftHalf, in: odd), halfR = f(.rightHalf, in: odd)
        XCTAssertEqual(halfL.maxX, halfR.minX); XCTAssertEqual(halfR.maxX, 1511)
    }

    func testTwoThirdsHugTheirSide() {
        XCTAssertEqual(f(.firstTwoThirds).minX, 0)
        XCTAssertEqual(f(.lastTwoThirds).maxX, 1800)
        XCTAssertEqual(f(.firstTwoThirds).width, 1200)
    }

    func testMaximizeIsTheWholeAreaAndMaximizeHeightKeepsTheWidth() {
        XCTAssertEqual(f(.maximize), area)
        let m = f(.maximizeHeight)
        XCTAssertEqual(m.minX, any.minX); XCTAssertEqual(m.width, any.width)
        XCTAssertEqual(m.minY, 39); XCTAssertEqual(m.height, 1130)
    }

    func testCenterKeepsTheSizeAndAWindowBiggerThanTheAreaIsShrunk() {
        let c = f(.center)
        XCTAssertEqual(c.size, any.size)
        XCTAssertEqual(c.midX, area.midX, accuracy: 1); XCTAssertEqual(c.midY, area.midY, accuracy: 1)
        let big = f(.center, from: CGRect(x: 0, y: 0, width: 5000, height: 4000))
        XCTAssertEqual(big, area)
    }

    func testRestoreAndDisplayMovesAreNotRectanglesOfOneScreen() {
        for a in [WindowAction.restore, .nextDisplay, .previousDisplay] {
            XCTAssertNil(WindowGeometry.frame(for: a, from: any, in: area))
        }
    }

    // ── The usable area ──

    /// The bug this exists to avoid: the Dock held up, or revealed, must not take height off a window.
    func testAutoHideMeansTheScreenBelowTheMenuBarWhateverVisibleFrameSays() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let primaryHeight: CGFloat = 1169
        let hidden = CGRect(x: 0, y: 0, width: 1800, height: 1130)     // Dock hidden
        let up = CGRect(x: 0, y: 107, width: 1800, height: 1023)       // Dock pinned up: 1130 -> 1023
        for visible in [hidden, up] {
            let a = WindowGeometry.usableArea(screenFrame: screen, visibleFrame: visible, userAutoHidesDock: true,
                                              primaryHeight: primaryHeight)
            XCTAssertEqual(a, CGRect(x: 0, y: 39, width: 1800, height: 1130), "same area, Dock up or not")
        }
    }

    func testWithoutAutoHideTheDockIsPartOfTheLayout() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let up = CGRect(x: 0, y: 107, width: 1800, height: 1023)
        let a = WindowGeometry.usableArea(screenFrame: screen, visibleFrame: up, userAutoHidesDock: false, primaryHeight: 1169)
        XCTAssertEqual(a, CGRect(x: 0, y: 39, width: 1800, height: 1023))
        XCTAssertEqual(a.maxY, 1062, "the window ends above the Dock")
    }

    func testASecondDisplayAboveTheFirstIsFlippedIntoTheSameSpace() {
        // An external display above the primary one: AppKit y 1169..1989, so window-server y -820..0.
        let external = CGRect(x: 0, y: 1169, width: 1280, height: 820)
        let a = WindowGeometry.usableArea(screenFrame: external, visibleFrame: CGRect(x: 0, y: 1169, width: 1280, height: 796),
                                          userAutoHidesDock: true, primaryHeight: 1169)
        XCTAssertEqual(a, CGRect(x: 0, y: -820 + 24, width: 1280, height: 796))
    }

    func testTheDockIntentIsTheUsersSettingEvenWhileAnodeHoldsItUp() {
        XCTAssertTrue(DockIntent.userAutoHidesDock(isEnabled: false, heldByAnode: true), "stored pref reads off, but only because we hold it")
        XCTAssertTrue(DockIntent.userAutoHidesDock(isEnabled: true, heldByAnode: false))
        XCTAssertFalse(DockIntent.userAutoHidesDock(isEnabled: false, heldByAnode: false))
        XCTAssertFalse(DockIntent.userAutoHidesDock(isEnabled: nil, heldByAnode: false))
    }

    // ── Minimum sizes, and moving between displays ──

    func testAWindowThatCameOutTooBigIsKeptOnScreenAtTheEdgeItWasAimedAt() {
        let wanted = f(.rightHalf)                                     // 900 wide at the right edge
        let actual = CGRect(x: 900, y: 39, width: 1100, height: 1130)  // it has a minimum width of 1100
        let kept = WindowGeometry.kept(actual, wanted: wanted, in: area)
        XCTAssertEqual(kept.maxX, 1800, "grows leftward from the right edge")
        XCTAssertEqual(kept.width, 1100)
        let leftWanted = f(.leftHalf), leftActual = CGRect(x: 0, y: 39, width: 1100, height: 1130)
        XCTAssertEqual(WindowGeometry.kept(leftActual, wanted: leftWanted, in: area).minX, 0)
    }

    func testCarryingAWindowToAnotherDisplayKeepsItsShareOfTheScreen() {
        let small = CGRect(x: 0, y: -820 + 24, width: 1280, height: 796)       // the second display
        let leftHalf = CGRect(x: 0, y: 39, width: 900, height: 1130)           // half of the first display's width
        let r = WindowGeometry.carried(leftHalf, from: area, to: small)
        XCTAssertEqual(r.width, (900 * 1280 / 1800).rounded(), accuracy: 1)
        XCTAssertEqual(r.height, 796, accuracy: 1, "full height of one is full height of the other")
        XCTAssertTrue(small.contains(r))
    }

    func testTheScreenAWindowIsOnIsTheOneItOverlapsMost() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800), right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        XCTAssertEqual(WindowGeometry.screenIndex(for: CGRect(x: 800, y: 100, width: 600, height: 300), in: [left, right]), 1)
        XCTAssertEqual(WindowGeometry.screenIndex(for: CGRect(x: 100, y: 100, width: 300, height: 300), in: [left, right]), 0)
        XCTAssertEqual(WindowGeometry.screenIndex(for: CGRect(x: 5000, y: 100, width: 300, height: 300), in: [left, right]), 1,
                       "off every screen: the nearest")
        XCTAssertNil(WindowGeometry.screenIndex(for: any, in: []))
    }

    func testDisplaysAreOrderedLeftToRight() {
        let areas = [CGRect(x: 1800, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: 100, height: 100),
                     CGRect(x: 900, y: 0, width: 100, height: 100)]
        XCTAssertEqual(WindowSnapper.displayOrder(areas), [1, 2, 0])
    }

    // ── The shortcuts ──

    func testEveryActionHasADistinctShortcut() {
        let all = WindowAction.allCases.map { "\($0.shortcut.key)/\($0.shortcut.modifiers)" }
        XCTAssertEqual(Set(all).count, WindowAction.allCases.count, "two actions on one key would shadow each other")
        XCTAssertEqual(WindowAction.leftHalf.shortcut.label, "⌃⌥←")
    }

    func testTheSettingDefaultsToOffAndTheSectionListsEveryShortcut() {
        let defaults = UserDefaults(suiteName: "window-actions-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.windowSnapperEnabled)
        s.windowSnapperEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).windowSnapperEnabled)
        let list = WindowActionsFeature.shortcutList()
        for a in WindowAction.allCases { XCTAssertTrue(list.contains(a.title)) }
        XCTAssertTrue(BetaFeaturesWindowController().features.contains { $0 is WindowActionsFeature })
    }
}
