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
    /// Minimized into the Dock, or belonging to a hidden app: listed, but not on screen.
    var isOffScreen = false
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

    /// One app's windows for its Dock preview: what is on screen on this Space, and the ones
    /// the screen does not show because they are minimized or the app is hidden. Any other window accessibility lists but the screen does not show is not
    /// one to offer: Finder's desktop is one, and it would have been a "minimized" tile. Pure.
    static func appWindows(onScreen: [SwitchableWindow], accessibility: [AXWindowInfo],
                           pid: pid_t, appName: String, appHidden: Bool = false) -> [SwitchableWindow] {
        let shown = Set(onScreen.map(\.id))
        let rest = accessibility.compactMap { w -> SwitchableWindow? in
            guard w.id != 0, !shown.contains(w.id), w.minimized || appHidden,
                  w.frame.width >= minSide, w.frame.height >= minSide else { return nil }
            return SwitchableWindow(id: w.id, pid: pid, appName: appName, title: w.title,
                                    bounds: w.frame, isOffScreen: true)
        }
        // Left to right as they sit on screen, then top to bottom for windows sharing a left
        // edge, so a row of tiled windows reads the way it looks: neither alphabetical nor the
        // order they were opened in (both tried and both wrong for a layout of thirds). Windows
        // that are not on screen have no place to read, so they follow, in the order opened.
        let (shownNow, away) = (onScreen.filter { $0.pid == pid } + rest).reduce(into: ([SwitchableWindow](), [SwitchableWindow]())) {
            if $1.isOffScreen { $0.1.append($1) } else { $0.0.append($1) }
        }
        let byPosition = shownNow.sorted {
            if abs($0.bounds.minX - $1.bounds.minX) > 1 { return $0.bounds.minX < $1.bounds.minX }
            if abs($0.bounds.minY - $1.bounds.minY) > 1 { return $0.bounds.minY < $1.bounds.minY }
            return $0.id < $1.id
        }
        return byPosition + away.sorted { $0.id < $1.id }
    }

    static func windows(of app: NSRunningApplication) -> [SwitchableWindow] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let pid = app.processIdentifier
        return appWindows(onScreen: switchable(windowInfo: info, regularPIDs: [pid]),
                          accessibility: WindowActivator.accessibilityWindows(of: pid),
                          pid: pid, appName: app.localizedName ?? "", appHidden: app.isHidden)
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

/// The last preview of every window, kept for whoever shows windows next (the switcher, the
/// Dock previews), so a tile opens on a picture rather than an icon and is refreshed in place.
/// A minimized window cannot be captured, so its last picture from when it was on screen is
/// the only one there is. Main thread only.
final class WindowPreviews {
    static let shared = WindowPreviews()
    static let maxSide: CGFloat = 220

    private var images: [CGWindowID: CGImage] = [:]

    func image(for id: CGWindowID) -> CGImage? { images[id] }

    /// Capture `ids` again; `each` gets every fresh picture as it arrives.
    func refresh(_ ids: [CGWindowID], each: ((CGWindowID, CGImage) -> Void)? = nil) {
        WindowThumbnails.capture(ids, maxSide: Self.maxSide) { [weak self] id, image in
            self?.images[id] = image
            each?(id, image)
        }
    }

    /// Drop pictures of windows that no longer exist anywhere (on any Space, minimized or not).
    func pruneClosed() {
        let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let alive = Set(all.compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } })
        images = images.filter { alive.contains($0.key) }
    }
}

/// What accessibility says about one window of an app.
struct AXWindowInfo: Equatable {
    let id: CGWindowID
    let title: String
    /// Top-left origin, as the window server's coordinates.
    let frame: CGRect
    var minimized = false
}

/// Windows tiled together: side by side, not overlapping, and between them filling a screen,
/// like three windows in thirds or two halves, whichever apps they belong to. macOS keeps no
/// public record of which windows were tiled together, so this reads it from where they are.
enum TileGroups {

    /// A window this far outside the screen's usable area still counts as inside it (shadows,
    /// a point of rounding).
    static let edgeTolerance: CGFloat = 16
    /// Overlap allowed between two members, as a share of the smaller one.
    static let maxOverlap: CGFloat = 0.02
    /// Members together must cover this much of the screen below the menu bar. Under 1 for
    /// margins around tiles, and for a Dock that is always shown (tiles stop above it).
    static let minCoverage: CGFloat = 0.85
    /// A member is at least this share of the screen: a tile, not a palette in a gap.
    static let minMemberShare: CGFloat = 0.08

    /// At most this many candidate windows are searched (the frontmost ones); the search is
    /// over combinations, and real layouts have a handful of tiles.
    static let maxCandidates = 12

    /// The tiled group `target` is part of, `target` first, then the others front to back; nil
    /// when it is not in one. `windows` front to back; `screens` are usable areas (window-server
    /// coordinates, menu bar and a fixed Dock left out). Pure, for tests.
    ///
    /// Of the windows on the same screen that do not overlap `target`, the combination that
    /// overlaps nothing within itself and covers the most of the screen wins; on a tie, the one
    /// nearer the front. Taking windows greedily front to back did not work: a third of another
    /// layout lying behind (Code at 1200-1800, beside TextEdit's left half) was taken first and
    /// then shut out the real partner (Finder's right half), leaving 83% and no group.
    static func group(containing target: CGWindowID, windows: [SwitchableWindow],
                      screens: [CGRect]) -> [SwitchableWindow]? {
        guard let first = windows.first(where: { $0.id == target }), !first.isOffScreen,
              let screen = screens.first(where: { $0.contains(CGPoint(x: first.bounds.midX, y: first.bounds.midY)) })
        else { return nil }
        let area = screen.width * screen.height
        let zone = screen.insetBy(dx: -edgeTolerance, dy: -edgeTolerance)
        func fits(_ w: SwitchableWindow) -> Bool {
            !w.isOffScreen && zone.contains(w.bounds)
                && w.bounds.width * w.bounds.height >= area * minMemberShare
        }
        func clear(_ a: SwitchableWindow, _ b: SwitchableWindow) -> Bool {
            let o = a.bounds.intersection(b.bounds)
            guard !o.isNull else { return true }
            let smaller = min(a.bounds.width * a.bounds.height, b.bounds.width * b.bounds.height)
            return o.width * o.height <= smaller * maxOverlap
        }
        func cover(_ w: SwitchableWindow) -> CGFloat {
            let o = w.bounds.intersection(screen)
            return o.isNull ? 0 : o.width * o.height
        }
        guard fits(first) else { return nil }
        // Candidates keep their front-to-back position, which is the tie-break.
        let candidates = Array(windows.enumerated()
            .filter { $0.element.id != target && fits($0.element) && clear($0.element, first) }
            .prefix(maxCandidates))

        var best: (members: [Int], covered: CGFloat, depth: Int) = ([], cover(first), 0)
        func search(_ from: Int, _ members: [Int], _ covered: CGFloat, _ depth: Int) {
            if covered > best.covered + 0.5 || (abs(covered - best.covered) <= 0.5 && depth < best.depth) {
                best = (members, covered, depth)
            }
            guard from < candidates.count else { return }
            for i in from..<candidates.count {
                let w = candidates[i].element
                guard members.allSatisfy({ clear(candidates[$0].element, w) }) else { continue }
                search(i + 1, members + [i], covered + cover(w), depth + candidates[i].offset)
            }
        }
        search(0, [], cover(first), 0)
        guard !best.members.isEmpty, best.covered >= area * minCoverage else { return nil }
        return [first] + best.members.map { candidates[$0].element }
    }

    /// Every screen below its menu bar, in window-server coordinates. NOT `visibleFrame`: that
    /// shrinks to make room for the Dock while the Dock is showing, even an auto-hiding one —
    /// which it is at the moment of a Dock click (measured: 1023 pt high instead of 1130), and
    /// full-height tiles then did not "fit" and no group was found.
    static func usableAreas() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { s in
            let f = s.frame
            let menuBar = f.maxY - s.visibleFrame.maxY
            return CGRect(x: f.minX, y: primaryHeight - f.maxY + menuBar, width: f.width, height: f.height - menuBar)
        }
    }
}

/// Bring one particular window to the front, app and all; or close it.
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
        let app = NSRunningApplication(processIdentifier: window.pid)
        if app?.isHidden == true { app?.unhide() }
        let element = axWindow(window)
        // A minimized window has to be back on screen before it can be brought forward.
        if let element, window.isOffScreen {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if !frontViaSkyLight(window) {
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
        }
        // Within the app, the chosen window over its siblings.
        guard let element else { return }
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

    /// Raise a window within the stack WITHOUT switching to its app. Measured: a raised window of
    /// an app that is not active lands just under the active app's front window, above all else
    /// — the place a tiled partner of the window just clicked belongs.
    static func raiseWithoutActivating(_ window: SwitchableWindow) {
        guard let element = axWindow(window) else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Press the window's own close button, as a click on it would: the app gets to ask
    /// about unsaved changes. False when the window has no close button to press.
    @discardableResult
    static func close(_ window: SwitchableWindow) -> Bool {
        guard let element = axWindow(window) else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Does the window have a close button to press? A dialog (TextEdit's Open panel, say) has
    /// none, and an ✕ on its tile would do nothing.
    static func canClose(_ window: SwitchableWindow) -> Bool {
        guard let element = axWindow(window) else { return false }
        var button: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success
            && button != nil
    }

    /// Every window accessibility lists for `pid`, minimized ones included.
    static func accessibilityWindows(of pid: pid_t) -> [AXWindowInfo] {
        guard let getWindow else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.map { element in
            var id: CGWindowID = 0
            _ = getWindow(element, &id)
            var title: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
            var origin = CGPoint.zero, extent = CGSize.zero
            if let position { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
            if let size { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            return AXWindowInfo(id: id, title: title as? String ?? "", frame: CGRect(origin: origin, size: extent),
                                minimized: minimized as? Bool ?? false)
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

    /// How long Command must be held after Tab before the panel appears. 10 ms on request
    /// (was 120): the panel should be there at once, and a tap quick enough to beat it only
    /// shows it for a moment while switching to the previous window.
    static let showDelay: TimeInterval = 0.01

    static let tab: Int64 = 48, escape: Int64 = 53, left: Int64 = 123, right: Int64 = 124

    private let settings: Settings
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var settingToken: AnyObject?
    private var retryTimer: Timer?
    private var showTimer: Timer?

    private(set) var isActive = false
    private var windows: [SwitchableWindow] = []
    private let previews = WindowPreviews.shared
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
        previews.pruneClosed()
        previews.refresh(WindowCatalog.current().map(\.id))
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
            self.panel.prepare(self.windows, selected: self.selection.index, previews: self.previews)
            self.previews.refresh(self.windows.map(\.id)) { [weak self] id, image in
                guard let self, self.isActive else { return }
                self.panel.setThumbnail(image, for: id)
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

    /// Bigger than the Dock popup's, with the same shape-following layout: a tall window gets a
    /// narrow tile and a wide one a wide tile, not a fixed square.
    static let shape = PreviewLayout(previewHeight: 150, minPreviewWidth: 70, maxPreviewWidth: 380,
                                     tileInset: 8, labelHeight: 18, spacing: 8, padding: 14, minScale: 0.4)

    var onClick: ((Int) -> Void)?

    private var window: NSPanel?
    private var tiles: [SwitcherTile] = []

    /// Lay the panel out, off screen until `reveal`.
    func prepare(_ windows: [SwitchableWindow], selected: Int?, previews: WindowPreviews) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let (frames, size) = Self.shape.layout(
            aspects: windows.map { $0.bounds.width / max(1, $0.bounds.height) },
            limit: CGSize(width: area.width * 0.9, height: area.height * 0.8))

        let panel = window ?? makePanel()
        window = panel
        let content = panel.contentView!
        tiles.forEach { $0.removeFromSuperview() }
        tiles = zip(windows.indices, zip(windows, frames)).map { i, pair in
            let (w, f) = pair
            // Flipped: the layout counts rows down from the top.
            let frame = NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
            let tile = SwitcherTile(frame: frame, window: w, icon: Self.appIcon(for: w.pid))
            if let image = previews.image(for: w.id) { tile.setThumbnail(image) }
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
    static func appIcon(for pid: pid_t) -> NSImage? {
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
        let labelHeight = SwitcherPanel.shape.labelHeight, inset = SwitcherPanel.shape.tileInset

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
