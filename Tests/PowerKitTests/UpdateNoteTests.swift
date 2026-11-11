import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The two sentences that say what an update is, and the version beside them.
final class UpdateNoteTests: XCTestCase {

    // ── Reading the file ────────────────────────────────────────────────────

    func testPlainTextComesBackAsItIs() {
        XCTAssertEqual(UpdateNote.text(from: "One thing. Another thing.\n"), "One thing. Another thing.")
    }

    func testHeadingsAndCommentsAreNotPartOfTheNote() {
        let raw = """
        # Release note
        <!-- instructions for whoever writes the next one,
             over two lines -->
        Uses less power. Fixes a highlight.
        """
        XCTAssertEqual(UpdateNote.text(from: raw), "Uses less power. Fixes a highlight.")
    }

    func testALineWrappedParagraphIsOneParagraph() {
        XCTAssertEqual(UpdateNote.text(from: "It does a thing\nacross   lines.\n\n  And more."), "It does a thing across lines. And more.")
    }

    func testNothingToSayIsNil() {
        XCTAssertNil(UpdateNote.text(from: nil))
        XCTAssertNil(UpdateNote.text(from: ""))
        XCTAssertNil(UpdateNote.text(from: "<!-- only a comment -->\n# only a heading\n\n"))
    }

    func testALongNoteIsCutAtASentenceEnd() {
        let first = "This is the first sentence and it is of a reasonable length for a small window."
        let long = first + " " + String(repeating: "word ", count: 200) + "end."
        let cut = UpdateNote.text(from: long)!
        XCTAssertLessThanOrEqual(cut.count, UpdateNote.maxLength)
        XCTAssertEqual(cut, first)
    }

    func testALongNoteWithNoSentenceEndIsCutAtAWordWithAnEllipsis() {
        let cut = UpdateNote.text(from: String(repeating: "word ", count: 200))!
        XCTAssertLessThanOrEqual(cut.count, UpdateNote.maxLength + 1)
        XCTAssertTrue(cut.hasSuffix("word…"), cut)
    }

    func testSentenceCount() {
        XCTAssertEqual(UpdateNote.sentenceCount("One. Two."), 2)
        XCTAssertEqual(UpdateNote.sentenceCount("One. Two! Three?"), 3)
        XCTAssertEqual(UpdateNote.sentenceCount("No full stop"), 1)
        XCTAssertEqual(UpdateNote.sentenceCount(""), 0)
        XCTAssertEqual(UpdateNote.sentenceCount("Version 1.15.0 is out. Done."), 2, "a number's dots are not sentence ends")
    }

    // ── The version ─────────────────────────────────────────────────────────

    func testTheVersionIsReadFromTheBuildScript() {
        XCTAssertEqual(UpdateNote.version(inBuildScript: "#!/bin/bash\nAPP=x\nVERSION=\"1.15.0\"\nBUILD=1\n"), "1.15.0")
        XCTAssertEqual(UpdateNote.version(inBuildScript: "VERSION=\"2.0\""), "2.0")
    }

    func testAnythingThatIsNotAVersionIsNil() {
        XCTAssertNil(UpdateNote.version(inBuildScript: nil))
        XCTAssertNil(UpdateNote.version(inBuildScript: "VERSION=\"\"\n"))
        XCTAssertNil(UpdateNote.version(inBuildScript: "VERSION=\"1.x.0\"\n"))
        XCTAssertNil(UpdateNote.version(inBuildScript: "VERSION=\"7\"\n"))
        XCTAssertNil(UpdateNote.version(inBuildScript: "# VERSION=\"1.0.0\"\n"))
    }

    // ── From a real checkout: what the UPSTREAM commit says, before pulling ─

    private func sh(_ args: [String], in dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }

    func testTheNoteAndVersionComeFromTheUpstreamCommitNotTheWorkingCopy() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anode-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = root.appendingPathComponent("origin"), clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        sh(["git", "init", "--initial-branch=main"], in: origin)
        sh(["git", "config", "user.email", "t@example.com"], in: origin)
        sh(["git", "config", "user.name", "T"], in: origin)
        try "VERSION=\"1.0.0\"\n".write(to: origin.appendingPathComponent("build-app.sh"), atomically: true, encoding: .utf8)
        sh(["git", "add", "."], in: origin); sh(["git", "commit", "-m", "first"], in: origin)
        sh(["git", "clone", "--quiet", origin.path, clone.path], in: root)

        // Nothing upstream yet says anything.
        XCTAssertNil(SourceCheckout.atPath(clone.path).upstreamNote())
        XCTAssertEqual(SourceCheckout.atPath(clone.path).upstreamVersion(), "1.0.0")

        // A newer commit lands upstream; the clone has fetched but not pulled.
        try "VERSION=\"1.1.0\"\n".write(to: origin.appendingPathComponent("build-app.sh"), atomically: true, encoding: .utf8)
        try "# note\nIt does a new thing. It fixes an old one.\n".write(to: origin.appendingPathComponent(UpdateNote.fileName),
                                                                       atomically: true, encoding: .utf8)
        sh(["git", "add", "."], in: origin); sh(["git", "commit", "-m", "second"], in: origin)
        let c = SourceCheckout.atPath(clone.path)
        XCTAssertTrue(c.fetch())
        XCTAssertEqual(c.upstreamNote(), "It does a new thing. It fixes an old one.")
        XCTAssertEqual(c.upstreamVersion(), "1.1.0")
        XCTAssertNil(try? String(contentsOf: clone.appendingPathComponent(UpdateNote.fileName)),
                     "the working copy has not been touched: this is what is ABOUT to be installed")
    }
}

/// The update panel with a description.
final class UpdatePanelNoteTests: XCTestCase {

    private func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if let f = view as? NSTextField, !f.isHidden { out.append(f.stringValue) }
        for s in view.subviews where !s.isHidden { out += texts(in: s) }
        return out
    }

    private let note = "Anode now idles properly with the lid shut in Keep Awake. The Sensors list no longer lights every row."

    func testTheHeadingNamesTheVersionAndTheNoteIsShown() {
        let panel = UpdatePanelController(build: 437, version: "1.15.0", note: note)
        let shown = texts(in: panel.window?.contentView)
        XCTAssertTrue(shown.contains("Updating to Anode 1.15.0…"), "\(shown)")
        XCTAssertTrue(shown.contains(note), "\(shown)")
        XCTAssertTrue(shown.contains { $0.contains("version 1.15.0 (build 437)") }, "the reopen line names version and build: \(shown)")
    }

    func testWithoutANoteOrVersionItIsTheOldPanel() {
        let panel = UpdatePanelController(build: 437)
        let shown = texts(in: panel.window?.contentView)
        XCTAssertTrue(shown.contains("Updating Anode…"), "\(shown)")
        XCTAssertFalse(shown.contains(note))
        XCTAssertTrue(shown.contains { $0.contains("build 437") })
    }

    func testTheWindowGrowsToHoldTheNoteAndNoTaller() {
        let plain = UpdatePanelController(build: 1)
        let withNote = UpdatePanelController(build: 1, version: "1.15.0", note: note)
        let a = plain.window!.contentLayoutRect.height, b = withNote.window!.contentLayoutRect.height
        XCTAssertGreaterThan(b, a + 20, "two sentences take several lines at this width")
        XCTAssertLessThan(b, 300)
    }

    func testAFailedUpdateDropsTheNoteAndShowsTheReason() {
        let panel = UpdatePanelController(build: 1, version: "1.15.0", note: note)
        panel.fail("The update did not finish.", log: URL(fileURLWithPath: "/tmp/none.log"))
        let shown = texts(in: panel.window?.contentView)
        XCTAssertFalse(shown.contains(note), "\(shown)")
        XCTAssertTrue(shown.contains("The update did not finish."))
    }
}
