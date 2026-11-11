import XCTest
import AppKit
@testable import AnodeApp

/// The two caches that took font creation and text measurement out of every tick of the open window.
final class FontCacheTests: XCTestCase {

    func testTheSameRequestIsTheSameFont() {
        XCTAssertTrue(Palette.Font.mono(11) === Palette.Font.mono(11))
        XCTAssertTrue(Palette.Font.sans(11.5, .semibold) === Palette.Font.sans(11.5, .semibold))
    }

    func testSizeWeightAndKindEachMakeADifferentFont() {
        let base = Palette.Font.mono(11)
        XCTAssertFalse(base === Palette.Font.mono(12))
        XCTAssertFalse(base === Palette.Font.mono(11, .bold))
        XCTAssertFalse(base === Palette.Font.sans(11))
    }

    /// A cached font must be exactly what the system would have built, or the table changes look.
    func testACachedFontIsTheOneTheSystemWouldHaveBuilt() {
        XCTAssertEqual(Palette.Font.mono(11), NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        XCTAssertEqual(Palette.Font.sans(11.5, .semibold), NSFont.systemFont(ofSize: 11.5, weight: .semibold))
        XCTAssertEqual(Palette.Font.label(), NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold))
    }

    func testTheCacheStaysBoundedWhateverSizesAreAskedFor() {
        for i in 0..<1_000 { _ = Palette.Font.mono(CGFloat(6 + i) / 10) }
        XCTAssertLessThanOrEqual(Palette.Font.cachedCount, 129)
    }

    func testItIsSafeFromSeveralThreads() {
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            _ = Palette.Font.mono(CGFloat(9 + i % 5))
            _ = Palette.Font.sans(CGFloat(9 + i % 5))
        }
    }
}

final class TextWidthMemoTests: XCTestCase {

    func testItMeasuresWhatTheTypesetterMeasures() {
        var memo = TextWidthMemo()
        let font = Palette.Font.mono(11)
        for text in ["", "0.0", "Brave Browser", "com.apple.WebKit.WebContent (Safari)"] {
            XCTAssertEqual(memo.width(of: text, in: font),
                           (text as NSString).size(withAttributes: [.font: font]).width, accuracy: 0.0001, text)
        }
    }

    func testAnAskedAgainStringIsNotMeasuredAgain() {
        var memo = TextWidthMemo()
        let font = Palette.Font.mono(11)
        _ = memo.width(of: "12.5", in: font)
        _ = memo.width(of: "12.5", in: font)
        _ = memo.width(of: "12.5", in: font)
        XCTAssertEqual(memo.count, 1)
    }

    func testTheSameTextAtAnotherFontIsAnotherMeasurement() {
        var memo = TextWidthMemo()
        let a = memo.width(of: "Anode", in: Palette.Font.sans(11.5, .regular))
        let b = memo.width(of: "Anode", in: Palette.Font.sans(11.5, .semibold))
        XCTAssertEqual(memo.count, 2)
        XCTAssertNotEqual(a, b, "a bold name is wider, and sizing the column to the regular width would clip it")
    }

    func testItIsBoundedSoALongRunCannotGrowItWithoutLimit() {
        var memo = TextWidthMemo()
        let font = Palette.Font.mono(11)
        for i in 0..<(TextWidthMemo.limit * 2 + 10) { _ = memo.width(of: "process-\(i)", in: font) }
        XCTAssertLessThanOrEqual(memo.count, TextWidthMemo.limit)
    }

    /// The point of the exercise: the second pass over a screenful of text must be much cheaper than the first.
    func testRemeasuringAScreenfulIsFasterThanMeasuringIt() {
        var memo = TextWidthMemo()
        let font = Palette.Font.mono(11)
        let texts = (0..<400).map { "Process \($0) 12.\($0 % 10)" }
        func pass() -> CFAbsoluteTime {
            let t = CFAbsoluteTimeGetCurrent()
            for s in texts { _ = memo.width(of: s, in: font) }
            return CFAbsoluteTimeGetCurrent() - t
        }
        let first = pass()
        let second = pass()
        XCTAssertLessThan(second, first / 3, "first \(first * 1000) ms, second \(second * 1000) ms")
    }
}
