import XCTest
@testable import PowerKit

/// Which clicks on macOS's own Sound icon Anode takes for itself, and which it leaves alone.
final class NativeIconClickGateTests: XCTestCase {

    private let icon = CGRect(x: 1544, y: 8, width: 22, height: 22)
    private let inside = CGPoint(x: 1555, y: 19)
    private let outside = CGPoint(x: 1300, y: 19)

    func testClickOnTheNativeIconIsSwallowedAndOpens() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: inside, modifiers: false, icon: icon, isTheIcon: { true }), .swallowAndOpen)
    }

    func testClickElsewhereIsPassed() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: outside, modifiers: false, icon: icon, isTheIcon: { true }), .pass)
    }

    func testReleaseOfASwallowedClickIsSwallowedEvenIfThePointerMoved() {
        var g = NativeIconClickGate()
        _ = g.decide(.down, at: inside, modifiers: false, icon: icon, isTheIcon: { true })
        XCTAssertEqual(g.decide(.up, at: outside, modifiers: false, icon: icon, isTheIcon: { false }), .swallow)
        XCTAssertEqual(g.decide(.up, at: outside, modifiers: false, icon: icon, isTheIcon: { false }), .pass, "only the one release")
    }

    func testReleaseWithoutASwallowedPressPasses() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.up, at: inside, modifiers: false, icon: icon, isTheIcon: { true }), .pass)
    }

    func testCommandOptionOrControlClickPassesSoIconsCanBeRearranged() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: inside, modifiers: true, icon: icon, isTheIcon: { true }), .pass)
        XCTAssertEqual(g.decide(.up, at: inside, modifiers: true, icon: icon, isTheIcon: { true }), .pass)
    }

    func testAHitThatIsNotTheIconIsPassed() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: inside, modifiers: false, icon: icon, isTheIcon: { false }), .pass,
                       "the bar moved since the frame was read: the click belongs to whatever is there now")
    }

    func testAClickJustBesideTheLastKnownFrameIsStillTakenWhenTheLiveCheckSaysItIsTheIcon() {
        var g = NativeIconClickGate()
        // The bar's other items changed width a moment ago, so the icon has moved a few points since its frame was read.
        let moved = CGPoint(x: icon.minX - 14, y: 19)
        XCTAssertEqual(g.decide(.down, at: moved, modifiers: false, icon: icon, isTheIcon: { true }), .swallowAndOpen)
    }

    func testABesideClickThatIsNotTheIconIsPassed() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: CGPoint(x: icon.minX - 14, y: 19), modifiers: false, icon: icon, isTheIcon: { false }), .pass)
    }

    func testFarFromTheIconNothingIsEvenAsked() {
        var g = NativeIconClickGate()
        var asked = 0
        _ = g.decide(.down, at: CGPoint(x: icon.minX - 400, y: 19), modifiers: false, icon: icon, isTheIcon: { asked += 1; return true })
        XCTAssertEqual(asked, 0)
    }

    func testBelowTheMenuBarNothingIsAsked() {
        var g = NativeIconClickGate()
        var asked = 0
        _ = g.decide(.down, at: CGPoint(x: icon.midX, y: 300), modifiers: false, icon: icon, isTheIcon: { asked += 1; return true })
        XCTAssertEqual(asked, 0)
    }

    func testAnIconOnAnotherDisplayDoesNotMakeEverythingAboveItWorthALook() {
        var g = NativeIconClickGate()
        let lower = CGRect(x: 1544, y: 1088, width: 22, height: 22)   // a bar on a display below the main one
        var asked = 0
        let far = g.decide(.down, at: CGPoint(x: lower.midX, y: 400), modifiers: false, icon: lower, isTheIcon: { asked += 1; return true })
        XCTAssertEqual(far, .pass); XCTAssertEqual(asked, 0, "nothing is asked, nothing taken, that far from the icon")
        XCTAssertEqual(g.decide(.down, at: CGPoint(x: lower.midX, y: lower.midY), modifiers: false, icon: lower, isTheIcon: { true }), .swallowAndOpen)
    }

    // The icon is a 22 pt square in the middle of an item that is as tall as the bar: a click at the very top or bottom of the bar,
    // above or under the square, is still a click on the item.
    private let bar = CGRect(x: 1544, y: 0, width: 22, height: 39)

    func testAClickAtTheVeryTopOfTheBarAboveTheSquareIsTakenWhenTheItemIsKnown() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: CGPoint(x: icon.midX, y: 0), modifiers: false, icon: icon, bar: bar, isTheIcon: { true }), .swallowAndOpen)
    }

    func testAClickAtTheBottomEdgeOfTheBarUnderTheSquareIsTakenWhenTheItemIsKnown() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: CGPoint(x: icon.midX, y: 38.5), modifiers: false, icon: icon, bar: bar, isTheIcon: { true }), .swallowAndOpen)
    }

    func testTheItemsHeightDoesNotReachAnotherDisplayAboveOrBelow() {
        var g = NativeIconClickGate()
        var asked = 0
        let belowBar = g.decide(.down, at: CGPoint(x: icon.midX, y: 60), modifiers: false, icon: icon, bar: bar, isTheIcon: { asked += 1; return true })
        XCTAssertEqual(belowBar, .pass); XCTAssertEqual(asked, 0)
        let above = g.decide(.down, at: CGPoint(x: icon.midX, y: -20), modifiers: false, icon: icon, bar: bar, isTheIcon: { asked += 1; return true })
        XCTAssertEqual(above, .pass); XCTAssertEqual(asked, 0)
    }

    func testNoKnownIconPassesEverything() {
        var g = NativeIconClickGate()
        XCTAssertEqual(g.decide(.down, at: inside, modifiers: false, icon: nil, isTheIcon: { true }), .pass)
    }

    func testTheHitTestRunsOnlyInsideTheFrame() {
        var g = NativeIconClickGate()
        var asked = 0
        _ = g.decide(.down, at: outside, modifiers: false, icon: icon, isTheIcon: { asked += 1; return true })
        XCTAssertEqual(asked, 0)
        _ = g.decide(.down, at: inside, modifiers: false, icon: icon, isTheIcon: { asked += 1; return true })
        XCTAssertEqual(asked, 1)
    }

    func testAPressWithoutItsReleaseDoesNotLeaveTheNextOnePassingByMistake() {
        var g = NativeIconClickGate()
        _ = g.decide(.down, at: inside, modifiers: false, icon: icon, isTheIcon: { true })
        // the release was lost; a new press elsewhere clears the memory
        XCTAssertEqual(g.decide(.down, at: outside, modifiers: false, icon: icon, isTheIcon: { true }), .pass)
        XCTAssertEqual(g.decide(.up, at: outside, modifiers: false, icon: icon, isTheIcon: { true }), .pass)
    }

    // While Anode's still picture of an icon is up (macOS's panel is being read), a click on the picture counts as a click on the icon.
    // It must count only for the icon the picture is over: the Sound and Battery icons are 16 pt apart, inside each other's slack, and
    // a click on one opened the other's menu while the other's picture was up.
    private let sound = CGRect(x: 1540, y: 8.5, width: 22, height: 22)
    private let battery = CGRect(x: 1578, y: 8.5, width: 26, height: 22)

    func testAClickOnTheSoundIconIsNotAClickOnThePictureOverTheBattery() {
        XCTAssertFalse(NativeIconClickGate.isOnCover(CGPoint(x: 1551, y: 19), of: battery))
        XCTAssertFalse(NativeIconClickGate.isOnCover(CGPoint(x: 1562, y: 19), of: battery), "the right edge of the sound icon")
    }

    func testAClickOnTheBatteryIconIsNotAClickOnThePictureOverTheSound() {
        XCTAssertFalse(NativeIconClickGate.isOnCover(CGPoint(x: 1590, y: 19), of: sound))
    }

    func testAClickOnTheIconItselfIsOnItsPicture() {
        XCTAssertTrue(NativeIconClickGate.isOnCover(CGPoint(x: 1590, y: 19), of: battery))
        XCTAssertTrue(NativeIconClickGate.isOnCover(CGPoint(x: 1551, y: 19), of: sound))
    }

    func testTheTopRowOfTheBarAboveTheIconIsStillOnThePictureWhenTheItemIsKnown() {
        let bar = CGRect(x: 1578, y: 0, width: 26, height: 39)
        XCTAssertTrue(NativeIconClickGate.isOnCover(CGPoint(x: 1590, y: 0), of: battery, bar: bar))
    }
}

