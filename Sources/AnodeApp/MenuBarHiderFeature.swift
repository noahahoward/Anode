import AppKit
import PowerKit

// ── Menu Bar Hider (Beta Features) ──────────────────────────────────────────
//
// The switch, the two lists (on the bar / behind the chevron, drag and drop between and within them), how long the pill stays
// open, and what is missing if the hider cannot work. Every control writes straight to `Settings`; the controller observes it.

/// One of the two lists. Rows are `BarItem`s; a row can be dragged (unless it is locked) and dropped into either list.
final class BarListSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    static let pasteboardType = NSPasteboard.PasteboardType("dev.anode.menubarhider.item")

    let group: BarGroup
    var rows: [BarItem] = []
    var onDrop: ((_ key: String, _ group: BarGroup, _ row: Int) -> Void)?
    var isDraggable: (String) -> Bool = { _ in true }

    init(group: BarGroup) { self.group = group }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: BarPictures.appIcon(for: item))
        icon.frame = NSRect(x: 4, y: 3, width: 16, height: 16)
        let label = NSTextField(labelWithString: item.title.isEmpty ? item.appName : "\(item.title) · \(item.appName)")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = item.isLocked ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 26, y: 3, width: 170, height: 16)
        cell.addSubview(icon)
        cell.addSubview(label)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), isDraggable(rows[row].key) else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].key, forType: Self.pasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: Self.pasteboardType) != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let key = info.draggingPasteboard.string(forType: Self.pasteboardType) else { return false }
        onDrop?(key, group, row)
        return true
    }
}

final class MenuBarHiderFeature: BetaFeature {

    let title = "Menu Bar Hider"
    let summary = "Folds the menu bar down to the icons you pick (battery, sound and Wi-Fi to begin with) and a chevron. "
                + "Press the chevron, or the shortcut, and every other icon appears in a small panel under the notch, "
                + "each one clickable. Needs Accessibility to read the bar."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let itemsProvider: () -> [BarItem]
    private let accessibility: () -> Bool
    private let screenRecording: () -> Bool
    private let statusProvider: () -> String?

    let enableCheckbox = NSButton(checkboxWithTitle: "Fold the menu bar behind a chevron", target: nil, action: nil)
    let autoClosePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let statusLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let accessibilityButton = NSButton(title: "Open Accessibility settings", target: nil, action: nil)
    let screenRecordingButton = NSButton(title: "Open Screen Recording settings", target: nil, action: nil)
    let coverNote = BetaFeaturesWindowController.wrapping(
        "The cover over hidden icons is plain black, which matches a black menu bar. On a coloured or see-through bar it may show. "
        + "An icon macOS has moved off the bar for lack of room opens its menu in the top-left corner of the screen when you "
        + "press it in the panel: macOS offers no way to open it anywhere else.",
        color: .secondaryLabelColor)
    let shortcutNote = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    private let onBarSource = BarListSource(group: .onBar)
    private let behindSource = BarListSource(group: .behindChevron)
    private var observers: [AnyObject] = []
    private let onBarTable = NSTableView()
    private let behindTable = NSTableView()

    init(settings: Settings = .shared,
         items: @escaping () -> [BarItem] = { MenuBarHiderController.current?.allItems ?? [] },
         accessibilityAllowed: @escaping () -> Bool = { AccessibilityAccess.isTrusted },
         screenRecordingAllowed: @escaping () -> Bool = { ScreenRecordingAccess.isGranted },
         status: @escaping () -> String? = { MenuBarHiderFeature.describe(MenuBarHiderController.current?.decision) }) {
        self.settings = settings
        self.itemsProvider = items
        self.accessibility = accessibilityAllowed
        self.screenRecording = screenRecordingAllowed
        self.statusProvider = status
        // Follows the settings and the controller itself, so a change made from the chevron's menu, or the lists filling in a
        // second after the switch goes on, show without the window being brought forward.
        for key in [Settings.Key.menuBarHiderEnabled, Settings.Key.menuBarHiderArrangement, Settings.Key.menuBarHiderAutoCloseSeconds] {
            observers.append(settings.observe(key) { [weak self] in self?.refresh() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: MenuBarHiderController.didChange, object: nil, queue: .main) {
            [weak self] _ in self?.refresh()
        })
    }

    deinit {
        for case let token as NSObjectProtocol in observers { NotificationCenter.default.removeObserver(token) }
    }

    // ── Pure parts ──────────────────────────────────────────────────────────

    /// The two lists: on the bar (the pinned items in their order, then the locked ones: the clock and Control Center, which
    /// are always there) and behind the chevron (in the pill's order).
    static func rows(for arrangement: BarArrangement, items: [BarItem]) -> (onBar: [BarItem], behind: [BarItem]) {
        let pinned = arrangement.pinned.compactMap { key in items.first { $0.key == key && !$0.isLocked } }
        let locked = items.filter(\.isLocked)
        return (pinned + locked, arrangement.pillItems(from: items))
    }

    static func describe(_ decision: HiderDecision?) -> String? {
        guard let decision else { return nil }
        switch decision {
        case .collapsed: return "On: the menu bar is folded."
        case .standDown(let why):
            switch why {
            case .disabled: return nil
            case .noAccessibility: return "Waiting for Accessibility: Anode cannot read the menu bar without it."
            case .layoutUnreadable: return "The menu bar could not be read just now; nothing is covered."
            case .fullScreen: return "Paused while an app is full screen."
            case .settling: return "Paused for a moment while the screen settles."
            case .itemsNotOnThisScreen: return "The menu bar icons are not on this screen, so nothing is covered."
            case .chevronOffBar:
                return "The chevron has no room on the menu bar, so nothing is hidden. Remove an icon or two and turn this off and on again."
            }
        }
    }

    private var arrangement: BarArrangement {
        settings.menuBarHiderArrangement ?? BarArrangement.defaultArrangement(for: itemsProvider())
    }

    var onBarKeys: [String] { onBarSource.rows.map(\.key) }
    var behindKeys: [String] { behindSource.rows.map(\.key) }

    func isDraggable(key: String) -> Bool {
        itemsProvider().first { $0.key == key }.map { !$0.isLocked } ?? false
    }

    /// What the table's drop handler does: put `key` into `group` at table row `row`. Locked and unknown items do not move.
    func handleDrop(key: String, to group: BarGroup, at row: Int) {
        let items = itemsProvider()
        guard let item = items.first(where: { $0.key == key }), !item.isLocked else { return }
        let current = arrangement
        let lists = Self.rows(for: current, items: items)
        let index: Int
        switch group {
        case .behindChevron:
            let was = lists.behind.firstIndex { $0.key == key }
            index = was.map { $0 < row ? row - 1 : row } ?? row
        case .onBar:
            // The table counts the locked items too; the pinned list does not.
            let above = lists.onBar.prefix(max(row, 0))
            index = above.filter { !$0.isLocked }.count - (above.contains { $0.key == key } ? 1 : 0)
        }
        settings.menuBarHiderArrangement = current.moving(key, to: group, at: index, items: items)
        refresh()
    }

    // ── View ────────────────────────────────────────────────────────────────

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled)
        autoClosePopup.removeAllItems()
        autoClosePopup.addItems(withTitles: BarChevron.autoCloseChoices.map(\.title))
        autoClosePopup.target = self
        autoClosePopup.action = #selector(autoCloseChosen)
        for button in [accessibilityButton, screenRecordingButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        accessibilityButton.action = #selector(openAccessibility)
        screenRecordingButton.action = #selector(openScreenRecording)

        for (source, table) in [(onBarSource, onBarTable), (behindSource, behindTable)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
            column.width = 200
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = 22
            table.dataSource = source
            table.delegate = source
            table.registerForDraggedTypes([BarListSource.pasteboardType])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.draggingDestinationFeedbackStyle = .gap
            source.onDrop = { [weak self] key, group, row in self?.handleDrop(key: key, to: group, at: row) }
            source.isDraggable = { [weak self] key in self?.isDraggable(key: key) ?? false }
        }
        func column(_ title: String, _ table: NSTableView) -> NSStackView {
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: 205).isActive = true
            let caption = NSTextField(labelWithString: title)
            caption.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            let stack = NSStackView(views: [caption, scroll])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            return stack
        }
        let lists = NSStackView(views: [column("Always on the bar", onBarTable), column("Behind the chevron", behindTable)])
        lists.spacing = 10
        lists.alignment = .top
        let closeRow = NSStackView(views: [NSTextField(labelWithString: "Hide again after"), autoClosePopup])
        closeRow.spacing = 8
        let stack = NSStackView(views: [enableCheckbox, statusLabel, accessibilityButton, screenRecordingButton, lists, closeRow,
                                        shortcutNote, coverNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        refresh()
        return stack
    }

    @objc private func enableToggled() {
        let on = enableCheckbox.state == .on
        settings.menuBarHiderEnabled = on
        if on && !accessibility() { AccessibilityAccess.request() }
        refresh()
    }

    @objc private func autoCloseChosen() {
        let index = autoClosePopup.indexOfSelectedItem
        guard BarChevron.autoCloseChoices.indices.contains(index) else { return }
        settings.menuBarHiderAutoCloseSeconds = BarChevron.autoCloseChoices[index].seconds
    }

    @objc private func openAccessibility() { AccessibilityAccess.openSettings() }
    @objc private func openScreenRecording() { ScreenRecordingAccess.openSettings() }

    func refresh() {
        let on = settings.menuBarHiderEnabled
        enableCheckbox.state = on ? .on : .off
        let seconds = settings.menuBarHiderAutoCloseSeconds
        autoClosePopup.selectItem(at: BarChevron.autoCloseChoices.firstIndex { $0.seconds == seconds } ?? 1)

        let trusted = accessibility()
        let captured = screenRecording()
        accessibilityButton.isHidden = !on || trusted
        screenRecordingButton.isHidden = !on || captured
        if !on {
            statusLabel.stringValue = "Off."
        } else if !trusted {
            statusLabel.stringValue = "Needs Accessibility: without it Anode cannot read the menu bar, so it will not cover anything."
        } else if !captured {
            statusLabel.stringValue = (statusProvider() ?? "On.") + " Without Screen Recording the panel shows each app's icon instead of the icon itself."
        } else {
            statusLabel.stringValue = statusProvider() ?? "On."
        }
        statusLabel.textColor = on && !trusted ? .systemOrange : .secondaryLabelColor
        let key = (ShortcutStore.shared.shortcut(for: ShortcutCommands.hiderToggle) ?? ShortcutCommands.hiderToggle.defaultShortcut).label
        shortcutNote.stringValue = "\(key) shows or hides the icons too, and so does a right-click on the chevron."

        let lists = Self.rows(for: arrangement, items: itemsProvider())
        onBarSource.rows = lists.onBar
        behindSource.rows = lists.behind
        onBarTable.reloadData()
        behindTable.reloadData()
        layoutChanged?()
    }
}
