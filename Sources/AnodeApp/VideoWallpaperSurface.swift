import AVFoundation
import AppKit
import PowerKit

/// A view whose backing layer IS the player layer, so it always fills the window with nothing to keep in step.
final class WallpaperPlayerView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A looping video on one display. Shares its player with every other display showing the same item.
///
/// Created paused and not shown: the window appears when the first frame is ready to draw (`start()`), and the controller
/// then plays or pauses it. `present: false` keeps the window off screen, which is how the tests build one.
final class VideoWallpaperSurface: WallpaperSurface {

    let displayUUID: String
    let pausable = true
    var onCoveredChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    let player: AVQueuePlayer
    let window: DesktopWallpaperWindow
    private let playerView: WallpaperPlayerView
    private let players: WallpaperPlayers
    private let itemID: UUID
    private let present: Bool
    private var observations: [NSKeyValueObservation] = []
    private var closed = false

    static func gravity(for scaling: WallpaperScaling) -> AVLayerVideoGravity {
        switch scaling {
        case .fill:    return .resizeAspectFill
        case .fit:     return .resizeAspect
        case .stretch: return .resize
        }
    }

    init(display: DisplayInfo, item: WallpaperItem, library: WallpaperLibrary, players: WallpaperPlayers, present: Bool = true) throws {
        guard let url = library.contentURL(item) else { throw WallpaperSurfaceError.missingFile(item.name) }
        self.displayUUID = display.uuid
        self.players = players
        self.itemID = item.id
        self.present = present
        self.player = try players.acquire(item: item.id, url: url)
        window = DesktopWallpaperWindow(frame: display.frame)
        playerView = WallpaperPlayerView(frame: NSRect(origin: .zero, size: display.frame.size))
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspectFill
        playerView.playerLayer.backgroundColor = NSColor.black.cgColor
        window.contentView = playerView
        window.onVisibilityChange = { [weak self] visible in self?.onCoveredChange?(!visible) }
    }

    deinit { close() }

    /// Begin: show the window once the layer has a frame, and report a looper that fails.
    func start() {
        let layer = playerView.playerLayer
        observations.append(layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.present else { return }
                self.window.present()
            }
        })
        if let looper = players.looper(for: itemID) {
            observations.append(looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                let why = looper.error?.localizedDescription ?? "The video can't be played."
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.onFailure?(why)
                }
            })
        }
    }

    func setPlaying(_ playing: Bool) {
        guard !closed else { return }
        players.setPlaying(playing, owner: ObjectIdentifier(self), item: itemID)
        // A resume after wake or unlock must really resume even if this surface believes it is already playing: the system
        // can stop a player without telling it. `play()` on a playing player is a no-op, so asking again is free.
        if playing { player.play() }
    }

    func apply(_ prefs: WallpaperPrefs) {
        guard !closed else { return }
        players.setMuted(prefs.muted, item: itemID)
        player.volume = prefs.volume
        player.defaultRate = Float(prefs.speed)
        // A rate change takes effect on a playing player at once; a paused one picks it up on its next play.
        if player.rate != 0 { player.rate = Float(prefs.speed) }
        playerView.playerLayer.videoGravity = Self.gravity(for: prefs.scaling)
    }

    func updateFrame(_ frame: NSRect) {
        guard !closed else { return }
        window.setFrame(frame, display: false)
    }

    func close() {
        guard !closed else { return }
        closed = true
        observations.removeAll()
        playerView.playerLayer.player = nil
        window.dismiss()
        onCoveredChange = nil
        onFailure = nil
        players.release(item: itemID, owner: ObjectIdentifier(self))
    }
}
