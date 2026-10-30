import XCTest
import AppKit
@testable import AnodeApp

final class BetaColumnHeightTests: XCTestCase {
    func testColumnsKeepTheirNaturalHeight() {
        _ = NSApplication.shared
        let c = BetaFeaturesWindowController()
        c.window!.contentView!.layoutSubtreeIfNeeded()
        var stacks: [NSStackView] = []
        func walk(_ v: NSView, _ depth: Int) {
            if let sv = v as? NSStackView, sv.orientation == .vertical, depth <= 5, sv.frame.width == BetaFeaturesWindowController.columnWidth,
               sv.arrangedSubviews.count >= 2, sv.arrangedSubviews.contains(where: { $0 is NSStackView }) { stacks.append(sv) }
            v.subviews.forEach { walk($0, depth + 1) }
        }
        walk(c.window!.contentView!, 0)
        let columns = stacks.filter { $0.arrangedSubviews.contains { $0 is NSBox } || $0.arrangedSubviews.count >= 2 }
        XCTAssertFalse(columns.isEmpty)
        for col in columns {
            XCTAssertEqual(col.frame.height, col.fittingSize.height, accuracy: 1.5, "a column is as tall as its sections need, not stretched to its neighbour")
        }
    }
}
