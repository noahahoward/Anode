import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The chevron's right-click menu. The menu is built and its items are performed, but no status item is created.
final class BarChevronTests: XCTestCase {

    private func menu(isOpen: Bool = false, autoClose: Int = 10, toggled: @escaping () -> Void = {},
                      chose: @escaping (Int) -> Void = { _ in }, beta: @escaping () -> Void = {}) -> NSMenu {
        BarChevron.buildMenu(isOpen: isOpen, autoClose: autoClose, onToggle: toggled, onAutoClose: chose, onOpenBeta: beta)
    }

    /// `performActionForItem` does nothing without a menu on screen; performing the item's action on its target is what a click does.
    private func fire(_ menu: NSMenu?, at index: Int) {
        guard let item = menu?.item(at: index), let action = item.action else { return XCTFail("no item at \(index)") }
        _ = (item.target as? NSObject)?.perform(action)
    }

    func testMenuTitleFollowsState() {
        XCTAssertEqual(menu(isOpen: false).items.first?.title, "Show icons")
        XCTAssertEqual(menu(isOpen: true).items.first?.title, "Hide icons")
    }

    func testTheToggleItemRunsTheToggle() {
        var toggled = 0
        let m = menu(toggled: { toggled += 1 })
        fire(m, at: 0)
        XCTAssertEqual(toggled, 1)
    }

    func testAutoCloseChoicesAndCheckmark() {
        let parent = menu(autoClose: 30).items.first { $0.title == "Hide again after" }
        let titles = parent?.submenu?.items.map(\.title)
        XCTAssertEqual(titles, ["5 seconds", "10 seconds", "30 seconds", "Never"])
        XCTAssertEqual(parent?.submenu?.items.map(\.state), [.off, .off, .on, .off])
        XCTAssertEqual(menu(autoClose: 0).items.first { $0.title == "Hide again after" }?.submenu?.items.map(\.state), [.off, .off, .off, .on])
    }

    func testChoosingAnAutoCloseReportsTheSeconds() {
        var chosen: [Int] = []
        let sub = menu(chose: { chosen.append($0) }).items.first { $0.title == "Hide again after" }?.submenu
        fire(sub, at: 0)
        fire(sub, at: 3)
        XCTAssertEqual(chosen, [5, 0])
    }

    func testMenuHasOpenBetaFeaturesItem() {
        var opened = 0
        let m = menu(beta: { opened += 1 })
        let index = m.items.firstIndex { $0.title == "Open Beta Features…" }
        XCTAssertNotNil(index)
        fire(m, at: index!)
        XCTAssertEqual(opened, 1)
    }
}
