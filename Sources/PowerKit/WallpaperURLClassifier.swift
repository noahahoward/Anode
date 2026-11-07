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
    public static func youtubeWrapperHTML(embedURL: URL) -> String {
        let src = embedURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        html,body{margin:0;height:100%;background:#000;overflow:hidden}
        iframe{position:fixed;left:50%;top:50%;border:0;transform:translate(-50%,-50%);
               width:max(100vw,177.78vh);height:max(56.25vw,100vh)}
        </style></head><body>
        <iframe id="p" src="\(src)" allow="autoplay; encrypted-media" referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
    }

    /// JavaScript, run in the wrapper page, that pauses or resumes the embedded player through the IFrame API.
    public static func youtubePlayerCommand(playing: Bool) -> String {
        let func_ = playing ? "playVideo" : "pauseVideo"
        return "document.getElementById('p').contentWindow.postMessage("
            + "JSON.stringify({event:'command',func:'\(func_)',args:[]}),'*');"
    }
}
