import XCTest
import AVFoundation
import WebKit
@testable import AnodeApp
@testable import PowerKit

/// The desktop window and its three renderers. Nothing is ordered onto a screen, no video is played, and no URL is loaded
/// from the network (the one page loaded is a local file written by the test).
@MainActor
final class WallpaperSurfaceTests: XCTestCase {

    private var root: URL!
    private var libDir: URL!
    private var library: WallpaperLibrary!
    private let fm = FileManager.default
    private let display = DisplayInfo(uuid: "TEST-DISPLAY", name: "Test", frame: NSRect(x: 100, y: 50, width: 200, height: 150),
                                      pixelSize: CGSize(width: 400, height: 300))

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("WallpaperSurfaceTests-\(UUID().uuidString)")
        libDir = root.appendingPathComponent("lib")
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        library = WallpaperLibrary(directory: libDir)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func item(_ kind: WallpaperKind, _ source: WallpaperSource, name: String = "item") -> WallpaperItem {
        WallpaperItem(name: name, kind: kind, source: source, posterFilename: nil, thumbnailFilename: nil, durationSeconds: nil,
                      pixelWidth: nil, pixelHeight: nil, codec: nil, hasAudio: nil, hardwareDecodable: nil)
    }

    private func videoItem() async throws -> WallpaperItem {
        try await TestVideo.make(seconds: 1, in: libDir, name: "v.mov")
        return item(.video, .file("v.mov"))
    }

    // MARK: the window

    func testWindowCoversTheDisplayAtTheDesktopLevelAndIsInert() {
        let w = DesktopWallpaperWindow(frame: display.frame)
        XCTAssertEqual(w.frame, display.frame)
        XCTAssertEqual(w.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)))
        XCTAssertEqual(DesktopWallpaperWindow.level(), w.level)
        XCTAssertTrue(w.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(w.collectionBehavior.contains(.stationary))
        XCTAssertTrue(w.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(w.ignoresMouseEvents)
        XCTAssertFalse(w.canBecomeKey)
        XCTAssertFalse(w.canBecomeMain)
        XCTAssertEqual(w.animationBehavior, NSWindow.AnimationBehavior.none)
        XCTAssertFalse(w.hasShadow)
        XCTAssertFalse(w.isReleasedWhenClosed)
        XCTAssertFalse(w.isVisible, "creating a window shows nothing")
    }

    func testTheLevelIsBelowTheDesktopIconsAndAboveTheSystemWallpaper() {
        // Measured: system Wallpaper −2147483624, ours −2147483623, Finder/Event Shield −2147483603.
        XCTAssertEqual(DesktopWallpaperWindow.level().rawValue, -2147483623)
    }

    // MARK: video

    func testGravityMapping() {
        XCTAssertEqual(VideoWallpaperSurface.gravity(for: .fill), .resizeAspectFill)
        XCTAssertEqual(VideoWallpaperSurface.gravity(for: .fit), .resizeAspect)
        XCTAssertEqual(VideoWallpaperSurface.gravity(for: .stretch), .resize)
        XCTAssertEqual(ImageWallpaperSurface.gravity(for: .fill), .resizeAspectFill)
        XCTAssertEqual(ImageWallpaperSurface.gravity(for: .fit), .resizeAspect)
        XCTAssertEqual(ImageWallpaperSurface.gravity(for: .stretch), .resize)
    }

    func testTwoSurfacesForOneItemShareOnePlayerAndClosingBothEmptiesThePool() async throws {
        let it = try await videoItem()
        let players = WallpaperPlayers()
        let a = try VideoWallpaperSurface(display: display, item: it, library: library, players: players, present: false)
        let b = try VideoWallpaperSurface(display: display, item: it, library: library, players: players, present: false)
        XCTAssertTrue(a.player === b.player)
        XCTAssertEqual(players.liveKeys, [it.id])
        a.close()
        XCTAssertEqual(players.liveKeys, [it.id], "still held by the other display")
        b.close()
        XCTAssertEqual(players.liveKeys, [])
    }

    func testASurfaceIsCreatedPausedAndNeverKeepsTheDisplayAwake() async throws {
        let it = try await videoItem()
        let s = try VideoWallpaperSurface(display: display, item: it, library: library, players: WallpaperPlayers(), present: false)
        defer { s.close() }
        XCTAssertEqual(s.player.rate, 0)
        XCTAssertFalse(s.player.preventsDisplaySleepDuringVideoPlayback)
        XCTAssertFalse(s.window.isVisible)
        XCTAssertTrue(s.pausable)
    }

    func testApplyingPrefsSetsMuteVolumeAndRate() async throws {
        let it = try await videoItem()
        let s = try VideoWallpaperSurface(display: display, item: it, library: library, players: WallpaperPlayers(), present: false)
        defer { s.close() }
        var p = WallpaperPrefs()
        p.muted = false; p.volume = 0.25; p.speed = 1.5
        s.apply(p)
        XCTAssertFalse(s.player.isMuted)
        XCTAssertEqual(s.player.volume, 0.25)
        XCTAssertEqual(s.player.defaultRate, 1.5)
        XCTAssertEqual(s.player.rate, 0, "applying prefs does not start playback")
        p.muted = true
        s.apply(p)
        XCTAssertTrue(s.player.isMuted)
    }

    func testAMissingFileMakesTheFactoryThrowBeforeAnyWindowExists() {
        let gone = item(.video, .file("nope.mov"), name: "Gone")
        let factory = RealWallpaperSurfaceFactory(players: WallpaperPlayers())
        XCTAssertThrowsError(try factory.makeSurface(for: display, item: gone, library: library, prefs: WallpaperPrefs())) { error in
            XCTAssertEqual(error as? WallpaperSurfaceError, .missingFile("Gone"))
        }
    }

    // MARK: image

    func testTargetSizeIsJustEnoughToFillTheDisplay() {
        let display = CGSize(width: 400, height: 300)
        // Same shape, larger: scaled down to the display.
        XCTAssertEqual(ImageWallpaperSurface.targetMaxPixel(imageSize: CGSize(width: 4000, height: 3000), displayPixels: display, scaling: .fill), 400)
        // Smaller than the display: never enlarged.
        XCTAssertEqual(ImageWallpaperSurface.targetMaxPixel(imageSize: CGSize(width: 200, height: 150), displayPixels: display, scaling: .fill), 200)
        // A tall photo on a wide screen is drawn wider than the screen's long side, so it needs more than 400.
        let tall = ImageWallpaperSurface.targetMaxPixel(imageSize: CGSize(width: 3000, height: 4000), displayPixels: display, scaling: .fill)
        XCTAssertGreaterThan(tall, 400)
        // ...but fit needs only enough to fit inside.
        XCTAssertEqual(ImageWallpaperSurface.targetMaxPixel(imageSize: CGSize(width: 3000, height: 4000), displayPixels: display, scaling: .fit), 300)
    }

    func testTheDecodedAreaIsCappedAtTwiceTheDisplay() {
        let display = CGSize(width: 400, height: 300)
        let n = ImageWallpaperSurface.targetMaxPixel(imageSize: CGSize(width: 40000, height: 1000), displayPixels: display, scaling: .fill)
        let area = Double(n) * Double(n) / 40.0   // 40:1 panorama
        XCTAssertLessThanOrEqual(area, 2.0 * 400 * 300 * 1.05)
    }

    func testImageSurfaceHoldsABitmapNoLargerThanTheDisplayAndNeverPauses() throws {
        try TestImage.writePNG(width: 1600, height: 1200, to: libDir.appendingPathComponent("big.png"))
        let it = item(.image, .file("big.png"))
        let s = try ImageWallpaperSurface(display: display, item: it, library: library, scaling: .fill, present: false)
        defer { s.close() }
        XCTAssertFalse(s.pausable)
        let loaded = expectation(description: "decoded")
        s.onLoaded = { loaded.fulfill() }
        s.start()
        wait(for: [loaded], timeout: 10)
        let image = try XCTUnwrap(s.image)
        XCTAssertLessThanOrEqual(image.width, 400)
        XCTAssertLessThanOrEqual(image.height, 300)
        XCTAssertGreaterThan(image.width, 0)
        s.setPlaying(false); s.setPlaying(true)   // nothing to do, and nothing breaks
        XCTAssertFalse(s.window.isVisible)
    }

    func testAnUnreadableImageReportsFailureAndShowsNothing() throws {
        try Data("not an image".utf8).write(to: libDir.appendingPathComponent("bad.png"))
        let it = item(.image, .file("bad.png"))
        let s = try ImageWallpaperSurface(display: display, item: it, library: library, scaling: .fill, present: false)
        defer { s.close() }
        let failed = expectation(description: "failure")
        s.onFailure = { _ in failed.fulfill() }
        s.start()
        wait(for: [failed], timeout: 10)
        XCTAssertNil(s.image)
    }

    // MARK: web

    func testWebConfigurationContainsThePage() {
        let c = WebWallpaperSurface.webConfiguration()
        XCTAssertFalse(c.websiteDataStore.isPersistent)
        XCTAssertEqual(c.mediaTypesRequiringUserActionForPlayback, [])
        XCTAssertFalse(c.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(c.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(c.userContentController.userScripts.count, 1)
    }

    func testTheMutingScriptRunsAtDocumentStartInEveryFrame() {
        let s = WebWallpaperSurface.mutingUserScript()
        XCTAssertEqual(s.injectionTime, .atDocumentStart)
        XCTAssertFalse(s.isForMainFrameOnly)
        for needle in ["HTMLMediaElement", "muted", "AudioContext", "__anodeSetSound"] {
            XCTAssertTrue(s.source.contains(needle), "the script should deal with \(needle)")
        }
    }

    func testNavigationIsFreeBeforeTheFirstLoadCommitsAndLockedAfter() {
        let page = URL(string: "https://example.com/art")!
        let elsewhere = URL(string: "https://evil.example/")!
        // First load, and a redirect on the way, in the main frame.
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: nil, target: page), .allow)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: nil, target: elsewhere), .allow)
        // Afterwards the main frame stays on the page...
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: page, target: elsewhere), .cancel)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: page, target: nil), .cancel)
        // ...may reload itself or move within itself...
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: page, target: page), .allow)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: page,
                                                            target: URL(string: "https://example.com/art#top")!), .allow)
        // ...and sub-frames (an embedded player) are not its business.
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: false, committedMainURL: page, target: elsewhere), .allow)
    }

    func testAFolderItemIsReadableOnlyFromItsOwnFolder() throws {
        let dir = libDir.appendingPathComponent("web-1")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: dir.appendingPathComponent("index.html"))
        let it = item(.web, .folder(directory: "web-1", entry: "index.html"))
        guard case .file(let url, let readAccess)? = WebWallpaperSurface.loadPlan(for: it, library: library) else {
            return XCTFail("expected a local file plan")
        }
        XCTAssertEqual(url.path, dir.appendingPathComponent("index.html").path)
        XCTAssertEqual(readAccess.standardizedFileURL.path, dir.standardizedFileURL.path, "read access is the page's own folder, not the library")
    }

    func testAYouTubeEmbedLoadsThroughTheWrapperPageNotDirectly() {
        let embed = WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")
        guard case .html(let html, let base)? = WebWallpaperSurface.loadPlan(for: item(.web, .remote(embed)), library: library) else {
            return XCTFail("expected the wrapper page")
        }
        XCTAssertTrue(html.contains("<iframe"))
        XCTAssertEqual(base, WallpaperURLClassifier.youtubeWrapperBaseURL)
        XCTAssertEqual(WebWallpaperSurface.loadPlan(for: item(.web, .remote(URL(string: "https://example.com/")!)), library: library),
                       .remote(URL(string: "https://example.com/")!))
    }

    func testWebSurfaceIsPausableAndStartsWithoutLoadingAnything() throws {
        let dir = libDir.appendingPathComponent("web-2")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: dir.appendingPathComponent("index.html"))
        let it = item(.web, .folder(directory: "web-2", entry: "index.html"))
        let s = try WebWallpaperSurface(display: display, item: it, library: library, present: false)
        defer { s.close() }
        XCTAssertTrue(s.pausable)
        XCTAssertNil(s.webView.url, "nothing loads until start()")
        XCTAssertFalse(s.window.isVisible)
        XCTAssertTrue(s.webView.superview != nil)
    }

    func testAWebItemWhoseFolderIsGoneThrows() {
        let it = item(.web, .folder(directory: "../outside", entry: "index.html"), name: "Escape")
        XCTAssertThrowsError(try WebWallpaperSurface(display: display, item: it, library: library, present: false))
    }

    func testTheRealSnapshotterPicturesALocalPage() async throws {
        let page = libDir.appendingPathComponent("snap.html")
        try Data("<html><body style='background:#c33'><h1>hello</h1></body></html>".utf8).write(to: page)
        let image = try await WebWallpaperSurface.snapshot(page, size: CGSize(width: 320, height: 200))
        XCTAssertGreaterThanOrEqual(image.width, 320)
        XCTAssertGreaterThanOrEqual(image.height, 200)
    }
}
