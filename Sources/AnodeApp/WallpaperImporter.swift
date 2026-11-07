import AVFoundation
import AppKit
import ImageIO
import PowerKit
import UniformTypeIdentifiers
import VideoToolbox

// ── Getting content into the wallpaper library ──────────────────────────────
//
// Every import follows the same rule: validate first, then copy, then make the poster and thumbnail, and if ANY step fails
// remove every file this import created and add no entry. A half-imported wallpaper (a copy with no entry, an entry with no
// poster) never survives an error.
//
// Nothing here shows a window or plays anything, and nothing touches the network: a link's download and a page's snapshot
// arrive as closures, so the real ones (URLSession, WKWebView) live elsewhere and tests inject fakes.

struct VideoProbe: Equatable {
    let durationSeconds: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let codec: String
    let hasAudio: Bool
    let hardwareDecodable: Bool
}

enum WallpaperImportError: Error, Equatable {
    case notPlayable, noVideoTrack, tooShort, copyFailed, notAnImage, noIndexHTML, tooLarge, notHTTPS
    case unsupportedLink(String)
    case downloadFailed

    /// What the library row or the alert says.
    var message: String {
        switch self {
        case .notPlayable:      return "That file can't be played."
        case .noVideoTrack:     return "That file has no video in it."
        case .tooShort:         return "That clip is shorter than half a second."
        case .copyFailed:       return "Couldn't copy it into the library."
        case .notAnImage:       return "That isn't an image Anode can read."
        case .noIndexHTML:      return "A web wallpaper folder needs an index.html at its top level."
        case .tooLarge:         return "That's too large (the limit is 500 MB and 5000 files for a folder, 2 GB for a download)."
        case .notHTTPS:         return "Only https links work."
        case .unsupportedLink(let why): return why
        case .downloadFailed:   return "The download failed."
        }
    }
}

/// Renders a page to an image. The real one is a WKWebView snapshot (`WebWallpaperSurface.snapshot`); tests pass a fake.
typealias PageSnapshotter = (URL, CGSize) async throws -> CGImage

struct ImportResult {
    let item: WallpaperItem
    let warnings: [String]
}

enum WallpaperImporter {

    static let minimumDuration = 0.5
    static let maximumDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumFolderBytes: Int64 = 500 * 1024 * 1024
    static let maximumFolderFiles = 5000
    static let thumbnailWidth = 320
    static let posterMaxPixels = 1920
    static let snapshotSize = CGSize(width: 1280, height: 800)

    private static var fm: FileManager { .default }

    // MARK: video

    static func probeVideo(_ url: URL) async throws -> VideoProbe {
        let asset = AVURLAsset(url: url)
        let playable: Bool, duration: CMTime, video: [AVAssetTrack], audio: [AVAssetTrack]
        do {
            playable = try await asset.load(.isPlayable)
            duration = try await asset.load(.duration)
            video = try await asset.loadTracks(withMediaType: .video)
            audio = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw WallpaperImportError.notPlayable
        }
        guard playable else { throw WallpaperImportError.notPlayable }
        guard let track = video.first else { throw WallpaperImportError.noVideoTrack }
        guard let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform),
              let formats = try? await track.load(.formatDescriptions), let format = formats.first else {
            throw WallpaperImportError.notPlayable
        }
        // A phone clip is stored sideways and rotated by its transform; the size that matters is the displayed one.
        let shown = natural.applying(transform)
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        return VideoProbe(durationSeconds: duration.isNumeric ? duration.seconds : 0,
                          pixelWidth: Int(abs(shown.width).rounded()), pixelHeight: Int(abs(shown.height).rounded()),
                          codec: fourCC(subtype), hasAudio: !audio.isEmpty,
                          hardwareDecodable: VTIsHardwareDecodeSupported(CMVideoCodecType(subtype)))
    }

    static func warnings(for probe: VideoProbe) -> [String] {
        var out: [String] = []
        if !probe.hardwareDecodable { out.append("This video uses software decoding, which costs more battery.") }
        if probe.pixelWidth > 7680 || probe.pixelHeight > 7680 { out.append("This video is larger than 8K and may play poorly.") }
        return out
    }

    /// Copy a video into the library (or, for a file Anode just downloaded, move it) and give it a poster and a thumbnail.
    static func importVideo(from url: URL, into library: WallpaperLibrary,
                            makePoster: (AVAsset, URL) async throws -> Void = WallpaperImporter.writePoster) async throws -> ImportResult {
        try await importVideo(from: url, into: library, moveSource: false, makePoster: makePoster, name: nil)
    }

    private static func importVideo(from url: URL, into library: WallpaperLibrary, moveSource: Bool,
                                    makePoster: (AVAsset, URL) async throws -> Void, name: String?) async throws -> ImportResult {
        let probe = try await probeVideo(url)
        guard probe.durationSeconds >= minimumDuration else { throw WallpaperImportError.tooShort }

        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let contentName = "\(id.uuidString).\(ext)", posterName = "\(id.uuidString)-poster.png", thumbName = "\(id.uuidString)-thumb.jpg"
        let dir = library.directory
        let created = [dir.appendingPathComponent(contentName), dir.appendingPathComponent(posterName), dir.appendingPathComponent(thumbName)]
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                if moveSource { try fm.moveItem(at: url, to: created[0]) } else { try fm.copyItem(at: url, to: created[0]) }
            } catch { throw WallpaperImportError.copyFailed }
            try await makePoster(AVURLAsset(url: created[0]), created[1])
            try writeThumbnail(from: created[1], to: created[2])
            let item = WallpaperItem(id: id, name: name ?? displayName(of: url), kind: .video, source: .file(contentName),
                                     posterFilename: posterName, thumbnailFilename: thumbName, durationSeconds: probe.durationSeconds,
                                     pixelWidth: probe.pixelWidth, pixelHeight: probe.pixelHeight, codec: probe.codec,
                                     hasAudio: probe.hasAudio, hardwareDecodable: probe.hardwareDecodable)
            try library.add(item)
            return ImportResult(item: item, warnings: warnings(for: probe))
        } catch {
            for f in created { try? fm.removeItem(at: f) }
            throw error
        }
    }

    /// A still from the clip at one second (or its midpoint if shorter), at most `posterMaxPixels` on a side, as a PNG.
    static func writePoster(_ asset: AVAsset, to url: URL) async throws {
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: posterMaxPixels, height: posterMaxPixels)
        let at = CMTime(seconds: duration > 1 ? 1 : duration / 2, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: at)
        try writePNG(image, to: url)
    }

    // MARK: image

    static func importImage(from url: URL, into library: WallpaperLibrary) async throws -> ImportResult {
        try importImage(from: url, into: library, moveSource: false, name: nil)
    }

    private static func importImage(from url: URL, into library: WallpaperLibrary, moveSource: Bool, name: String?) throws -> ImportResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw WallpaperImportError.notAnImage
        }
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        let contentName = "\(id.uuidString).\(ext)", posterName = "\(id.uuidString)-poster.png", thumbName = "\(id.uuidString)-thumb.jpg"
        let dir = library.directory
        let created = [dir.appendingPathComponent(contentName), dir.appendingPathComponent(posterName), dir.appendingPathComponent(thumbName)]
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                if moveSource { try fm.moveItem(at: url, to: created[0]) } else { try fm.copyItem(at: url, to: created[0]) }
            } catch { throw WallpaperImportError.copyFailed }
            try writeDownsampled(from: created[0], maxPixels: posterMaxPixels, to: created[1], type: .png)
            try writeThumbnail(from: created[1], to: created[2])
            let item = WallpaperItem(id: id, name: name ?? displayName(of: url), kind: .image, source: .file(contentName),
                                     posterFilename: posterName, thumbnailFilename: thumbName, durationSeconds: nil,
                                     pixelWidth: w, pixelHeight: h, codec: nil, hasAudio: nil, hardwareDecodable: nil)
            try library.add(item)
            return ImportResult(item: item, warnings: [])
        } catch {
            for f in created { try? fm.removeItem(at: f) }
            throw error
        }
    }

    // MARK: animated images (GIF, animated PNG, animated WebP)

    /// An animated picture is turned into a looping H.264 clip when it is added, so it plays through the same shared player,
    /// the same pause rules and the same hardware decoder as any video. Drawing a GIF frame by frame on a timer would cost
    /// far more battery and need its own pause logic.
    static let animatedTypes: [UTType] = [.gif, .png, .webP]
    static let maximumAnimatedSide = 3840
    static let defaultFrameDelay = 0.1
    static let minimumAnimatedDuration = 1.0
    private static let frameTimescale: Int32 = 6000

    /// How many animation frames the file has: its frame count for a GIF, PNG or WebP, 1 for any other picture (or a still
    /// one), 0 if it is not an image.
    static func animatedFrameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return 0 }
        guard let id = CGImageSourceGetType(src) as String?, let type = UTType(id),
              animatedTypes.contains(where: { type.conforms(to: $0) }) else { return 1 }
        return count
    }

    /// How long a frame is shown. A missing, zero or one-hundredth-of-a-second delay becomes 0.1 s, which is what browsers do
    /// with the many GIFs that were written with no delay at all.
    static func frameDelay(_ src: CGImageSource, at index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] else { return defaultFrameDelay }
        let kinds: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)]
        for (dictionary, unclamped, clamped) in kinds {
            guard let d = props[dictionary] as? [CFString: Any] else { continue }
            if let v = (d[unclamped] as? Double) ?? (d[clamped] as? Double) { return v > 0.011 ? v : defaultFrameDelay }
        }
        return defaultFrameDelay
    }

    static func importAnimatedImage(from url: URL, into library: WallpaperLibrary) async throws -> ImportResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw WallpaperImportError.notAnImage
        }
        let temp = library.directory.appendingPathComponent("convert-\(UUID().uuidString).mov")
        do {
            try fm.createDirectory(at: library.directory, withIntermediateDirectories: true)
            try await writeClip(from: src, to: temp)
            return try await importVideo(from: temp, into: library, moveSource: true, makePoster: writePoster, name: displayName(of: url))
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// The frames of `src` as an H.264 QuickTime clip with each frame's own duration, repeated until it lasts at least
    /// `minimumAnimatedDuration` (a loop of a very short GIF looks the same, and a clip under half a second is refused).
    private static func writeClip(from src: CGImageSource, to url: URL) async throws {
        let count = CGImageSourceGetCount(src)
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let sourceW = props[kCGImagePropertyPixelWidth] as? Int, let sourceH = props[kCGImagePropertyPixelHeight] as? Int,
              sourceW > 0, sourceH > 0 else { throw WallpaperImportError.notAnImage }
        let shrink = min(1, Double(maximumAnimatedSide) / Double(max(sourceW, sourceH)))
        let width = max(2, Int(Double(sourceW) * shrink) / 2 * 2), height = max(2, Int(Double(sourceH) * shrink) / 2 * 2)
        let delays = (0..<count).map { frameDelay(src, at: $0) }
        let once = delays.reduce(0, +)
        let passes = once >= minimumAnimatedDuration ? 1 : Int((minimumAnimatedDuration / once).rounded(.up))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.85]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw WallpaperImportError.copyFailed }
        writer.add(input)
        guard writer.startWriting() else { throw WallpaperImportError.copyFailed }
        writer.startSession(atSourceTime: .zero)

        var elapsed = 0.0
        func time(_ seconds: Double) -> CMTime { CMTime(value: CMTimeValue((seconds * Double(frameTimescale)).rounded()), timescale: frameTimescale) }
        for _ in 0..<passes {
            for i in 0..<count {
                guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw WallpaperImportError.notAnImage }
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                guard let pool = adaptor.pixelBufferPool else { throw WallpaperImportError.copyFailed }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let pixels = buffer else { throw WallpaperImportError.copyFailed }
                CVPixelBufferLockBaseAddress(pixels, [])
                if let base = CVPixelBufferGetBaseAddress(pixels),
                   let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    // Transparent GIFs sit on black, the colour a wallpaper window is behind them anyway.
                    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    ctx.interpolationQuality = .high
                    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                guard adaptor.append(pixels, withPresentationTime: time(elapsed)) else { throw WallpaperImportError.copyFailed }
                elapsed += delays[i]
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time(elapsed))
        await writer.finishWriting()
        guard writer.status == .completed else { throw WallpaperImportError.copyFailed }
    }

    // MARK: web

    static func importHTMLFile(from url: URL, into library: WallpaperLibrary, snapshot: PageSnapshotter) async throws -> ImportResult {
        let id = UUID()
        let folderName = "web-\(id.uuidString)"
        let folder = library.directory.appendingPathComponent(folderName)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do { try fm.copyItem(at: url, to: folder.appendingPathComponent("index.html")) } catch { throw WallpaperImportError.copyFailed }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return try await finishWebItem(id: id, name: displayName(of: url), source: .folder(directory: folderName, entry: "index.html"),
                                       pageURL: folder.appendingPathComponent("index.html"), createdFolder: folder, library: library,
                                       snapshot: snapshot,
                                       extraWarnings: ["Only this one file was copied, so the page's other files (images, scripts, styles) "
                                                       + "won't be found. To keep them, add the page's whole folder instead."])
    }

    static func importWebFolder(from url: URL, into library: WallpaperLibrary, snapshot: PageSnapshotter,
                                maxBytes: Int64 = WallpaperImporter.maximumFolderBytes,
                                maxFiles: Int = WallpaperImporter.maximumFolderFiles) async throws -> ImportResult {
        // Plan the whole copy before making anything: which files, how big, and whether it has a root index.html.
        guard let walker = fm.enumerator(atPath: url.path) else { throw WallpaperImportError.copyFailed }
        var files: [String] = []
        var total: Int64 = 0
        for case let rel as String in walker {
            let attrs = try? fm.attributesOfItem(atPath: url.appendingPathComponent(rel).path)
            // A symbolic link is never followed or copied: it could point at anything the user can read.
            guard let type = attrs?[.type] as? FileAttributeType, type == .typeRegular else { continue }
            if rel == ".DS_Store" || rel.hasSuffix("/.DS_Store") { continue }
            files.append(rel)
            total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if files.count > maxFiles || total > maxBytes { throw WallpaperImportError.tooLarge }
        }
        guard files.contains("index.html") else { throw WallpaperImportError.noIndexHTML }

        let id = UUID()
        let folderName = "web-\(id.uuidString)"
        let folder = library.directory.appendingPathComponent(folderName)
        do {
            for rel in files {
                let dest = folder.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url.appendingPathComponent(rel), to: dest)
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw WallpaperImportError.copyFailed
        }
        return try await finishWebItem(id: id, name: displayName(of: url), source: .folder(directory: folderName, entry: "index.html"),
                                       pageURL: folder.appendingPathComponent("index.html"), createdFolder: folder, library: library,
                                       snapshot: snapshot, extraWarnings: [])
    }

    /// Snapshot the page for a poster and thumbnail (a failure only costs the preview), then add the entry.
    private static func finishWebItem(id: UUID, name: String, source: WallpaperSource, pageURL: URL, createdFolder: URL?,
                                      library: WallpaperLibrary, snapshot: PageSnapshotter, extraWarnings: [String]) async throws -> ImportResult {
        var warnings = extraWarnings
        let dir = library.directory
        let posterName = "\(id.uuidString)-poster.png", thumbName = "\(id.uuidString)-thumb.jpg"
        var poster: String?, thumb: String?
        var created: [URL] = []
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let image = try? await snapshot(pageURL, snapshotSize) {
                let p = dir.appendingPathComponent(posterName), t = dir.appendingPathComponent(thumbName)
                created += [p, t]
                try writePNG(image, to: p)
                try writeThumbnail(from: p, to: t)
                poster = posterName; thumb = thumbName
            } else {
                warnings.append("Couldn't make a preview picture of this page (it may not have loaded).")
            }
            let item = WallpaperItem(id: id, name: name, kind: .web, source: source, posterFilename: poster, thumbnailFilename: thumb,
                                     durationSeconds: nil, pixelWidth: nil, pixelHeight: nil, codec: nil, hasAudio: nil, hardwareDecodable: nil)
            try library.add(item)
            return ImportResult(item: item, warnings: warnings)
        } catch {
            for f in created { try? fm.removeItem(at: f) }
            if let createdFolder { try? fm.removeItem(at: createdFolder) }
            throw error
        }
    }

    // MARK: links

    static func addLink(_ url: URL, into library: WallpaperLibrary, downloadCopy: Bool,
                        download: (URL, URL, Int64) async throws -> Void, snapshot: PageSnapshotter) async throws -> ImportResult {
        switch WallpaperURLClassifier.classify(url) {
        case .unsupported(let why):
            if url.scheme?.lowercased() == "http" { throw WallpaperImportError.notHTTPS }
            throw WallpaperImportError.unsupportedLink(why)

        case .youtube(let id):
            let embed = WallpaperURLClassifier.youtubeEmbedURL(id: id)
            return try await finishWebItem(id: UUID(), name: "YouTube video", source: .remote(embed), pageURL: embed, createdFolder: nil,
                                           library: library, snapshot: snapshot, extraWarnings: [])

        case .webPage:
            return try await finishWebItem(id: UUID(), name: url.host ?? "Web page", source: .remote(url), pageURL: url, createdFolder: nil,
                                           library: library, snapshot: snapshot, extraWarnings: [])

        case .directVideo where !downloadCopy:
            let item = WallpaperItem(name: displayName(of: url), kind: .video, source: .remote(url), posterFilename: nil,
                                     thumbnailFilename: nil, durationSeconds: nil, pixelWidth: nil, pixelHeight: nil, codec: nil,
                                     hasAudio: nil, hardwareDecodable: nil)
            try library.add(item)
            return ImportResult(item: item, warnings: ["Streamed, not saved: it needs the network every time it plays."])

        case .directVideo:
            let temp = try await downloadToTemp(url, library: library, download: download)
            do { return try await importVideo(from: temp, into: library, moveSource: true, makePoster: writePoster, name: displayName(of: url)) }
            catch { try? fm.removeItem(at: temp); throw error }

        case .directImage:
            let temp = try await downloadToTemp(url, library: library, download: download)
            do { return try importImage(from: temp, into: library, moveSource: true, name: displayName(of: url)) }
            catch { try? fm.removeItem(at: temp); throw error }
        }
    }

    /// Download into a uniquely named file inside the library folder (same volume, so adopting it is a rename). Anything
    /// the download left behind is removed if it fails.
    private static func downloadToTemp(_ url: URL, library: WallpaperLibrary,
                                       download: (URL, URL, Int64) async throws -> Void) async throws -> URL {
        try fm.createDirectory(at: library.directory, withIntermediateDirectories: true)
        let ext = url.pathExtension.lowercased()
        let temp = library.directory.appendingPathComponent("download-\(UUID().uuidString).\(ext)")
        do {
            try await download(url, temp, maximumDownloadBytes)
            return temp
        } catch {
            try? fm.removeItem(at: temp)
            if let e = error as? WallpaperImportError { throw e }
            if error is CancellationError { throw error }
            throw WallpaperImportError.downloadFailed
        }
    }

    // MARK: files

    static func displayName(of url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? (url.host ?? "Wallpaper") : base
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WallpaperImportError.copyFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw WallpaperImportError.copyFailed }
    }

    static func writeThumbnail(from imageURL: URL, to url: URL) throws {
        try writeDownsampled(from: imageURL, maxPixels: thumbnailWidth, to: url, type: .jpeg)
    }

    /// Read `source` no larger than `maxPixels` on its longer side (never decoding the full picture) and write it as `type`.
    static func writeDownsampled(from source: URL, maxPixels: Int, to url: URL, type: UTType) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw WallpaperImportError.notAnImage }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw WallpaperImportError.notAnImage }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw WallpaperImportError.copyFailed
        }
        CGImageDestinationAddImage(dest, image, type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary : nil)
        guard CGImageDestinationFinalize(dest) else { throw WallpaperImportError.copyFailed }
    }
}
