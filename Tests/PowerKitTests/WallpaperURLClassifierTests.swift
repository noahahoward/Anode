import XCTest
@testable import PowerKit

/// Links are classified from their text alone: scheme, host and extension. No network.
final class WallpaperURLClassifierTests: XCTestCase {

    private func kind(_ s: String) -> LinkKind { WallpaperURLClassifier.classify(URL(string: s)!) }

    func testDirectVideoLinks() {
        for ext in ["mp4", "mov", "m4v", "m3u8", "MP4"] {
            XCTAssertEqual(kind("https://x.com/a/clip.\(ext)"), .directVideo, ext)
        }
        XCTAssertEqual(kind("https://x.com/clip.mp4?token=abc"), .directVideo, "a query string does not hide the extension")
    }

    func testDirectImageLinks() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp", "gif", "tif", "tiff"] {
            XCTAssertEqual(kind("https://x.com/a/pic.\(ext)"), .directImage, ext)
        }
    }

    func testYouTubeLinksAllGiveTheSameID() {
        let id = "dQw4w9WgXcQ"
        for s in ["https://www.youtube.com/watch?v=\(id)", "https://youtu.be/\(id)", "https://www.youtube.com/embed/\(id)",
                  "https://www.youtube.com/watch?v=\(id)&t=30s", "https://youtube.com/watch?v=\(id)",
                  "https://m.youtube.com/watch?v=\(id)", "https://youtu.be/\(id)?t=30"] {
            XCTAssertEqual(kind(s), .youtube(id: id), s)
        }
    }

    func testAYouTubeLinkWithoutAValidIDIsJustAWebPage() {
        XCTAssertEqual(kind("https://www.youtube.com/"), .webPage)
        XCTAssertEqual(kind("https://www.youtube.com/watch?v=short"), .webPage)
        XCTAssertEqual(kind("https://www.youtube.com/@somechannel"), .webPage)
    }

    func testAnotherHostThatMerelyContainsYouTubeIsNotYouTube() {
        XCTAssertEqual(kind("https://evil-youtube.com/watch?v=dQw4w9WgXcQ"), .webPage)
        XCTAssertEqual(kind("https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ"), .webPage)
    }

    func testOrdinaryPagesAreWebPages() {
        XCTAssertEqual(kind("https://example.com/page"), .webPage)
        XCTAssertEqual(kind("https://example.com"), .webPage)
    }

    func testOnlyHTTPSWorks() {
        let expected = LinkKind.unsupported("Only https links work")
        XCTAssertEqual(kind("http://example.com/a.mp4"), expected)
        XCTAssertEqual(kind("http://example.com/page"), expected)
        XCTAssertEqual(kind("http://www.youtube.com/watch?v=dQw4w9WgXcQ"), expected)
    }

    func testFileAndScriptLinksAreRefused() {
        if case .unsupported = kind("file:///etc/passwd") {} else { XCTFail("file: must be refused") }
        if case .unsupported = kind("javascript:alert(1)") {} else { XCTFail("javascript: must be refused") }
        if case .unsupported = kind("ftp://example.com/a.mp4") {} else { XCTFail("ftp: must be refused") }
        if case .unsupported = kind("https:///nohost") {} else { XCTFail("no host must be refused") }
    }

    func testEmbedURLCarriesTheAutoplayMuteLoopAndNoControlsParameters() {
        let url = WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://www.youtube.com/embed/dQw4w9WgXcQ?"))
        for needle in ["autoplay=1", "mute=1", "loop=1", "controls=0", "playlist=dQw4w9WgXcQ",
                       "enablejsapi=1", "cc_load_policy=0", "playsinline=1", "origin=https://anode.app"] {
            XCTAssertTrue(s.contains(needle), "missing \(needle) in \(s)")
        }
    }

    func testTheEmbedURLIsRecognisedAsOneAndTheIDRecovered() {
        let id = "dQw4w9WgXcQ"
        XCTAssertEqual(WallpaperURLClassifier.youtubeEmbedID(in: WallpaperURLClassifier.youtubeEmbedURL(id: id)), id)
        XCTAssertNil(WallpaperURLClassifier.youtubeEmbedID(in: URL(string: "https://example.com/embed/\(id)")!))
        XCTAssertNil(WallpaperURLClassifier.youtubeEmbedID(in: URL(string: "https://www.youtube.com/watch?v=\(id)")!))
    }

    func testTheWrapperPageEmbedsTheIframeUnderAnHTTPSBase() {
        // Navigating straight to the embed URL fails with "Video player configuration error 153": the embed needs a
        // referring page. The wrapper supplies one.
        let embed = WallpaperURLClassifier.youtubeEmbedURL(id: "dQw4w9WgXcQ")
        let html = WallpaperURLClassifier.youtubeWrapperHTML(embedURL: embed)
        XCTAssertTrue(html.contains("<iframe"))
        XCTAssertTrue(html.contains(embed.absoluteString.replacingOccurrences(of: "&", with: "&amp;")) || html.contains(embed.absoluteString))
        XCTAssertTrue(html.contains("autoplay"), "the iframe is allowed to autoplay")
        XCTAssertEqual(WallpaperURLClassifier.youtubeWrapperBaseURL.scheme, "https")
    }

    func testThePlayerCommandsAreTheIFrameAPIOnes() {
        XCTAssertTrue(WallpaperURLClassifier.youtubePlayerCommand(playing: false).contains("pauseVideo"))
        XCTAssertTrue(WallpaperURLClassifier.youtubePlayerCommand(playing: true).contains("playVideo"))
        XCTAssertTrue(WallpaperURLClassifier.youtubePlayerCommand(playing: false).contains("postMessage"))
    }
}
