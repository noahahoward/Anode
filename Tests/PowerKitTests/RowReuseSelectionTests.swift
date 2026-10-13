import XCTest
@testable import AnodeApp

/// A reused row must report what it shows NOW, not what it was built showing.
///
/// `BodyStack.setItems` re-texts the views already in the stack when the shape
/// of the list is unchanged, and the Sensors list is sorted hottest-first — so
/// the same view shows a different sensor from one tick to the next. The click
/// handlers were wired once, at build, with the label of the moment: clicking a
/// row then picked whichever sensor that view had started out as, and the
/// highlight landed on a different row from the one under the pointer.
final class RowReuseSelectionTests: XCTestCase {

    private func rows(in stack: BodyStack) -> [SystemPane.BarRow] {
        stack.arrangedSubviews.compactMap { $0 as? SystemPane.BarRow }
    }

    func testAReusedRowReportsTheLabelItShowsNow() {
        let stack = BodyStack()
        var picked: [String] = []
        stack.onSelectRow = { picked.append($0) }

        stack.setItems([.row("CPU sensor 24", "61.0 °C"), .row("CPU sensor 26", "60.0 °C")])
        let before = rows(in: stack)
        // 26 warms past 24 and the two trade places.
        stack.setItems([.row("CPU sensor 26", "62.0 °C"), .row("CPU sensor 24", "61.0 °C")])
        let after = rows(in: stack)
        XCTAssertTrue(before[0] === after[0], "the views are meant to be reused")

        after[0].onSelect?()
        after[1].onSelect?()
        XCTAssertEqual(picked, ["CPU sensor 26", "CPU sensor 24"])
    }

    /// The same wiring on group headers, which are reused the same way.
    func testAReusedGroupHeaderReportsTheGroupItShowsNow() {
        let stack = BodyStack()
        var toggled: [String] = []
        stack.onToggleGroup = { toggled.append($0) }

        stack.setItems([.group("CPU", "12 · 61.0 °C max", expanded: false)])
        stack.setItems([.group("GPU", "8 · 55.0 °C max", expanded: false)])
        (stack.arrangedSubviews.first as? SystemPane.GroupHeaderView)?.onToggle?()
        XCTAssertEqual(toggled, ["GPU"])
    }
}
