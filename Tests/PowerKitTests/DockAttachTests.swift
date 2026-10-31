import XCTest
import AppKit
@testable import AnodeApp

final class DockAttachTests: XCTestCase {

    // ── When the connection to the Dock is stale ──

    func testAHealthyConnectionIsLeftAlone() {
        XCTAssertFalse(DockPreviews.shouldReattach(attachedPID: 410, currentPID: 410, listAnswers: true))
    }

    func testARestartedDockOrADeadListMeansAttachAgain() {
        XCTAssertTrue(DockPreviews.shouldReattach(attachedPID: 410, currentPID: 977, listAnswers: true), "a new Dock process")
        XCTAssertTrue(DockPreviews.shouldReattach(attachedPID: 410, currentPID: nil, listAnswers: false), "no Dock at all")
        XCTAssertTrue(DockPreviews.shouldReattach(attachedPID: 410, currentPID: 410, listAnswers: false), "the list stopped answering")
    }

    func testNothingAttachedMeansNothingToCheck() {
        XCTAssertFalse(DockPreviews.shouldReattach(attachedPID: nil, currentPID: 410, listAnswers: false))
    }

    // ── The log ──

    func testTextFromOutsideCannotForgeALine() {
        let forged = FeatureLog.clean("Dock item\n2026-01-01T00:00:00Z attached to the Dock\u{7}", limit: 240)
        XCTAssertFalse(forged.contains("\n"))
        XCTAssertFalse(forged.unicodeScalars.contains { $0.value < 0x20 })
        XCTAssertEqual(FeatureLog.clean(String(repeating: "x", count: 1000), limit: 240).count, 240)
    }

    func testTheLogIsTrimmedFromALineBoundaryAndKeptSmall() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("featurelog-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = (0..<400).map { "line \($0) " + String(repeating: "y", count: 40) }.joined(separator: "\n") + "\n"
        try lines.write(to: url, atomically: true, encoding: .utf8)
        FeatureLog.trim(url, maxBytes: 4_000)
        let kept = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(kept.utf8.count, 2_000, "the older half is gone")
        XCTAssertTrue(kept.hasPrefix("line "), "it starts at a whole line, not mid-line")
        XCTAssertTrue(kept.contains("line 399"), "the newest lines survive")
        XCTAssertFalse(kept.contains("line 0 "))
        // A small file is left alone.
        try "short\n".write(to: url, atomically: true, encoding: .utf8)
        FeatureLog.trim(url, maxBytes: 4_000)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "short\n")
    }
}
