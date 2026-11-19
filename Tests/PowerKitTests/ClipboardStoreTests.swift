import CoreGraphics
import ImageIO
import XCTest
@testable import PowerKit

/// The Clipboard History store: how a copy becomes an entry, what is kept of a big one, how the limits keep it small, and what
/// is on disk (the folder is private, a bad index starts again, nothing is left over from a crash).
///
/// Every test makes its own store in a folder of its own under the temporary directory and removes it afterwards. None reads
/// or writes the real pasteboard or the real Application Support folder. The dates are whole seconds because the index keeps
/// seconds only, and a date that must survive a reload has to be one.
final class ClipboardStoreTests: XCTestCase {

    /// A clock the test moves by hand: the store's own idea of "now".
    private final class TickingClock {
        var date: Date
        init(_ date: Date) { self.date = date }
        func advance(by seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    private struct Unexpected: Error {}

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let plain = "public.utf8-plain-text"
    private let fileURL = "public.file-url"

    private var root: URL!
    private var clock: TickingClock!
    private var directory: URL { root.appendingPathComponent(ClipboardStore.folderName, isDirectory: true) }
    private var blobsFolder: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.anode.tests.clipboard-store.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = TickingClock(start)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private func makeLimits(maxEntries: Int = 1000, maxEntryBytes: Int = 1_000_000, maxTotalBytes: Int = 100_000_000,
                            maxAge: TimeInterval? = nil) -> ClipboardStore.Limits {
        ClipboardStore.Limits(maxEntries: maxEntries, maxEntryBytes: maxEntryBytes, maxTotalBytes: maxTotalBytes, maxAge: maxAge)
    }

    private func makeStore(_ limits: ClipboardStore.Limits? = nil) -> ClipboardStore {
        let clock = self.clock!
        return ClipboardStore(directory: directory, limits: limits ?? makeLimits(), now: { clock.date })
    }

    private func rep(_ type: String, _ string: String, item: Int = 0) -> ClipboardRepresentation {
        ClipboardRepresentation(item: item, type: type, data: Data(string.utf8))
    }

    private func snapshot(_ reps: [ClipboardRepresentation], at offset: TimeInterval = 0, from app: String? = nil,
                          named name: String? = nil) -> ClipboardSnapshot {
        ClipboardSnapshot(representations: reps, sourceBundleID: app, sourceName: name, date: start.addingTimeInterval(offset))
    }

    private func textCopy(_ string: String, at offset: TimeInterval = 0, from app: String? = nil,
                          named name: String? = nil) -> ClipboardSnapshot {
        snapshot([rep(plain, string)], at: offset, from: app, named: name)
    }

    private func addedID(_ result: ClipboardStore.AddResult, file: StaticString = #filePath, line: UInt = #line) throws -> UUID {
        guard case .added(let id) = result else {
            XCTFail("expected .added, got \(result)", file: file, line: line)
            throw Unexpected()
        }
        return id
    }

    @discardableResult
    private func addText(_ store: ClipboardStore, _ string: String, at offset: TimeInterval = 0, file: StaticString = #filePath,
                         line: UInt = #line) throws -> UUID {
        try addedID(store.add(textCopy(string, at: offset)), file: file, line: line)
    }

    private func isSkipped(_ result: ClipboardStore.AddResult) -> Bool {
        if case .skipped = result { return true }
        return false
    }

    private func blobFolder(_ id: UUID) -> URL { blobsFolder.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// The names of the folders under `blobs`, sorted; none when there is no such folder.
    private func blobFolderNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: blobsFolder.path)) ?? []).sorted()
    }

    private func names(of ids: [UUID]) -> [String] { ids.map(\.uuidString).sorted() }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return number.intValue & 0o777
    }

    /// A small valid PNG, made here: a solid colour `width` by `height`.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // ── What a copy becomes ─────────────────────────────────────────────────

    /// The commonest copy: some words. The entry says what they are, shows them, and a search can look through them.
    func testATextCopyBecomesATextEntryWithItsPreviewAndText() throws {
        let store = makeStore()
        let id = try addedID(store.add(textCopy("remember the milk", at: 5, from: "com.apple.Notes", named: "Notes")))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .text)
        XCTAssertEqual(entry.text, "remember the milk")
        XCTAssertEqual(entry.preview, "remember the milk")
        XCTAssertNil(entry.detail, "one line has nothing to count")
        XCTAssertEqual(entry.sourceBundleID, "com.apple.Notes")
        XCTAssertEqual(entry.sourceName, "Notes")
        XCTAssertEqual(entry.date, start.addingTimeInterval(5))
        XCTAssertFalse(entry.pinned)
        XCTAssertEqual(entry.byteSize, "remember the milk".utf8.count)
        XCTAssertEqual(store.entries, [entry])
    }

    /// A copy of several lines: the row shows the first, and the second line of it says how many there are.
    func testAMultiLineTextCopyShowsItsFirstLineAndHowManyLines() throws {
        let store = makeStore()
        let id = try addedID(store.add(textCopy("first line\nsecond line\nthird line")))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .text)
        XCTAssertEqual(entry.preview, "first line")
        XCTAssertEqual(entry.text, "first line\nsecond line\nthird line")
        XCTAssertEqual(entry.detail, "3 lines")
    }

    /// Blank lines and spaces at the top of a copy are no use as a preview: it is the first line with something in it.
    func testThePreviewIsTheFirstLineThatHasAnythingInIt() throws {
        let store = makeStore()
        let id = try addedID(store.add(textCopy("\n\n   hello world  \nsecond")))
        XCTAssertEqual(try XCTUnwrap(store.entry(id)).preview, "hello world")
    }

    /// What a search looks through, and what a row shows, are the start of the copy only; the whole of it is on disk, ready to
    /// be pasted again.
    func testAVeryLongCopyKeepsTheStartForSearchAndAPreviewButAllOfItOnDisk() throws {
        let store = makeStore()
        let long = String(repeating: "a", count: 5000)
        let id = try addedID(store.add(textCopy(long)))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.text.count, ClipboardEntry.searchableCharacters)
        XCTAssertEqual(entry.preview.count, ClipboardEntry.previewCharacters)
        XCTAssertEqual(entry.byteSize, 5000)
        XCTAssertEqual(try XCTUnwrap(store.payload(for: id)).first?.data.count, 5000)
    }

    /// A copy that is one web address (or another address with a scheme) is a link.
    func testASingleWebAddressIsALink() throws {
        let store = makeStore()
        let links = ["https://example.com/page?q=1", "http://example.com", "ftp://files.example.com/a.zip",
                     "mailto:someone@example.com", "  https://example.com/padded  \n"]
        for (n, text) in links.enumerated() {
            try addText(store, text, at: TimeInterval(n + 1))
            XCTAssertEqual(store.entries.first?.kind, .link, text)
            XCTAssertNil(store.entries.first?.detail, "a link has no line count")
        }
        XCTAssertEqual(store.entries.first?.preview, "https://example.com/padded", "the padding is not part of the preview")
    }

    /// Prose with an address inside it is something somebody wrote, and stays text. So does anything that only looks a little
    /// like an address.
    func testProseThatHasAnAddressInItIsText() throws {
        let store = makeStore()
        let notLinks = ["see https://example.com for details", "example.com", "file:///Users/example/notes.txt",
                        "javascript:alert(1)", "https://example.com\nhttps://example.org"]
        for (n, text) in notLinks.enumerated() {
            try addText(store, text, at: TimeInterval(n + 1))
            XCTAssertEqual(store.entries.first?.kind, .text, text)
        }
    }

    /// A copy that carries only an address type (no text beside it) is still a link, and shows the address.
    func testAnAddressTypeAloneIsALinkWithItsText() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([rep("public.url", "https://example.com/doc")])))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .link)
        XCTAssertEqual(entry.text, "https://example.com/doc")
        XCTAssertEqual(entry.preview, "https://example.com/doc")
        XCTAssertEqual(entry.parts.map(\.type), ["public.url"])
    }

    /// Files copied in Finder: the row shows their names, the second line says how many, and the paths are what a search sees.
    func testAFileCopyIsAFileEntryWithItsNamesAndCount() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([
            rep(fileURL, "file:///Users/example/Documents/report.pdf", item: 0),
            rep(fileURL, "file:///Users/example/Pictures/photo.png", item: 1),
        ])))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.preview, "report.pdf, photo.png")
        XCTAssertEqual(entry.detail, "2 files")
        XCTAssertEqual(entry.text, "/Users/example/Documents/report.pdf\n/Users/example/Pictures/photo.png")
        XCTAssertEqual(entry.parts.count, 2)
    }

    /// One file says "File", and a name with spaces in it is shown with the spaces, not as it is written in the address.
    func testOneFileSaysFileAndItsNameIsShownAsItIsCalled() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([rep(fileURL, "file:///Users/example/My%20Docs/a%20b.txt")])))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.detail, "File")
        XCTAssertEqual(entry.preview, "a b.txt")
        XCTAssertEqual(entry.text, "/Users/example/My Docs/a b.txt")
    }

    /// Finder puts the file's name on the pasteboard as text beside the file itself; the file is what was copied.
    func testAFileIsAFileEvenWithItsNameAsTextBesideIt() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([rep(fileURL, "file:///Users/example/Documents/report.pdf"), rep(plain, "report.pdf")])))
        XCTAssertEqual(try XCTUnwrap(store.entry(id)).kind, .file)
    }

    /// A picture: its size is the second line, and what was stored is the PNG itself.
    func testAPNGIsAnImageWithItsSize() throws {
        let data = try png(width: 4, height: 3)
        // The PNG made here is checked on its own, with ImageIO and not with the code under test, so a fault in making it is
        // not taken for a fault in the store.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 3)

        let store = makeStore()
        let id = try addedID(store.add(snapshot([ClipboardRepresentation(item: 0, type: "public.png", data: data)])))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.text, "Image")
        XCTAssertEqual(entry.preview, "Image")
        XCTAssertEqual(entry.detail, "4 \u{00D7} 3")
        XCTAssertEqual(entry.parts.map(\.type), ["public.png"])
        XCTAssertEqual(try XCTUnwrap(store.payload(for: id)).first?.data, data)
    }

    /// Bytes that say they are a picture and are not one are still kept as an image, with no size to show.
    func testAnImageThatCannotBeReadHasNoSize() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([ClipboardRepresentation(item: 0, type: "public.png", data: Data([0, 1, 2, 3]))])))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .image)
        XCTAssertNil(entry.detail)
    }

    /// With pictures switched off a picture is not kept (they are the big ones), and it says why; words still are.
    func testWithImagesOffAPictureIsSkippedAndTextIsNot() throws {
        let store = makeStore()
        let off = ClipboardStore.Policy(ignoredApps: [], keepImages: false)
        let data = try png(width: 4, height: 3)
        XCTAssertEqual(store.add(snapshot([ClipboardRepresentation(item: 0, type: "public.png", data: data)]), policy: off),
                       .skipped("images are off"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing was written for it")

        _ = try addedID(store.add(textCopy("still kept"), policy: off))
        XCTAssertEqual(store.entries.map(\.text), ["still kept"])
    }

    /// Text with its formatting and nothing else (no plain version): kept, and shown as formatted text.
    func testARichTextOnlyCopyIsShownAsFormattedText() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([rep("public.rtf", "{\\rtf1 hello}")])))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.kind, .text)
        XCTAssertEqual(entry.preview, "Formatted text")
        XCTAssertEqual(entry.text, "")
        XCTAssertEqual(entry.parts.map(\.type), ["public.rtf"])
    }

    /// Nothing in it, only a type nobody here reads, or only blanks: nothing to keep, said in a word, and nothing written.
    func testCopiesWithNothingToKeepAreSkippedWithAWord() {
        let store = makeStore()
        XCTAssertEqual(store.add(snapshot([])), .skipped("empty"))
        XCTAssertEqual(store.add(snapshot([rep("com.example.private-format", "data")])), .skipped("nothing to keep"))
        XCTAssertEqual(store.add(textCopy("  \n\t ")), .skipped("nothing to keep"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // ── The same copy again ─────────────────────────────────────────────────

    /// Copying the same thing twice is one entry, back at the top with the new time, and a pin is not lost.
    func testTheSameTextCopiedTwiceMovesToTheTopAndKeepsItsPin() throws {
        let store = makeStore()
        let alpha = try addedID(store.add(textCopy("alpha", at: 1)))
        try addText(store, "beta", at: 2)
        store.setPinned(alpha, true)
        XCTAssertEqual(store.entries.map(\.text), ["beta", "alpha"])

        XCTAssertEqual(store.add(textCopy("alpha", at: 3)), .moved(alpha))
        XCTAssertEqual(store.entries.map(\.text), ["alpha", "beta"], "one entry for alpha, and it is first")
        XCTAssertEqual(store.entries.first?.date, start.addingTimeInterval(3))
        XCTAssertEqual(store.entries.first?.pinned, true)
        XCTAssertEqual(blobFolderNames().count, 2, "the contents were not written a second time")

        let again = makeStore()
        XCTAssertEqual(again.entries.first?.id, alpha)
        XCTAssertEqual(again.entries.first?.date, start.addingTimeInterval(3), "the move was saved")
        XCTAssertEqual(again.entries.first?.pinned, true)
    }

    /// The same picture and the same files are recognised too, not only text.
    func testTheSamePictureAndTheSameFilesAreRecognisedAgain() throws {
        let store = makeStore()
        let data = try png(width: 5, height: 2)
        let picture = try addedID(store.add(snapshot([ClipboardRepresentation(item: 0, type: "public.png", data: data)], at: 1)))
        let files = try addedID(store.add(snapshot([rep(fileURL, "file:///Users/example/a.txt")], at: 2)))
        XCTAssertEqual(store.add(snapshot([ClipboardRepresentation(item: 0, type: "public.png", data: data)], at: 3)), .moved(picture))
        XCTAssertEqual(store.add(snapshot([rep(fileURL, "file:///Users/example/a.txt")], at: 4)), .moved(files))
        XCTAssertEqual(store.entries.map(\.id), [files, picture])
    }

    /// A different character is a different copy: nothing is merged on a guess.
    func testTextThatDiffersByACharacterIsAnotherEntry() throws {
        let store = makeStore()
        for (n, text) in ["Hello", "hello", "hello ", "hello."].enumerated() { try addText(store, text, at: TimeInterval(n + 1)) }
        XCTAssertEqual(store.entries.count, 4)
    }

    // ── What is stored, and given back ──────────────────────────────────────

    /// Every form of the copy that is kept comes back, in the order it was kept, with the very bytes, so pasting it again
    /// gives the app everything the first paste had.
    func testPayloadGivesBackEveryStoredFormInOrderWithTheSameBytes() throws {
        let store = makeStore()
        let reps = [
            rep(plain, "h\u{00E9}llo", item: 0),
            rep("public.html", "<b>h\u{00E9}llo</b>", item: 0),
            ClipboardRepresentation(item: 0, type: "public.rtf", data: Data([0x00, 0xFF, 0x10, 0x7F])),
            ClipboardRepresentation(item: 0, type: "com.example.private-format", data: Data([1, 2, 3, 4])),
            rep(plain, "second item", item: 1),
        ]
        let id = try addedID(store.add(snapshot(reps)))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.parts.map(\.type), reps.map(\.type))
        XCTAssertEqual(entry.parts.map(\.size), reps.map { $0.data.count })
        XCTAssertEqual(entry.byteSize, reps.reduce(0) { $0 + $1.data.count })
        XCTAssertEqual(store.totalBytes, entry.byteSize)
        XCTAssertEqual(try XCTUnwrap(store.payload(for: id)), reps)
    }

    /// An entry that is not there, and one whose contents have gone from disk, give nothing back rather than a half answer.
    func testPayloadOfAnUnknownEntryOrOneWhoseFilesAreGoneIsNil() throws {
        let store = makeStore()
        let id = try addText(store, "kept for now")
        XCTAssertNil(store.payload(for: UUID()))
        XCTAssertNil(store.entry(UUID()))
        XCTAssertNotNil(store.payload(for: id))
        try FileManager.default.removeItem(at: blobFolder(id))
        XCTAssertNil(store.payload(for: id))
    }

    /// A row's picture reads one stored form by its type, not all of them: that form's bytes, or nothing when the entry has no
    /// such form, the list of types is empty, or the file is gone.
    func testOneStoredFormCanBeReadByItsType() throws {
        let store = makeStore()
        let html = Data("<b>x</b>".utf8)
        let id = try addedID(store.add(snapshot([rep(plain, "x"), ClipboardRepresentation(item: 0, type: "public.html", data: html)])))
        XCTAssertEqual(store.data(for: id, ofType: ["public.html"]), html)
        XCTAssertEqual(store.data(for: id, ofType: [plain]), Data("x".utf8))
        XCTAssertNil(store.data(for: id, ofType: ["public.png"]))
        XCTAssertNil(store.data(for: id, ofType: []))
        XCTAssertNil(store.data(for: UUID(), ofType: [plain]))
        try FileManager.default.removeItem(at: blobFolder(id))
        XCTAssertNil(store.data(for: id, ofType: [plain]))
    }

    /// The markers say how an app wants a copy treated; one that is not itself a reason to refuse the copy (nspasteboard.org's
    /// source marker) is dropped from what is stored, so no entry carries one to be pasted back.
    func testMarkerTypesAreNeverStoredAsParts() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([
            rep("org.nspasteboard.source", "com.example.Editor"),
            rep(plain, "hello"),
            rep("org.nspasteboard.custom", "marker data"),
        ])))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.parts.map(\.type), [plain])
        XCTAssertEqual(try XCTUnwrap(store.payload(for: id)).map(\.type), [plain])
        let files = try FileManager.default.contentsOfDirectory(atPath: blobFolder(id).path)
        XCTAssertEqual(files.count, 1, "one stored form, one file")
        XCTAssertEqual(entry.byteSize, "hello".utf8.count)
    }

    // ── A copy over the size of one entry ───────────────────────────────────

    /// Over the limit, what survives is what is enough to paste the copy again: the text, the file or address, a picture, the
    /// rich forms. An app's private type is the first to go.
    func testACopyOverTheEntryLimitKeepsOnlyWhatIsEnoughToPasteAgain() throws {
        let store = makeStore(makeLimits(maxEntryBytes: 1000))
        let id = try addedID(store.add(snapshot([
            rep(plain, String(repeating: "a", count: 100)),
            rep("com.example.private-format", String(repeating: "p", count: 5000)),
            rep("public.rtf", String(repeating: "r", count: 400)),
        ])))
        XCTAssertEqual(try XCTUnwrap(store.entry(id)).parts.map(\.type), [plain, "public.rtf"])
        XCTAssertEqual(try XCTUnwrap(store.entry(id)).byteSize, 500)
    }

    /// When even those are too much, only the plain text is kept.
    func testWhenEvenThoseAreTooBigOnlyThePlainTextIsKept() throws {
        let store = makeStore(makeLimits(maxEntryBytes: 1000))
        let id = try addedID(store.add(snapshot([
            rep(plain, String(repeating: "b", count: 100)),
            rep("public.rtf", String(repeating: "r", count: 2000)),
        ])))
        XCTAssertEqual(try XCTUnwrap(store.entry(id)).parts.map(\.type), [plain])
        XCTAssertEqual(try XCTUnwrap(store.payload(for: id)).first?.data.count, 100)
    }

    /// A copy that cannot be kept in any form within the limit is skipped, and says it was too large; nothing is written.
    func testACopyThatCannotFitInAnyFormIsSkippedAsTooLarge() throws {
        let store = makeStore(makeLimits(maxEntryBytes: 1000))
        XCTAssertEqual(store.add(textCopy(String(repeating: "c", count: 2000))), .skipped("too large"))

        let picture = try png(width: 4, height: 3)
        XCTAssertGreaterThan(picture.count, 10)
        let tiny = makeStore(makeLimits(maxEntryBytes: 10))
        XCTAssertEqual(tiny.add(snapshot([ClipboardRepresentation(item: 0, type: "public.png", data: picture)])), .skipped("too large"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(tiny.entries.isEmpty)
    }

    /// The limit is a number of bytes a copy may be: exactly that many fits, one more does not.
    func testACopyOfExactlyTheEntryLimitFitsAndOneByteMoreDoesNot() throws {
        let store = makeStore(makeLimits(maxEntryBytes: 1000))
        let id = try addedID(store.add(textCopy(String(repeating: "d", count: 1000))))
        XCTAssertEqual(try XCTUnwrap(store.entry(id)).byteSize, 1000)
        XCTAssertEqual(store.add(textCopy(String(repeating: "e", count: 1001))), .skipped("too large"))
    }

    // ── Keeping to the limits ───────────────────────────────────────────────

    /// Older than the age limit is dropped, with its contents; a pinned entry is kept however old. The clock is the store's own.
    func testAnEntryOlderThanTheAgeLimitGoesButAPinnedOneStays() throws {
        let store = makeStore(makeLimits(maxAge: 3600))
        let pinnedOld = try addText(store, "pinned and old", at: -3000)
        let middle = try addText(store, "old and not pinned", at: -2800)
        let fresh = try addText(store, "fresh", at: -1000)
        store.setPinned(pinnedOld, true)
        XCTAssertEqual(store.entries.count, 3, "at this moment none is over the limit")

        clock.advance(by: 1000)
        store.prune()
        XCTAssertEqual(store.entries.map(\.id), [fresh, pinnedOld])
        XCTAssertNil(store.entry(middle))
        XCTAssertEqual(blobFolderNames(), names(of: [fresh, pinnedOld]), "the dropped entry's contents went with it")
        XCTAssertEqual(makeStore().entries.map(\.id), [fresh, pinnedOld], "and it was saved")
    }

    /// An entry exactly as old as the limit is kept; a second older, it goes.
    func testAnEntryExactlyAsOldAsTheLimitIsKept() throws {
        let store = makeStore(makeLimits(maxAge: 3600))
        let id = try addText(store, "on the line", at: -3600)
        store.prune()
        XCTAssertEqual(store.entries.map(\.id), [id])
        clock.advance(by: 1)
        store.prune()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(blobFolderNames().isEmpty)
    }

    /// A copy that is already older than the age limit is not kept at all, and leaves no contents behind.
    func testACopyAlreadyOlderThanTheAgeLimitIsNotKept() {
        let store = makeStore(makeLimits(maxAge: 3600))
        XCTAssertEqual(store.add(textCopy("from long ago", at: -7200)), .skipped("older than the limits"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(blobFolderNames().isEmpty)
    }

    /// With no age limit nothing is dropped for being old.
    func testWithNoAgeLimitNothingIsDroppedForBeingOld() throws {
        let store = makeStore(makeLimits(maxAge: nil))
        let id = try addText(store, "ancient", at: -86_400 * 3650)
        clock.advance(by: 86_400 * 3650)
        store.prune()
        XCTAssertEqual(store.entries.map(\.id), [id])
    }

    /// Too many: the oldest go first, with their contents.
    func testTheOldestUnpinnedGoFirstWhenThereAreTooMany() throws {
        let plainStore = makeStore(makeLimits(maxEntries: 3))
        for (n, text) in ["one", "two", "three", "four", "five"].enumerated() { try addText(plainStore, text, at: TimeInterval(n + 1)) }
        XCTAssertEqual(plainStore.entries.map(\.text), ["five", "four", "three"])
        XCTAssertEqual(blobFolderNames().count, 3)
    }

    /// The oldest copy is not always the one to go: a pin keeps it, and the next oldest goes in its place.
    func testAPinnedEntryIsPassedOverWhenTheOldestAreDropped() throws {
        let store = makeStore(makeLimits(maxEntries: 3))
        let a = try addText(store, "a", at: 1)
        store.setPinned(a, true)
        try addText(store, "b", at: 2)
        try addText(store, "c", at: 3)
        try addText(store, "d", at: 4)
        XCTAssertEqual(store.entries.map(\.text), ["d", "c", "a"], "b was the oldest that was not pinned")
    }

    /// Pinned entries are never dropped, even past the limit; and a new copy that would have to go is the one that does.
    func testPinnedEntriesAreNeverDroppedAndANewCopyIsTheOneToGo() throws {
        let store = makeStore(makeLimits(maxEntries: 2))
        let first = try addText(store, "first", at: 1)
        store.setPinned(first, true)
        let second = try addText(store, "second", at: 2)
        store.setPinned(second, true)

        XCTAssertTrue(isSkipped(store.add(textCopy("third", at: 3))))
        XCTAssertEqual(store.entries.map(\.id), [second, first])
        XCTAssertEqual(blobFolderNames(), names(of: [first, second]), "the copy that did not stay left no contents behind")
    }

    /// Lowering the limit under what is pinned drops nothing that is pinned.
    func testLoweringTheLimitUnderTheNumberPinnedDropsNoPinnedEntry() throws {
        let store = makeStore()
        for (n, text) in ["x", "y", "z"].enumerated() {
            let id = try addText(store, text, at: TimeInterval(n + 1))
            store.setPinned(id, true)
        }
        store.limits = makeLimits(maxEntries: 2)
        XCTAssertEqual(store.entries.count, 3)
    }

    /// Too many bytes: the oldest unpinned go until the whole fits, and a pinned entry is passed over.
    func testTheOldestGoFirstWhenTheBytesAreOverTheLimit() throws {
        let store = makeStore(makeLimits(maxTotalBytes: 25))
        try addText(store, "aaaaaaaaaa", at: 1)
        try addText(store, "bbbbbbbbbb", at: 2)
        XCTAssertEqual(store.totalBytes, 20)
        try addText(store, "cccccccccc", at: 3)
        XCTAssertEqual(store.entries.map(\.text), ["cccccccccc", "bbbbbbbbbb"])
        XCTAssertEqual(store.totalBytes, 20)

        let oldest = try XCTUnwrap(store.entries.last?.id)
        store.setPinned(oldest, true)
        try addText(store, "dddddddddd", at: 4)
        XCTAssertEqual(store.entries.map(\.text), ["dddddddddd", "bbbbbbbbbb"], "the pinned one stays, the next oldest goes")
        XCTAssertEqual(blobFolderNames().count, 2)
    }

    /// One copy bigger than the whole allowance is not kept.
    func testACopyBiggerThanTheWholeAllowanceIsNotKept() {
        let store = makeStore(makeLimits(maxTotalBytes: 5))
        XCTAssertTrue(isSkipped(store.add(textCopy("more than five bytes"))))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(blobFolderNames().isEmpty)
    }

    /// Changing the limits does not wait for the next copy: what no longer fits goes at once, and it is saved.
    func testChangingTheLimitsPrunesAtOnceAndItSurvivesARelaunch() throws {
        let store = makeStore()
        for (n, text) in ["aaaaaaaaaa", "bbbbbbbbbb", "cccccccccc", "dddddddddd", "eeeeeeeeee"].enumerated() {
            try addText(store, text, at: TimeInterval(n + 1))
        }
        XCTAssertEqual(store.entries.count, 5)

        store.limits = makeLimits(maxEntries: 4)
        XCTAssertEqual(store.entries.map(\.text), ["eeeeeeeeee", "dddddddddd", "cccccccccc", "bbbbbbbbbb"])

        store.limits.maxTotalBytes = 25
        XCTAssertEqual(store.entries.map(\.text), ["eeeeeeeeee", "dddddddddd"])
        XCTAssertEqual(blobFolderNames().count, 2)

        store.limits.maxEntries = 1
        XCTAssertEqual(store.entries.map(\.text), ["eeeeeeeeee"])
        XCTAssertEqual(makeStore(makeLimits(maxEntries: 1)).entries.map(\.text), ["eeeeeeeeee"])
    }

    /// Opening the store again under a tighter limit than it was kept under applies the limit then.
    func testAStoreOpenedUnderATighterLimitPrunesWhenItOpens() throws {
        let store = makeStore()
        for (n, text) in ["one", "two", "three"].enumerated() { try addText(store, text, at: TimeInterval(n + 1)) }
        XCTAssertEqual(makeStore(makeLimits(maxEntries: 1)).entries.map(\.text), ["three"])
        XCTAssertEqual(blobFolderNames().count, 1)
    }

    // ── Changing an entry ───────────────────────────────────────────────────

    /// A pin is the person's choice and has to last: it is on disk, and an unpin is too.
    func testPinningAndUnpinningIsKeptAcrossARelaunch() throws {
        let store = makeStore()
        let id = try addText(store, "keep me", at: 1)
        store.setPinned(id, true)
        XCTAssertEqual(store.entry(id)?.pinned, true)
        XCTAssertEqual(makeStore().entry(id)?.pinned, true)
        store.setPinned(id, false)
        XCTAssertEqual(makeStore().entry(id)?.pinned, false)

        let before = store.entries
        store.setPinned(UUID(), true)
        XCTAssertEqual(store.entries, before, "an entry that is not there is nobody's to pin")
    }

    /// Deleting one entry takes its contents from disk and nobody else's.
    func testDeletingAnEntryRemovesItsFolderAndOnlyThat() throws {
        let store = makeStore()
        let doomed = try addText(store, "delete me", at: 1)
        let kept = try addText(store, "keep me", at: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobFolder(doomed).path))

        store.delete(doomed)
        XCTAssertNil(store.entry(doomed))
        XCTAssertNil(store.payload(for: doomed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobFolder(doomed).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobFolder(kept).path))
        XCTAssertNotNil(store.payload(for: kept))
        XCTAssertEqual(makeStore().entries.map(\.id), [kept], "and it was saved")

        store.delete(UUID())
        XCTAssertEqual(store.entries.map(\.id), [kept])
    }

    /// Clear everything: no entries, no contents left on disk, an empty index that loads without a problem.
    func testClearingEverythingLeavesNoEntriesAndNoContents() throws {
        let store = makeStore()
        let pinned = try addText(store, "pinned", at: 1)
        store.setPinned(pinned, true)
        try addText(store, "loose", at: 2)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(blobFolderNames().isEmpty)
        let again = makeStore()
        XCTAssertTrue(again.entries.isEmpty)
        XCTAssertNil(again.loadProblem)
    }

    /// Clear but keep what is pinned: the pinned ones stay with their contents, the rest go with theirs.
    func testClearingButKeepingPinnedLeavesThePinnedOnesWithTheirContents() throws {
        let store = makeStore()
        let pinned = try addText(store, "pinned", at: 1)
        store.setPinned(pinned, true)
        let loose = try addText(store, "loose", at: 2)

        store.clear(keepPinned: true)
        XCTAssertEqual(store.entries.map(\.id), [pinned])
        XCTAssertEqual(try XCTUnwrap(store.payload(for: pinned)).first?.data, Data("pinned".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobFolder(loose).path))
        XCTAssertEqual(blobFolderNames(), names(of: [pinned]))
        XCTAssertEqual(makeStore().entries.map(\.id), [pinned])
    }

    /// Pasting an entry from the history puts it back at the top, as if it had just been copied, at the store's own time.
    func testTouchMovesAnEntryToTheTopWithTheTimeItIsNow() throws {
        let store = makeStore()
        let older = try addText(store, "older", at: 1)
        let newer = try addText(store, "newer", at: 2)
        XCTAssertEqual(store.entries.map(\.id), [newer, older])

        clock.date = start.addingTimeInterval(100)
        store.touch(older)
        XCTAssertEqual(store.entries.map(\.id), [older, newer])
        XCTAssertEqual(store.entries.first?.date, start.addingTimeInterval(100))
        XCTAssertEqual(makeStore().entries.map(\.id), [older, newer], "and it was saved")

        store.touch(UUID())
        XCTAssertEqual(store.entries.map(\.id), [older, newer])
    }

    // ── What is on disk ─────────────────────────────────────────────────────

    /// A store opened again on the same folder is the same list, newest first, with every entry's contents.
    func testANewStoreOnTheSameFolderSeesTheSameEntriesNewestFirstWithTheirContents() throws {
        let store = makeStore()
        let reps = [rep(plain, "alpha"), rep("public.html", "<i>alpha</i>")]
        let a = try addedID(store.add(snapshot(reps, at: 1, from: "com.example.Editor", named: "Editor")))
        let b = try addText(store, "beta", at: 2)
        let c = try addText(store, "gamma", at: 3)
        store.setPinned(b, true)

        let again = makeStore()
        XCTAssertNil(again.loadProblem)
        XCTAssertEqual(again.entries.map(\.id), [c, b, a])
        XCTAssertEqual(again.entries, store.entries)
        XCTAssertEqual(again.entries[1].pinned, true)
        XCTAssertEqual(again.entries[2].sourceName, "Editor")
        XCTAssertEqual(try XCTUnwrap(again.payload(for: a)), reps)
        XCTAssertEqual(try XCTUnwrap(again.payload(for: c)).first?.data, Data("gamma".utf8))
    }

    /// Newest first is by date, not by the order the file or the adding happened to be in.
    func testEntriesComeBackNewestFirstWhateverOrderTheyWereAdded() throws {
        let store = makeStore()
        let newer = try addText(store, "newer", at: 30)
        let older = try addText(store, "older", at: 10)
        XCTAssertEqual(store.entries.map(\.id), [older, newer], "added last, so first in memory")
        XCTAssertEqual(makeStore().entries.map(\.id), [newer, older])
    }

    /// A folder nobody has written to yet is an empty history with no problem, and the store has not made it.
    func testAFreshFolderIsAnEmptyHistoryWithNoProblem() {
        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.loadProblem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// An index that cannot be read is started again empty and the store says why. What it had pointed at is no one's, and is
    /// removed.
    func testAnIndexThatCannotBeReadStartsEmptyAndSaysWhy() throws {
        let first = makeStore()
        let id = try addText(first, "about to be lost", at: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobFolder(id).path))
        try Data("{ this is not json".utf8).write(to: indexFile)

        let second = makeStore()
        XCTAssertTrue(second.entries.isEmpty)
        let problem = try XCTUnwrap(second.loadProblem)
        XCTAssertFalse(problem.isEmpty)
        XCTAssertTrue(blobFolderNames().isEmpty, "contents no entry owns are removed")

        // And the history is usable again: the next copy is kept and the next launch reads a good index.
        try addText(second, "a new start", at: 2)
        let third = makeStore()
        XCTAssertNil(third.loadProblem)
        XCTAssertEqual(third.entries.map(\.text), ["a new start"])
    }

    /// An index written by a version this one does not know is not guessed at.
    func testAnIndexOfAnotherVersionStartsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"entries":[]}"#.utf8).write(to: indexFile)
        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.loadProblem)
    }

    /// An entry whose contents are gone from disk has nothing to paste, and is dropped when the store opens.
    func testAnEntryWhoseContentsAreGoneIsDroppedAtLoad() throws {
        let store = makeStore()
        let gone = try addText(store, "lost its folder", at: 1)
        let stays = try addText(store, "still has it", at: 2)
        try FileManager.default.removeItem(at: blobFolder(gone))

        let again = makeStore()
        XCTAssertEqual(again.entries.map(\.id), [stays])
        XCTAssertNil(again.loadProblem, "this is not a problem with the index")
    }

    /// A folder of contents that no entry owns (a crash between writing the contents and the index) is removed when the store
    /// opens; so is anything else in there that is not an entry's.
    func testAFolderOfContentsNoEntryOwnsIsRemovedAtLoad() throws {
        let store = makeStore()
        let owned = try addText(store, "owned", at: 1)
        let stray = blobFolder(UUID())
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: stray.appendingPathComponent("0-0").path, contents: Data("left over".utf8)))
        try FileManager.default.createDirectory(at: blobsFolder.appendingPathComponent("junk", isDirectory: true),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(blobFolderNames().count, 3)

        let again = makeStore()
        XCTAssertEqual(again.entries.map(\.id), [owned])
        XCTAssertEqual(blobFolderNames(), names(of: [owned]))
        XCTAssertNotNil(again.payload(for: owned))
    }

    // ── Who can read it ─────────────────────────────────────────────────────

    /// The folder only this account can open, the index and every stored form only this account can read.
    func testTheFolderIsPrivateAndSoAreTheIndexAndEveryStoredForm() throws {
        let store = makeStore()
        let id = try addedID(store.add(snapshot([rep(plain, "private words"), rep("public.html", "<p>private words</p>")])))

        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(blobsFolder), 0o700)
        XCTAssertEqual(try permissions(blobFolder(id)), 0o700)
        XCTAssertEqual(try permissions(indexFile), 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: blobFolder(id).path)
        XCTAssertEqual(files.count, 2)
        for name in files {
            XCTAssertEqual(try permissions(blobFolder(id).appendingPathComponent(name)), 0o600, name)
        }
    }

    /// Every save writes the index afresh; the new file is private too, not only the first.
    func testTheIndexStaysPrivateEachTimeItIsWrittenAgain() throws {
        let store = makeStore()
        let id = try addText(store, "one", at: 1)
        try addText(store, "two", at: 2)
        store.setPinned(id, true)
        XCTAssertEqual(try permissions(indexFile), 0o600)
        clock.date = start.addingTimeInterval(50)
        store.touch(id)
        XCTAssertEqual(try permissions(indexFile), 0o600)
        store.delete(id)
        XCTAssertEqual(try permissions(indexFile), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)
    }
}
