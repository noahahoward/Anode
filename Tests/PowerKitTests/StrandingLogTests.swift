import XCTest
@testable import AnodeApp

/// One line when the window is lost and one when it comes back — nothing in
/// between, however long that is.
final class StrandingLogTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingIsLoggedWhileTheWindowIsFine() {
        var log = StrandingLog()
        XCTAssertNil(log.observe(stranded: false, at: t0))
        XCTAssertNil(log.observe(stranded: false, at: t0 + 2))
    }

    func testTheOnsetIsLoggedOnceNotOnEveryTick() {
        var log = StrandingLog()
        XCTAssertEqual(log.observe(stranded: true, at: t0), .began(at: t0))
        XCTAssertNil(log.observe(stranded: true, at: t0 + 2))
        XCTAssertNil(log.observe(stranded: true, at: t0 + 86_400))
    }

    func testRecoveryCarriesHowLongItLasted() {
        var log = StrandingLog()
        _ = log.observe(stranded: true, at: t0)
        XCTAssertEqual(log.observe(stranded: false, at: t0 + 90),
                       .ended(at: t0 + 90, after: 90))
    }

    func testASecondEpisodeIsLoggedAgain() {
        var log = StrandingLog()
        _ = log.observe(stranded: true, at: t0)
        _ = log.observe(stranded: false, at: t0 + 10)
        XCTAssertEqual(log.observe(stranded: true, at: t0 + 20), .began(at: t0 + 20))
    }

    func testTheLinesSayWhichEventAndCarryTheContext() {
        XCTAssertTrue(StrandingLog.line(for: .began(at: t0), context: "screens=1")
            .hasSuffix("STRANDED screens=1"))
        XCTAssertTrue(StrandingLog.line(for: .ended(at: t0, after: 90.4), context: "x")
            .contains("recovered after 90 s x"))
    }

    func testAppendingCreatesTheFileThenAddsToIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anode-stranding-\(UUID().uuidString)/log.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StrandingLog.append("one", to: url)
        StrandingLog.append("two", to: url)
        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("two") { break }
            usleep(20_000)
        }
        XCTAssertEqual(text, "one\ntwo\n")
    }
}
