import AVFoundation
import AppKit
import PowerKit

// ── The wallpaper window, and what draws into it ────────────────────────────
//
// One borderless window per display, at the desktop-window level: above the system's own wallpaper, below the desktop icons
// and widgets (measured on this Mac, macOS 27: system "Wallpaper" −2147483624, `.desktopWindow` −2147483623, Finder and the
// Event Shield −2147483603, widgets −2147483601). It is click-through, never key, never main, and on every Space.
//
// A `WallpaperSurface` is one display's wallpaper: the window plus a renderer (video, image or web page). The controller makes
// them through a `WallpaperSurfaceFactory`, tells them to play or pause, and closes them. A surface is created PAUSED and shows
// nothing until its content is ready (first video frame, decoded image, loaded page): until then the system wallpaper shows
// through, which is also what is left if the content never arrives.

struct DisplayInfo: Equatable {
    let uuid: String
    let name: String
    let frame: NSRect
    let pixelSize: CGSize

    /// The connected displays, identified by display UUID (never by index), so an assignment survives a monitor being
    /// unplugged and plugged back in.
    static func current() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, cf) as String? else { return nil }
            let scale = screen.backingScaleFactor
            return DisplayInfo(uuid: string, name: screen.localizedName, frame: screen.frame,
                               pixelSize: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale))
        }
    }
}

enum WallpaperSurfaceError: Error, Equatable {
    case missingFile(String)
    case unreadable(String)

    var message: String {
        switch self {
        case .missingFile(let name): return "File missing: \(name)"
        case .unreadable(let why):   return why
        }
    }
}

protocol WallpaperSurface: AnyObject {
    var displayUUID: String { get }
    /// Whether `setPlaying(false)` does anything (an image never plays or pauses).
    var pausable: Bool { get }
    /// The window server says none of this display's wallpaper window can be seen (true) or some of it can (false).
    var onCoveredChange: ((Bool) -> Void)? { get set }
    /// The content could not be shown (it failed to load, decode or play). The surface stays in place; the controller decides.
    var onFailure: ((String) -> Void)? { get set }
    func setPlaying(_ playing: Bool)
    func apply(_ prefs: WallpaperPrefs)
    func updateFrame(_ frame: NSRect)
    func close()
}

protocol WallpaperSurfaceFactory: AnyObject {
    func makeSurface(for display: DisplayInfo, item: WallpaperItem, library: WallpaperLibrary, prefs: WallpaperPrefs) throws -> WallpaperSurface
}

// MARK: the window

final class DesktopWallpaperWindow: NSWindow {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Fires when the window's visibility to the window server changes (and only then). Not fired before the window is shown.
    var onVisibilityChange: ((Bool) -> Void)?

    private var lastVisible: Bool?
    private var observer: NSObjectProtocol?
    private(set) var hasBeenPresented = false

    /// The desktop-window level: one above the system wallpaper, below the icons.
    static func level() -> NSWindow.Level { NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))) }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(frame, display: false)
        isReleasedWhenClosed = false
        level = Self.level()
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        animationBehavior = .none
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: self,
                                                          queue: .main) { [weak self] _ in self?.occlusionChanged() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func occlusionChanged() {
        guard hasBeenPresented else { return }
        let visible = occlusionState.contains(.visible)
        guard visible != lastVisible else { return }
        lastVisible = visible
        onVisibilityChange?(visible)
    }

    /// Show the window. Called once the content is ready; harmless if repeated.
    func present() {
        guard !hasBeenPresented else { return }
        hasBeenPresented = true
        orderFrontRegardless()
    }

    func dismiss() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        onVisibilityChange = nil
        contentView = nil
        orderOut(nil)
    }
}

// MARK: the players

/// One `AVQueuePlayer` (looping through an `AVPlayerLooper`) per library item, shared by every display showing that item,
/// and played whenever ANY of its surfaces wants it played: two displays with one video decode it once.
final class WallpaperPlayers {

    private let pool: RefCountedPool<UUID, AVQueuePlayer>
    private var urls: [UUID: URL] = [:]
    private var made: [UUID: AVQueuePlayer] = [:]
    private var loopers: [UUID: AVPlayerLooper] = [:]
    private var wanting: [UUID: Set<ObjectIdentifier>] = [:]

    static let shared = WallpaperPlayers()

    var liveKeys: Set<UUID> { pool.liveKeys }

    init() {
        // The two closures need `self`, which does not exist until the stored pool does; a box breaks the knot.
        let box = WeakBox<WallpaperPlayers>()
        pool = RefCountedPool(make: { id in
            guard let me = box.value, let url = me.urls[id] else { throw WallpaperSurfaceError.unreadable("No file to play") }
            return me.makePlayer(id: id, url: url)
        }, dispose: { player in
            box.value?.dispose(player)
        })
        box.value = self
    }

    func acquire(item id: UUID, url: URL) throws -> AVQueuePlayer {
        urls[id] = url
        return try pool.acquire(id)
    }

    func looper(for id: UUID) -> AVPlayerLooper? { loopers[id] }

    func release(item id: UUID, owner: ObjectIdentifier) {
        wanting[id]?.remove(owner)
        refresh(id)
        pool.release(id)
    }

    /// `owner` wants the item playing (or no longer does). It plays while any owner does.
    func setPlaying(_ playing: Bool, owner: ObjectIdentifier, item id: UUID) {
        if playing { wanting[id, default: []].insert(owner) } else { wanting[id]?.remove(owner) }
        refresh(id)
    }

    private func refresh(_ id: UUID) {
        guard let player = made[id] else { return }
        if wanting[id]?.isEmpty == false { player.play() } else { player.pause() }
    }

    private func makePlayer(id: UUID, url: URL) -> AVQueuePlayer {
        let template = AVPlayerItem(asset: AVURLAsset(url: url))
        let largest = DisplayInfo.current().map(\.pixelSize).max { $0.width * $0.height < $1.width * $1.height }
        template.preferredMaximumResolution = largest ?? CGSize(width: 3840, height: 2160)
        let player = AVQueuePlayer()
        // A wallpaper must never keep the Mac or its display awake.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .advance
        loopers[id] = AVPlayerLooper(player: player, templateItem: template)
        made[id] = player
        return player
    }

    private func dispose(_ player: AVQueuePlayer) {
        player.pause()
        guard let id = made.first(where: { $0.value === player })?.key else { return }
        loopers[id]?.disableLooping()
        loopers[id] = nil
        made[id] = nil
        urls[id] = nil
        wanting[id] = nil
        player.removeAllItems()
    }
}

private final class WeakBox<T: AnyObject> { weak var value: T? }

// MARK: the real factory

final class RealWallpaperSurfaceFactory: WallpaperSurfaceFactory {
    private let players: WallpaperPlayers

    init(players: WallpaperPlayers = .shared) { self.players = players }

    func makeSurface(for display: DisplayInfo, item: WallpaperItem, library: WallpaperLibrary, prefs: WallpaperPrefs) throws -> WallpaperSurface {
        // Checked before any window exists: a wallpaper whose file is gone must leave the system wallpaper showing.
        if library.isMissing(item) { throw WallpaperSurfaceError.missingFile(item.name) }
        switch item.kind {
        case .video:
            let s = try VideoWallpaperSurface(display: display, item: item, library: library, players: players)
            s.apply(prefs); s.start()
            return s
        case .image:
            let s = try ImageWallpaperSurface(display: display, item: item, library: library, scaling: prefs.scaling)
            s.apply(prefs); s.start()
            return s
        case .web:
            let s = try WebWallpaperSurface(display: display, item: item, library: library)
            s.apply(prefs); s.start()
            return s
        }
    }
}
