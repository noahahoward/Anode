import XCTest
import ApplicationServices
@testable import PowerKit
@testable import AnodeApp

/// A stand-in for MenuBarAgent's menu bar, with the reads counted. Elements are application elements made from made-up process
/// numbers (nothing is asked of any process), told apart with CFEqual.
private final class FakeBar {
    var trusted = true
    var agentPid: pid_t? = 61000
    var alivePids: Set<pid_t> = [61000]
    var lookups = 0
    /// Every Accessibility read, as "tag.attribute".
    var log: [String] = []

    private var nodes: [(tag: Int, element: AXUIElement, attrs: [String: CFTypeRef])] = []
    private var broken: Set<Int> = []

    func element(_ tag: Int) -> AXUIElement {
        if let n = nodes.first(where: { $0.tag == tag }) { return n.element }
        let e = AXUIElementCreateApplication(pid_t(62000 + tag))
        nodes.append((tag, e, [:]))
        return e
    }
    func set(_ tag: Int, _ name: String, _ value: CFTypeRef) {
        _ = element(tag)
        let i = nodes.firstIndex(where: { $0.tag == tag })!
        nodes[i].attrs[name] = value
    }
    func setChildren(_ tag: Int, _ children: [Int]) { set(tag, kAXChildrenAttribute, children.map { element($0) } as NSArray) }
    func setFrame(_ tag: Int, _ r: CGRect) { var r = r; set(tag, "AXFrame", AXValueCreate(.cgRect, &r)!) }
    func setIdentifier(_ tag: Int, _ id: String) { set(tag, "AXIdentifier", id as NSString) }
    /// The element answers nothing from now on, as an element whose item has gone away.
    func breakElement(_ tag: Int) { broken.insert(tag) }

    func reads() -> MenuBarAXReads {
        MenuBarAXReads(
            isTrusted: { self.trusted },
            agentPid: { self.lookups += 1; return self.agentPid },
            isAlive: { self.alivePids.contains($0) },
            application: { _ in self.element(0) },
            attribute: { e, name in
                guard let n = self.nodes.first(where: { CFEqual($0.element, e) }) else { return nil }
                self.log.append("\(n.tag).\(name)")
                return self.broken.contains(n.tag) ? nil : n.attrs[name]
            })
    }

    /// Tags: 0 the application, 1 the bar, 2 the group holding the icon, 3 the icon, 4 another item in that group,
    /// 5 a second group, 7 an item in it.
    static let iconFrame = CGRect(x: 900, y: 0, width: 24, height: 24)
    static let itemFrame = CGRect(x: 892, y: 0, width: 40, height: 38)

    static func standard() -> FakeBar {
        let f = FakeBar()
        f.set(0, "AXExtrasMenuBar", f.element(1))
        f.setChildren(1, [2, 5])
        f.setChildren(2, [4, 3])
        f.setIdentifier(4, "com.apple.menuextra.wifi")
        f.setIdentifier(3, NativeMenuExtraIcon.soundIdentifier)
        f.setFrame(3, iconFrame)
        f.setFrame(2, itemFrame)
        f.setChildren(5, [7])
        f.setIdentifier(7, "com.apple.menuextra.clock")
        return f
    }
}

final class NativeMenuExtraIconLookTests: XCTestCase {

    private func icon(_ bar: FakeBar) -> NativeMenuExtraIcon {
        NativeMenuExtraIcon(identifier: NativeMenuExtraIcon.soundIdentifier, logName: "test-native-icon.log", reads: bar.reads())
    }

    func testTheFirstLookWalksTheBarAndStopsAtTheMatch() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        XCTAssertEqual(found.currentFrame(), FakeBar.iconFrame)
        XCTAssertEqual(bar.lookups, 1)
        // The second group's item is never asked for its identifier: the match came first.
        XCTAssertFalse(bar.log.contains("7.AXIdentifier"))
        XCTAssertFalse(bar.log.contains("5.AXChildren"))
        XCTAssertEqual(bar.log.filter { $0 == "0.AXExtrasMenuBar" }.count, 1)
    }

    func testASteadyPollReadsOnlyTheCachedElementsAndNeverAsksLaunchServices() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        bar.log.removeAll()
        for _ in 0..<5 { XCTAssertEqual(found.currentFrame(), FakeBar.iconFrame) }
        XCTAssertEqual(bar.lookups, 1, "no Launch Services lookup on the steady path")
        XCTAssertEqual(bar.log.count, 15, "three reads per poll")
        XCTAssertEqual(Set(bar.log), ["3.AXIdentifier", "3.AXFrame", "2.AXFrame"])
        XCTAssertFalse(bar.log.contains { $0.hasSuffix(kAXChildrenAttribute) }, "no children enumeration")
    }

    func testTheClickTapStillLearnsTheFrameTheBarAndThePidOnTheSteadyPath() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        let first = found.tapState
        XCTAssertEqual(first.frame, FakeBar.iconFrame)
        XCTAssertEqual(first.bar, FakeBar.itemFrame)
        XCTAssertEqual(first.pid, 61000)
        // Overwritten by the tap, then refreshed by a steady poll.
        bar.setFrame(3, CGRect(x: 800, y: 0, width: 24, height: 24))
        XCTAssertEqual(found.currentFrame(), CGRect(x: 800, y: 0, width: 24, height: 24))
        let second = found.tapState
        XCTAssertEqual(second.frame, CGRect(x: 800, y: 0, width: 24, height: 24))
        XCTAssertEqual(second.bar, FakeBar.itemFrame)
        XCTAssertEqual(second.pid, 61000)
    }

    func testAnEmptyItemFrameOfTheGroupGivesNoBarButStillTheIcon() {
        let bar = FakeBar.standard()
        bar.setFrame(2, .zero)
        let found = icon(bar)
        XCTAssertEqual(found.currentFrame(), FakeBar.iconFrame)
        XCTAssertNil(found.tapState.bar)
        bar.log.removeAll()
        XCTAssertEqual(found.currentFrame(), FakeBar.iconFrame)
        XCTAssertEqual(bar.log.count, 3, "an empty group frame is not a reason for a full look")
        XCTAssertNil(found.tapState.bar)
    }

    func testWhenTheIconMovesThePollReturnsTheNewFrameFromTheCachedItem() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        let moved = CGRect(x: 700, y: 0, width: 24, height: 24)
        bar.setFrame(3, moved)
        bar.log.removeAll()
        XCTAssertEqual(found.currentFrame(), moved)
        XCTAssertEqual(bar.log.count, 3)
        XCTAssertEqual(bar.lookups, 1)
    }

    func testAnItemThatVanishesGivesOneFullLookAndNilAndAReappearanceIsFoundByTheNextLook() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        // The icon is taken out of the bar: its element stops answering and the group no longer lists it.
        bar.breakElement(3)
        bar.setChildren(2, [4])
        bar.log.removeAll()
        XCTAssertNil(found.currentFrame())
        XCTAssertEqual(bar.lookups, 2, "the failed cache costs one full look")
        XCTAssertEqual(bar.log.filter { $0 == "0.AXExtrasMenuBar" }.count, 1)
        XCTAssertNil(found.tapState.frame)
        XCTAssertEqual(found.tapState.pid, 0)
        // Still absent: each poll is a full look, as before.
        XCTAssertNil(found.currentFrame())
        XCTAssertEqual(bar.lookups, 3)
        // Back in the bar as a new element.
        bar.setIdentifier(6, NativeMenuExtraIcon.soundIdentifier)
        bar.setFrame(6, CGRect(x: 850, y: 0, width: 24, height: 24))
        bar.setChildren(2, [4, 6])
        XCTAssertEqual(found.currentFrame(), CGRect(x: 850, y: 0, width: 24, height: 24))
        XCTAssertEqual(found.tapState.pid, 61000)
        // And the steady path is the new element's.
        bar.log.removeAll()
        XCTAssertEqual(found.currentFrame(), CGRect(x: 850, y: 0, width: 24, height: 24))
        XCTAssertEqual(Set(bar.log), ["6.AXIdentifier", "6.AXFrame", "2.AXFrame"])
    }

    func testACachedItemThatNowCarriesAnotherIdentifierIsNotTheIcon() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        // The bar was rebuilt: the element is still there but it is another item now, and the icon sits elsewhere.
        bar.setIdentifier(3, "com.apple.menuextra.bluetooth")
        bar.setIdentifier(4, NativeMenuExtraIcon.soundIdentifier)
        bar.setFrame(4, CGRect(x: 600, y: 0, width: 24, height: 24))
        XCTAssertEqual(found.currentFrame(), CGRect(x: 600, y: 0, width: 24, height: 24))
        XCTAssertEqual(bar.lookups, 2)
    }

    func testAChangedMenuBarAgentPidGivesAFullLook() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        bar.alivePids = [61001]
        bar.agentPid = 61001
        XCTAssertEqual(found.currentFrame(), FakeBar.iconFrame)
        XCTAssertEqual(bar.lookups, 2)
        XCTAssertEqual(found.tapState.pid, 61001)
        // Then steady again on the new pid.
        bar.log.removeAll()
        _ = found.currentFrame()
        XCTAssertEqual(bar.lookups, 2)
        XCTAssertEqual(bar.log.count, 3)
    }

    func testAnEmptyIconFrameIsNilAsBeforeAndKeepsThePid() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        bar.setFrame(3, .zero)
        XCTAssertNil(found.currentFrame())
        XCTAssertEqual(bar.lookups, 2, "an empty frame is one full look")
        XCTAssertNil(found.tapState.frame)
        XCTAssertNil(found.tapState.bar)
        XCTAssertEqual(found.tapState.pid, 61000)
        // A frame that is back is found by the next look.
        bar.setFrame(3, FakeBar.iconFrame)
        XCTAssertEqual(found.currentFrame(), FakeBar.iconFrame)
    }

    func testWithoutAccessibilityOrMenuBarAgentThereIsNoIconAndNoTrustedPid() {
        let bar = FakeBar.standard()
        let found = icon(bar)
        _ = found.currentFrame()
        bar.trusted = false
        bar.log.removeAll()
        XCTAssertNil(found.currentFrame())
        XCTAssertTrue(bar.log.isEmpty)
        XCTAssertEqual(found.tapState.pid, 0)
        bar.trusted = true
        bar.agentPid = nil
        XCTAssertNil(found.currentFrame())
        XCTAssertEqual(found.tapState.pid, 0)
        XCTAssertNil(found.tapState.frame)
    }

    func testAMenuBarWithoutAnExtrasBarHasNoIcon() {
        let bar = FakeBar.standard()
        bar.set(0, "AXExtrasMenuBar", "nothing" as NSString)
        let found = icon(bar)
        XCTAssertNil(found.currentFrame())
        XCTAssertEqual(found.tapState.pid, 0)
    }
}
