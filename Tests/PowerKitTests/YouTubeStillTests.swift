import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import AnodeApp
@testable import PowerKit

/// The clean picture a YouTube wallpaper shows instead of the player's own paused screen. The network is a closure here.
final class YouTubeStillTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default
    private struct NotFound: Error {}

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("YouTubeStillTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let url = try TestImage.write(.jpeg, width: width, height: height, to: root.appendingPathComponent("t-\(UUID().uuidString).jpg"))
        return try Data(contentsOf: url)
    }

    func testTheLargestThumbnailThatExistsIsKept() async throws {
        let good = try jpeg(width: 1280, height: 720)
        var asked: [String] = []
        let dest = root.appendingPathComponent("still.jpg")
        let ok = await YouTubeStill.ensure(id: "dQw4w9WgXcQ", at: dest) { url in
            asked.append(url.lastPathComponent)
            if url.lastPathComponent == "maxresdefault.jpg" { throw NotFound() }
            return good
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(asked, ["maxresdefault.jpg", "hq720.jpg"], "stops at the first one that works")
        XCTAssertEqual(TestImage.pixelSize(of: dest)?.width, 1280)
    }

    func testSomethingThatIsNotAPictureOrIsTooSmallIsSkipped() async throws {
        let tiny = try jpeg(width: 120, height: 90)     // YouTube's grey stand-in size
        let fine = try jpeg(width: 640, height: 360)
        var asked = 0
        let dest = root.appendingPathComponent("still.jpg")
        let ok = await YouTubeStill.ensure(id: "dQw4w9WgXcQ", at: dest) { _ in
            asked += 1
            return [Data("<html>no</html>".utf8), tiny, fine][asked - 1]
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(asked, 3)
        XCTAssertEqual(TestImage.pixelSize(of: dest)?.width, 640)
    }

    func testWhenNothingWorksNothingIsWritten() async {
        let dest = root.appendingPathComponent("still.jpg")
        let ok = await YouTubeStill.ensure(id: "dQw4w9WgXcQ", at: dest) { _ in throw NotFound() }
        XCTAssertFalse(ok)
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
    }

    func testAStillThatIsAlreadyThereIsNotFetchedAgain() async throws {
        let dest = root.appendingPathComponent("still.jpg")
        try jpeg(width: 640, height: 360).write(to: dest)
        var asked = 0
        let ok = await YouTubeStill.ensure(id: "dQw4w9WgXcQ", at: dest) { _ in asked += 1; throw NotFound() }
        XCTAssertTrue(ok)
        XCTAssertEqual(asked, 0)
    }

    func testThePreviewPictureOfAYouTubeLinkIsTheThumbnailNotThePlayersScreen() async throws {
        let good = try jpeg(width: 1280, height: 720)
        let image = await YouTubeStill.thumbnailImage(id: "dQw4w9WgXcQ") { _ in good }
        XCTAssertEqual(image?.width, 1280)
        let none = await YouTubeStill.thumbnailImage(id: "dQw4w9WgXcQ") { _ in throw NotFound() }
        XCTAssertNil(none)
    }
}
