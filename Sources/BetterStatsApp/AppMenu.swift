import AppKit

// ── Main menu ───────────────────────────────────────────────────────────────
//
// There is no nib, so nothing builds a menu bar unless this does — which is why
// the app shipped with one menu and seven missing ones.
//
// The Edit menu is the load-bearing part, not the cosmetic one. NSTextField does
// not implement copy or paste itself: ⌘C arrives as a key equivalent that
// NSApplication matches against `NSApp.mainMenu` and then sends to the first
// responder (the field editor) through the responder chain. With no Edit menu
// there was nothing to match, so ⌘C/⌘V/⌘X/⌘A did nothing anywhere in the app,
// including the Settings text fields where a retention value is typed.
//
// Menus cost nothing while closed: AppKit validates items only as a menu opens,
// so none of this touches the idle budget.

extension AppDelegate {

    func buildMenu() {
        let bar = NSMenu()
        bar.addItem(appMenuItem())
        bar.addItem(editMenuItem())
        bar.addItem(viewMenuItem())
        bar.addItem(settingsMenuItem())
        let windows = windowMenuItem()
        bar.addItem(windows)
        let help = helpMenuItem()
        if let help { bar.addItem(help) }

        NSApp.mainMenu = bar
        // These two tell AppKit which submenu to append the open-windows list to,
        // and which one to put the system's menu-item search field in. Assigned
        // after the bar is installed so AppKit is pointing at menus it already
        // owns. nil for help is the documented default (AppKit then looks for a
        // menu titled "Help"), so an omitted Help menu stays omitted.
        NSApp.windowsMenu = windows.submenu
        NSApp.helpMenu = help?.submenu
    }

    // ── App ─────────────────────────────────────────────────────────────────

    private func appMenuItem() -> NSMenuItem {
        submenu("BetterStats") { m in
            let about = NSMenuItem(title: "About BetterStats",
                                   action: #selector(showAbout(_:)), keyEquivalent: "")
            about.target = self
            m.addItem(about)
            m.addItem(.separator())

            // Settings is NOT here.
            //
            // macOS convention puts it in the app menu, and this deliberately
            // departs from that at the user's request: it lives in its own
            // top-level "Settings" menu beside View and Window, where it is
            // visible without opening anything. ⌘, still works, because the
            // shortcut moved with the item rather than being left behind.
            //
            // If this ever reverts to the convention, move the ⌘, item back —
            // do not leave one in both places. Two Settings entries is worse
            // than either position, because the user then has to learn which
            // one is real.
            m.addItem(withTitle: "Hide BetterStats",
                      action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let hideOthers = NSMenuItem(title: "Hide Others",
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
            hideOthers.keyEquivalentModifierMask = [.command, .option]
            m.addItem(hideOthers)
            m.addItem(withTitle: "Show All",
                      action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            m.addItem(.separator())

            m.addItem(withTitle: "Quit BetterStats",
                      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
    }

    // ── Settings ────────────────────────────────────────────────────────────

    /// Settings as a TOP-LEVEL menu, beside View and Window.
    ///
    /// A departure from the macOS convention of burying it in the app menu, made
    /// deliberately: this app's settings are not incidental — which widgets are
    /// bound, what the sample interval is, how long history is kept — and a user
    /// looking for them should see the word without opening a menu first.
    ///
    /// It carries a submenu rather than acting as a bare clickable title because
    /// AppKit does not route clicks to a top-level item that has no submenu: such
    /// an item renders but cannot be invoked. So "Settings ▸ Open Settings… ⌘,"
    /// is the shape that actually works, and ⌘, is still the shortcut.
    private func settingsMenuItem() -> NSMenuItem {
        submenu("Settings") { m in
            let open = NSMenuItem(title: "Open Settings…",
                                  action: #selector(openPrefs), keyEquivalent: ",")
            open.target = self
            m.addItem(open)
        }
    }

    // ── Edit ────────────────────────────────────────────────────────────────

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = EditMenu.make()
        return item
    }

    // ── View ────────────────────────────────────────────────────────────────

    private func viewMenuItem() -> NSMenuItem {
        submenu("View") { m in
            var previousWasPerProcess = true
            for (lens, key) in ViewMenu.lensItems {
                // Mirror the rail's own break between its two groups rather than
                // separating at a fixed index, which would drift the first time a
                // lens is added.
                if lens.isPerProcess != previousWasPerProcess {
                    m.addItem(.separator())
                    previousWasPerProcess = lens.isPerProcess
                }
                let item = NSMenuItem(title: lens.title,
                                      action: #selector(showLens(_:)), keyEquivalent: key)
                item.target = self
                // The lens travels ON the item, so nothing has to map a title or a
                // tag back to a case.
                item.representedObject = lens
                m.addItem(item)
            }
        }
    }

    /// Switch lens from the keyboard. Ends with the window visible and showing it,
    /// exactly like clicking the rail row.
    @objc func showLens(_ sender: NSMenuItem) {
        guard let lens = sender.representedObject as? SidebarView.Lens else { return }
        // Through the rail rather than straight into select(), for the reason
        // openFromWidget gives: the rail owns `selected` and the highlight, so
        // switching around it leaves the old row lit beside the new content.
        main.sidebar.select(lens)
        guard !main.window.isVisible else { return }
        main.show()
        // Hidden windows sample at `hiddenInterval`, so without this the lens just
        // opened can sit on values several seconds stale.
        restartTimer(hidden: false)
    }

    // ── Window ──────────────────────────────────────────────────────────────

    private func windowMenuItem() -> NSMenuItem {
        submenu("Window") { m in
            // Responder-chain actions again: these act on the key window, whichever
            // one that is, so Settings gets ⌘M and ⌘W for free.
            m.addItem(withTitle: "Minimise",
                      action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Close",
                      action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            m.addItem(.separator())

            // Closing the window does not quit — the app keeps running in the menu
            // bar (`applicationShouldTerminateAfterLastWindowClosed` is false) and
            // AppKit removes a closed window from the list below, so without this
            // the Window menu would be the one place that could not get it back.
            let reopen = NSMenuItem(title: "BetterStats Window",
                                    action: #selector(showMainWindow(_:)), keyEquivalent: "0")
            reopen.target = self
            m.addItem(reopen)
            m.addItem(withTitle: "Bring All to Front",
                      action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        }
    }

    /// Reopen the main window.
    ///
    /// IMPORTANT, because this reads as broken and is not: ⌘0 CANNOT bring the
    /// window back after the LAST window closes. `MainWindowController.hide()`
    /// drops the app to `.accessory`, which is deliberate — an app with no window
    /// has no business holding a Dock tile — but `.accessory` also removes the
    /// application's menu bar, so there is no menu for the key equivalent to
    /// reach. The keystroke goes to whatever app is frontmost instead.
    ///
    /// So this item is useful only while ANOTHER BetterStats window is open, in
    /// practice Settings. The route back from menu-bar-only is clicking a menu
    /// bar widget, which opens the window at the lens that widget names.
    ///
    /// Do not "fix" this by keeping the app `.regular` — that reinstates the Dock
    /// tile that made a closed window feel like a running app, which is the thing
    /// `hide()` exists to prevent.
    @objc func showMainWindow(_ sender: Any?) {
        main.show()
        restartTimer(hidden: false)   // same staleness argument as showLens
    }

    // ── Help ────────────────────────────────────────────────────────────────

    /// nil when no document can be found, so the menu is absent rather than
    /// present-and-dead. See `Documentation` for where it looks and why.
    private func helpMenuItem() -> NSMenuItem? {
        let found = Documentation.pages.compactMap { page -> (String, URL)? in
            Documentation.url(for: page.file).map { (page.title, $0) }
        }
        guard !found.isEmpty else { return nil }
        return submenu("Help") { m in
            for (title, url) in found {
                let item = NSMenuItem(title: title,
                                      action: #selector(openDocumentation(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                m.addItem(item)
            }
        }
    }

    @objc func openDocumentation(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // ── About ───────────────────────────────────────────────────────────────

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(
            options: AboutPanel.options(info: Bundle.main.infoDictionary ?? [:]))
    }

    @objc func openPrefs() { PreferencesWindowController.shared.show() }

    // ── Building blocks ─────────────────────────────────────────────────────

    /// A top-level bar item and its submenu. The bar item's own title is never
    /// drawn — AppKit takes each menu's name from its submenu — but the submenu
    /// title is what `NSApp.helpMenu`'s fallback and VoiceOver read.
    private func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showLens(_:)):
            // A tick beside the lens on screen, so the menu answers "where am I"
            // as well as "where can I go".
            item.state = (item.representedObject as? SidebarView.Lens) == lens ? .on : .off
        case #selector(openDocumentation(_:)):
            // The file was there when the menu was built; a checkout can move or a
            // doc can be deleted while the app runs. Greying out beats opening
            // nothing. One stat() per doc, only as the menu opens.
            guard let url = item.representedObject as? URL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        default:
            break
        }
        return true
    }
}

// ── Edit menu contents ──────────────────────────────────────────────────────

/// The standard editing commands.
///
/// Free of AppDelegate on purpose: every item routes through the responder chain
/// and none of them needs the app object, which also means the wiring can be
/// asserted in a test without an app to run it in.
enum EditMenu {

    static func make() -> NSMenu {
        let m = NSMenu(title: "Edit")
        // Every item here keeps target nil ON PURPOSE. A nil target sends the
        // action down the responder chain to whatever is actually focused, so one
        // Edit menu serves the main window, the Settings text fields and any window
        // added later. Giving these a target would bind them to that one object,
        // and paste would stop working the moment focus moved.
        //
        // undo:/redo: are spelled as strings because no AppKit class Swift can name
        // declares them — they arrive at NSUndoManager through the responder chain
        // — so #selector has nothing to check them against.
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(undo)
        m.addItem(redo)
        m.addItem(.separator())

        m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Select All",
                  action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return m
    }
}

// ── View menu contents ──────────────────────────────────────────────────────

enum ViewMenu {
    /// What the View menu lists, in order, and the key that gets there.
    ///
    /// Derived from `SidebarView.Lens.displayOrder` — the same array the rail
    /// builds its rows from — so a new lens appears in both places or in neither.
    /// Nothing here knows how many lenses exist or which ones they are.
    ///
    /// ⌘1…⌘9 top to bottom. There is no ⌘10, so a tenth lens gets an item with no
    /// shortcut rather than one that collides with something else.
    static var lensItems: [(lens: SidebarView.Lens, key: String)] {
        SidebarView.Lens.displayOrder.enumerated().map { index, lens in
            (lens, index < 9 ? String(index + 1) : "")
        }
    }
}

// ── Documentation ───────────────────────────────────────────────────────────

/// Where the project's own docs can be found AT RUNTIME.
///
/// README.md and TESTING.md live in the repo. `build-app.sh` copies only the
/// binary and the icon into the bundle, so a shipped BetterStats.app contains
/// neither, and the GitHub remote (noahahoward/betterstats) is PRIVATE — checked:
/// an unauthenticated GET of the repo and of the raw README both return 404. A
/// Help item pointing there would open a "not found" page for every tester who is
/// not the author, which is the silent failure this app's rules exist to prevent.
///
/// So the item is offered only where the file genuinely is:
///   1. the bundle's Resources — nothing puts it there today, but that is where
///      documentation belongs, and two `cp` lines in build-app.sh would make the
///      Help menu work in a shipped bundle with no change here;
///   2. the source checkout, which is where a `swift build` binary runs from.
/// Neither hit means no Help menu at all.
enum Documentation {

    /// Offered in this order.
    static let pages: [(title: String, file: String)] = [
        ("BetterStats README", "README.md"),
        ("Testing Notes", "TESTING.md"),
    ]

    static func url(for file: String,
                    bundle: Bundle = .main,
                    fileManager: FileManager = .default) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        if let inBundle = bundle.url(forResource: name, withExtension: ext) {
            return inBundle
        }
        // `bundleURL` is the .app for a bundled build and the directory holding the
        // executable for a bare one, so this starts at the right place either way.
        return checkoutURL(for: file, near: bundle.bundleURL, fileManager: fileManager)
    }

    /// Walk up from `start` for the source checkout: the first directory holding
    /// BOTH Package.swift and the doc.
    ///
    /// The Package.swift anchor is the whole point. Ascending until any README.md
    /// turns up would happily match one belonging to an unrelated parent — the
    /// installed bundle sits in ~/Applications, and a stray README beside it is not
    /// this app's documentation.
    ///
    /// `maxDepth` bounds the stat() walk. `.build/<triple>/<config>/` is three
    /// levels down from the checkout root, so eight is slack, not a limit anyone
    /// will meet.
    static func checkoutURL(for file: String, near start: URL,
                            fileManager: FileManager = .default,
                            maxDepth: Int = 8) -> URL? {
        var dir = start
        for _ in 0..<maxDepth {
            let doc = dir.appendingPathComponent(file)
            if fileManager.fileExists(atPath: dir.appendingPathComponent("Package.swift").path),
               fileManager.fileExists(atPath: doc.path) {
                return doc
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // reached the root
            dir = parent
        }
        return nil
    }
}

// ── About ───────────────────────────────────────────────────────────────────

/// The standard About panel, plus the one fact it cannot find on its own.
///
/// Version and build need no help: the panel reads CFBundleShortVersionString and
/// CFBundleVersion out of Info.plist itself, so passing them back as options
/// would change nothing. BSSourceCommit is ours and the panel has never heard of
/// it — and that is the field that matters here, because there is no update
/// mechanism and a tester may be running anything. The short hash makes "which
/// build is that?" answerable without a terminal.
enum AboutPanel {

    static func options(info: [String: Any]) -> [NSApplication.AboutPanelOptionKey: Any] {
        guard let text = creditsText(info: info) else { return [:] }
        let credits = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return [.credits: credits]
    }

    /// nil when the bundle cannot say what it was built from — a `swift run`
    /// binary has no Info.plist at all.
    static func creditsText(info: [String: Any]) -> String? {
        // "unknown" is what build-app.sh writes when git could not be read. A panel
        // stating the source is unknown says less than one that does not raise the
        // subject.
        guard let commit = info["BSSourceCommit"] as? String,
              !commit.isEmpty, commit != "unknown" else { return nil }
        var lines = ["Source commit \(commit)"]
        // build-app.sh appends "+" when `git diff --quiet HEAD` failed, so the
        // bundle contains changes that are in no commit and the hash alone does not
        // identify it. Nobody reading a hash knows that unless it is said.
        if commit.hasSuffix("+") {
            lines.append("Built from a modified working tree, so the commit does "
                       + "not describe this build exactly.")
        }
        return lines.joined(separator: "\n")
    }
}
