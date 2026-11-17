import XCTest
@testable import PowerKit

/// Which way macOS opens the panel of a menu bar icon, and where Anode's menu goes to match it. The numbers are from macOS 27 on a
/// 1800 pt wide screen with a notch (right of it from x 1010): the window macOS opens is 522 pt wide and starts 42 pt before the icon
/// (icons at x 1110 to 1159: the panel opens to the right of the icon) or ends 42 pt past it (the Wi-Fi icon at 1553: it opens to
/// the left, ending at the icon). The panel itself is 10.5 pt out past the icon's edge on the side it is anchored.
final class MenuPanelPlacementTests: XCTestCase {

    private let battery = CGRect(x: 1117, y: 8.5, width: 26, height: 22)
    private let wifi = CGRect(x: 1553, y: 8.5, width: 22, height: 22)

    // ── From the window macOS opened ────────────────────────────────────────

    func testAWindowThatStartsBeforeTheIconOpensToTheRight() {
        XCTAssertEqual(MenuPanelPlacement.side(ofWindowMinX: 1075, icon: battery), .startsAtIcon)
    }

    func testAWindowThatEndsPastTheIconOpensToTheLeft() {
        XCTAssertEqual(MenuPanelPlacement.side(ofWindowMinX: 1095, icon: wifi), .endsAtIcon)
    }

    // ── Where Anode's menu goes ─────────────────────────────────────────────

    func testAMenuThatEndsAtTheIconHasItsRightEdge10_5PastTheIcons() {
        XCTAssertEqual(MenuPanelPlacement.minX(icon: wifi, side: .endsAtIcon, width: 308), 1575 + 10.5 - 308)
    }

    func testAMenuThatStartsAtTheIconHasItsLeftEdge10_5BeforeTheIcons() {
        XCTAssertEqual(MenuPanelPlacement.minX(icon: battery, side: .startsAtIcon, width: 308), 1117 - 10.5)
        XCTAssertEqual(MenuPanelPlacement.minX(icon: battery, side: .startsAtIcon, width: 309), 1117 - 10.5, "whatever its width")
    }

    // ── A guess, before macOS has shown one ─────────────────────────────────

    func testAPanelThatWouldReachUnderTheNotchOpensToTheRightInstead() {
        // Right-aligned, the 522 pt window of the icon at 1117 would start at 663, left of where the notch ends (1010).
        XCTAssertEqual(MenuPanelPlacement.predictedSide(for: battery, leftLimit: 1010), .startsAtIcon)
        XCTAssertEqual(MenuPanelPlacement.predictedSide(for: wifi, leftLimit: 1010), .endsAtIcon)
    }

    func testOnAScreenWithoutANotchIconsOpenToTheLeftAsAlways() {
        XCTAssertEqual(MenuPanelPlacement.predictedSide(for: battery, leftLimit: 0), .endsAtIcon)
        XCTAssertEqual(MenuPanelPlacement.predictedSide(for: CGRect(x: 600, y: 8.5, width: 22, height: 22), leftLimit: 0), .endsAtIcon)
        XCTAssertEqual(MenuPanelPlacement.predictedSide(for: CGRect(x: 300, y: 8.5, width: 22, height: 22), leftLimit: 0), .startsAtIcon,
                       "an icon so far left that the window would leave the screen")
    }

    func testTheGuessChangesAtTheIconWhoseWindowJustFits() {
        // The window's left end is icon.maxX + 42 - 522: it fits from icon.maxX = limit + 480.
        XCTAssertEqual(MenuPanelPlacement.predictedSide(for: CGRect(x: 1468, y: 0, width: 21, height: 22), leftLimit: 1010), .startsAtIcon)
        XCTAssertEqual(MenuPanelPlacement.predictedSide(for: CGRect(x: 1469, y: 0, width: 21, height: 22), leftLimit: 1010), .endsAtIcon)
    }

    // ── What was seen ───────────────────────────────────────────────────────

    func testWhatMacOSDidForAnIconIsRemembered_NotTheGuess() {
        var memory = PanelSideMemory()
        XCTAssertEqual(memory.side(for: battery, leftLimit: 1010), .startsAtIcon, "the guess, to begin with")
        memory.learn(.endsAtIcon, for: battery, leftLimit: 1010)
        XCTAssertEqual(memory.side(for: battery, leftLimit: 1010), .endsAtIcon)
        // The icon a point or two off (its neighbours changed width) is the same icon.
        XCTAssertEqual(memory.side(for: battery.offsetBy(dx: 2, dy: 0), leftLimit: 1010), .endsAtIcon)
    }

    func testLearningSaysWhetherItChangedAnything() {
        var memory = PanelSideMemory()
        XCTAssertFalse(memory.learn(.startsAtIcon, for: battery, leftLimit: 1010), "what the guess said")
        XCTAssertTrue(memory.learn(.endsAtIcon, for: battery, leftLimit: 1010), "not what the guess said")
        XCTAssertFalse(memory.learn(.endsAtIcon, for: battery, leftLimit: 1010), "now known")
    }

    func testAnIconFurtherLeftThanOneThatOpenedToTheRightOpensToTheRightToo() {
        var memory = PanelSideMemory()
        memory.learn(.startsAtIcon, for: CGRect(x: 1600, y: 0, width: 22, height: 22), leftLimit: 1010)   // against the guess
        XCTAssertEqual(memory.side(for: CGRect(x: 1300, y: 0, width: 22, height: 22), leftLimit: 1010), .startsAtIcon)
        XCTAssertEqual(memory.side(for: CGRect(x: 1700, y: 0, width: 22, height: 22), leftLimit: 1010), .endsAtIcon, "not known for the other way")
    }

    func testAnIconFurtherRightThanOneThatOpenedToTheLeftOpensToTheLeftToo() {
        var memory = PanelSideMemory()
        memory.learn(.endsAtIcon, for: CGRect(x: 1200, y: 0, width: 22, height: 22), leftLimit: 1010)   // against the guess
        XCTAssertEqual(memory.side(for: CGRect(x: 1300, y: 0, width: 22, height: 22), leftLimit: 1010), .endsAtIcon)
        XCTAssertEqual(memory.side(for: CGRect(x: 1110, y: 0, width: 22, height: 22), leftLimit: 1010), .startsAtIcon, "not known for the other way")
    }

    func testWhetherASideIsKnownForAnIcon() {
        var memory = PanelSideMemory()
        XCTAssertFalse(memory.knows(battery))
        memory.learn(.startsAtIcon, for: battery, leftLimit: 1010)
        XCTAssertTrue(memory.knows(battery))
        XCTAssertFalse(memory.knows(wifi))
    }

    // ── The picture over the place macOS's panel appears ────────────────────

    func testTheRegionCoversEachSideItMightOpenTo() {
        let right = MenuPanelPlacement.region(for: battery, sides: [.endsAtIcon], width: 309)
        let left = MenuPanelPlacement.region(for: battery, sides: [.startsAtIcon], width: 309)
        let both = MenuPanelPlacement.region(for: battery, sides: [.endsAtIcon, .startsAtIcon], width: 309)
        XCTAssertEqual(right.minX, CGFloat(Int(1143 + 10.5 - 309) - 28))
        XCTAssertEqual(right.width, 309 + 56)
        XCTAssertEqual(left.minX, CGFloat(Int(1117 - 10.5) - 28))
        XCTAssertEqual(left.width, 309 + 56)
        XCTAssertEqual(both, right.union(left))
        XCTAssertEqual(both.minY, 40); XCTAssertEqual(both.height, 600)
    }
}
