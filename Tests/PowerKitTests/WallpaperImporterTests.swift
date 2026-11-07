import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import AnodeApp
@testable import PowerKit

/// Getting content into the library. Real (tiny) files, a library in a temp folder, and no network: downloads and page
/// snapshots are injected.
final class WallpaperImporterTests: XCTestCase {

    private var root: URL!
    private var libDir: URL!
    private var srcDir: URL!
    private var library: WallpaperLibrary!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("WallpaperImporterTests-\(UUID().uuidString)")
        libDir = root.appendingPathComponent("lib")
        srcDir = root.appendingPathComponent("src")
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        library = WallpaperLibrary(directory: libDir)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func libraryFiles() -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: libDir.path)) ?? []).subtracting(["library.json"])
    }

    private let snapshot: PageSnapshotter = { _, _ in TestImage.cgImage(width: 160, height: 100) }
    private struct Offline: Error {}
    private let failingSnapshot: PageSnapshotter = { _, _ in throw Offline() }

    // MARK: video

    func testProbeReadsDurationSizeCodecAudioAndHardwareDecode() async throws {
        let clip = try await TestVideo.make(seconds: 1, in: srcDir)
        let p = try await WallpaperImporter.probeVideo(clip)
        XCTAssertEqual(p.durationSeconds, 1, accuracy: 0.1)
        XCTAssertEqual(p.pixelWidth, 64)
        XCTAssertEqual(p.pixelHeight, 64)
        XCTAssertEqual(p.codec, "avc1")
        XCTAssertFalse(p.hasAudio)
        XCTAssertTrue(p.hardwareDecodable)
    }

    func testATextFileNamedMovIsNotPlayable() async throws {
        let fake = srcDir.appendingPathComponent("x.mov")
        try Data("hello".utf8).write(to: fake)
        do { _ = try await WallpaperImporter.probeVideo(fake); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? WallpaperImportError, .notPlayable) }
    }

    func testImportVideoLeavesTheCopyAPosterAndAThumbnailAndOneNamedEntry() async throws {
        let clip = try await TestVideo.make(seconds: 1, in: srcDir, name: "Waves.mov")
        let r = try await WallpaperImporter.importVideo(from: clip, into: library)
        XCTAssertEqual(r.item.kind, .video)
        XCTAssertEqual(r.item.name, "Waves")
        XCTAssertEqual(library.items.count, 1)
        let content = try XCTUnwrap(library.contentURL(r.item))
        XCTAssertTrue(fm.fileExists(atPath: content.path))
        XCTAssertEqual(content.pathExtension, "mov")
        XCTAssertNotEqual(content.lastPathComponent, "Waves.mov", "stored under a generated name")
        XCTAssertTrue(fm.fileExists(atPath: clip.path), "the original is never touched")
        let poster = try XCTUnwrap(library.posterURL(r.item))
        XCTAssertNotNil(TestImage.pixelSize(of: poster), "a decodable image")
        XCTAssertEqual(poster.pathExtension, "png")
        let thumb = try XCTUnwrap(library.thumbnailURL(r.item))
        XCTAssertEqual(thumb.pathExtension, "jpg")
        XCTAssertNotNil(TestImage.pixelSize(of: thumb))
        XCTAssertEqual(r.item.pixelWidth, 64)
        XCTAssertEqual(r.item.hardwareDecodable, true)
        XCTAssertEqual(r.warnings, [])
    }

    func testAPosterFailureRemovesEveryFileItCreatedAndAddsNoEntry() async throws {
        struct PosterBoom: Error {}
        let clip = try await TestVideo.make(seconds: 1, in: srcDir)
        do {
            _ = try await WallpaperImporter.importVideo(from: clip, into: library) { _, _ in throw PosterBoom() }
            XCTFail("should throw")
        } catch {}
        XCTAssertEqual(libraryFiles(), [], "no copy, poster or thumbnail left behind")
        XCTAssertEqual(library.items, [])
    }

    func testAClipUnderHalfASecondIsTooShort() async throws {
        let clip = try await TestVideo.make(seconds: 0.2, in: srcDir)
        do { _ = try await WallpaperImporter.importVideo(from: clip, into: library); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? WallpaperImportError, .tooShort) }
        XCTAssertEqual(libraryFiles(), [])
    }

    func testWarningsMentionSoftwareDecodingAndHugeSizes() {
        func probe(w: Int = 1920, h: Int = 1080, hw: Bool = true) -> VideoProbe {
            VideoProbe(durationSeconds: 5, pixelWidth: w, pixelHeight: h, codec: "avc1", hasAudio: false, hardwareDecodable: hw)
        }
        XCTAssertEqual(WallpaperImporter.warnings(for: probe()), [])
        XCTAssertTrue(WallpaperImporter.warnings(for: probe(hw: false)).joined().contains("software decoding"))
        XCTAssertTrue(WallpaperImporter.warnings(for: probe(w: 8000)).joined().contains("larger than"))
        XCTAssertTrue(WallpaperImporter.warnings(for: probe(h: 8000)).joined().contains("larger than"))
        XCTAssertEqual(WallpaperImporter.warnings(for: probe(w: 7680, h: 4320)), [], "8K itself is fine")
    }

    // MARK: image

    func testImportImageAcceptsPNGAndJPEGAndWritesAThumbnail() async throws {
        for (type, ext) in [(UTType.png, "png"), (UTType.jpeg, "jpg")] {
            let url = try TestImage.write(type, width: 400, height: 300, to: srcDir.appendingPathComponent("pic.\(ext)"))
            let r = try await WallpaperImporter.importImage(from: url, into: library)
            XCTAssertEqual(r.item.kind, .image)
            XCTAssertEqual(r.item.name, "pic")
            XCTAssertEqual(r.item.pixelWidth, 400)
            XCTAssertEqual(r.item.pixelHeight, 300)
            XCTAssertNotNil(TestImage.pixelSize(of: try XCTUnwrap(library.contentURL(r.item))))
            let thumb = try XCTUnwrap(library.thumbnailURL(r.item))
            XCTAssertLessThanOrEqual(TestImage.pixelSize(of: thumb)?.width ?? 9999, 320)
            XCTAssertEqual(library.posterURL(r.item)?.pathExtension, "png")
        }
        XCTAssertEqual(library.items.count, 2)
    }

    func testImportImageRejectsATextFileAndLeavesNothing() async throws {
        let fake = srcDir.appendingPathComponent("x.png")
        try Data("hello".utf8).write(to: fake)
        do { _ = try await WallpaperImporter.importImage(from: fake, into: library); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? WallpaperImportError, .notAnImage) }
        XCTAssertEqual(libraryFiles(), [])
    }

    // MARK: animated images (GIF)

    func testAnimatedGIFBecomesALoopingVideoOfTheSameLength() async throws {
        let gif = try TestImage.writeAnimated(frames: 10, delay: 0.2, to: srcDir.appendingPathComponent("spin.gif"))
        let r = try await WallpaperImporter.importAnimatedImage(from: gif, into: library)
        XCTAssertEqual(r.item.kind, .video)
        XCTAssertEqual(r.item.name, "spin")
        XCTAssertEqual(try XCTUnwrap(r.item.durationSeconds), 2.0, accuracy: 0.1, "10 frames of 0.2 s")
        XCTAssertEqual(r.item.pixelWidth, 48)
        XCTAssertEqual(r.item.pixelHeight, 32)
        XCTAssertEqual(r.item.hasAudio, false)
        XCTAssertEqual(try XCTUnwrap(library.contentURL(r.item)).pathExtension, "mov")
        XCTAssertNotNil(library.posterURL(r.item))
        XCTAssertNotNil(library.thumbnailURL(r.item))
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(libraryFiles().count, 3, "the video, its poster, its thumbnail: no temp file left behind")
        let probe = try await WallpaperImporter.probeVideo(try XCTUnwrap(library.contentURL(r.item)))
        XCTAssertEqual(probe.durationSeconds, 2.0, accuracy: 0.1)
    }

    func testAGIFShorterThanHalfASecondStillImportsByRepeatingItself() async throws {
        let gif = try TestImage.writeAnimated(frames: 2, delay: 0.1, to: srcDir.appendingPathComponent("blink.gif"))
        let r = try await WallpaperImporter.importAnimatedImage(from: gif, into: library)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r.item.durationSeconds), 1.0 - 0.05)
    }

    func testGIFFramesWithNoDelayPlayAtATenthOfASecondLikeABrowser() async throws {
        let gif = try TestImage.writeAnimated(frames: 20, delay: 0, to: srcDir.appendingPathComponent("zero.gif"))
        let r = try await WallpaperImporter.importAnimatedImage(from: gif, into: library)
        XCTAssertEqual(try XCTUnwrap(r.item.durationSeconds), 2.0, accuracy: 0.1, "20 frames at the 0.1 s browsers use")
    }

    func testAnOddSizedGIFImports() async throws {
        let gif = try TestImage.writeAnimated(frames: 6, delay: 0.2, width: 33, height: 21, to: srcDir.appendingPathComponent("odd.gif"))
        let r = try await WallpaperImporter.importAnimatedImage(from: gif, into: library)
        XCTAssertEqual(r.item.kind, .video)
        XCTAssertEqual(try XCTUnwrap(r.item.pixelWidth) % 2, 0, "H.264 needs even sizes")
        XCTAssertEqual(try XCTUnwrap(r.item.pixelHeight) % 2, 0)
    }

    func testAnAnimatedPNGBecomesAVideoToo() async throws {
        let apng = try TestImage.writeAnimated(.png, frames: 5, delay: 0.2, to: srcDir.appendingPathComponent("anim.png"))
        let r = try await WallpaperImporter.importAnimatedImage(from: apng, into: library)
        XCTAssertEqual(r.item.kind, .video)
        XCTAssertEqual(try XCTUnwrap(r.item.durationSeconds), 1.0, accuracy: 0.1)
    }

    func testAnimatedImageImportRejectsATextFileAndLeavesNothing() async throws {
        let fake = srcDir.appendingPathComponent("x.gif")
        try Data("hello".utf8).write(to: fake)
        do { _ = try await WallpaperImporter.importAnimatedImage(from: fake, into: library); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? WallpaperImportError, .notAnImage) }
        XCTAssertEqual(libraryFiles(), [])
        XCTAssertEqual(library.items.count, 0)
    }

    func testAnimatedFrameCountSeesGIFFramesAndOneForAStill() throws {
        let gif = try TestImage.writeAnimated(frames: 7, delay: 0.1, to: srcDir.appendingPathComponent("a.gif"))
        let still = try TestImage.write(.gif, width: 20, height: 20, to: srcDir.appendingPathComponent("s.gif"))
        let png = try TestImage.writePNG(to: srcDir.appendingPathComponent("p.png"))
        XCTAssertEqual(WallpaperImporter.animatedFrameCount(gif), 7)
        XCTAssertEqual(WallpaperImporter.animatedFrameCount(still), 1)
        XCTAssertEqual(WallpaperImporter.animatedFrameCount(png), 1)
        XCTAssertEqual(WallpaperImporter.animatedFrameCount(srcDir.appendingPathComponent("missing.gif")), 0)
    }

    func testAddFileSendsAnAnimatedGIFToVideoAndAStillGIFToImage() async throws {
        let importer = RealWallpaperImporter(library: library)
        let moving = try TestImage.writeAnimated(frames: 10, delay: 0.1, to: srcDir.appendingPathComponent("move.gif"))
        let still = try TestImage.write(.gif, width: 20, height: 20, to: srcDir.appendingPathComponent("still.gif"))
        let a = try await importer.addFile(moving)
        let b = try await importer.addFile(still)
        XCTAssertEqual(a.item.kind, .video)
        XCTAssertEqual(b.item.kind, .image)
    }

    // MARK: web

    func testImportHTMLFileCopiesOnlyThatFileSnapshotsItAndWarns() async throws {
        let page = srcDir.appendingPathComponent("wave.html")
        try Data("<html><body>hi</body></html>".utf8).write(to: page)
        try Data("sibling".utf8).write(to: srcDir.appendingPathComponent("secret.txt"))
        let r = try await WallpaperImporter.importHTMLFile(from: page, into: library, snapshot: snapshot)
        XCTAssertEqual(r.item.kind, .web)
        XCTAssertEqual(r.item.name, "wave")
        guard case .folder(let dir, let entry) = r.item.source else { return XCTFail("a copied page is a folder source") }
        XCTAssertEqual(entry, "index.html")
        let folder = libDir.appendingPathComponent(dir)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: folder.path)), ["index.html"], "the file's siblings are not copied")
        XCTAssertTrue(r.warnings.joined().contains("other files"))
        XCTAssertNotNil(library.posterURL(r.item))
        XCTAssertNotNil(library.thumbnailURL(r.item))
    }

    func testImportWebFolderCopiesTheFolderWithItsSubfolders() async throws {
        let site = srcDir.appendingPathComponent("site")
        try fm.createDirectory(at: site.appendingPathComponent("js"), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: site.appendingPathComponent("index.html"))
        try Data("1".utf8).write(to: site.appendingPathComponent("js/app.js"))
        let r = try await WallpaperImporter.importWebFolder(from: site, into: library, snapshot: snapshot)
        guard case .folder(let dir, let entry) = r.item.source else { return XCTFail() }
        XCTAssertEqual(entry, "index.html")
        XCTAssertTrue(fm.fileExists(atPath: libDir.appendingPathComponent(dir).appendingPathComponent("js/app.js").path))
        XCTAssertEqual(r.item.name, "site")
    }

    func testAFolderWithoutARootIndexIsRefused() async throws {
        let site = srcDir.appendingPathComponent("site")
        try fm.createDirectory(at: site.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: site.appendingPathComponent("nested/index.html"))
        do { _ = try await WallpaperImporter.importWebFolder(from: site, into: library, snapshot: snapshot); XCTFail() }
        catch { XCTAssertEqual(error as? WallpaperImportError, .noIndexHTML) }
        XCTAssertEqual(libraryFiles(), [])
    }

    func testAFolderOverTheSizeOrFileLimitIsRefusedBeforeAnythingIsCopied() async throws {
        let site = srcDir.appendingPathComponent("site")
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: site.appendingPathComponent("index.html"))
        try Data(count: 5_000).write(to: site.appendingPathComponent("big.bin"))
        for limits in [(bytes: Int64(4_000), files: 100), (bytes: Int64(1_000_000), files: 1)] {
            do {
                _ = try await WallpaperImporter.importWebFolder(from: site, into: library, snapshot: snapshot,
                                                                maxBytes: limits.bytes, maxFiles: limits.files)
                XCTFail("should throw")
            } catch { XCTAssertEqual(error as? WallpaperImportError, .tooLarge) }
        }
        XCTAssertEqual(libraryFiles(), [])
    }

    func testSymlinksInAFolderAreNotFollowedOrCopied() async throws {
        let site = srcDir.appendingPathComponent("site")
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: site.appendingPathComponent("index.html"))
        let outside = srcDir.appendingPathComponent("private.txt")
        try Data("secret".utf8).write(to: outside)
        try fm.createSymbolicLink(at: site.appendingPathComponent("leak.txt"), withDestinationURL: outside)
        let r = try await WallpaperImporter.importWebFolder(from: site, into: library, snapshot: snapshot)
        guard case .folder(let dir, _) = r.item.source else { return XCTFail() }
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: libDir.appendingPathComponent(dir).path)), ["index.html"])
    }

    func testASnapshotThatFailsStillAddsThePageWithAWarning() async throws {
        let page = srcDir.appendingPathComponent("p.html")
        try Data("<html></html>".utf8).write(to: page)
        let r = try await WallpaperImporter.importHTMLFile(from: page, into: library, snapshot: failingSnapshot)
        XCTAssertNil(r.item.posterFilename)
        XCTAssertNil(r.item.thumbnailFilename)
        XCTAssertTrue(r.warnings.joined().lowercased().contains("preview"))
        XCTAssertEqual(library.items.count, 1)
    }

    // MARK: links

    private func noDownload() -> (URL, URL, Int64) async throws -> Void {
        { _, _, _ in XCTFail("nothing should be downloaded") }
    }

    func testAYouTubeLinkBecomesAWebItemOnTheEmbedURL() async throws {
        let r = try await WallpaperImporter.addLink(URL(string: "https://youtu.be/dQw4w9WgXcQ")!, into: library,
                                                    downloadCopy: true, download: noDownload(), snapshot: snapshot)
        XCTAssertEqual(r.item.kind, .web)
        XCTAssertEqual(r.item.source, .remote(WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")))
    }

    func testAnOrdinaryPageBecomesAWebItemOnItsOwnURL() async throws {
        let url = URL(string: "https://example.com/art")!
        let r = try await WallpaperImporter.addLink(url, into: library, downloadCopy: true, download: noDownload(), snapshot: snapshot)
        XCTAssertEqual(r.item.kind, .web)
        XCTAssertEqual(r.item.source, .remote(url))
        XCTAssertEqual(r.item.name, "example.com")
    }

    func testADirectVideoWithDownloadCopyDownloadsThenImports() async throws {
        let clip = try await TestVideo.make(seconds: 1, in: srcDir, name: "remote.mov")
        var asked: (URL, Int64)?
        let r = try await WallpaperImporter.addLink(URL(string: "https://x.com/remote.mov")!, into: library, downloadCopy: true,
                                                    download: { source, dest, max in
            asked = (source, max)
            try self.fm.copyItem(at: clip, to: dest)
        }, snapshot: snapshot)
        XCTAssertEqual(asked?.0, URL(string: "https://x.com/remote.mov"))
        XCTAssertEqual(asked?.1, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(r.item.kind, .video)
        guard case .file = r.item.source else { return XCTFail("a downloaded video is a library file") }
        XCTAssertEqual(libraryFiles().filter { $0.hasSuffix(".mov") }.count, 1, "the download's temporary file is gone")
        XCTAssertEqual(r.item.name, "remote")
    }

    func testADirectVideoWithoutDownloadCopyStreamsAndDownloadsNothing() async throws {
        let url = URL(string: "https://x.com/live.m3u8")!
        let r = try await WallpaperImporter.addLink(url, into: library, downloadCopy: false, download: noDownload(), snapshot: snapshot)
        XCTAssertEqual(r.item.kind, .video)
        XCTAssertEqual(r.item.source, .remote(url))
        XCTAssertEqual(libraryFiles(), [])
    }

    func testADirectImageIsDownloadedAndImported() async throws {
        let png = try TestImage.writePNG(width: 80, height: 60, to: srcDir.appendingPathComponent("remote.png"))
        let r = try await WallpaperImporter.addLink(URL(string: "https://x.com/remote.png")!, into: library, downloadCopy: false,
                                                    download: { _, dest, _ in try self.fm.copyItem(at: png, to: dest) }, snapshot: snapshot)
        XCTAssertEqual(r.item.kind, .image)
        guard case .file = r.item.source else { return XCTFail() }
    }

    func testAFailedDownloadLeavesNothingBehind() async throws {
        struct Net: Error {}
        do {
            _ = try await WallpaperImporter.addLink(URL(string: "https://x.com/a.mp4")!, into: library, downloadCopy: true,
                                                    download: { _, dest, _ in try Data("partial".utf8).write(to: dest); throw Net() },
                                                    snapshot: snapshot)
            XCTFail("should throw")
        } catch { XCTAssertEqual(error as? WallpaperImportError, .downloadFailed) }
        XCTAssertEqual(libraryFiles(), [])
        XCTAssertEqual(library.items, [])
    }

    func testAnHTTPLinkIsRefused() async throws {
        do {
            _ = try await WallpaperImporter.addLink(URL(string: "http://x.com/a.mp4")!, into: library, downloadCopy: true,
                                                    download: noDownload(), snapshot: snapshot)
            XCTFail("should throw")
        } catch { XCTAssertEqual(error as? WallpaperImportError, .notHTTPS) }
    }

    func testAFileLinkIsRefusedAsUnsupported() async throws {
        do {
            _ = try await WallpaperImporter.addLink(URL(string: "file:///etc/hosts")!, into: library, downloadCopy: true,
                                                    download: noDownload(), snapshot: snapshot)
            XCTFail("should throw")
        } catch {
            guard case .unsupportedLink? = error as? WallpaperImportError else { return XCTFail("wrong error \(error)") }
        }
    }

    // MARK: downloader rules

    func testDownloaderRefusesRedirectsToAnythingButHTTPS() {
        XCTAssertTrue(WallpaperDownloader.allowsRedirect(to: URL(string: "https://cdn.example.com/a.mp4")!))
        XCTAssertFalse(WallpaperDownloader.allowsRedirect(to: URL(string: "http://cdn.example.com/a.mp4")!))
        XCTAssertFalse(WallpaperDownloader.allowsRedirect(to: URL(string: "file:///etc/passwd")!))
    }

    func testDownloaderSizeCheckUsesTheDeclaredLengthAndTheRunningCount() {
        XCTAssertFalse(WallpaperDownloader.exceeds(maxBytes: 100, declared: 50, received: 50))
        XCTAssertTrue(WallpaperDownloader.exceeds(maxBytes: 100, declared: 101, received: 0), "refused before it starts")
        XCTAssertTrue(WallpaperDownloader.exceeds(maxBytes: 100, declared: -1, received: 101), "unknown length, caught as it grows")
        XCTAssertFalse(WallpaperDownloader.exceeds(maxBytes: 100, declared: -1, received: 100))
    }
}
