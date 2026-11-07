import Foundation

// ── What a pasted link is ───────────────────────────────────────────────────
//
// Decided from the link's text alone (scheme, host, extension): nothing here touches the network. https only: a plain http link
// can be rewritten in transit, and a wallpaper is a page or a file that Anode would then run or decode.

public enum LinkKind: Equatable {
    case directVideo
    case directImage
    case youtube(id: String)
    case webPage
    case unsupported(String)
}

public enum WallpaperURLClassifier {

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "m3u8"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tif", "tiff"]
    private static let youtubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com"]

    public static func classify(_ url: URL) -> LinkKind {
        guard let scheme = url.scheme?.lowercased() else { return .unsupported("That is not a web link") }
        guard scheme == "https" else {
            return .unsupported(scheme == "http" ? "Only https links work" : "Only https links work (not \(scheme):)")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .unsupported("That link has no address in it") }

        if let id = youtubeID(host: host, url: url) { return .youtube(id: id) }

        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .directVideo }
        if imageExtensions.contains(ext) { return .directImage }
        return .webPage
    }

    // MARK: YouTube

    static func isValidYouTubeID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func youtubeID(host: String, url: URL) -> String? {
        let comps = url.pathComponents.filter { $0 != "/" }
        if host == "youtu.be" {
            guard let first = comps.first, isValidYouTubeID(first) else { return nil }
            return first
        }
        guard youtubeHosts.contains(host) else { return nil }
        if comps.first == "embed", comps.count >= 2, isValidYouTubeID(comps[1]) { return comps[1] }
        if comps.first == "watch",
           let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           isValidYouTubeID(v) { return v }
        return nil
    }

    /// The page that identifies Anode to the player as the embedding site.
    public static let youtubeWrapperBaseURL = URL(string: "https://anode.app/")!

    /// The official embed player, set to autoplay, muted, loop (a one-video playlist), no controls, no captions, and with the
    /// IFrame API on so the page can pause it (a cross-origin frame cannot be paused any other way).
    public static func youtubeEmbedURL(id: String) -> URL {
        URL(string: "https://www.youtube.com/embed/\(id)?autoplay=1&mute=1&loop=1&playlist=\(id)&controls=0&enablejsapi=1"
            + "&cc_load_policy=0&playsinline=1&rel=0&origin=https://anode.app")!
    }

    /// Where YouTube keeps a video's still picture, largest first (not every video has the largest). Used for the picture a
    /// paused YouTube wallpaper shows: the player's own paused screen has the title, buttons and "More videos" drawn on it.
    public static func youtubeThumbnailURLs(id: String) -> [URL] {
        guard isValidYouTubeID(id) else { return [] }
        return ["maxresdefault.jpg", "hq720.jpg", "mqdefault.jpg"].compactMap { URL(string: "https://i.ytimg.com/vi/\(id)/\($0)") }
    }

    /// The id inside an embed URL made by `youtubeEmbedURL`, or nil for any other URL.
    public static func youtubeEmbedID(in url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "www.youtube.com" else { return nil }
        let comps = url.pathComponents.filter { $0 != "/" }
        guard comps.count == 2, comps[0] == "embed", isValidYouTubeID(comps[1]) else { return nil }
        return comps[1]
    }

    /// A page holding the embed in an iframe, to be loaded with `youtubeWrapperBaseURL` as its base. Loading the embed URL
    /// directly fails with "Video player configuration error 153" because the player wants a referring page. The iframe is
    /// sized to cover the window (the video fills the display rather than sitting in black bars).
    ///
    /// The player is `quality` device pixels tall (its CSS size is that divided by the display's pixel ratio), then scaled up to
    /// cover the window. Measured on this Mac: the player decodes exactly the resolution of its own size in device pixels
    /// (1920 css px wide at ratio 2 gives 2160p, 1280 gives 1440p, 960 gives 1080p, 640 gives 720p), and ignores
    /// `setPlaybackQuality` sent from outside its frame. `anodeSetQuality(n)` resizes it, without reloading, to change the choice.
    public static func youtubeWrapperHTML(embedURL: URL, quality: Int = 2160) -> String {
        let src = embedURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{position:fixed;left:50%;top:50%;border:0}
        </style></head><body>
        <iframe id="p" src="\(src)" allow="autoplay; encrypted-media" referrerpolicy="strict-origin-when-cross-origin"></iframe>
        <script>
        (function(){
          var q = \(quality), p = document.getElementById('p');
          function fit(){
            var dpr = window.devicePixelRatio || 1, h = q / dpr, w = h * 16 / 9;
            p.style.width = w + 'px'; p.style.height = h + 'px';
            var s = Math.max(innerWidth / w, innerHeight / h);
            p.style.transform = 'translate(-50%,-50%) scale(' + s + ')';
          }
          window.anodeSetQuality = function(n){ q = n; fit(); };
          window.addEventListener('resize', fit); fit();
        })();
        </script>
        </body></html>
        """
    }

    /// Script, run in the wrapper page, that changes the player's size to `height` device pixels tall.
    public static func youtubeQualityCommand(height: Int) -> String { "window.anodeSetQuality && window.anodeSetQuality(\(height));" }

    /// Runs inside every frame of a wallpaper page and does something only inside YouTube's own. Hides everything the player
    /// draws over the video (title, buttons, "More videos", the logo, the unmute prompt, captions) and makes the browser loop
    /// the video itself.
    ///
    /// The embed's controls are not in a stable place (its markup changed to a different set of classes between two checks), so
    /// this does not name them: it keeps the video and every ancestor of it, and hides every other element beside any of them,
    /// including ones the player adds later. Looping with the video's own `loop` means the player never reaches the end of its
    /// video, so it never reloads and never shows its screen at a restart (measured: with `loop=1&playlist=` it did, for seconds,
    /// at every restart of a short video).
    public static let youtubeChromeHidingScript = """
    (function(){
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname) || window.__anodeHide) return;
      window.__anodeHide = true;
      function sweep(){
        var v = document.querySelector('video'); if (!v) return;
        var n = v;
        while (n && n !== document.body && n.parentElement) {
          var kids = n.parentElement.children;
          for (var i = 0; i < kids.length; i++) {
            var k = kids[i], t = k.tagName;
            if (k !== n && t !== 'SCRIPT' && t !== 'STYLE' && t !== 'LINK' && k.style.display !== 'none') k.style.setProperty('display', 'none', 'important');
          }
          n = n.parentElement;
        }
        if (!v.loop) v.loop = true;
      }
      var pending = 0;
      function soon(){ if (pending) return; pending = setTimeout(function(){ pending = 0; sweep(); }, 40); }
      new MutationObserver(soon).observe(document.documentElement, {childList: true, subtree: true});
      setInterval(sweep, 250);
      sweep();
    })();
    """

    /// JavaScript, run in the wrapper page, that pauses or resumes the embedded player through the IFrame API.
    public static func youtubePlayerCommand(playing: Bool) -> String {
        let func_ = playing ? "playVideo" : "pauseVideo"
        return "document.getElementById('p').contentWindow.postMessage("
            + "JSON.stringify({event:'command',func:'\(func_)',args:[]}),'*');"
    }
}
