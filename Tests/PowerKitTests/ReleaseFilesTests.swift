import XCTest
@testable import PowerKit

/// The files a release is made of must agree, so a push cannot go out with the version, the changelog and the note
/// telling three different stories. (Which was how 1.0.0 stayed 1.0.0 for three months.)
final class ReleaseFilesTests: XCTestCase {

    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheVersionIsWellFormed() throws {
        let v = try XCTUnwrap(UpdateNote.version(inBuildScript: try read("build-app.sh")))
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "MAJOR.MINOR.PATCH, got \(v)")
    }

    func testTheChangelogsNewestEntryIsTheBuildScriptsVersion() throws {
        let version = try XCTUnwrap(UpdateNote.version(inBuildScript: try read("build-app.sh")))
        let top = try read("CHANGELOG.md").split(separator: "\n").first { $0.hasPrefix("## ") }
        XCTAssertTrue(top?.hasPrefix("## \(version) ") ?? false,
                      "VERSION is \(version) but the newest CHANGELOG.md entry is \(top.map(String.init) ?? "missing"): bump both, and rewrite UPDATE-NOTE.md")
    }

    func testTheNoteIsTwoSentencesThatFitTheUpdateScreen() throws {
        let note = try XCTUnwrap(UpdateNote.text(from: try read(UpdateNote.fileName)), "UPDATE-NOTE.md has no text")
        XCTAssertEqual(UpdateNote.sentenceCount(note), 2, "two sentences, as the update screen promises: \(note)")
        XCTAssertLessThan(note.count, UpdateNote.maxLength, "it would be cut on the screen")
    }
}
