import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

final class WindowGroupsTests: XCTestCase {
    private func m(_ id: CGWindowID, pid: pid_t = 1, app: String = "App", x: CGFloat = 0) -> GroupMember {
        GroupMember(id: id, pid: pid, appName: app, title: "w\(id)", frame: CGRect(x: x, y: 0, width: 100, height: 100))
    }

    // ── Making and changing groups ──

    func testAGroupNeedsTwoDistinctWindows() {
        var s = WindowGroupStore()
        XCTAssertNil(s.create(from: [m(1)]))
        XCTAssertNil(s.create(from: [m(1), m(1)]), "the same window twice is one window")
        XCTAssertNotNil(s.create(from: [m(1), m(2)]))
        XCTAssertEqual(s.groups.count, 1)
    }

    func testGroupsAreNamedInOrderAndFindableByAnyMember() {
        var s = WindowGroupStore()
        let a = s.create(from: [m(1), m(2)])!, b = s.create(from: [m(3), m(4)])!
        XCTAssertEqual([a.name, b.name], ["Group 1", "Group 2"])
        XCTAssertEqual(s.group(containing: 2)?.id, a.id)
        XCTAssertEqual(s.group(containing: 4)?.id, b.id)
        XCTAssertNil(s.group(containing: 9))
    }

    /// A window is in one group. Putting it in another takes it out of the first, which dissolves if it is left short.
    func testAWindowIsInOneGroupAndALeftoverPairDissolves() {
        var s = WindowGroupStore()
        s.create(from: [m(1), m(2), m(3)])
        let b = s.create(from: [m(3), m(4)])!             // 3 moves to the new group
        XCTAssertEqual(s.group(containing: 3)?.id, b.id)
        XCTAssertEqual(s.groups.first { $0.name == "Group 1" }?.members.map(\.id), [1, 2], "two are enough to stay a group")
        s.create(from: [m(1), m(9)])                      // now 1 leaves the first group, leaving only 2
        XCTAssertNil(s.groups.first { $0.name == "Group 1" }, "one window is not a group")
        XCTAssertNil(s.group(containing: 2))
    }

    func testAddingMovesAWindowIntoTheGroupAndUpdatesItsFrame() {
        var s = WindowGroupStore()
        let g = s.create(from: [m(1), m(2)])!
        XCTAssertTrue(s.add(m(3, x: 50), to: g.id))
        XCTAssertEqual(s.group(withID: g.id)?.members.map(\.id), [1, 2, 3])
        XCTAssertTrue(s.add(m(3, x: 99), to: g.id), "again: updates, does not duplicate")
        XCTAssertEqual(s.group(withID: g.id)?.members.count, 3)
        XCTAssertEqual(s.group(withID: g.id)?.members.last?.frame.minX, 99)
        XCTAssertFalse(s.add(m(5), to: 42), "no such group")
    }

    func testRemovingOneOfTwoDissolvesTheGroupButOneOfThreeDoesNot() {
        var s = WindowGroupStore()
        let g = s.create(from: [m(1), m(2), m(3)])!
        s.remove(3)
        XCTAssertEqual(s.group(withID: g.id)?.members.map(\.id), [1, 2])
        s.remove(2)
        XCTAssertTrue(s.groups.isEmpty)
    }

    func testClosedWindowsAreDroppedAndAShortGroupDissolves() {
        var s = WindowGroupStore()
        s.create(from: [m(1), m(2), m(3)])
        s.prune(alive: [1, 2])
        XCTAssertEqual(s.groups.first?.members.map(\.id), [1, 2])
        s.prune(alive: [1])
        XCTAssertTrue(s.groups.isEmpty)
    }

    func testRememberingAndDissolving() {
        var s = WindowGroupStore()
        let g = s.create(from: [m(1), m(2)])!
        s.remember(frames: [1: CGRect(x: 7, y: 8, width: 9, height: 10)], in: g.id)
        XCTAssertEqual(s.group(withID: g.id)?.members.first?.frame, CGRect(x: 7, y: 8, width: 9, height: 10))
        XCTAssertEqual(s.group(withID: g.id)?.members.last?.frame.minX, 0, "the rest are as they were")
        s.dissolve(g.id)
        XCTAssertTrue(s.groups.isEmpty)
        s.create(from: [m(1), m(2)]); s.dissolveAll()
        XCTAssertTrue(s.groups.isEmpty)
    }

    // ── What comes forward ──

    func testTheOthersAreRaisedLastFirstAndOnlyIfOnScreen() {
        var s = WindowGroupStore()
        let g = s.create(from: [m(1), m(2), m(3), m(4)])!
        let order = WindowGroupStore.raiseOrder(front: 2, group: g, onScreen: [1, 2, 3])   // 4 is minimized
        XCTAssertEqual(order.map(\.id), [3, 1], "the front window itself and the unseen one are left out; reversed")
    }

    func testAGroupOfOneVisibleWindowRaisesNothing() {
        var s = WindowGroupStore()
        let g = s.create(from: [m(1), m(2)])!
        XCTAssertTrue(WindowGroupStore.raiseOrder(front: 1, group: g, onScreen: [1]).isEmpty)
    }

    // ── Shortcuts and the section ──

    func testGroupShortcutsAreDistinctFromEachOtherAndFromWindowActions() {
        let g = GroupAction.allCases.map { "\($0.shortcut.key)/\($0.shortcut.modifiers)" }
        XCTAssertEqual(Set(g).count, g.count)
        let w = Set(WindowAction.allCases.map { "\($0.shortcut.key)/\($0.shortcut.modifiers)" })
        XCTAssertTrue(w.isDisjoint(with: Set(g)), "a group key that is also a window action would fire both")
    }

    func testTheSettingDefaultsToOffAndTheSectionIsListed() {
        let defaults = UserDefaults(suiteName: "window-groups-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.windowGroupsEnabled)
        s.windowGroupsEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).windowGroupsEnabled)
        XCTAssertTrue(BetaFeaturesWindowController().features.contains { $0 is WindowGroupsFeature })
        let f = WindowGroupsFeature(settings: s, accessibilityAllowed: { true }, controller: { nil })
        _ = f.makeView()
        XCTAssertEqual(f.groupList.stringValue, "No groups yet.")
        XCTAssertFalse(f.buttons_isHiddenForTests)
    }
}

extension WindowGroupsFeature {
    var buttons_isHiddenForTests: Bool { tiledButton.superview?.isHidden ?? true }
}
