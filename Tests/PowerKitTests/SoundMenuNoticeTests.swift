import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The line under the rows (a refusal's reason, a missing permission) was always given room for two lines: a short one left a line
/// of empty glass under it, before the footer.
final class SoundMenuNoticeTests: XCTestCase {

    private typealias M = SoundMenuMetrics

    override func setUp() { super.setUp(); _ = NSApplication.shared }

    private func model(notice: String?) -> SoundMenuModel {
        SoundMenuModel(volume: 0.5, muted: false, devices: [.init(id: "a", name: "MacBook Pro Speakers", kind: .speakers, isSelected: true)],
                       expandedDevice: nil, listening: [], spatial: [], conversation: [], appleAvailable: true, notice: notice)
    }

    private func noticeRow(_ r: SoundMenuLayout.Result) -> CGRect? { r.rows.first { $0.kind == .notice }?.frame }

    // ── The layout ──────────────────────────────────────────────────────────

    func testAOneLineNoticeTakesOneLineAndTheMenuIsThatMuchShorter() throws {
        let one = SoundMenuLayout.frames(for: model(notice: "x"), noticeLines: 1)
        let two = SoundMenuLayout.frames(for: model(notice: "x"), noticeLines: 2)
        XCTAssertEqual(try XCTUnwrap(noticeRow(one)).height, M.noticeLineHeight)
        XCTAssertEqual(try XCTUnwrap(noticeRow(two)).height, 2 * M.noticeLineHeight)
        XCTAssertEqual(two.height - one.height, M.noticeLineHeight, accuracy: 0.01)
    }

    func testTwoLinesAreWhatTheNoticeAlwaysHad() {
        XCTAssertEqual(2 * M.noticeLineHeight, 30, "a two-line notice is drawn as before")
        XCTAssertEqual(SoundMenuLayout.frames(for: model(notice: "x")), SoundMenuLayout.frames(for: model(notice: "x"), noticeLines: 2))
    }

    func testWithoutANoticeTheLinesDoNotMatter() {
        XCTAssertEqual(SoundMenuLayout.frames(for: model(notice: nil), noticeLines: 1), SoundMenuLayout.frames(for: model(notice: nil), noticeLines: 2))
    }

    // ── How many lines a notice is, as it is drawn ──────────────────────────

    func testAShortNoticeIsOneLineAndALongOneTwo() {
        XCTAssertEqual(SoundMenuContentView.noticeLines("Couldn't change that just now."), 1)
        XCTAssertEqual(SoundMenuContentView.noticeLines("Put Test AirPods Pro Max in both ears to use Adaptive Audio."), 2)
    }

    func testTheMenuDrawsAShortNoticeOnOneLine() {
        let short = SoundMenuContentView(), long = SoundMenuContentView()
        short.apply(model(notice: "Couldn't change that just now."))
        long.apply(model(notice: "Put Test AirPods Pro Max in both ears to use Adaptive Audio."))
        XCTAssertEqual(long.fittingSize.height - short.fittingSize.height, M.noticeLineHeight, accuracy: 0.01,
                       "no empty line under a short notice")
    }
}
