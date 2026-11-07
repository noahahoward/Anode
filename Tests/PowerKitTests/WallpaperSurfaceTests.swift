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

    func testAMutedWallpaperHoldsNoAudioStreamOpen() async throws {
        // Measured on the Mac: a muted AVPlayer with an enabled audio track still holds a Core Audio output stream, and
        // coreaudiod then holds PreventUserIdleSystemSleep for the app. Muted means the audio tracks are switched off.
        try await TestVideo.make(seconds: 1, audio: true, in: libDir, name: "av.mov")
        let it = item(.video, .file("av.mov"))
        let s = try VideoWallpaperSurface(display: display, item: it, library: library, players: WallpaperPlayers(), present: false)
        defer { s.close() }
        var p = WallpaperPrefs(); p.muted = true
        s.apply(p)
        try await waitForAudioTracks(of: s.player)
        XCTAssertTrue(audioTracks(of: s.player).allSatisfy { !$0.isEnabled }, "muted: every audio track is off")
        p.muted = false
        s.apply(p)
        try await waitUntil { self.audioTracks(of: s.player).allSatisfy { $0.isEnabled } }
        p.muted = true
        s.apply(p)
        try await waitUntil { self.audioTracks(of: s.player).allSatisfy { !$0.isEnabled } }
    }

    private func audioTracks(of player: AVQueuePlayer) -> [AVPlayerItemTrack] {
        player.items().flatMap { $0.tracks }.filter { $0.assetTrack?.mediaType == .audio }
    }

    private func waitForAudioTracks(of player: AVQueuePlayer) async throws {
        try await waitUntil { !self.audioTracks(of: player).isEmpty }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for the audio tracks to settle") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
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
        let scripts = c.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2, "the sound switch and the YouTube player-screen hider, and nothing else")
        XCTAssertTrue(scripts.contains { $0.source == WallpaperURLClassifier.youtubeChromeHidingScript && !$0.isForMainFrameOnly },
                      "the hider has to run inside YouTube's own frame")
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

    // MARK: web: review fixes

    private func webItem(_ source: WallpaperSource) throws -> WallpaperItem {
        if case .folder(let dir, let entry) = source {
            let d = libDir.appendingPathComponent(dir)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: d.appendingPathComponent(entry))
        }
        return item(.web, source)
    }

    func testARedirectToAnInsecureAddressIsRefusedEvenBeforeTheFirstCommit() {
        let secure = URL(string: "https://art.example/")!, insecure = URL(string: "http://art.example/")!
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: nil, target: insecure), .cancel)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: nil, target: secure), .allow)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: nil,
                                                            target: URL(string: "file:///tmp/p/index.html")!), .allow)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: nil, target: URL(string: "about:blank")!), .allow)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: true, committedMainURL: nil,
                                                            target: URL(string: "javascript:alert(1)")!), .cancel)
        XCTAssertEqual(WebWallpaperSurface.navigationPolicy(isMainFrame: false, committedMainURL: nil, target: insecure), .allow,
                       "an embedded frame is not the page")
    }

    func testAResponseTheViewCannotShowIsRefusedAndReportedForTheMainFrame() {
        let bad = WebWallpaperSurface.responsePolicy(canShowMIMEType: false, isMainFrame: true)
        XCTAssertEqual(bad.policy, .cancel)
        XCTAssertNotNil(bad.failure, "the row must say why, not claim Playing")
        let sub = WebWallpaperSurface.responsePolicy(canShowMIMEType: false, isMainFrame: false)
        XCTAssertEqual(sub.policy, .cancel)
        XCTAssertNil(sub.failure)
        let fine = WebWallpaperSurface.responsePolicy(canShowMIMEType: true, isMainFrame: true)
        XCTAssertEqual(fine.policy, .allow)
        XCTAssertNil(fine.failure)
    }

    func testAPageThatNeverFinishesLoadingIsReportedAsFailed() throws {
        let s = try WebWallpaperSurface(display: display, item: webItem(.folder(directory: "web-t", entry: "index.html")),
                                        library: library, present: false)
        defer { s.close() }
        var reported: [String] = []
        s.onFailure = { reported.append($0) }
        s.loadTimedOut()
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported[0].lowercased().contains("too long"))
        // Once loaded, a late timer is harmless.
        s.webView(s.webView, didFinish: nil)
        s.loadTimedOut()
        XCTAssertEqual(reported.count, 1)
    }

    func testEachSurfaceHasItsOwnSecretSoundSwitchNotTheDefaultName() throws {
        let a = try WebWallpaperSurface(display: display, item: webItem(.folder(directory: "web-a", entry: "index.html")), library: library, present: false)
        let b = try WebWallpaperSurface(display: display, item: webItem(.folder(directory: "web-b", entry: "index.html")), library: library, present: false)
        defer { a.close(); b.close() }
        XCTAssertNotEqual(a.setterName, b.setterName)
        XCTAssertNotEqual(a.setterName, WebWallpaperSurface.defaultSetterName)
        var sent: [String] = []
        a.scriptSink = { sent.append($0) }
        var p = WallpaperPrefs(); p.muted = false
        a.apply(p)
        XCTAssertTrue(sent.contains { $0.contains(a.setterName) && $0.contains("true") }, sent.description)
        XCTAssertFalse(sent.contains { $0.contains(WebWallpaperSurface.defaultSetterName) })
    }

    func testAYouTubeEmbedIsPausedAndResumedThroughThePlayerAPI() throws {
        let embed = WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")
        let s = try WebWallpaperSurface(display: display, item: item(.web, .remote(embed)), library: library, present: false)
        defer { s.close() }
        var sent: [String] = []
        s.scriptSink = { sent.append($0) }
        s.webView(s.webView, didFinish: nil)       // loaded
        sent.removeAll()
        s.setPlaying(true)
        XCTAssertTrue(sent.contains { $0.contains("playVideo") }); XCTAssertTrue(sent.contains { $0.contains("anode-resume") })
        sent.removeAll()
        s.setPlaying(false)
        XCTAssertTrue(sent.contains { $0.contains("pauseVideo") }); XCTAssertTrue(sent.contains { $0.contains("anode-pause") })
    }

    // MARK: YouTube quality and hiding the player's own screen

    private func evaluate(_ web: WKWebView, _ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { c in
            web.evaluateJavaScript(js) { r, e in if let e { c.resume(throwing: e) } else { c.resume(returning: r) } }
        }
    }

    private func loaded(_ html: String, base: String = "https://anode.app/") async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: WKWebViewConfiguration())
        let waiter = LoadWaiter()
        web.navigationDelegate = waiter
        web.loadHTMLString(html, baseURL: URL(string: base))
        await waiter.wait()
        return web
    }

    func testTheYouTubePlayerIsSizedSoItDecodesExactlyTheChosenResolution() async throws {
        // Measured on the Mac: the player picks its quality from its own size times the display's pixel ratio
        // (iframe 1920 css px -> 2160p, 1280 -> 1440p, 960 -> 1080p, 640 -> 720p at ratio 2).
        for q in YouTubeQuality.allCases {
            let web = try await loaded(WallpaperURLClassifier.youtubeWrapperHTML(embedURL: URL(string: "about:blank")!, quality: q.height))
            let device = try await evaluate(web, "parseFloat(document.getElementById('p').style.height) * window.devicePixelRatio") as? Double
            XCTAssertEqual(try XCTUnwrap(device), Double(q.height), accuracy: 1, "\(q)")
        }
    }

    func testChangingTheQualityResizesThePlayerWithoutReloadingIt() async throws {
        let web = try await loaded(WallpaperURLClassifier.youtubeWrapperHTML(embedURL: URL(string: "about:blank")!, quality: 2160))
        _ = try await evaluate(web, WallpaperURLClassifier.youtubeQualityCommand(height: 1080))
        let device = try await evaluate(web, "parseFloat(document.getElementById('p').style.height) * window.devicePixelRatio") as? Double
        XCTAssertEqual(try XCTUnwrap(device), 1080, accuracy: 1)
        let covers = try await evaluate(web, """
            (function(){ var r = document.getElementById('p').getBoundingClientRect();
              return r.width >= innerWidth - 1 && r.height >= innerHeight - 1 && r.left <= 1 && r.top <= 1; })()
            """) as? Bool
        XCTAssertEqual(covers, true, "scaled up, the player still covers the whole window")
    }

    func testTheHidingScriptRemovesEveryOverlayNowAndOnesAddedLaterButKeepsTheVideoAndLoopsIt() async throws {
        let html = """
        <html><body><div id="player"><div class="html5-video-player" id="pl">
          <div class="html5-video-container" id="vc"><video id="v" class="video-stream"></video></div>
          <div class="ytp-unmute" id="o1">unmute</div><div id="o2">title</div>
        </div><div id="o3">controls host</div></div></body></html>
        """
        let web = try await loaded(html, base: "https://www.youtube.com/")
        _ = try await evaluate(web, WallpaperURLClassifier.youtubeChromeHidingScript)
        let later = try await evaluate(web, """
            (function(){ var d = document.createElement('div'); d.id = 'late'; document.getElementById('pl').appendChild(d);
              var e = document.createElement('div'); e.id = 'late2'; document.getElementById('vc').appendChild(e); return true; })()
            """)
        XCTAssertEqual(later as? Bool, true)
        await wait(0.6)
        func display(_ id: String) async throws -> String {
            try await evaluate(web, "getComputedStyle(document.getElementById('\(id)')).display") as? String ?? "?"
        }
        for id in ["o1", "o2", "o3", "late", "late2"] { let d = try await display(id); XCTAssertEqual(d, "none", id) }
        for id in ["player", "pl", "vc", "v"] { let d = try await display(id); XCTAssertNotEqual(d, "none", "\(id) must stay") }
        let loops = try await evaluate(web, "document.getElementById('v').loop") as? Bool
        XCTAssertEqual(loops, true, "the browser loops the video itself, so there is no reload and no overlay at each restart")
    }

    func testTheHidingScriptDoesNothingOnAPageThatIsNotYouTube() async throws {
        let web = try await loaded("<html><body><video id='v'></video><div id='o'>x</div></body></html>", base: "https://example.com/")
        _ = try await evaluate(web, WallpaperURLClassifier.youtubeChromeHidingScript)
        await wait(0.6)
        let shown = try await evaluate(web, "getComputedStyle(document.getElementById('o')).display") as? String
        XCTAssertEqual(shown, "block")
    }

    func testAYouTubeSurfaceIsToldTheQualityAtOnceAndWhenItChanges() throws {
        let embed = WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")
        let s = try WebWallpaperSurface(display: display, item: item(.web, .remote(embed)), library: library, present: false)
        defer { s.close() }
        var sent: [String] = []
        s.scriptSink = { sent.append($0) }
        var p = WallpaperPrefs(); p.youtubeQuality = .p1080
        s.apply(p)
        XCTAssertTrue(sent.contains(WallpaperURLClassifier.youtubeQualityCommand(height: 1080)), sent.description)
        sent.removeAll()
        s.apply(p)
        XCTAssertFalse(sent.contains { $0.contains("anodeSetQuality") }, "an unchanged choice is not sent again")
        p.youtubeQuality = .p720
        s.apply(p)
        XCTAssertTrue(sent.contains(WallpaperURLClassifier.youtubeQualityCommand(height: 720)))
        sent.removeAll()
        s.webView(s.webView, didFinish: nil); s.webView(s.webView, didFinish: nil)   // loaded, then reloaded
        XCTAssertTrue(sent.contains(WallpaperURLClassifier.youtubeQualityCommand(height: 720)), "a reloaded page gets the choice again")
    }

    func testAPageThatIsNotYouTubeIsNeverToldAQuality() throws {
        let s = try WebWallpaperSurface(display: display, item: webItem(.folder(directory: "web-q", entry: "index.html")),
                                        library: library, present: false)
        defer { s.close() }
        var sent: [String] = []
        s.scriptSink = { sent.append($0) }
        s.apply(WallpaperPrefs())
        XCTAssertFalse(sent.contains { $0.contains("anodeSetQuality") })
    }

    // MARK: YouTube: the player's own screen is never what the desktop shows

    private func youtubeSurfaceWithAStill() throws -> (WebWallpaperSurface, WallpaperItem) {
        let it = item(.web, .remote(WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")))
        try TestImage.write(.jpeg, width: 640, height: 360, to: try XCTUnwrap(library.stillURL(it)))
        let s = try WebWallpaperSurface(display: display, item: it, library: library, present: false)
        s.chromeSettle = 0.05
        s.fadeDuration = 0.01
        s.webView(s.webView, didFinish: nil)
        return (s, it)
    }

    private func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func testAPausedYouTubeWallpaperIsCoveredByOurStillBeforeThePlayerIsToldToPause() throws {
        let (s, _) = try youtubeSurfaceWithAStill()
        defer { s.close() }
        var coveredWhenPauseSent: Bool?
        s.scriptSink = { js in if js.contains("pauseVideo") { coveredWhenPauseSent = !s.placeholder.isHidden && s.webView.superview == nil } }
        s.setPlaying(false)
        XCTAssertFalse(s.placeholder.isHidden, "the still is up")
        XCTAssertNotNil(s.placeholder.layer?.contents)
        XCTAssertNil(s.webView.superview, "the live player is out of the window")
        XCTAssertEqual(coveredWhenPauseSent, true, "the player is only told to pause once nothing of it can be seen")
    }

    func testAYouTubeWallpaperKeepsTheStillUpWhileThePlayerHidesItsTitleThenFadesItAway() async throws {
        let (s, _) = try youtubeSurfaceWithAStill()
        defer { s.close() }
        s.setPlaying(false)
        s.setPlaying(true)
        XCTAssertNotNil(s.webView.superview, "the player is back")
        XCTAssertFalse(s.placeholder.isHidden, "but the still stays over it while its title and buttons are showing")
        await wait(0.5)
        XCTAssertTrue(s.placeholder.isHidden, "and goes once they have faded")
    }

    func testAPauseDuringTheSettlingTimeDoesNotLetTheOldFadeUncoverThePausedPlayer() async throws {
        let (s, _) = try youtubeSurfaceWithAStill()
        defer { s.close() }
        s.chromeSettle = 0.1
        s.setPlaying(true)
        s.setPlaying(false)
        await wait(0.5)
        XCTAssertFalse(s.placeholder.isHidden, "paused means the still stays")
    }

    func testAYouTubeWallpaperWithNoStillYetFetchesOneAndKeepsIt() async throws {
        let it = item(.web, .remote(WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")))
        let jpegURL = try TestImage.write(.jpeg, width: 640, height: 360, to: root.appendingPathComponent("src.jpg"))
        let data = try Data(contentsOf: jpegURL)
        let s = try WebWallpaperSurface(display: display, item: it, library: library, present: false)
        defer { s.close() }
        s.stillFetch = { _ in data }
        XCTAssertFalse(s.hasStill)
        await s.fetchStillIfNeeded()
        XCTAssertTrue(s.hasStill)
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(library.stillURL(it)).path))
    }

    func testAPageThatReloadsAfterACrashIsToldItsStateAgain() throws {
        let s = try WebWallpaperSurface(display: display, item: webItem(.folder(directory: "web-c", entry: "index.html")),
                                        library: library, present: false)
        defer { s.close() }
        var p = WallpaperPrefs(); p.muted = false
        s.apply(p)
        s.setPlaying(true)
        s.webView(s.webView, didFinish: nil)       // first load
        var sent: [String] = []
        s.scriptSink = { sent.append($0) }
        s.webView(s.webView, didFinish: nil)       // the reload after a crash
        XCTAssertTrue(sent.contains { $0.contains(s.setterName) && $0.contains("true") }, "the unmuted choice is sent again: \(sent)")
        XCTAssertTrue(sent.contains { $0.contains("anode-resume") }, "and so is the playing state")
    }

    func testAPageThatFindsTheSoundSwitchStillCannotUseItWithoutTheKey() async throws {
        // Measured on the Mac: Object.getOwnPropertyNames(window) lists a non-enumerable switch, so hiding the name is not enough.
        let config = WebWallpaperSurface.webConfiguration(setterName: "__found", setterKey: "right-key")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        let waiter = LoadWaiter()
        web.navigationDelegate = waiter
        let loaded = expectation(description: "loaded")
        waiter.onFinish = { loaded.fulfill() }
        web.loadHTMLString("<html><body></body></html>", baseURL: WallpaperURLClassifier.youtubeWrapperBaseURL)
        await fulfillment(of: [loaded], timeout: 15)
        func mutedAfterTryingToUnmute() async throws -> String {
            try await web.evaluateJavaScript("(function(){var v=document.createElement('video');v.muted=false;return String(v.muted)})()") as? String ?? "?"
        }
        do { let m = try await mutedAfterTryingToUnmute(); XCTAssertEqual(m, "true", "forced muted from the start") }
        _ = try await web.evaluateJavaScript("window['__found'](true)")
        do { let m = try await mutedAfterTryingToUnmute(); XCTAssertEqual(m, "true", "no key: nothing changes") }
        _ = try await web.evaluateJavaScript("window['__found'](true, 'guess')")
        do { let m = try await mutedAfterTryingToUnmute(); XCTAssertEqual(m, "true", "wrong key: nothing changes") }
        let source = try await web.evaluateJavaScript("String(window['__found'])") as? String ?? ""
        XCTAssertFalse(source.contains("right-key"), "the key is not readable from the function's text")
        _ = try await web.evaluateJavaScript("window['__found'](true, 'right-key')")
        do { let m = try await mutedAfterTryingToUnmute(); XCTAssertEqual(m, "false", "the app, which knows the key, can unmute") }
        _ = try await web.evaluateJavaScript("window['__found'](false, 'right-key')")
        do { let m = try await mutedAfterTryingToUnmute(); XCTAssertEqual(m, "true") }
        web.navigationDelegate = nil
    }

    func testTheMutingScriptCannotBeTurnedOffByThePageItself() async throws {
        let config = WebWallpaperSurface.webConfiguration(setterName: "__secretSwitch")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        let waiter = LoadWaiter()
        web.navigationDelegate = waiter
        let loaded = expectation(description: "loaded")
        waiter.onFinish = { loaded.fulfill() }
        web.loadHTMLString("<html><body></body></html>", baseURL: WallpaperURLClassifier.youtubeWrapperBaseURL)
        await fulfillment(of: [loaded], timeout: 15)
        let js = """
        (function(){
          var Ctx = window.AudioContext || window.webkitAudioContext;
          var out = {};
          out.defaultNameHidden = (typeof window.__anodeSetSound === 'undefined');
          if (Ctx) {
            var c = new Ctx();
            out.constructorIsWrapped = (c.constructor === Ctx);
            out.sameConstructorStillQuiet = (new (c.constructor)().constructor === Ctx);
            out.resumeCannotBeRestored = (delete c.resume) === false || typeof c.resume === 'function';
            out.protoResumeLocked = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(c), 'resume') === undefined
                                    || Object.getOwnPropertyDescriptor(Ctx.prototype, 'resume').configurable === false;
          }
          return JSON.stringify(out);
        })()
        """
        let result = try await web.evaluateJavaScript(js) as? String ?? ""
        XCTAssertTrue(result.contains("\"defaultNameHidden\":true"), result)
        XCTAssertTrue(result.contains("\"constructorIsWrapped\":true"), result)
        XCTAssertTrue(result.contains("\"sameConstructorStillQuiet\":true"), result)
        XCTAssertTrue(result.contains("\"protoResumeLocked\":true"), result)
        web.navigationDelegate = nil
    }

    func testTheRealSnapshotterPicturesALocalPage() async throws {
        let page = libDir.appendingPathComponent("snap.html")
        try Data("<html><body style='background:#c33'><h1>hello</h1></body></html>".utf8).write(to: page)
        let image = try await WebWallpaperSurface.snapshot(page, size: CGSize(width: 320, height: 200))
        XCTAssertGreaterThanOrEqual(image.width, 320)
        XCTAssertGreaterThanOrEqual(image.height, 200)
    }
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
}

private extension LoadWaiter {
    /// Returns when the page has finished loading.
    func wait() async { await withCheckedContinuation { c in onFinish = { c.resume() } } }
}
