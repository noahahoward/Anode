import AppKit
import ScreenCaptureKit
import PowerKit

// ── The pill (Menu Bar Hider) ───────────────────────────────────────────────
//
// A small floating panel under the notch holding every icon behind the chevron. It shows and forwards; it never replaces an
// app's own menu. Each cell is a picture of the real icon (cut out of one capture of the bar, taken with Anode's own windows
// left out so the covers do not paint over what is under them), or the app's icon when the real one cannot be captured (an
// item macOS has parked off the bar, no Screen Recording, macOS 13). Anode's own widgets are drawn by Anode with live readings.

enum BarPictures {

    enum Source: Equatable { case capture, appIcon }

    /// A picture is cut out of the capture only for an item that is on a bar and when a capture can be taken.
    static func source(for item: BarItem, screens: [CGRect], captureAvailable: Bool) -> Source {
        captureAvailable && item.isOnBar(screens: screens) ? .capture : .appIcon
    }

    /// Where an item sits inside a capture of the bar taken at `scale` pixels per point, the capture starting at `bandOrigin`
    /// (top-left global points). In pixels, clamped to the image; empty when the item is not in the capture.
    static func crop(imageSize: CGSize, itemFrame: CGRect, bandOrigin: CGPoint, scale: CGFloat) -> CGRect {
        let px = CGRect(x: (itemFrame.minX - bandOrigin.x) * scale, y: (itemFrame.minY - bandOrigin.y) * scale,
                        width: itemFrame.width * scale, height: itemFrame.height * scale)
        let inside = px.intersection(CGRect(origin: .zero, size: imageSize))
        return inside.isNull ? .zero : inside
    }

    static var captureAvailable: Bool {
        if #available(macOS 14.0, *) { return ScreenRecordingAccess.isGranted }
        return false
    }

    static func appIcon(for item: BarItem) -> NSImage {
        let icon = item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        return icon
    }

    /// Set on the hider's covers and pill, so a capture of the bar can leave out exactly those.
    static let hiderWindowIdentifier = "dev.anode.menuBarHider"

    /// The window numbers to leave out of a capture: the hider's own covers and pill, and nothing else of Anode's. The
    /// menu bar backdrop must stay in, because on a bar it paints black it IS the bar's colour.
    static func windowsToLeaveOut(_ windows: [(number: Int, identifier: String?)]) -> Set<CGWindowID> {
        Set(windows.filter { $0.identifier == hiderWindowIdentifier && $0.number > 0 }.map { CGWindowID($0.number) })
    }

    /// One capture of the bar band of the display carrying `screen` (top-left global points), the windows in `leavingOut`
    /// (the hider's covers and pill) left out.
    /// Never called without Screen Recording granted: asking without it puts a permission dialog on the owner's screen.
    @available(macOS 14.0, *)
    static func captureBand(of screen: CGRect, height: CGFloat,
                            leavingOut: Set<CGWindowID>) async -> (image: CGImage, origin: CGPoint, scale: CGFloat)? {
        guard ScreenRecordingAccess.isGranted else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.frame.intersects(screen) }) else { return nil }
            let hidden = content.windows.filter { leavingOut.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: hidden)
            let config = SCStreamConfiguration()
            let scale: CGFloat = 2
            config.sourceRect = CGRect(x: 0, y: 0, width: display.frame.width, height: height)
            config.width = Int(display.frame.width * scale)
            config.height = Int(height * scale)
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, display.frame.origin, scale)
        } catch {
            return nil
        }
    }
}

/// One icon in the pill. A click anywhere on it presses the real item.
final class PillCell: NSView {
    let item: BarItem
    private let imageView = NSImageView()
    var onPress: ((BarItem) -> Void)?

    init(item: BarItem, frame: NSRect) {
        self.item = item
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        imageView.imageScaling = .scaleProportionallyDown
        imageView.frame = bounds.insetBy(dx: 4, dy: 3)
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title.isEmpty ? item.appName : item.title)
        toolTip = item.title.isEmpty ? item.appName : item.title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setPicture(_ image: NSImage?) {
        imageView.image = image
        imageView.contentTintColor = .white   // a template picture (Anode's own widgets) is drawn white on the dark pill
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(item) }
    }
}

private final class PillContent: NSVisualEffectView {
    override var isFlipped: Bool { true }
}

final class BarPillWindow: PillPresenting {

    static let cell = CGSize(width: 40, height: 30)
    static let maxWidth: CGFloat = 520
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 6

    /// The picture for one of Anode's own widgets, by its metric id; nil draws Anode's icon.
    var anodeImage: (String) -> NSImage? = { _ in nil }
    /// A click outside the pill.
    var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private var cells: [PillCell] = []
    private var clickMonitor: Any?
    private var generation = 0
    private var screenTopLeft = CGRect.zero

    var isShowing: Bool { panel?.isVisible ?? false }

    func show(items: [BarItem], origin: CGPoint?, press: @escaping (BarItem) -> Void) {
        generation += 1
        let layout = PillLayout.frames(count: items.count, cell: Self.cell, maxWidth: Self.maxWidth,
                                       padding: Self.padding, spacing: Self.spacing)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let content = panel.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        cells = []
        for (item, frame) in zip(items, layout.cells) {
            let cell = PillCell(item: item, frame: frame)
            cell.onPress = press
            content.addSubview(cell)
            cells.append(cell)
        }
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        let topLeft = origin ?? CGPoint(x: (screens.first?.frame.midX ?? 0) - layout.size.width / 2, y: 40)
        screenTopLeft = CGRect(x: 0, y: 0, width: screens.first?.frame.width ?? 0, height: primaryHeight)
        panel.setFrame(NSRect(x: topLeft.x, y: primaryHeight - topLeft.y - layout.size.height,
                              width: layout.size.width, height: layout.size.height), display: true)
        panel.orderFrontRegardless()
        installMonitor()
        loadPictures(for: items, generation: generation)
    }

    func hide() {
        generation += 1
        panel?.orderOut(nil)
        cells = []
        removeMonitor()
    }

    /// Redraw Anode's own widgets with the readings of the moment (the pill stays up for seconds).
    func refreshAnodeCells() {
        for cell in cells where cell.item.key.hasPrefix(MenuBarWidgetController.key(forMetricID: "")) {
            let id = String(cell.item.key.dropFirst(MenuBarWidgetController.key(forMetricID: "").count))
            cell.setPicture(anodeImage(id) ?? BarPictures.appIcon(for: cell.item))
        }
    }

    // ── Pictures ────────────────────────────────────────────────────────────

    private func loadPictures(for items: [BarItem], generation gen: Int) {
        let screens = NSScreen.screens.map { screen -> CGRect in
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        let capturable = BarPictures.captureAvailable
        // Everything gets its fallback at once; captures replace the ones that can be taken.
        for cell in cells {
            if cell.item.hasPress == false && cell.item.bundleID == "dev.anode.app" {
                cell.setPicture(anodeImage(String(cell.item.key.dropFirst(MenuBarWidgetController.key(forMetricID: "").count))) ?? BarPictures.appIcon(for: cell.item))
            } else {
                cell.setPicture(BarPictures.appIcon(for: cell.item))
            }
        }
        guard capturable, #available(macOS 14.0, *) else { return }
        let wanted = items.filter { BarPictures.source(for: $0, screens: screens, captureAvailable: true) == .capture }
        guard !wanted.isEmpty, let band = screens.first(where: { s in wanted.contains { $0.frame.intersects(s) } }) else { return }
        let leaveOut = BarPictures.windowsToLeaveOut(NSApp.windows.map { (number: $0.windowNumber, identifier: $0.identifier?.rawValue) })
        Task { [weak self] in
            guard let shot = await BarPictures.captureBand(of: band, height: 40, leavingOut: leaveOut) else { return }
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                for cell in self.cells where wanted.contains(where: { $0.key == cell.item.key }) {
                    let r = BarPictures.crop(imageSize: CGSize(width: shot.image.width, height: shot.image.height),
                                             itemFrame: cell.item.frame, bandOrigin: shot.origin, scale: shot.scale)
                    guard !r.isEmpty, let piece = shot.image.cropping(to: r) else { continue }
                    cell.setPicture(NSImage(cgImage: piece, size: NSSize(width: r.width / shot.scale, height: r.height / shot.scale)))
                }
            }
        }
    }

    // ── Window ──────────────────────────────────────────────────────────────

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.hidesOnDeactivate = false
        p.level = .popUpMenu
        p.identifier = NSUserInterfaceItemIdentifier(BarPictures.hiderWindowIdentifier)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        let content = PillContent(frame: p.contentLayoutRect)
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        p.contentView = content
        return p
    }

    private func installMonitor() {
        guard clickMonitor == nil else { return }
        // A global monitor sees only clicks in OTHER apps' windows and the system's; a click in the pill is Anode's own and does
        // not come here. A click on the chevron DOES (macOS 27 draws status items in MenuBarAgent): the controller treats the
        // toggle that follows at once as the same click (`MenuBarHiderController.sameClickSeconds`).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.onDismiss?()
        }
    }

    private func removeMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}
