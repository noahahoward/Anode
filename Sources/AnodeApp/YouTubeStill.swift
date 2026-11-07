import Foundation
import ImageIO
import PowerKit

/// The clean picture a YouTube wallpaper shows instead of the player's own screen.
///
/// Pausing an embedded YouTube player makes YouTube draw its paused screen over the video: the title and channel at the top
/// left, a pause button in the middle, "More videos" and the YouTube logo along the bottom. A snapshot of the page then
/// captures all of it, and it cannot be switched off from outside the player's frame. The video's own thumbnail has none of that,
/// so it is fetched once, kept beside the library entry, and put over the player whenever the player would show its own screen.
enum YouTubeStill {

    typealias Fetch = (URL) async throws -> Data

    /// YouTube answers a missing thumbnail with a small grey picture; anything narrower than this is that, not the video.
    static let minimumWidth = 300
    static let maximumBytes = 5 * 1024 * 1024

    /// Make sure `dest` holds a thumbnail of the video. True if it does (already, or now); false if none could be fetched.
    static func ensure(id: String, at dest: URL, fetch: Fetch = YouTubeStill.download) async -> Bool {
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        for url in WallpaperURLClassifier.youtubeThumbnailURLs(id: id) {
            guard let data = try? await fetch(url), isUsable(data) else { continue }
            do { try data.write(to: dest, options: .atomic); return true } catch { return false }
        }
        return false
    }

    /// The first usable thumbnail as a picture, for the library's preview (nil if none could be fetched).
    static func thumbnailImage(id: String, fetch: Fetch = YouTubeStill.download) async -> CGImage? {
        for url in WallpaperURLClassifier.youtubeThumbnailURLs(id: id) {
            guard let data = try? await fetch(url), isUsable(data), let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            return image
        }
        return nil
    }

    static func isUsable(_ data: Data) -> Bool {
        guard data.count <= maximumBytes, let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int else { return false }
        return width >= minimumWidth
    }

    /// The real fetch: https to YouTube's image host only, no cookies, a short timeout.
    static func download(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "i.ytimg.com" else { throw URLError(.badURL) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maximumBytes else { throw URLError(.badServerResponse) }
        return data
    }
}
