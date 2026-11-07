import XCTest
@testable import PowerKit

/// The wallpaper library: an index plus the files it owns, in one folder.
final class WallpaperLibraryTests: XCTestCase {

    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("WallpaperLibraryTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    private func item(_ name: String = "clip", kind: WallpaperKind = .video, source: WallpaperSource,
                      poster: String? = nil, thumb: String? = nil) -> WallpaperItem {
        WallpaperItem(id: UUID(), name: name, kind: kind, source: source, posterFilename: poster, thumbnailFilename: thumb,
                      durationSeconds: nil, pixelWidth: nil, pixelHeight: nil, codec: nil, hasAudio: nil,
                      hardwareDecodable: nil, addedAt: Date(timeIntervalSince1970: 1_000))
    }

    private func touch(_ rel: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? dir).appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testEmptyAtFirst() {
        XCTAssertEqual(WallpaperLibrary(directory: dir).items, [])
    }

    func testAddPersistsAcrossANewLibraryOnTheSameFolder() throws {
        _ = try touch("a.mov")
        let lib = WallpaperLibrary(directory: dir)
        let it = item(source: .file("a.mov"))
        try lib.add(it)
        XCTAssertEqual(WallpaperLibrary(directory: dir).items, [it])
    }

    func testEverySourceCaseRoundTripsThroughJSON() throws {
        let sources: [WallpaperSource] = [.file("a.mov"), .folder(directory: "site-1", entry: "index.html"),
                                          .remote(URL(string: "https://example.com/a.mp4")!)]
        for s in sources {
            let back = try JSONDecoder().decode(WallpaperSource.self, from: JSONEncoder().encode(s))
            XCTAssertEqual(back, s)
        }
    }

    func testRemovingAFileItemDeletesItsFileAndPosterAndThumbnailAndEntry() throws {
        let f = try touch("a.mov"), p = try touch("a.png"), t = try touch("a.jpg")
        let lib = WallpaperLibrary(directory: dir)
        let it = item(source: .file("a.mov"), poster: "a.png", thumb: "a.jpg")
        try lib.add(it)
        try lib.remove(id: it.id)
        XCTAssertFalse(fm.fileExists(atPath: f.path))
        XCTAssertFalse(fm.fileExists(atPath: p.path))
        XCTAssertFalse(fm.fileExists(atPath: t.path))
        XCTAssertEqual(lib.items, [])
        XCTAssertEqual(WallpaperLibrary(directory: dir).items, [], "and it stays removed")
    }

    func testRemovingAWebFolderItemDeletesTheWholeFolder() throws {
        let entry = try touch("site-1/index.html")
        _ = try touch("site-1/css/app.css")
        let lib = WallpaperLibrary(directory: dir)
        let it = item(kind: .web, source: .folder(directory: "site-1", entry: "index.html"))
        try lib.add(it)
        try lib.remove(id: it.id)
        XCTAssertFalse(fm.fileExists(atPath: entry.deletingLastPathComponent().path))
    }

    func testRemovingARemoteItemDeletesOnlyItsPosterAndThumbnail() throws {
        let p = try touch("r.png"), t = try touch("r.jpg"), other = try touch("other.mov")
        let lib = WallpaperLibrary(directory: dir)
        let it = item(kind: .video, source: .remote(URL(string: "https://example.com/a.m3u8")!), poster: "r.png", thumb: "r.jpg")
        try lib.add(it)
        try lib.remove(id: it.id)
        XCTAssertFalse(fm.fileExists(atPath: p.path))
        XCTAssertFalse(fm.fileExists(atPath: t.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path), "nothing else in the folder is touched")
    }

    func testRenameRejectsAnEmptyNameAndKeepsTheOldOne() throws {
        let lib = WallpaperLibrary(directory: dir)
        let it = item(source: .remote(URL(string: "https://example.com/")!))
        try lib.add(it)
        XCTAssertThrowsError(try lib.rename(id: it.id, to: "   "))
        XCTAssertEqual(lib.item(id: it.id)?.name, "clip")
        try lib.rename(id: it.id, to: "Waves")
        XCTAssertEqual(WallpaperLibrary(directory: dir).item(id: it.id)?.name, "Waves")
    }

    func testIsMissingIsTrueOnceTheFileIsGoneAndNeverForRemote() throws {
        let f = try touch("a.mov")
        let lib = WallpaperLibrary(directory: dir)
        let local = item(source: .file("a.mov"))
        let remote = item(source: .remote(URL(string: "https://example.com/a.mp4")!))
        try lib.add(local); try lib.add(remote)
        XCTAssertFalse(lib.isMissing(local))
        try fm.removeItem(at: f)
        XCTAssertTrue(lib.isMissing(local))
        XCTAssertFalse(lib.isMissing(remote))
    }

    func testContentURLPerSourceCase() throws {
        let lib = WallpaperLibrary(directory: dir)
        let file = item(source: .file("a.mov"))
        let folder = item(kind: .web, source: .folder(directory: "site-1", entry: "pages/index.html"))
        let remote = item(source: .remote(URL(string: "https://example.com/a.mp4")!))
        XCTAssertEqual(lib.contentURL(file), dir.appendingPathComponent("a.mov"))
        XCTAssertEqual(lib.contentURL(folder), dir.appendingPathComponent("site-1").appendingPathComponent("pages/index.html"))
        XCTAssertEqual(lib.contentURL(remote), URL(string: "https://example.com/a.mp4"))
        XCTAssertEqual(lib.folderURL(folder), dir.appendingPathComponent("site-1"))
        XCTAssertNil(lib.folderURL(file))
    }

    func testPosterAndThumbnailURLsAreNilWhenThereIsNone() {
        let lib = WallpaperLibrary(directory: dir)
        let with = item(source: .file("a.mov"), poster: "a.png", thumb: "a.jpg")
        let without = item(source: .file("b.mov"))
        XCTAssertEqual(lib.posterURL(with), dir.appendingPathComponent("a.png"))
        XCTAssertEqual(lib.thumbnailURL(with), dir.appendingPathComponent("a.jpg"))
        XCTAssertNil(lib.posterURL(without))
        XCTAssertNil(lib.thumbnailURL(without))
    }

    func testACorruptIndexYieldsAnEmptyLibraryAndDeletesNothing() throws {
        let f = try touch("a.mov")
        try Data("{ nonsense".utf8).write(to: dir.appendingPathComponent("library.json"))
        let lib = WallpaperLibrary(directory: dir)
        XCTAssertEqual(lib.items, [])
        XCTAssertTrue(fm.fileExists(atPath: f.path))
    }

    func testDidChangePostsOnAddRemoveAndRename() throws {
        let lib = WallpaperLibrary(directory: dir)
        var fired = 0
        let token = NotificationCenter.default.addObserver(forName: WallpaperLibrary.didChange, object: lib, queue: nil) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let it = item(source: .remote(URL(string: "https://example.com/")!))
        try lib.add(it)
        try lib.rename(id: it.id, to: "B")
        try lib.remove(id: it.id)
        XCTAssertEqual(fired, 3)
    }

    func testRemovingAnUnknownIDIsHarmless() throws {
        let lib = WallpaperLibrary(directory: dir)
        XCTAssertNoThrow(try lib.remove(id: UUID()))
    }

    func testAFileNameCannotEscapeTheLibraryFolder() throws {
        let lib = WallpaperLibrary(directory: dir)
        let evil = item(source: .file("../outside.mov"))
        XCTAssertNil(lib.contentURL(evil), "a path that leaves the folder is not a library file")
        XCTAssertTrue(lib.isMissing(evil))
    }
}
