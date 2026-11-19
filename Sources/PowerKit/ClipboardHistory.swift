import CryptoKit
import Foundation
import ImageIO

// ── Clipboard History: what is kept, and what never is ──────────────────────
//
// The pure part of the feature: what a copy is made of, which copies are never recorded, how one becomes an entry, the store
// that keeps the entries on disk, and the search over them. Nothing here touches the pasteboard, a window or a timer: the app
// reads the pasteboard and hands what it found in as a `ClipboardSnapshot`, so every rule below can be tested with no
// clipboard at all (and a test must never read or write the person's real one).
//
// PRIVACY comes first. A history of everything copied will hold passwords, tokens and private messages unless it is built not
// to, so the rules that keep them out are here, in one place, and the store applies them itself as well as the watcher: an
// entry that carries a marker for "do not record this" is dropped whoever calls `add`.

/// What an entry is, for its icon and the way it is shown.
public enum ClipboardKind: String, Codable, CaseIterable {
    case text, link, image, file

    public var title: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

/// The pasteboard type strings the feature reads, in one place.
public enum ClipboardTypes {
    public static let plainText = ["public.utf8-plain-text", "NSStringPboardType", "public.plain-text", "public.text"]
    public static let fileURL = "public.file-url"
    public static let url = "public.url"
    public static let images = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
    public static let richText = ["public.rtf", "public.html", "com.apple.flat-rtfd"]
    /// What survives when an entry is too big to keep in full: enough to paste it again.
    public static let essential: Set<String> = Set(plainText + [fileURL, url] + images + richText)

    /// The marker types (nspasteboard.org) are never stored: they say how an app wants its copy treated, and an entry kept for
    /// good must not carry one.
    public static func isMarker(_ type: String) -> Bool { type.hasPrefix("org.nspasteboard.") }

    /// A form of Anode's own that goes on every entry it puts back on the pasteboard to be pasted. Whatever the change counter does
    /// afterwards, a pasteboard that carries it holds Anode's own paste, which is not a new copy: it is never recorded again, and so
    /// never under another app's name (or this one's).
    public static let ownWrite = "dev.anode.clipboard-history.pasted"
}

/// One form of one pasteboard item, as read.
public struct ClipboardRepresentation: Equatable {
    public let item: Int
    public let type: String
    public let data: Data

    public init(item: Int, type: String, data: Data) {
        self.item = item
        self.type = type
        self.data = data
    }
}

/// What a copy was, as the app read it: every form of every item, the app that made it, and when.
public struct ClipboardSnapshot: Equatable {
    public var representations: [ClipboardRepresentation]
    /// The app that was in front when the copy was noticed: what the system says, and the one the rules about apps trust.
    public var sourceBundleID: String?
    /// The app the copy says it came from (`org.nspasteboard.source`). It is only what the copying app says of itself, so it can name
    /// any app: it is never trusted in place of `sourceBundleID`, only checked as well and used to label the entry.
    public var declaredSourceBundleID: String?
    /// The name to show: the declared app's when there is one, else the app in front's.
    public var sourceName: String?
    public var date: Date

    public init(representations: [ClipboardRepresentation], sourceBundleID: String? = nil, declaredSourceBundleID: String? = nil,
                sourceName: String? = nil, date: Date = Date()) {
        self.representations = representations
        self.sourceBundleID = sourceBundleID
        self.declaredSourceBundleID = declaredSourceBundleID
        self.sourceName = sourceName
        self.date = date
    }

    /// The app to show the entry as coming from.
    public var displayBundleID: String? { declaredSourceBundleID ?? sourceBundleID }

    /// The type strings, each once, in the order they came.
    public var types: [String] {
        var seen = Set<String>()
        return representations.map(\.type).filter { seen.insert($0).inserted }
    }
}

// ── What is never recorded ──────────────────────────────────────────────────

public enum ClipboardPrivacy {

    /// Markers an app puts on a copy to say it is not for a history, with the word the log uses. From nspasteboard.org, which
    /// clipboard managers honour: concealed (passwords), transient (restored a moment later), auto-generated (not a Copy the
    /// person made), and the markers of text expanders and 1Password that mean the same. `com.apple.is-remote-clipboard` is
    /// Universal Clipboard: a copy from another device, which is fetched only when it is pasted.
    public static let markers: [String: String] = [
        "org.nspasteboard.ConcealedType": "concealed",
        "org.nspasteboard.TransientType": "transient",
        "org.nspasteboard.AutoGeneratedType": "auto-generated",
        "de.petermaurer.TransientPasteboardType": "transient",
        "com.typeit4me.clipping": "transient",
        "Pasteboard generator type": "transient",
        "com.agilebits.onepassword": "concealed",
        "com.apple.is-remote-clipboard": "from another device",
    ]

    /// Password managers: whatever they copy is never recorded, whether or not they remember to mark it. The person's own
    /// list of apps to ignore is added to these and cannot take any away.
    public static let passwordManagers: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx", "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "in.sinew.Enpass-Desktop", "com.nordsec.nordpass", "me.proton.pass.electron",
    ]

    /// Fragments of a bundle id that name a password manager the list above does not know by its exact id.
    private static let managerFragments = ["1password", "bitwarden", "keepass", "lastpass", "dashlane", "enpass", "nordpass"]

    public static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let id = bundleID, !id.isEmpty else { return false }
        if passwordManagers.contains(id) { return true }
        let lower = id.lowercased()
        return managerFragments.contains { lower.contains($0) }
    }

    /// Why a copy must not be recorded, in a word for the log; nil when it may be. Read before any data is, from the type
    /// strings alone.
    /// Both the app in front and the app the copy declares are judged: a copy that names another app as its source cannot get past
    /// the list by it, and a password manager that names itself is refused whatever was in front.
    public static func skipReason(types: [String], sourceBundleID: String?, ignoredApps: Set<String>,
                                  declaredSourceBundleID: String? = nil) -> String? {
        for t in types { if let why = markers[t] { return why } }
        for id in [sourceBundleID, declaredSourceBundleID] {
            if isPasswordManager(id) { return "password manager" }
            if let id, ignoredApps.contains(id) { return "ignored app" }
        }
        return nil
    }
}

// ── The entry ───────────────────────────────────────────────────────────────

/// One stored form of an entry: a file in the entry's own folder.
public struct ClipboardPart: Codable, Equatable {
    public let item: Int
    public let type: String
    public let file: String
    public let size: Int

    public init(item: Int, type: String, file: String, size: Int) {
        self.item = item
        self.type = type
        self.file = file
        self.size = size
    }
}

public struct ClipboardEntry: Codable, Equatable, Identifiable {
    public let id: UUID
    public var kind: ClipboardKind
    /// What a search looks through: the text, the link, the file paths. The start of it only: the whole copy is in the parts.
    public var text: String
    /// What the row shows: the first line, or the file names.
    public var preview: String
    /// A second line for the row: "1200 × 800", "3 files", "12 lines".
    public var detail: String?
    public var parts: [ClipboardPart]
    /// When it was last copied (or pasted from here): the order of the list.
    public var date: Date
    public var pinned: Bool
    public var sourceBundleID: String?
    public var sourceName: String?
    public var byteSize: Int
    public var fingerprint: String

    public static let searchableCharacters = 4000
    public static let previewCharacters = 200
}

// ── Making an entry of a copy ───────────────────────────────────────────────

enum ClipboardBuilder {

    struct Built {
        var entry: ClipboardEntry
        /// What goes to disk, in the order of `entry.parts`.
        var kept: [ClipboardRepresentation]
    }

    enum Outcome {
        case built(Built)
        case skipped(String)
    }

    static func build(_ snapshot: ClipboardSnapshot, id: UUID, maxEntryBytes: Int, keepImages: Bool) -> Outcome {
        let reps = snapshot.representations
        guard !reps.isEmpty else { return .skipped("empty") }

        // What it is, and what to say of it.
        let paths = reps.filter { $0.type == ClipboardTypes.fileURL }.compactMap { path(of: $0.data) }
        let plain = reps.first { ClipboardTypes.plainText.contains($0.type) }.flatMap { String(data: $0.data, encoding: .utf8) }
        let urlText = reps.first { $0.type == ClipboardTypes.url }.flatMap { String(data: $0.data, encoding: .utf8) }
        let image = reps.first { ClipboardTypes.images.contains($0.type) }

        let kind: ClipboardKind
        var text = ""
        var preview = ""
        var detail: String?
        var identity = Data()

        if !paths.isEmpty {
            kind = .file
            text = paths.joined(separator: "\n")
            preview = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            detail = paths.count == 1 ? "File" : "\(paths.count) files"
            identity = Data(text.utf8)
        } else if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            kind = isLink(trimmed) ? .link : .text
            text = plain
            preview = firstLine(of: plain)
            let lines = plain.trimmingCharacters(in: .newlines).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            if kind == .text, lines > 1 { detail = "\(lines) lines" }
            identity = Data(plain.utf8)
        } else if let urlText, !urlText.isEmpty {
            kind = .link
            text = urlText
            preview = urlText
            identity = Data(urlText.utf8)
        } else if let image {
            guard keepImages else { return .skipped("images are off") }
            kind = .image
            text = "Image"
            preview = "Image"
            if let size = imageSize(image.data) { detail = "\(size.width) × \(size.height)" }
            identity = image.data
        } else if reps.contains(where: { ClipboardTypes.richText.contains($0.type) }) {
            kind = .text
            text = ""
            preview = "Formatted text"
            identity = reps.first { ClipboardTypes.richText.contains($0.type) }?.data ?? Data()
        } else {
            return .skipped("nothing to keep")
        }

        // With images off, a copy that is text and a picture keeps the text and not the picture's bytes.
        let usable = keepImages ? reps : reps.filter { !ClipboardTypes.images.contains($0.type) }
        guard let kept = choose(usable, maxBytes: maxEntryBytes) else { return .skipped("too large") }
        var parts: [ClipboardPart] = []
        for (n, rep) in kept.enumerated() {
            parts.append(ClipboardPart(item: rep.item, type: rep.type, file: "\(rep.item)-\(n)", size: rep.data.count))
        }
        var hash = SHA256()
        hash.update(data: Data(kind.rawValue.utf8))
        hash.update(data: identity)
        let fingerprint = hash.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()

        let entry = ClipboardEntry(
            id: id, kind: kind, text: String(text.prefix(ClipboardEntry.searchableCharacters)),
            preview: String(preview.prefix(ClipboardEntry.previewCharacters)), detail: detail, parts: parts, date: snapshot.date,
            pinned: false, sourceBundleID: snapshot.displayBundleID, sourceName: snapshot.sourceName,
            byteSize: kept.reduce(0) { $0 + $1.data.count }, fingerprint: fingerprint)
        return .built(Built(entry: entry, kept: kept))
    }

    /// The forms to keep: all of them (less the markers), or when that is over `maxBytes`, only what is enough to paste the
    /// copy again, or only its text. nil when even that does not fit.
    static func choose(_ reps: [ClipboardRepresentation], maxBytes: Int) -> [ClipboardRepresentation]? {
        func size(_ r: [ClipboardRepresentation]) -> Int { r.reduce(0) { $0 + $1.data.count } }
        let clean = reps.filter { !ClipboardTypes.isMarker($0.type) }
        if !clean.isEmpty, size(clean) <= maxBytes { return clean }
        let essential = clean.filter { ClipboardTypes.essential.contains($0.type) }
        if !essential.isEmpty, size(essential) <= maxBytes { return essential }
        let words = clean.filter { ClipboardTypes.plainText.contains($0.type) || $0.type == ClipboardTypes.url || $0.type == ClipboardTypes.fileURL }
        if !words.isEmpty, size(words) <= maxBytes { return words }
        return nil
    }

    static func path(of data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), let url = URL(string: s),
              url.isFileURL else { return nil }
        return url.path
    }

    /// One line, no longer than a row: the first that has anything in it.
    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// A single token that is a web address or another URL with a scheme: a link, not prose that has one in it.
    static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), text.count <= 2048, let url = URL(string: text), let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https", "ftp", "mailto"].contains(scheme) && (url.host?.isEmpty == false || scheme == "mailto")
    }

    static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

// ── The store ───────────────────────────────────────────────────────────────

/// The entries, newest first, kept in a folder only this account can read. Used on the main thread only.
///
/// On disk: `index.json` (the entries, without their contents) and `blobs/<id>/<item>-<n>` (each stored form of each entry).
/// The folder is 0700 and every file 0600; an index that cannot be read is started again empty, and a blob folder no entry
/// owns (a crash between the two writes) is removed at the next launch.
public final class ClipboardStore {

    public static let folderName = "clipboard-history"

    public struct Limits: Equatable {
        public var maxEntries: Int
        public var maxEntryBytes: Int
        public var maxTotalBytes: Int
        /// How long an entry is kept, in seconds; nil is for ever. Pinned entries are kept whatever this says.
        public var maxAge: TimeInterval?

        public init(maxEntries: Int, maxEntryBytes: Int, maxTotalBytes: Int, maxAge: TimeInterval?) {
            self.maxEntries = maxEntries
            self.maxEntryBytes = maxEntryBytes
            self.maxTotalBytes = maxTotalBytes
            self.maxAge = maxAge
        }
    }

    public enum AddResult: Equatable {
        case added(UUID)
        /// The same copy was already there: it moved to the top.
        case moved(UUID)
        case skipped(String)
    }

    /// What the person asked to leave out, handed to `add` so the store can refuse it itself.
    public struct Policy: Equatable {
        public var ignoredApps: Set<String>
        public var keepImages: Bool

        public init(ignoredApps: Set<String> = [], keepImages: Bool = true) {
            self.ignoredApps = ignoredApps
            self.keepImages = keepImages
        }
    }

    public private(set) var entries: [ClipboardEntry] = []
    /// Why the index was started again empty, when it was.
    public private(set) var loadProblem: String?
    public var limits: Limits { didSet { if limits != oldValue { prune() } } }

    private let directory: URL
    private let now: () -> Date
    private let fm = FileManager.default

    private struct Index: Codable {
        var version = 1
        var entries: [ClipboardEntry]
    }

    public init(directory: URL, limits: Limits, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.limits = limits
        self.now = now
        load()
        prune()
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var blobsURL: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private func blobFolder(_ id: UUID) -> URL { blobsURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    public var totalBytes: Int { entries.reduce(0) { $0 + $1.byteSize } }

    // ── Adding ──────────────────────────────────────────────────────────────

    @discardableResult
    public func add(_ snapshot: ClipboardSnapshot, policy: Policy = Policy()) -> AddResult {
        // The rules again, whoever the caller is: a copy that must not be recorded is not, whatever else was checked.
        if let why = ClipboardPrivacy.skipReason(types: snapshot.types, sourceBundleID: snapshot.sourceBundleID,
                                                  ignoredApps: policy.ignoredApps, declaredSourceBundleID: snapshot.declaredSourceBundleID) {
            return .skipped(why)
        }
        let id = UUID()
        switch ClipboardBuilder.build(snapshot, id: id, maxEntryBytes: limits.maxEntryBytes, keepImages: policy.keepImages) {
        case .skipped(let why):
            return .skipped(why)
        case .built(let built):
            if let at = entries.firstIndex(where: { $0.fingerprint == built.entry.fingerprint }) {
                var same = entries.remove(at: at)
                same.date = snapshot.date
                entries.insert(same, at: 0)
                save()
                return .moved(same.id)
            }
            guard write(built) else { return .skipped("could not be saved") }
            entries.insert(built.entry, at: 0)
            prune()
            save()
            return entries.contains { $0.id == id } ? .added(id) : .skipped("older than the limits")
        }
    }

    // ── Changing ────────────────────────────────────────────────────────────

    public func entry(_ id: UUID) -> ClipboardEntry? { entries.first { $0.id == id } }

    /// The stored forms of an entry, read back from disk, in the order they were kept; nil when none can be read.
    public func payload(for id: UUID) -> [ClipboardRepresentation]? {
        guard let entry = entry(id) else { return nil }
        let folder = blobFolder(id)
        let reps: [ClipboardRepresentation] = entry.parts.compactMap { part in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(part.file)) else { return nil }
            return ClipboardRepresentation(item: part.item, type: part.type, data: data)
        }
        return reps.isEmpty ? nil : reps
    }

    /// One stored form of an entry, by type (the first stored form whose type is one of `types`): a row's picture reads this and
    /// not all of the forms. nil when the entry has none of them or its file is gone.
    public func data(for id: UUID, ofType types: [String]) -> Data? {
        guard let entry = entry(id), let part = entry.parts.first(where: { types.contains($0.type) }) else { return nil }
        return try? Data(contentsOf: blobFolder(id).appendingPathComponent(part.file))
    }

    /// Back to the top, as when it was just copied: after it was pasted from here.
    public func touch(_ id: UUID) {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries.remove(at: at)
        e.date = now()
        entries.insert(e, at: 0)
        save()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let at = entries.firstIndex(where: { $0.id == id }), entries[at].pinned != pinned else { return }
        entries[at].pinned = pinned
        save()
    }

    public func delete(_ id: UUID) {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: at)
        try? fm.removeItem(at: blobFolder(id))
        save()
    }

    /// Everything, pinned or not unless `keepPinned`; with nothing left on disk but the empty index.
    public func clear(keepPinned: Bool = false) {
        let gone = entries.filter { !(keepPinned && $0.pinned) }
        entries.removeAll { e in gone.contains { $0.id == e.id } }
        for e in gone { try? fm.removeItem(at: blobFolder(e.id)) }
        if !keepPinned { try? fm.removeItem(at: blobsURL) }
        save()
    }

    // ── Keeping to the limits ───────────────────────────────────────────────

    /// Drops what is older than `maxAge`, then the oldest beyond `maxEntries`, then the oldest until the whole fits
    /// `maxTotalBytes`. Pinned entries are never dropped.
    public func prune() {
        var drop = Set<UUID>()
        if let age = limits.maxAge {
            let cutoff = now().addingTimeInterval(-age)
            for e in entries where !e.pinned && e.date < cutoff { drop.insert(e.id) }
        }
        var live = entries.filter { !drop.contains($0.id) }
        // `entries` is newest first, so what is dropped for count or size is taken from the end.
        while live.count > limits.maxEntries, let last = live.last(where: { !$0.pinned }) {
            drop.insert(last.id)
            live.removeAll { $0.id == last.id }
        }
        var total = live.reduce(0) { $0 + $1.byteSize }
        while total > limits.maxTotalBytes, let last = live.last(where: { !$0.pinned }) {
            drop.insert(last.id)
            total -= last.byteSize
            live.removeAll { $0.id == last.id }
        }
        guard !drop.isEmpty else { return }
        for id in drop { try? fm.removeItem(at: blobFolder(id)) }
        entries = live
        save()
    }

    // ── The disk ────────────────────────────────────────────────────────────

    private func makeFolders() -> Bool {
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fm.createDirectory(at: blobsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }

    private func write(_ built: ClipboardBuilder.Built) -> Bool {
        guard makeFolders() else { return false }
        let folder = blobFolder(built.entry.id)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (part, rep) in zip(built.entry.parts, built.kept) {
                let url = folder.appendingPathComponent(part.file)
                guard fm.createFile(atPath: url.path, contents: rep.data, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return true
        } catch {
            try? fm.removeItem(at: folder)
            return false
        }
    }

    private func save() {
        guard makeFolders() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(Index(entries: entries)) else { return }
        try? data.write(to: indexURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func load() {
        guard fm.fileExists(atPath: indexURL.path) else { removeOrphans(); return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: indexURL), let index = try? decoder.decode(Index.self, from: data), index.version == 1 else {
            loadProblem = "the index could not be read; starting again empty"
            entries = []
            removeOrphans()
            return
        }
        // Newest first, whatever order the file kept; and nothing whose contents are gone.
        entries = index.entries.sorted { $0.date > $1.date }.filter { fm.fileExists(atPath: blobFolder($0.id).path) }
        removeOrphans()
    }

    /// Blob folders no entry owns: what a crash left between writing the contents and writing the index.
    private func removeOrphans() {
        guard let names = try? fm.contentsOfDirectory(atPath: blobsURL.path) else { return }
        let owned = Set(entries.map { $0.id.uuidString })
        for name in names where !owned.contains(name) { try? fm.removeItem(at: blobsURL.appendingPathComponent(name)) }
    }
}

// ── Search and how long ago ─────────────────────────────────────────────────

/// What the chips above the list narrow it to.
public enum ClipboardFilter: String, CaseIterable, Equatable {
    case text, link, image, file, pinned

    public var title: String {
        switch self {
        case .text: return "Text"
        case .link: return "Links"
        case .image: return "Images"
        case .file: return "Files"
        case .pinned: return "Pinned"
        }
    }

    public func admits(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .text: return entry.kind == .text
        case .link: return entry.kind == .link
        case .image: return entry.kind == .image
        case .file: return entry.kind == .file
        case .pinned: return entry.pinned
        }
    }

    /// The filters that would leave at least one of `entries`, in a steady order: a chip for a kind nothing here is would only
    /// show an empty list.
    public static func available(in entries: [ClipboardEntry]) -> [ClipboardFilter] {
        allCases.filter { filter in entries.contains { filter.admits($0) } }
    }
}

public enum ClipboardSearch {

    /// The entries that match `query`, best first. Every word of the query must be in the entry (its text, the app it came
    /// from, or its kind named whole: "link", "image", "file", "text"), ignoring case and accents; a match at the start of the text, or of a word, ranks higher; ties go to
    /// the newer. An empty query is every entry: pinned first, then newest.
    public static func results(_ entries: [ClipboardEntry], query: String, filter: ClipboardFilter? = nil) -> [ClipboardEntry] {
        let entries = filter.map { f in entries.filter { f.admits($0) } } ?? entries
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty {
            return entries.filter(\.pinned).sorted { $0.date > $1.date } + entries.filter { !$0.pinned }.sorted { $0.date > $1.date }
        }
        var scored: [(entry: ClipboardEntry, score: Int)] = []
        for e in entries {
            let text = fold(e.text.isEmpty ? e.preview : e.text)
            let haystack = text + "\n" + fold(e.sourceName ?? "")
            // The kind is a word of its own ("link", "image"), matched whole: "e" would otherwise find every text.
            guard words.allSatisfy({ haystack.contains($0) || $0 == e.kind.rawValue }) else { continue }
            var score = 0
            for w in words {
                if text.hasPrefix(w) { score += 4 }
                else if text.contains(" " + w) || text.contains("\n" + w) { score += 2 }
                else if text.contains(w) { score += 1 }
            }
            if e.pinned { score += 1 }
            scored.append((e, score))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.date > $1.entry.date }.map(\.entry)
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// "now", "5 min ago", "3 hr ago", "yesterday", "4 days ago", then the date.
    public static func ago(from date: Date, to now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) hr ago" }
        let days = Int(s / 86_400)
        if days == 1 { return "yesterday" }
        if days < 14 { return "\(days) days ago" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}
