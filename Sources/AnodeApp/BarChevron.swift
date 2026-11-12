import AppKit
import PowerKit

// ── The chevron (Menu Bar Hider) ────────────────────────────────────────────
//
// The one status item the hider adds, and the only one it never hides. A click toggles the pill (never hover); a right-click
// opens a small menu. The item exists only between `install()` and `remove()`: with the hider off nothing is created.

final class BarChevron: NSObject, ChevronPresenting {

    static let autosaveName = "AnodeHiderChevron"
    /// A tall, narrow "‹" (the hidden icons are to the left), in an item no wider than it: a square chevron took too much room.
    static let symbolName = "chevron.compact.left"
    static let length: CGFloat = 12

    var onToggle: (() -> Void)?
    /// Builds the right-click menu for the state of the moment.
    var menuProvider: (() -> NSMenu)?

    private var item: NSStatusItem?

    /// A status item can be refused (a dying WindowServer connection hands back one with no button): then there is no chevron
    /// and the owner reaches the settings through Anode's other items or its window.
    func install() {
        guard item == nil else { return }
        let created = NSStatusBar.system.statusItem(withLength: Self.length)
        guard let button = created.button else {
            NSStatusBar.system.removeStatusItem(created)
            return
        }
        created.autosaveName = Self.autosaveName
        // Explicitly visible, every time: macOS saves `isVisible` per autosave name (see `MenuBarWidgetController.rebuild`).
        created.isVisible = true
        let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: "Menu bar icons")
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel("Menu bar icons")
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item = created
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if isRight, let menu = menuProvider?() {
            // popUp, not `item.menu` plus `performClick`: that re-enters this very action from inside itself (the same
            // lesson as `MenuBarWidgetController.widgetClicked`).
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
        } else {
            onToggle?()
        }
    }

    // ── The menu ────────────────────────────────────────────────────────────

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static let autoCloseChoices: [(title: String, seconds: Int)] = [("5 seconds", 5), ("10 seconds", 10), ("30 seconds", 30), ("Never", 0)]

    /// Show or hide the icons, how long the pill stays open, and the way to the settings. Pure but for the items it makes.
    static func buildMenu(isOpen: Bool, autoClose: Int, onToggle: @escaping () -> Void,
                          onAutoClose: @escaping (Int) -> Void, onOpenBeta: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, to menu: NSMenu, _ run: @escaping () -> Void) -> NSMenuItem {
            let action = Action(run)
            let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action   // the menu item does not retain its target
            menu.addItem(item)
            return item
        }
        _ = add(isOpen ? "Hide icons" : "Show icons", to: menu, onToggle)

        let submenu = NSMenu()
        for choice in autoCloseChoices {
            let entry = add(choice.title, to: submenu) { onAutoClose(choice.seconds) }
            entry.state = choice.seconds == autoClose ? .on : .off
        }
        let parent = NSMenuItem(title: "Hide again after", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)

        menu.addItem(.separator())
        _ = add("Open Beta Features…", to: menu, onOpenBeta)
        return menu
    }
}
