import AppKit
import ApplicationServices
import ScreenCaptureKit
import PowerKit

// ── Window switcher (Beta Features) ─────────────────────────────────────────
//
// Replaces the system's Command-Tab with a switcher of WINDOWS, each shown as a live
// preview, the way BetterCmdTab does (used as a reference for behaviour only).
//
// How the key is taken over, measured before any of this was written:
// - An active event tap at the HID level that returns nil for Command-Tab stops the
//   system switcher. A synthetic Command-Tab switched Code -> Brave with no tap and
//   switched nothing with the tap swallowing it.
// - No system setting is changed to do it (the other way is turning the Command-Tab
//   symbolic hotkey off, which stays off if the app is killed). The tap dies with the
//   process, so a crash or a force-quit gives Command-Tab straight back to macOS.
// - The tap needs Accessibility. Without it `tapCreate` returns nil and nothing is
//   taken over; the system switcher keeps working.
//
// Bringing another app's window forward from the background: `NSRunningApplication
// .activate` returned true and did nothing (macOS 14+ cooperative activation; Code
// stayed in front of Plexamp). The private SkyLight front-process call, looked up by
// name, did it, and is used first; the public call is the fallback.

/// One window the switcher can offer.
struct SwitchableWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    /// In the window server's coordinates (origin top-left).
    let bounds: CGRect
}

enum WindowCatalog {

    /// Smaller than this on either side is a palette or a helper, not a window to switch to.
    static let minSide: CGFloat = 60

    /// The windows on the current Space worth switching to, front to back, which is close
    /// to most-recently-used. `regularPIDs` are the apps that have a Dock tile: an app with
    /// none (a menu bar extra, an agent) is not something a user Command-Tabs to. Pure.
    static func switchable(windowInfo: [[String: Any]], regularPIDs: Set<pid_t>) -> [SwitchableWindow] {
        windowInfo.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, regularPIDs.contains(pid),
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= minSide, bounds.height >= minSide else { return nil }
            return SwitchableWindow(id: CGWindowID(number), pid: pid,
                                    appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                                    title: entry[kCGWindowName as String] as? String ?? "",
                                    bounds: bounds)
        }
    }

    static func current() -> [SwitchableWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let regular = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        return switchable(windowInfo: info, regularPIDs: regular)
    }
}

/// Window previews. They need Screen Recording; without it there are none and the tiles
/// show the app's icon instead.
enum WindowThumbnails {

    /// Capture each window no larger than `maxSide` points, calling `each` on the main
    /// thread as each arrives. Measured: four windows at ~480 px took 156 ms together.
    static func capture(_ ids: [CGWindowID], maxSide: CGFloat,
                        each: @escaping (CGWindowID, CGImage) -> Void) {
        guard #available(macOS 14.0, *), ScreenRecordingAccess.isGranted, !ids.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true) else { return }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    guard let window = byID[id], window.frame.width > 0, window.frame.height > 0 else { continue }
                    group.addTask {
                        let config = SCStreamConfiguration()
                        let scale = min(1, maxSide / max(window.frame.width, window.frame.height))
                        config.width = max(1, Int(window.frame.width * scale * 2))
                        config.height = max(1, Int(window.frame.height * scale * 2))
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        guard let image = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: window),
                            configuration: config) else { return }
                        await MainActor.run { each(id, image) }
                    }
                }
            }
        }
    }
}

/// Bring one particular window to the front, app and all.
enum WindowActivator {

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Int32

    private static let getWindow: GetWindow? = dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }
    private static let getPSN: GetPSN? = dlsym(dlopen(nil, RTLD_NOW), "GetProcessForPID")
        .map { unsafeBitCast($0, to: GetPSN.self) }
    private static let setFront: SetFront? = dlsym(
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
        "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFront.self) }

    static func bringForward(_ window: SwitchableWindow) {
        if !frontViaSkyLight(window) {
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
        }
        // Within the app, the chosen window over its siblings.
        guard let element = axWindow(window) else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func frontViaSkyLight(_ window: SwitchableWindow) -> Bool {
        guard let getPSN, let setFront else { return false }
        var psn = [UInt32](repeating: 0, count: 2)
        return psn.withUnsafeMutableBytes { raw -> Bool in
            guard let p = raw.baseAddress, getPSN(window.pid, p) == 0 else { return false }
            // 0x200: user-generated, the mode a click on the window would use.
            return setFront(p, window.id, 0x200) == 0
        }
    }

    private static func axWindow(_ window: SwitchableWindow) -> AXUIElement? {
        guard let getWindow else { return nil }
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { element in
            var id: CGWindowID = 0
            return getWindow(element, &id) == .success && id == window.id
        }
    }
}

enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system's question (once; after that it only opens nothing).
    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Which tile is selected. Pure, for tests.
struct SwitcherSelection: Equatable {
    private(set) var index: Int?
    private(set) var count = 0

    /// Opening the switcher selects the window BEHIND the front one, so a quick
    /// Command-Tab goes back to the previous window, as the system's does with apps.
    mutating func start(count: Int) {
        self.count = count
        index = count == 0 ? nil : min(1, count - 1)
    }

    mutating func step(_ by: Int) {
        guard count > 0, let i = index else { return }
        index = ((i + by) % count + count) % count
    }

    mutating func select(_ i: Int) {
        guard (0..<count).contains(i) else { return }
        index = i
    }
}

final class WindowSwitcher {

    /// How long Command must be held after Tab before the panel appears. A quicker
    /// release switches without ever drawing it, as the system switcher does.
    static let showDelay: TimeInterval = 0.12

    static let tab: Int64 = 48, escape: Int64 = 53, left: Int64 = 123, right: Int64 = 124

    private let settings: Settings
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var settingToken: AnyObject?
    private var retryTimer: Timer?
    private var showTimer: Timer?

    private(set) var isActive = false
    private var windows: [SwitchableWindow] = []
    /// The last preview of every window, so a tile opens on a picture rather than an icon
    /// and is refreshed in place. Main thread only.
    private var thumbnails: [CGWindowID: CGImage] = [:]
    private var lastPrewarm = Date.distantPast
    private var activationToken: NSObjectProtocol?
    private var selection = SwitcherSelection()
    private let panel = SwitcherPanel()

    /// Is the takeover live right now (setting on and the tap made)?
    var isRunning: Bool { tap != nil }

    init(settings: Settings = .shared) {
        self.settings = settings
        panel.onClick = { [weak self] i in
            self?.selection.select(i)
            self?.commit()
        }
        settingToken = settings.observe(Settings.Key.windowSwitcherEnabled) { [weak self] in self?.apply() }
        // Switching apps is when the windows on screen change, so previews are taken then,
        // in the background, and the switcher opens on pictures already in hand.
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.prewarmDelay) { self?.prewarm() }
        }
        apply()
    }

    /// After an app comes forward, long enough for its window to have redrawn as active.
    static let prewarmDelay: TimeInterval = 0.3
    /// At most one background round of previews this often.
    static let prewarmInterval: TimeInterval = 1

    deinit {
        stop()
        if let t = activationToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
    }

    /// Take previews of what is on screen now, for the next time the switcher opens, and
    /// forget windows that have closed.
    private func prewarm() {
        guard isRunning, !isActive, Date().timeIntervalSince(lastPrewarm) >= Self.prewarmInterval else { return }
        lastPrewarm = Date()
        let current = WindowCatalog.current()
        let ids = Set(current.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        WindowThumbnails.capture(current.map(\.id), maxSide: SwitcherPanel.thumbnailSide) { [weak self] id, image in
            self?.thumbnails[id] = image
        }
    }

    /// Start or stop to match the setting. While the setting is on but Accessibility has
    /// not been granted, keep trying every two seconds, so a grant in System Settings
    /// takes effect without a relaunch.
    func apply() {
        guard settings.windowSwitcherEnabled else {
            stop()
            return
        }
        if tap == nil {
            start()
            if tap != nil { prewarm() }
        }
        if tap == nil {
            guard retryTimer == nil else { return }
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.apply()
            }
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    private func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: switcherTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        cancel()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    // ── Keys ────────────────────────────────────────────────────────────────

    /// Runs on the main thread, inside the tap. It must stay quick: a tap that is slow
    /// is switched off by the system (handled below by switching it back on).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .flagsChanged:
            if isActive && !event.flags.contains(.maskCommand) { commit() }
            return pass
        case .keyDown, .keyUp:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let commandTab = key == Self.tab && flags.contains(.maskCommand)
                && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
            if !isActive {
                guard commandTab else { return pass }
                // With no window on this Space (all minimized or hidden) there is nothing
                // to show, so the system's switcher, which lists apps, gets the key.
                if type == .keyDown, !begin(backward: flags.contains(.maskShift)) { return pass }
                return type == .keyDown ? nil : pass
            }
            // While open, the switcher owns the keyboard. Command is held throughout, so a
            // key let through arrives as a shortcut in the app in front: Command-Q, which
            // in the system switcher quits the highlighted app, would quit THIS one.
            if type == .keyDown {
                switch key {
                case Self.tab: move(flags.contains(.maskShift) ? -1 : 1)
                case Self.left: move(-1)
                case Self.right: move(1)
                case Self.escape: cancel()
                default: break
                }
            }
            return nil
        default:
            return pass
        }
    }

    /// Open the switcher; false when there is nothing to switch to.
    private func begin(backward: Bool) -> Bool {
        windows = WindowCatalog.current()
        guard !windows.isEmpty else { return false }
        selection.start(count: windows.count)
        if backward { selection.step(-2) }   // start() already took one step forward
        isActive = true
        // Everything slow happens now, during the hold delay, so that showing the panel
        // when the delay ends is only putting it on screen (measured before: ~70 ms of
        // building AFTER the delay, ~190 ms from Tab to panel).
        // Just after the tap returns, not inside it: keys queue behind a slow tap.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.panel.prepare(self.windows, selected: self.selection.index, thumbnails: self.thumbnails)
            WindowThumbnails.capture(self.windows.map(\.id), maxSide: SwitcherPanel.thumbnailSide) { [weak self] id, image in
                guard let self else { return }
                self.thumbnails[id] = image
                if self.isActive { self.panel.setThumbnail(image, for: id) }
            }
        }
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.panel.reveal()
        }
        return true
    }

    private func move(_ by: Int) {
        selection.step(by)
        panel.select(selection.index)
    }

    private func commit() {
        let chosen = selection.index.flatMap { windows.indices.contains($0) ? windows[$0] : nil }
        cancel()
        if let chosen { WindowActivator.bringForward(chosen) }
    }

    private func cancel() {
        isActive = false
        showTimer?.invalidate()
        showTimer = nil
        panel.dismiss()
        windows = []
        selection = SwitcherSelection()
    }
}

private func switcherTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<WindowSwitcher>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

// ── The panel ───────────────────────────────────────────────────────────────

final class SwitcherPanel {

    static let thumbnailSide: CGFloat = 220
    static let tileWidth: CGFloat = 240
    static let tileHeight: CGFloat = 190
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 20

    var onClick: ((Int) -> Void)?

    private var window: NSPanel?
    private var tiles: [SwitcherTile] = []

    /// Columns and rows for `count` tiles in `width` points, and the scale that keeps them
    /// inside `height`. Pure, for tests.
    static func grid(count: Int, width: CGFloat, height: CGFloat) -> (columns: Int, rows: Int, scale: CGFloat) {
        guard count > 0 else { return (0, 0, 1) }
        func fit(_ scale: CGFloat) -> (Int, Int) {
            let w = (tileWidth + spacing) * scale
            let columns = max(1, min(count, Int((width - 2 * padding + spacing * scale) / w)))
            return (columns, (count + columns - 1) / columns)
        }
        var scale: CGFloat = 1
        var (columns, rows) = fit(scale)
        while scale > 0.4, CGFloat(rows) * (tileHeight + spacing) * scale + 2 * padding > height {
            scale -= 0.05
            (columns, rows) = fit(scale)
        }
        return (columns, rows, scale)
    }

    /// Lay the panel out, off screen until `reveal`.
    func prepare(_ windows: [SwitchableWindow], selected: Int?, thumbnails: [CGWindowID: CGImage]) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let (columns, rows, scale) = Self.grid(count: windows.count, width: area.width * 0.9,
                                              height: area.height * 0.8)
        let tileW = Self.tileWidth * scale, tileH = Self.tileHeight * scale, gap = Self.spacing * scale
        let size = NSSize(width: CGFloat(columns) * tileW + CGFloat(columns - 1) * gap + 2 * Self.padding,
                          height: CGFloat(rows) * tileH + CGFloat(rows - 1) * gap + 2 * Self.padding)

        let panel = window ?? makePanel()
        window = panel
        let content = panel.contentView!
        tiles.forEach { $0.removeFromSuperview() }
        tiles = windows.enumerated().map { i, w in
            let row = i / columns, column = i % columns
            let frame = NSRect(x: Self.padding + CGFloat(column) * (tileW + gap),
                               y: size.height - Self.padding - CGFloat(row + 1) * tileH - CGFloat(row) * gap,
                               width: tileW, height: tileH)
            let tile = SwitcherTile(frame: frame, window: w, icon: Self.icon(for: w.pid))
            if let image = thumbnails[w.id] { tile.setThumbnail(image) }
            tile.onClick = { [weak self] in self?.onClick?(i) }
            content.addSubview(tile)
            return tile
        }
        select(selected)
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
    }

    func reveal() {
        window?.orderFrontRegardless()
    }

    /// App icons, kept: asking a running app for its icon each time the panel opens was part
    /// of the cost of opening it.
    private static var icons: [pid_t: NSImage] = [:]
    private static func icon(for pid: pid_t) -> NSImage? {
        if let hit = icons[pid] { return hit }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    func select(_ index: Int?) {
        for (i, tile) in tiles.enumerated() { tile.isSelected = i == index }
    }

    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        tiles.first { $0.target.id == id }?.setThumbnail(image)
    }

    func dismiss() {
        window?.orderOut(nil)
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        panel.contentView = background
        return panel
    }
}

final class SwitcherTile: NSView {

    let target: SwitchableWindow
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    private let preview = NSImageView()
    private let badge = NSImageView()
    private let label: NSTextField

    init(frame: NSRect, window: SwitchableWindow, icon: NSImage?) {
        target = window
        label = NSTextField(labelWithString: window.title.isEmpty ? window.appName : window.title)
        super.init(frame: frame)
        let labelHeight: CGFloat = 18
        let inset: CGFloat = 8

        preview.frame = NSRect(x: inset, y: labelHeight + inset, width: frame.width - 2 * inset,
                               height: frame.height - labelHeight - 2 * inset)
        preview.imageScaling = .scaleProportionallyUpOrDown
        // Until (or unless) a preview arrives, the app's icon stands in for it.
        preview.image = icon
        addSubview(preview)

        let badgeSide = min(36, frame.height * 0.2)
        badge.frame = NSRect(x: inset, y: labelHeight + inset, width: badgeSide, height: badgeSide)
        badge.image = icon
        badge.isHidden = true
        addSubview(badge)

        label.frame = NSRect(x: inset, y: 4, width: frame.width - 2 * inset, height: labelHeight - 2)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setThumbnail(_ image: CGImage) {
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        badge.isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
