import AppKit
import PowerKit

// ── Beta Features → Menu Bar Backdrop ───────────────────────────────────────
//
// The controls for what sits behind the menu bar (see `MenuBarBackdrop`): which
// mode, how see-through the blur is, and — in the follow mode — whether macOS has
// allowed Anode to read the screen, with a way to the pane where that is taken
// back. They live in a menu rather than the Settings window because the feature is
// a beta one, and everything beta lives under Beta Features.
//
// Every control writes straight to `Settings`, and the backdrop observes it, so a
// choice shows on the bar at once. The submenu is refreshed as it opens
// (`menuNeedsUpdate`) rather than kept in step by hand: checkmarks, the slider's
// position and the permission line are all read from the stored truth at that
// moment, so a change made elsewhere — `defaults write`, or the permission being
// revoked in System Settings — cannot leave this menu stale.

final class BackdropMenu: NSObject, NSMenuDelegate {

    private let settings: Settings
    private let access: () -> Bool
    let item: NSMenuItem

    private var modeItems: [(mode: MenuBarBackdropMode, item: NSMenuItem)] = []
    private let slider = NSSlider(value: 0.3, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sliderLabel = NSTextField(labelWithString: "See-through")
    private let sliderItem = NSMenuItem()
    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let openItem = NSMenuItem(title: "Open Screen Recording Settings…",
                                      action: nil, keyEquivalent: "")
    private let separatorBeforePermission = NSMenuItem.separator()

    init(settings: Settings = .shared,
         screenRecordingAllowed: @escaping () -> Bool = { ScreenRecordingAccess.isGranted }) {
        self.settings = settings
        self.access = screenRecordingAllowed
        item = NSMenuItem(title: "Menu Bar Backdrop", action: nil, keyEquivalent: "")
        super.init()

        let menu = NSMenu(title: "Menu Bar Backdrop")
        menu.delegate = self
        for mode in MenuBarBackdropMode.allCases {
            let entry = NSMenuItem(title: mode.title, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode
            menu.addItem(entry)
            modeItems.append((mode, entry))
        }

        // A slider needs a view, and a view item has no title of its own.
        menu.addItem(.separator())
        slider.target = self
        slider.action = #selector(slid(_:))
        slider.isContinuous = true
        sliderLabel.font = .menuFont(ofSize: 0)
        let row = NSStackView(views: [sliderLabel, slider])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        row.frame = NSRect(x: 0, y: 0, width: 250, height: 28)
        sliderItem.view = row
        menu.addItem(sliderItem)

        menu.addItem(separatorBeforePermission)
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        openItem.target = self
        openItem.action = #selector(openScreenRecording)
        menu.addItem(openItem)

        item.submenu = menu
    }

    // ── Actions ─────────────────────────────────────────────────────────────

    @objc private func choose(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? MenuBarBackdropMode else { return }
        settings.menuBarBackdropMode = mode
    }

    @objc private func slid(_ sender: NSSlider) {
        settings.menuBarBackdropTranslucency = sender.doubleValue
    }

    @objc private func openScreenRecording() {
        ScreenRecordingAccess.openSettings()
    }

    // ── What the menu says ──────────────────────────────────────────────────

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    /// Everything the menu shows, derived from `Settings` and the permission. Split
    /// out so a test can run it without opening a menu.
    func refresh() {
        let mode = settings.menuBarBackdropMode
        for (m, entry) in modeItems { entry.state = m == mode ? .on : .off }

        // The slider belongs to the blur alone; in any other mode it would move
        // nothing, so it is shown greyed rather than hidden, so the menu keeps one shape.
        slider.doubleValue = settings.menuBarBackdropTranslucency
        slider.isEnabled = mode == .blur
        sliderLabel.textColor = mode == .blur ? .labelColor : .disabledControlTextColor

        let follow = mode == .solidFollow
        separatorBeforePermission.isHidden = !follow
        statusItem.isHidden = !follow
        openItem.isHidden = !follow
        statusItem.title = access()
            ? "Screen Recording: allowed"
            : "Screen Recording: not allowed — only Anode's own windows are matched"
    }
}
