import AppKit
import Network
import PowerKit
import WebKit

// ── A web page as the wallpaper ─────────────────────────────────────────────
//
// A page is arbitrary code from somewhere else, so it is contained rather than trusted:
//  - a non-persistent data store (nothing it stores outlives the session, and it shares nothing with any browser),
//  - it cannot open windows, show alerts, pick files, use the camera or microphone, or read location/motion,
//  - once its first load has committed, the main frame cannot go anywhere else (a redirect during the first load is allowed),
//  - a local page may read only its own folder (`loadFileURL(_:allowingReadAccessTo:)`),
//  - every media element is forced muted, and audio contexts are held suspended, unless the user turned sound on,
//  - the window is click-through, so there is no interaction at all.
//
// Paused = media suspended, the page told (`anode-pause`), and the web view taken out of the window so WebKit marks the page
// hidden and stops running it (measured: a 20 %-of-a-core animation falls to 0.05 %). The last picture of the page is kept on
// screen as a still so the desktop doesn't go black. A YouTube embed lives in a cross-origin iframe, which the page cannot
// pause from outside, so it is paused through the player's IFrame API.

/// How a web wallpaper's page gets loaded.
enum WebLoadPlan: Equatable {
    /// A local file, readable together with its own folder and nothing else.
    case file(url: URL, readAccess: URL)
    case remote(URL)
    /// Our own page, loaded as if from an https address (the YouTube wrapper).
    case html(String, baseURL: URL)
}

final class WebWallpaperSurface: NSObject, WallpaperSurface, WKNavigationDelegate, WKUIDelegate {

    let displayUUID: String
    let pausable = true
    var onCoveredChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    let window: DesktopWallpaperWindow
    let webView: WKWebView
    private let container: NSView
    private let placeholder: NSView
    private let plan: WebLoadPlan
    private let youtubeEmbed: Bool
    private let isRemote: Bool
    private let present: Bool
    private var committedMainURL: URL?
    private var desiredPlaying = false
    private var loaded = false
    private var failedAndWaitingForNetwork = false
    private var restarts = 0
    private var pauseToken = 0
    private var pathMonitor: NWPathMonitor?
    private var closed = false

    // MARK: pure pieces (tested)

    static func webConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        c.mediaTypesRequiringUserActionForPlayback = []
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.allowsAirPlayForMediaPlayback = false
        c.userContentController.addUserScript(mutingUserScript())
        return c
    }

    /// Forces every media element and audio context silent, in every frame, from the first moment of the page. The page can
    /// still run its own audio code; it just makes no sound. `window.__anodeSetSound(true)` lets sound through.
    static func mutingUserScript() -> WKUserScript {
        WKUserScript(source: mutingScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    static let mutingScriptSource = """
    (function () {
      if (window.__anodeSetSound) { return; }
      var allow = false;
      var proto = HTMLMediaElement.prototype;
      var mutedDesc = Object.getOwnPropertyDescriptor(proto, 'muted');
      function silence(m) { try { if (!allow && mutedDesc && mutedDesc.set) { mutedDesc.set.call(m, true); } } catch (e) {} }
      if (mutedDesc && mutedDesc.set) {
        Object.defineProperty(proto, 'muted', { configurable: true, enumerable: mutedDesc.enumerable,
          get: function () { return mutedDesc.get.call(this); },
          set: function (v) { mutedDesc.set.call(this, allow ? v : true); } });
      }
      var nativePlay = proto.play;
      proto.play = function () { silence(this); return nativePlay.apply(this, arguments); };
      function sweep() { var els = document.querySelectorAll('video,audio'); for (var i = 0; i < els.length; i++) { silence(els[i]); } }
      document.addEventListener('play', function (e) { if (e.target && e.target.tagName) { silence(e.target); } }, true);
      document.addEventListener('volumechange', function (e) { if (e.target && e.target.tagName) { silence(e.target); } }, true);
      var contexts = [];
      function quiet(c) { try { if (!allow) { c.suspend(); c.resume = function () { return Promise.resolve(); }; } } catch (e) {} }
      ['AudioContext', 'webkitAudioContext'].forEach(function (name) {
        var Native = window[name];
        if (!Native) { return; }
        var Wrapped = function () {
          var c = new Native(...arguments);
          contexts.push(c);
          quiet(c);
          return c;
        };
        Wrapped.prototype = Native.prototype;
        try { Object.defineProperty(window, name, { configurable: true, writable: true, value: Wrapped }); } catch (e) {}
      });
      window.__anodeSetSound = function (on) {
        allow = !!on;
        if (allow) { contexts.forEach(function (c) { try { delete c.resume; c.resume(); } catch (e) {} }); }
        else { contexts.forEach(quiet); sweep(); }
      };
      document.addEventListener('DOMContentLoaded', sweep);
    })();
    """

    /// Whether a navigation may go ahead. Before the page's first load has committed everything in the main frame is allowed
    /// (the load itself, and any server redirect on the way); afterwards the main frame may only reload the same page (or
    /// change its #fragment). Sub-frames (an embedded player, an ad, a widget) are never restricted here.
    static func navigationPolicy(isMainFrame: Bool, committedMainURL: URL?, target: URL?) -> WKNavigationActionPolicy {
        guard isMainFrame else { return .allow }
        guard let committed = committedMainURL else { return .allow }
        guard let target else { return .cancel }
        return withoutFragment(target) == withoutFragment(committed) ? .allow : .cancel
    }

    private static func withoutFragment(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? url.absoluteString
    }

    static func loadPlan(for item: WallpaperItem, library: WallpaperLibrary) -> WebLoadPlan? {
        switch item.source {
        case .folder:
            guard let page = library.contentURL(item), let folder = library.folderURL(item) else { return nil }
            return .file(url: page, readAccess: folder)
        case .file:
            guard let page = library.contentURL(item) else { return nil }
            return .file(url: page, readAccess: page.deletingLastPathComponent())
        case .remote(let url):
            if WallpaperURLClassifier.youtubeEmbedID(in: url) != nil {
                return .html(WallpaperURLClassifier.youtubeWrapperHTML(embedURL: url), baseURL: WallpaperURLClassifier.youtubeWrapperBaseURL)
            }
            return .remote(url)
        }
    }

    /// The plan for an arbitrary page URL (used to snapshot a page that is not yet a library item).
    static func loadPlan(forPage url: URL) -> WebLoadPlan {
        if url.isFileURL { return .file(url: url, readAccess: url.deletingLastPathComponent()) }
        if WallpaperURLClassifier.youtubeEmbedID(in: url) != nil {
            return .html(WallpaperURLClassifier.youtubeWrapperHTML(embedURL: url), baseURL: WallpaperURLClassifier.youtubeWrapperBaseURL)
        }
        return .remote(url)
    }

    fileprivate static func start(_ plan: WebLoadPlan, in webView: WKWebView) {
        switch plan {
        case .file(let url, let readAccess): webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        case .remote(let url):               webView.load(URLRequest(url: url))
        case .html(let html, let base):      webView.loadHTMLString(html, baseURL: base)
        }
    }

    // MARK: lifecycle

    init(display: DisplayInfo, item: WallpaperItem, library: WallpaperLibrary, present: Bool = true) throws {
        guard let plan = Self.loadPlan(for: item, library: library) else { throw WallpaperSurfaceError.missingFile(item.name) }
        self.displayUUID = display.uuid
        self.plan = plan
        self.present = present
        if case .remote(let url) = item.source { youtubeEmbed = WallpaperURLClassifier.youtubeEmbedID(in: url) != nil; isRemote = true }
        else { youtubeEmbed = false; isRemote = false }
        let bounds = NSRect(origin: .zero, size: display.frame.size)
        window = DesktopWallpaperWindow(frame: display.frame)
        container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizingMask = [.width, .height]
        placeholder = NSView(frame: bounds)
        placeholder.wantsLayer = true
        placeholder.autoresizingMask = [.width, .height]
        placeholder.isHidden = true
        webView = WKWebView(frame: bounds, configuration: Self.webConfiguration())
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .black
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        container.addSubview(placeholder)
        container.addSubview(webView)
        window.contentView = container
        window.onVisibilityChange = { [weak self] visible in self?.onCoveredChange?(!visible) }
    }

    deinit { close() }

    /// Begin loading. The window appears when the page has finished loading.
    func start() {
        if isRemote { watchNetwork() }
        Self.start(plan, in: webView)
    }

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.failedAndWaitingForNetwork else { return }
                self.failedAndWaitingForNetwork = false
                self.committedMainURL = nil
                Self.start(self.plan, in: self.webView)
            }
        }
        monitor.start(queue: DispatchQueue(label: "anode.wallpaper.network"))
        pathMonitor = monitor
    }

    // MARK: playing and pausing

    func setPlaying(_ playing: Bool) {
        guard !closed else { return }
        desiredPlaying = playing
        guard loaded else { return }   // not up yet: the load's end applies the wish
        playing ? resume() : pause()
    }

    private func pause() {
        pauseToken += 1
        let token = pauseToken
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.evaluateJavaScript("window.dispatchEvent(new Event('anode-pause'))", completionHandler: nil)
        if youtubeEmbed { webView.evaluateJavaScript(WallpaperURLClassifier.youtubePlayerCommand(playing: false), completionHandler: nil) }
        guard webView.superview != nil else { return }
        // Keep the page's last picture on screen as a still, then take the live view out so WebKit stops running the page. If
        // no picture can be taken, the view stays in place (suspended) rather than leaving a black desktop.
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, !self.closed, token == self.pauseToken, !self.desiredPlaying else { return }
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.placeholder.layer?.contents = cg
            self.placeholder.layer?.contentsGravity = .resizeAspectFill
            self.placeholder.isHidden = false
            self.webView.removeFromSuperview()
        }
    }

    private func resume() {
        pauseToken += 1   // a snapshot still in flight must not take the view out again
        if webView.superview == nil { container.addSubview(webView) }
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        webView.evaluateJavaScript("window.dispatchEvent(new Event('anode-resume'))", completionHandler: nil)
        if youtubeEmbed { webView.evaluateJavaScript(WallpaperURLClassifier.youtubePlayerCommand(playing: true), completionHandler: nil) }
        // Uncover the live view only once it has had a moment to draw, so there is no flash of an old frame.
        let token = pauseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.closed, token == self.pauseToken else { return }
            self.placeholder.isHidden = true
            self.placeholder.layer?.contents = nil
        }
    }

    func apply(_ prefs: WallpaperPrefs) {
        guard !closed else { return }
        webView.evaluateJavaScript("window.__anodeSetSound && window.__anodeSetSound(\(prefs.muted ? "false" : "true"))", completionHandler: nil)
    }

    func updateFrame(_ frame: NSRect) {
        guard !closed else { return }
        window.setFrame(frame, display: false)
    }

    func close() {
        guard !closed else { return }
        closed = true
        pauseToken += 1
        pathMonitor?.cancel()
        pathMonitor = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window.dismiss()
        onCoveredChange = nil
        onFailure = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // A request to open a new window has no target frame: refuse it.
        guard let target = navigationAction.targetFrame else { decisionHandler(.cancel); return }
        decisionHandler(Self.navigationPolicy(isMainFrame: target.isMainFrame, committedMainURL: committedMainURL,
                                              target: navigationAction.request.url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Something the web view would download rather than show is not a wallpaper.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedMainURL = webView.url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        failedAndWaitingForNetwork = false
        let firstTime = !loaded
        loaded = true
        guard firstTime else { return }
        // A YouTube player needs a moment after the page itself is done before it has a picture.
        let delay: TimeInterval = youtubeEmbed ? 2.0 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed else { return }
            if self.present { self.window.present() }
            // Apply what the controller asked for while the page was loading; a paused page gets a moment to paint first.
            if self.desiredPlaying { self.resume() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.closed, !self.desiredPlaying else { return }
                self.pause()
            } }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        guard !closed else { return }
        let ns = error as NSError
        // Our own policy cancelling a navigation is not a failure of the page.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        failedAndWaitingForNetwork = isRemote
        onFailure?(ns.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        restarts += 1
        if restarts > 3 { onFailure?("The page keeps crashing."); return }
        committedMainURL = nil
        Self.start(plan, in: webView)
    }

    // MARK: WKUIDelegate: a page gets none of these

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) { completionHandler() }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }


    // MARK: snapshot (the real PageSnapshotter)

    /// A picture of what the page looks like once loaded, for the library's poster and thumbnail. Uses the same containment as
    /// the wallpaper itself. Gives up (throws) after 20 seconds.
    static func snapshot(_ url: URL, size: CGSize) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                PageSnapshotJob(url: url, size: size, continuation: cont).begin()
            }
        }
    }
}

/// One snapshot, kept alive by itself until it finishes.
private final class PageSnapshotJob: NSObject, WKNavigationDelegate {
    struct Failed: Error {}

    private let size: CGSize
    private var continuation: CheckedContinuation<CGImage, Error>?
    private let webView: WKWebView
    private let window: NSWindow
    private let url: URL
    private var selfRetain: PageSnapshotJob?

    init(url: URL, size: CGSize, continuation: CheckedContinuation<CGImage, Error>) {
        self.url = url
        self.size = size
        self.continuation = continuation
        let frame = NSRect(origin: .zero, size: size)
        // Never ordered onto a screen; a window only gives the page somewhere to lay out.
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView = WKWebView(frame: frame, configuration: WebWallpaperSurface.webConfiguration())
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func begin() {
        selfRetain = self
        WebWallpaperSurface.start(WebWallpaperSurface.loadPlan(forPage: url), in: webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(.failure(Failed())) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let animations and a player reach a first picture before taking it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.continuation != nil else { return }
            self.webView.takeSnapshot(with: nil) { image, error in
                if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { self.finish(.success(cg)) }
                else { self.finish(.failure(error ?? Failed())) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<CGImage, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        selfRetain = nil
        switch result {
        case .success(let image): cont.resume(returning: image)
        case .failure(let e):     cont.resume(throwing: e)
        }
    }
}
