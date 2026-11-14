import Foundation

// ── The wallpaper library ───────────────────────────────────────────────────
//
// An index (`library.json`) plus the files it owns, all in one folder: `~/Library/Application Support/Anode/Wallpapers/`.
// Local files are COPIED in (on APFS a copy is a free clone), so a wallpaper keeps working when the original is moved or
// deleted. The library only ever deletes files it owns, and only through `remove`, the user's explicit act; nothing else in the
// app deletes anything here. Names stored in the index are relative to the folder, and one that would leave the folder is
// treated as missing rather than followed.

public enum WallpaperKind: String, Codable {
    case video, image, web
}

public enum WallpaperSource: Codable, Equatable {
    /// A file in the library folder (its relative name).
    case file(String)
    /// A web wallpaper: a folder in the library folder, and the page inside it to load (relative to that folder).
    case folder(directory: String, entry: String)
    /// A link that is shown, not copied.
    case remote(URL)
}

public struct WallpaperItem: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public let kind: WallpaperKind
    public let source: WallpaperSource
    public let posterFilename: String?
    public let thumbnailFilename: String?
    public let durationSeconds: Double?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let codec: String?
    public let hasAudio: Bool?
    public let hardwareDecodable: Bool?
    public let addedAt: Date

    public init(id: UUID = UUID(), name: String, kind: WallpaperKind, source: WallpaperSource, posterFilename: String?,
                thumbnailFilename: String?, durationSeconds: Double?, pixelWidth: Int?, pixelHeight: Int?, codec: String?,
                hasAudio: Bool?, hardwareDecodable: Bool?, addedAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.source = source
        self.posterFilename = posterFilename; self.thumbnailFilename = thumbnailFilename
        self.durationSeconds = durationSeconds; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.codec = codec; self.hasAudio = hasAudio; self.hardwareDecodable = hardwareDecodable; self.addedAt = addedAt
    }
}

public enum WallpaperLibraryError: Error, Equatable {
    case emptyName
    case unknownItem
    case writeFailed
}

public final class WallpaperLibrary {
    /// Posted (object: the library) after the list of items or any item's name changed.
    public static let didChange = Notification.Name("AnodeWallpaperLibraryDidChange")

    public static var defaultDirectory: URL {
        let base = AnodeFiles.applicationSupport
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Anode/Wallpapers", isDirectory: true)
    }

    /// The app's one library, so the controller and the Beta Features section see the same list.
    public static let shared = WallpaperLibrary(directory: WallpaperLibrary.defaultDirectory)

    public let directory: URL
    /// Readable from any thread: an import adds from its own thread while the UI reads on main.
    public var items: [WallpaperItem] { lock.lock(); defer { lock.unlock() }; return stored }
    private var stored: [WallpaperItem] = []
    private let lock = NSLock()

    private let fm: FileManager
    private var indexURL: URL { directory.appendingPathComponent("library.json") }

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fm = fileManager
        // A corrupt or unreadable index is an empty library; the files beside it are left exactly as they are.
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? Self.decoder.decode([WallpaperItem].self, from: data) {
            stored = decoded
        }
    }

    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }

    // MARK: changes

    public func add(_ item: WallpaperItem) throws {
        var next = items
        next.append(item)
        try save(next)
    }

    /// Remove the entry and the files it owns. A remote item owns only its poster and thumbnail.
    public func remove(id: UUID) throws {
        guard let item = item(id: id) else { return }
        var owned: [URL?] = [posterURL(item), thumbnailURL(item), stillURL(item)]
        switch item.source {
        case .file:                  owned.append(contentURL(item))
        case .folder:                owned.append(folderURL(item))
        case .remote:                break
        }
        // The index goes first: if a file then refuses to go, the worst case is a stray file, not an entry pointing at nothing.
        try save(items.filter { $0.id != id })
        for url in owned.compactMap({ $0 }) { try? fm.removeItem(at: url) }
    }

    public func rename(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WallpaperLibraryError.emptyName }
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw WallpaperLibraryError.unknownItem }
        var next = items
        next[index].name = trimmed
        try save(next)
    }

    private func save(_ next: [WallpaperItem]) throws {
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(next).write(to: indexURL, options: .atomic)
        } catch {
            throw WallpaperLibraryError.writeFailed
        }
        lock.lock(); stored = next; lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: lookups

    public func item(id: UUID) -> WallpaperItem? { items.first { $0.id == id } }

    /// A file inside the library folder, or nil if the name is empty or would leave the folder.
    private func owned(_ relative: String) -> URL? {
        guard !relative.isEmpty else { return nil }
        let url = directory.appendingPathComponent(relative).standardizedFileURL
        let root = directory.standardizedFileURL.path
        return url.path.hasPrefix(root + "/") ? url : nil
    }

    /// The file for `.file`, `<folder>/<entry>` for `.folder`, the link itself for `.remote`.
    public func contentURL(_ item: WallpaperItem) -> URL? {
        switch item.source {
        case .file(let name):                    return owned(name)
        case .folder(let dir, let entry):        return owned(dir + "/" + entry)
        case .remote(let url):                   return url
        }
    }

    /// The folder a web wallpaper lives in (the only place its page may read from); nil for anything else.
    public func folderURL(_ item: WallpaperItem) -> URL? {
        guard case .folder(let dir, _) = item.source else { return nil }
        return owned(dir)
    }

    public func posterURL(_ item: WallpaperItem) -> URL? { item.posterFilename.flatMap(owned) }
    public func thumbnailURL(_ item: WallpaperItem) -> URL? { item.thumbnailFilename.flatMap(owned) }

    /// Where a YouTube wallpaper keeps its clean still picture (it may not exist yet).
    public func stillURL(_ item: WallpaperItem) -> URL? { owned("\(item.id.uuidString)-still.jpg") }

    /// True when a local item's content is no longer on disk. A link is never missing (it may be unreachable, which is not this).
    public func isMissing(_ item: WallpaperItem) -> Bool {
        if case .remote = item.source { return false }
        guard let url = contentURL(item) else { return true }
        return !fm.fileExists(atPath: url.path)
    }
}
