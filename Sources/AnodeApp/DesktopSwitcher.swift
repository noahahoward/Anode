import AppKit
import ApplicationServices
import PowerKit

// ── Desktop switcher (Beta Features) ────────────────────────────────────────
//
// Option-Tab opens a row of your desktops (Spaces); Tab or the arrows move, letting go of
// Option goes there. Unlike the four-finger swipe it jumps straight to any desktop, not one
// step at a time, and it has no slide animation to wait for.
//
// How it works, measured before writing it:
// - SkyLight lists every display's Spaces (`SLSCopyManagedDisplaySpaces`) and which is current,
//   and says which Spaces a window is on (`SLSCopySpacesForWindows`), which is how each tile
//   knows what is on its desktop. Three desktops here; the windows mapped correctly.
// - `SLSManagedDisplaySetCurrentSpace` changed the screen to the other desktop's own content
//   (screenshot), and focus followed: the front window and app became that desktop's.
// All of it is private API, looked up by name: if any piece is missing nothing is taken over
// and Option-Tab stays whatever it was.
//
// The keys are taken the way the window switcher takes Command-Tab: an active event tap, which
// dies with the process, so a crash gives the key straight back. Needs Accessibility.

/// One desktop (Space) on one display.
struct DesktopInfo: Equatable {
    let id: Int
    /// "Desktop N" counts only ordinary desktops; a full-screen app's Space has none.
    let number: Int?
    let isFullScreen: Bool
    let isCurrent: Bool
    /// The apps with windows here, in the order first met, and how many windows in all.
    let pids: [pid_t]
    let windowCount: Int
}

enum SpaceCatalog {

    /// A full-screen app's own Space, as the window server types it. Ordinary desktops are 0.
    static let fullScreenType = 4

    /// The desktops of the display `displayUUID` (the first display when it is not found), in the
    /// order macOS shows them. `displays` is what `SLSCopyManagedDisplaySpaces` returns;
    /// `windowsBySpace` has one pid per window on each Space. Pure, for tests.
    static func desktops(displays: [[String: Any]], displayUUID: String?,
                         windowsBySpace: [Int: [pid_t]]) -> (display: String, desktops: [DesktopInfo])? {
        let wanted = displayUUID?.uppercased()
        guard let display = displays.first(where: { ($0["Display Identifier"] as? String)?.uppercased() == wanted })
                ?? displays.first,
              let identifier = display["Display Identifier"] as? String,
              let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
        let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        var number = 0
        let list: [DesktopInfo] = spaces.compactMap { space in
            guard let id = space["ManagedSpaceID"] as? Int else { return nil }
            let full = (space["type"] as? Int) == fullScreenType
            if !full { number += 1 }
            let windows = windowsBySpace[id] ?? []
            var seen = Set<pid_t>()
            let pids = windows.filter { seen.insert($0).inserted }
            return DesktopInfo(id: id, number: full ? nil : number, isFullScreen: full, isCurrent: id == current,
                               pids: pids, windowCount: windows.count)
        }
        return list.isEmpty ? nil : (identifier, list)
    }

    // ── The private calls ──

    private typealias ConnectionID = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetSpace = @convention(c) (Int32, CFString, Int) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
    private static let connection = symbol("SLSMainConnectionID", ConnectionID.self)
    private static let copySpaces = symbol("SLSCopyManagedDisplaySpaces", CopySpaces.self)
    private static let spacesForWindows = symbol("SLSCopySpacesForWindows", SpacesForWindows.self)
    private static let setSpace = symbol("SLSManagedDisplaySetCurrentSpace", SetSpace.self)

    /// Are all the private pieces there? Without them the switcher never starts.
    static var isAvailable: Bool {
        connection != nil && copySpaces != nil && spacesForWindows != nil && setSpace != nil
    }

    /// The desktops of the display under the pointer, with what is on each. About one SkyLight call
    /// per window, and nothing heavier.
    static func read() -> (display: String, desktops: [DesktopInfo])? {
        guard let connection, let copySpaces, let spacesForWindows else { return nil }
        let cid = connection()
        guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }

        let regular = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var bySpace: [Int: [pid_t]] = [:]
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, regular.contains(pid),
                  let number = w[kCGWindowNumber as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= WindowCatalog.minSide, bounds.height >= WindowCatalog.minSide else { continue }
            let spaces = spacesForWindows(cid, 7, [number] as CFArray)?.takeRetainedValue() as? [Int] ?? []
            for space in spaces { bySpace[space, default: []].append(pid) }
        }
        return desktops(displays: displays, displayUUID: displayUUID(under: NSEvent.mouseLocation),
                        windowsBySpace: bySpace)
    }

    /// Go to `desktop` on `display`.
    static func go(to desktop: DesktopInfo, on display: String) {
        guard let connection, let setSpace else { return }
        setSpace(connection(), display as CFString, desktop.id)
    }

    private static func displayUUID(under point: NSPoint) -> String? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        return string
    }
}

/// Which desktop is selected. Pure, for tests.
struct DesktopSelection: Equatable {
    private(set) var index: Int?
    private(set) var count = 0

    /// Opening selects the NEXT desktop (the previous one with Shift), so a quick Option-Tab
    /// goes one along, as Command-Tab goes to the previous window. Fewer than two desktops
    /// leaves nothing to select.
    mutating func start(count: Int, current: Int, backward: Bool) {
        self.count = count
        guard count >= 2, (0..<count).contains(current) else { index = nil; return }
        index = ((current + (backward ? -1 : 1)) % count + count) % count
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

final class DesktopSwitcher {

    static let tab: Int64 = 48, escape: Int64 = 53, left: Int64 = 123, right: Int64 = 124
    /// Number-row keys, 1 to 9: jump straight to that desktop.
    static let digits: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]

    private let settings: Settings
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var settingToken: AnyObject?
    private var retryTimer: Timer?
    private var showTimer: Timer?

    private(set) var isActive = false
    private var display = ""
    private var desktops: [DesktopInfo] = []
    private var selection = DesktopSelection()
    private let panel = DesktopPanel()

    var isRunning: Bool { tap != nil }

    init(settings: Settings = .shared) {
        self.settings = settings
        panel.onClick = { [weak self] i in
            self?.selection.select(i)
            self?.commit()
        }
        settingToken = settings.observe(Settings.Key.desktopSwitcherEnabled) { [weak self] in self?.apply() }
        apply()
    }

    deinit { stop() }

    /// Start or stop to match the setting; while it is on but Accessibility is not granted, try
    /// again every two seconds so a grant works without a relaunch.
    func apply() {
        guard settings.desktopSwitcherEnabled, SpaceCatalog.isAvailable else {
            stop()
            return
        }
        if tap == nil { start() }
        if tap == nil {
            guard retryTimer == nil else { return }
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.apply() }
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
                                          callback: desktopTapCallback,
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

    /// Runs on the main thread inside the tap, so it stays quick.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .flagsChanged:
            if isActive && !event.flags.contains(.maskAlternate) { commit() }
            return pass
        case .keyDown, .keyUp:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if !isActive {
                let optionTab = key == Self.tab && flags.contains(.maskAlternate)
                    && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
                guard optionTab else { return pass }
                // Nothing to switch to (one desktop, or no way to read them): the key is not ours.
                if type == .keyDown, !begin(backward: flags.contains(.maskShift)) { return pass }
                return type == .keyDown ? nil : (isActive ? nil : pass)
            }
            // Open: the switcher owns the keyboard, since Option is held and a key let through
            // would arrive in the app in front as an Option shortcut.
            if type == .keyDown {
                switch key {
                case Self.tab: move(flags.contains(.maskShift) ? -1 : 1)
                case Self.left: move(-1)
                case Self.right: move(1)
                case Self.escape: cancel()
                default:
                    if let i = Self.digits[key] {
                        selection.select(i)
                        panel.select(selection.index)
                    }
                }
            }
            return nil
        default:
            return pass
        }
    }

    /// Open the switcher; false when there is nothing to switch to.
    private func begin(backward: Bool) -> Bool {
        guard let read = SpaceCatalog.read(), read.desktops.count >= 2,
              let current = read.desktops.firstIndex(where: \.isCurrent) else { return false }
        display = read.display
        desktops = read.desktops
        selection.start(count: desktops.count, current: current, backward: backward)
        isActive = true
        showTimer?.invalidate()
        // Built just after the tap returns, shown after the same short delay as the window switcher.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.panel.prepare(self.desktops, selected: self.selection.index)
        }
        showTimer = Timer.scheduledTimer(withTimeInterval: WindowSwitcher.showDelay, repeats: false) { [weak self] _ in
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
        let chosen = selection.index.flatMap { desktops.indices.contains($0) ? desktops[$0] : nil }
        let display = self.display
        cancel()
        if let chosen, !chosen.isCurrent { SpaceCatalog.go(to: chosen, on: display) }
    }

    private func cancel() {
        isActive = false
        showTimer?.invalidate()
        showTimer = nil
        panel.dismiss()
        desktops = []
        selection = DesktopSelection()
    }
}

private func desktopTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<DesktopSwitcher>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

// ── The panel ───────────────────────────────────────────────────────────────

final class DesktopPanel {

    static let tileWidth: CGFloat = 156
    static let tileHeight: CGFloat = 104
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12

    var onClick: ((Int) -> Void)?

    private var window: NSPanel?
    private var tiles: [DesktopTile] = []

    /// Columns and rows for `count` tiles in `width` points. Pure, for tests.
    static func grid(count: Int, width: CGFloat) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (0, 0) }
        let fit = Int((width - 2 * padding + spacing) / (tileWidth + spacing))
        let columns = max(1, min(count, fit))
        return (columns, (count + columns - 1) / columns)
    }

    func prepare(_ desktops: [DesktopInfo], selected: Int?) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let (columns, rows) = Self.grid(count: desktops.count, width: area.width * 0.9)
        let size = NSSize(width: CGFloat(columns) * Self.tileWidth + CGFloat(columns - 1) * Self.spacing + 2 * Self.padding,
                          height: CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * Self.spacing + 2 * Self.padding)

        let panel = window ?? makePanel()
        window = panel
        let content = panel.contentView!
        tiles.forEach { $0.removeFromSuperview() }
        tiles = desktops.enumerated().map { i, d in
            let row = i / columns, column = i % columns
            let frame = NSRect(x: Self.padding + CGFloat(column) * (Self.tileWidth + Self.spacing),
                               y: size.height - Self.padding - CGFloat(row + 1) * Self.tileHeight - CGFloat(row) * Self.spacing,
                               width: Self.tileWidth, height: Self.tileHeight)
            let tile = DesktopTile(frame: frame, desktop: d)
            tile.onClick = { [weak self] in self?.onClick?(i) }
            content.addSubview(tile)
            return tile
        }
        select(selected)
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        panel.invalidateShadow()
    }

    func reveal() { window?.orderFrontRegardless() }

    func select(_ index: Int?) {
        for (i, tile) in tiles.enumerated() { tile.isSelected = i == index }
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
        background.maskImage = RoundedMask.image(radius: 16)
        panel.contentView = background
        return panel
    }
}

/// One desktop: its name, the apps on it as icons, and how many windows.
final class DesktopTile: NSView {

    let desktop: DesktopInfo
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    /// At most this many app icons; the rest are counted in "+N".
    static let maxIcons = 4

    init(frame: NSRect, desktop: DesktopInfo) {
        self.desktop = desktop
        super.init(frame: frame)

        let title = NSTextField(labelWithString: Self.title(for: desktop))
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .white
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 8, y: frame.height - 28, width: frame.width - 16, height: 18)
        addSubview(title)

        let shown = Array(desktop.pids.prefix(Self.maxIcons))
        let icon: CGFloat = 28, gap: CGFloat = 4
        let extra = desktop.pids.count - shown.count
        let slots = shown.count + (extra > 0 ? 1 : 0)
        var x = (frame.width - (CGFloat(slots) * icon + CGFloat(max(0, slots - 1)) * gap)) / 2
        for pid in shown {
            let view = NSImageView(frame: NSRect(x: x, y: frame.height / 2 - 10, width: icon, height: icon))
            view.image = SwitcherPanel.appIcon(for: pid)
            addSubview(view)
            x += icon + gap
        }
        if extra > 0 {
            let more = NSTextField(labelWithString: "+\(extra)")
            more.font = .systemFont(ofSize: 12)
            more.textColor = NSColor.white.withAlphaComponent(0.7)
            more.frame = NSRect(x: x, y: frame.height / 2 - 5, width: icon, height: 18)
            addSubview(more)
        }

        let detail = NSTextField(labelWithString: Self.detail(for: desktop))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor.white.withAlphaComponent(0.7)
        detail.alignment = .center
        detail.frame = NSRect(x: 8, y: 8, width: frame.width - 16, height: 16)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func title(for d: DesktopInfo) -> String {
        if let number = d.number { return "Desktop \(number)" }
        let app = d.pids.first.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return app ?? "Full screen"
    }

    static func detail(for d: DesktopInfo) -> String {
        let windows = d.windowCount == 0 ? "Empty" : (d.windowCount == 1 ? "1 window" : "\(d.windowCount) windows")
        return d.isCurrent ? "Current · \(windows)" : windows
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        } else if desktop.isCurrent {
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
