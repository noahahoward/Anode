import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Anode's menus open on the side of their icon macOS opens its panel on, and move to it when macOS shows them the other one.
final class PanelSidesTests: XCTestCase {

    private func icon(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 8.5, width: 26, height: 22) }

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    func testTheGuessIsUsedUntilMacOSHasOpenedAPanelForTheIcon() {
        let sides = PanelSides(leftLimit: { 1010 }, screen: { self.screen })
        XCTAssertEqual(sides.side(for: icon(1117)), .startsAtIcon)
        XCTAssertEqual(sides.side(for: icon(1553)), .endsAtIcon)
        XCTAssertEqual(sides.sidesToCover(for: icon(1117)), [.endsAtIcon, .startsAtIcon], "not known: the picture covers both places")
    }

    func testAnIconNearTheRightEdgeIsNotCoveredOnASideThatCouldNotFit() {
        let sides = PanelSides(leftLimit: { 1010 }, screen: { self.screen })
        XCTAssertEqual(sides.sidesToCover(for: icon(1583)), [.endsAtIcon], "its panel cannot open to the right: it would leave the screen")
        XCTAssertEqual(sides.sidesToCover(for: icon(1117)), [.endsAtIcon, .startsAtIcon])
    }

    func testAnIconWhereNeitherSideFitsStillGetsASide() {
        let sides = PanelSides(leftLimit: { 0 }, screen: { CGRect(x: 0, y: 0, width: 200, height: 400) })
        XCTAssertEqual(sides.sidesToCover(for: icon(100)).count, 1)
    }

    func testAWindowThatStartedBeforeTheIconSaysItOpensToTheRight() {
        let sides = PanelSides(leftLimit: { 0 }, screen: { self.screen })   // no notch: the guess is the left
        sides.learn(windowMinX: 1075, icon: icon(1117))
        XCTAssertEqual(sides.side(for: icon(1117)), .startsAtIcon)
        XCTAssertEqual(sides.sidesToCover(for: icon(1117)), [.startsAtIcon], "known: only that place")
    }

    func testASideOtherThanTheGuessIsAnnounced_ButWhatTheGuessSaidIsNot() {
        let sides = PanelSides(leftLimit: { 1010 }, screen: { self.screen })
        var told = 0
        let token = NotificationCenter.default.addObserver(forName: PanelSides.changed, object: nil, queue: .main) { _ in told += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        sides.learn(windowMinX: 1075, icon: icon(1117))   // the guess for this icon
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(told, 0)
        sides.learn(windowMinX: 1117 + 26 + 42 - 522, icon: icon(1117))   // the other side
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(told, 1)
    }

    func testAMenuIsKeptInsideTheScreen() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "needs a screen")
        // Far left: it would start before the screen; far right: it would end after it.
        XCTAssertGreaterThanOrEqual(PanelSides.menuMinX(anchor: icon(0), width: 308, in: screen), 8)
        XCTAssertLessThanOrEqual(PanelSides.menuMinX(anchor: icon(screen.frame.width), width: 308, in: screen), screen.frame.width - 308 - 8)
    }

    // The menu goes where macOS's panel was seen to open, also when that is the other side than the guess.
    func testAnOpenBatteryMenuMovesToTheSideMacOSOpenedItsPanelOn() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "needs a screen")
        let panel = BatteryMenuPanel()
        defer { panel.orderOut(nil) }
        let anchor = icon(777)   // an icon no other test uses: the memory is shared
        let model = BatteryMenuModel(powerSource: "Battery", modes: [.init(id: "automatic", title: "Automatic", isSelected: true)], energyApps: [])
        PanelSides.shared.learn(windowMinX: anchor.maxX + 42 - 522, icon: anchor)   // opens to the left, ending at the icon
        panel.show(model, below: anchor)
        try XCTSkipUnless(panel.isVisible, "no window server here")
        XCTAssertEqual(panel.frame.maxX, anchor.maxX + 10.5, accuracy: 1)
        PanelSides.shared.learn(windowMinX: anchor.minX - 42, icon: anchor)   // then it opens to the right, starting at the icon
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(panel.frame.minX, anchor.minX - 10.5, accuracy: 1)
    }

    func testAnOpenSoundMenuMovesToTheSideMacOSOpenedItsPanelOn() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "needs a screen")
        let panel = SoundMenuPanel()
        defer { panel.orderOut(nil) }
        let anchor = icon(888)
        let model = SoundMenuModel.merge(outputs: [OutputDevice(id: "a", name: "Speakers", kind: .speakers)], defaultID: "a", volume: 0.5, muted: false,
                                         batteries: [], apple: nil, expanded: nil)
        PanelSides.shared.learn(windowMinX: anchor.maxX + 42 - 522, icon: anchor)
        panel.show(model, below: anchor)
        try XCTSkipUnless(panel.isVisible, "no window server here")
        XCTAssertEqual(panel.frame.maxX, anchor.maxX + 10.5, accuracy: 1)
        PanelSides.shared.learn(windowMinX: anchor.minX - 42, icon: anchor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(panel.frame.minX, anchor.minX - 10.5, accuracy: 1)
    }
}
