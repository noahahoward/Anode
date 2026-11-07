import AppKit
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
    private let present: Bool
    let setterName: String
    /// Every script the surface runs is also passed here, for tests.
    var scriptSink: ((String) -> Void)?
    var loadTimeout: TimeInterval = 30
    private var loadTimer: DispatchWorkItem?
    private var lastPrefs: WallpaperPrefs?
    private var committedMainURL: URL?
    private var desiredPlaying = false
    private var loaded = false
    private var restarts = 0
    private var pauseToken = 0
    private var closed = false

    // MARK: pure pieces (tested)

    /// The name the page-facing sound switch has when none is given (tests). A real surface makes its own, so a page cannot
    /// know what to call.
    static let defaultSetterName = "__anodeSetSound"

    static func webConfiguration(setterName: String = WebWallpaperSurface.defaultSetterName) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        c.mediaTypesRequiringUserActionForPlayback = []
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        c.allowsAirPlayForMediaPlayback = false
        c.userContentController.addUserScript(mutingUserScript(setterName: setterName))
        return c
    }

    /// Forces every media element and audio context silent, in every frame, from the first moment of the page. The page can
    /// still run its own audio code; it just makes no sound. A global function named `setterName` lets sound through; it is
    /// not enumerable and its name is random per surface, and the hooks it relies on are installed non-configurable, so the
    /// page has no ordinary route back to a working `resume()` or an unwrapped `AudioContext`. (WebKit has no public "mute this
    /// page" switch, so this is containment of the obvious routes, not a guarantee.)
    static func mutingUserScript(setterName: String = WebWallpaperSurface.defaultSetterName) -> WKUserScript {
        WKUserScript(source: mutingScriptSource(setterName: setterName), injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    static func mutingScriptSource(setterName: String) -> String {
        """
        (function () {
          var NAME = '\(setterName)';
          if (window[NAME]) { return; }
          var allow = false;
          var proto = HTMLMediaElement.prototype;
          var mutedDesc = Object.getOwnPropertyDescriptor(proto, 'muted');
          function silence(m) { try { if (!allow && mutedDesc && mutedDesc.set) { mutedDesc.set.call(m, true); } } catch (e) {} }
          if (mutedDesc && mutedDesc.set) {
            Object.defineProperty(proto, 'muted', { configurable: false, enumerable: mutedDesc.enumerable,
              get: function () { return mutedDesc.get.call(this); },
              set: function (v) { mutedDesc.set.call(this, allow ? v : true); } });
          }
          var nativePlay = proto.play;
          Object.defineProperty(proto, 'play', { configurable: false, writable: false,
            value: function () { silence(this); return nativePlay.apply(this, arguments); } });
          function each(fn) { var els = document.querySelectorAll('video,audio'); for (var i = 0; i < els.length; i++) { fn(els[i]); } }
          document.addEventListener('play', function (e) { if (e.target && e.target.tagName) { silence(e.target); } }, true);
          document.addEventListener('volumechange', function (e) { if (e.target && e.target.tagName) { silence(e.target); } }, true);
          document.addEventListener('DOMContentLoaded', function () { each(silence); });
          var contexts = [];
          function quiet(c) { try { if (!allow) { c.suspend(); } } catch (e) {} }
          var seen = [];
          ['AudioContext', 'webkitAudioContext'].forEach(function (name) {
            var Native = window[name];
            if (!Native) { return; }
            var done = seen.filter(function (w) { return w.native === Native; })[0];
            var Wrapped = done ? done.wrapped : null;
            if (!Wrapped) {
              var realResume = Native.prototype.resume;
              Wrapped = function () { var c = new Native(...arguments); contexts.push(c); quiet(c); return c; };
              Wrapped.prototype = Native.prototype;
              try { Object.defineProperty(Native.prototype, 'resume', { configurable: false, writable: false,
                    value: function () { return allow ? realResume.apply(this, arguments) : Promise.resolve(); } }); } catch (e) {}
              try { Object.defineProperty(Native.prototype, 'constructor', { configurable: false, writable: false, value: Wrapped }); } catch (e) {}
              seen.push({ native: Native, wrapped: Wrapped });
            }
            try { Object.defineProperty(window, name, { configurable: true, writable: true, value: Wrapped }); } catch (e) {}
          });
          Object.defineProperty(window, NAME, { enumerable: false, configurable: false, writable: false, value: function (on) {
            allow = !!on;
            if (allow) {
              each(function (m) { try { mutedDesc.set.call(m, false); } catch (e) {} });
              contexts.forEach(function (c) { try { c.resume(); } catch (e) {} });
            } else {
              each(silence);
              contexts.forEach(quiet);
            }
          } });
        })();
        """
    }

    /// Whether a navigation may go ahead. Before the page's first load has committed everything in the main frame is allowed
    /// (the load itself, and any server redirect on the way); afterwards the main frame may only reload the same page (or
    /// change its #fragment). Sub-frames (an embedded player, an ad, a widget) are never restricted here.
    static func navigationPolicy(isMainFrame: Bool, committedMainURL: URL?, target: URL?) -> WKNavigationActionPolicy {
        guard isMainFrame else { return .allow }
        // Only secure or local addresses, even mid-redirect: an https page that bounces to http would otherwise run as the
        // wallpaper over a connection anyone on the network can rewrite.
        if let target, !isAllowedMainFrameScheme(target) { return .cancel }
        guard let committed = committedMainURL else { return .allow }
        guard let target else { return .cancel }
        return withoutFragment(target) == withoutFragment(committed) ? .allow : .cancel
    }

    static func isAllowedMainFrameScheme(_ url: URL) -> Bool {
        ["https", "file", "about"].contains(url.scheme?.lowercased() ?? "")
    }

    /// What to do with a response, and the failure to report if the page can't be shown. Something the web view would
    /// download rather than show is not a wallpaper, and the row must say so rather than claim it is playing.
    static func responsePolicy(canShowMIMEType: Bool, isMainFrame: Bool) -> (policy: WKNavigationResponsePolicy, failure: String?) {
        if canShowMIMEType { return (.allow, nil) }
        return (.cancel, isMainFrame ? "That address is a download, not a web page." : nil)
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
        if case .remote(let url) = item.source { youtubeEmbed = WallpaperURLClassifier.youtubeEmbedID(in: url) != nil }
        else { youtubeEmbed = false }
        setterName = "__a" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
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
        webView = WKWebView(frame: bounds, configuration: Self.webConfiguration(setterName: setterName))
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

    /// Begin loading. The window appears when the page has finished loading; if it never does, the surface reports a failure.
    func start() {
        Self.start(plan, in: webView)
        let timer = DispatchWorkItem { [weak self] in self?.loadTimedOut() }
        loadTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + loadTimeout, execute: timer)
    }

    /// The load has taken too long. Harmless if the page has finished or the surface is gone.
    func loadTimedOut() {
        guard !closed, !loaded else { return }
        onFailure?("The page took too long to load.")
    }

    private func runScript(_ js: String) {
        scriptSink?(js)
        webView.evaluateJavaScript(js, completionHandler: nil)
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
        runScript("window.dispatchEvent(new Event('anode-pause'))")
        if youtubeEmbed { runScript(WallpaperURLClassifier.youtubePlayerCommand(playing: false)) }
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
        runScript("window.dispatchEvent(new Event('anode-resume'))")
        if youtubeEmbed { runScript(WallpaperURLClassifier.youtubePlayerCommand(playing: true)) }
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
        lastPrefs = prefs
        sendSound(!prefs.muted)
    }

    private func sendSound(_ on: Bool) {
        runScript("window['\(setterName)'] && window['\(setterName)'](\(on ? "true" : "false"))")
    }

    /// The page was reloaded (a crashed content process comes back as a fresh page): tell it again what it was last told.
    func reassertAfterReload() {
        guard !closed else { return }
        if let lastPrefs { sendSound(!lastPrefs.muted) }
        desiredPlaying ? resume() : pause()
    }

    func updateFrame(_ frame: NSRect) {
        guard !closed else { return }
        window.setFrame(frame, display: false)
    }

    func close() {
        guard !closed else { return }
        closed = true
        pauseToken += 1
        loadTimer?.cancel()
        loadTimer = nil
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
        let policy = Self.navigationPolicy(isMainFrame: target.isMainFrame, committedMainURL: committedMainURL,
                                           target: navigationAction.request.url)
        decisionHandler(policy)
        // A first load that is turned away (a redirect to an insecure address) never finishes: say so.
        if policy == .cancel, target.isMainFrame, committedMainURL == nil, !loaded {
            onFailure?("That page redirected to an address that isn't https.")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Something the web view would download rather than show is not a wallpaper.
        let r = Self.responsePolicy(canShowMIMEType: navigationResponse.canShowMIMEType, isMainFrame: navigationResponse.isForMainFrame)
        decisionHandler(r.policy)
        if let failure = r.failure { onFailure?(failure) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedMainURL = webView.url
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        loadTimer?.cancel()
        let firstTime = !loaded
        loaded = true
        guard firstTime else { reassertAfterReload(); return }
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
        loadTimer?.cancel()
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
