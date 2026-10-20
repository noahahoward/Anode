import AppKit

// THE MENU BAR KEEPS macOS's OWN INKS, and that is not an oversight.
//
// Everything inside the window draws from `Palette`, which is this app's design
// and is tuned to its near-black ground. A status item is not on that ground: it
// sits in the menu bar, whose tint follows the wallpaper behind it and inverts
// with the system appearance independently of anything here. `labelColor` and
// its siblings are the only inks that track that, which is why they are correct
// here and wrong in every other file.
//
// The one real exception is `NSColor.black` on the battery fill, which is a
// deliberate contrast pick against a bright fill rather than a semantic colour.
import PowerKit

// Menu bar widgets, bound to metrics by ID.
//
// The design constraint: a widget is (metric ID, style), nothing else. Every metric
// the registry ever gains is automatically available to every style with no new
// widget code. Configs are persisted, so the ID string is the durable contract; a
// widget bound to an ID this build no longer knows must render a neutral placeholder
// and NEVER crash or block the other widgets — the user is replacing Stats precisely
// because it "often breaks on startup".
//
// Colour rule: semantic colours only (label/secondaryLabel/system*), resolved at
// draw time so both light and dark menu bars stay legible. Never a hardcoded grey.

public enum WidgetStyle: String, Codable, CaseIterable {
    /// One slot that expands to a panel of every metric. Keeps the bar to a
    /// single item without losing anything.
    case group
    case text, textWithLabel, bar, sparkline, dot

    /// Tolerant decode: a style written by a newer build (or hand-edited plist) falls
    /// back to .text instead of throwing and taking the whole config array with it.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = WidgetStyle(rawValue: raw) ?? .text
    }
}

public struct WidgetConfig: Codable, Equatable {
    public var metricID: String
    public var style: WidgetStyle
    public var enabled: Bool

    public init(metricID: String, style: WidgetStyle = .text, enabled: Bool = true) {
        self.metricID = metricID
        self.style = style
        self.enabled = enabled
    }

    /// Per-field tolerance: only metricID is required. Damage to one field degrades
    /// that field, not the widget; damage to one array element must not nuke startup.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metricID = try c.decode(String.self, forKey: .metricID)
        style = (try? c.decode(WidgetStyle.self, forKey: .style)) ?? .text
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }
}

public final class MenuBarWidgetController: NSObject, NSMenuDelegate {

    public static let defaultsKey = "com.anode.menubar.widgets.v1"

    /// Is the group panel on screen right now?
    ///
    /// The app knew only window-visible vs hidden, and an open panel is neither: it
    /// is a reader looking at a surface the hidden path is explicitly built for
    /// nobody to be looking at. Both halves of that cost showed up in one
    /// screenshot — CPU temperature, GPU temperature and Fan speed reading "—"
    /// while every other row carried a figure, on a machine with two working fans.
    ///
    /// Written on the main thread by the delegate callbacks and read on the main
    /// thread by `AppDelegate.refresh`, which is where visibility is already read
    /// for the same reason.
    public internal(set) var isPanelOpen = false

    /// Called when that changes, so the tick can resample at the panel's needs and
    /// re-pace itself without waiting out the 8 s hidden interval.
    public var onPanelVisibilityChange: ((Bool) -> Void)?

    /// The panel currently on screen, so its rows can be updated in place. Weak:
    /// NSMenu owns itself while shown and this must not keep it alive after.
    private weak var openPanel: NSMenu?

    /// The out-of-the-box menu bar, used whenever persistence is empty or
    /// unreadable. It must always contain at least one clickable item or the main
    /// window becomes unreachable.
    ///
    /// This is THE default set — callers must not try to substitute their own by
    /// testing `configs.isEmpty`, because this list means it is never empty. That
    /// mistake silently left the app with a single widget.
    static let fallbackConfigs = [
        WidgetConfig(metricID: MetricID.batteryDrain.rawValue, style: .textWithLabel),
        WidgetConfig(metricID: MetricID.cpuUsage.rawValue, style: .textWithLabel),
        WidgetConfig(metricID: MetricID.memoryUsage.rawValue, style: .textWithLabel),
        // Everything else is one click away without claiming menu bar width up front.
        WidgetConfig(metricID: MetricID.groupPlaceholder.rawValue, style: .group),
    ]

    /// The key macOS files an item's remembered position and visibility under.
    ///
    /// DELIBERATELY NO INDEX. It used to be "AnodeWidget.\(index).\(metricID)",
    /// and the index meant every add or remove renamed every item after it — so a
    /// user's cmd-dragged positions were silently discarded whenever the widget
    /// list changed, and an item inherited whatever state the previous occupant of
    /// its index had left behind.
    ///
    /// That renaming was also this bug's camouflage: removing a widget and adding
    /// it back gave it a fresh name, which dodged a stuck hidden state and made
    /// the problem look like it had been fixed while it moved to another item.
    /// Dropping the index without setting `isVisible` would remove the escape
    /// hatch and make things worse; the two changes belong together.
    ///
    /// Changing the format retires the old names once, so positions reset a single
    /// time on upgrade. That is the cost of them being stable from then on.
    static func autosaveName(for metricID: String) -> String { "AnodeWidget.\(metricID)" }

    static let historyCap = 60   // sparkline samples kept per metric

    /// Total side padding of a compact text item, against AppKit's 16.
    static let compactPadding: CGFloat = 6

    // ── Placement ───────────────────────────────────────────────────────────────
    //
    // A status item that macOS declines to show is indistinguishable, from every
    // property this app sets, from one that is showing: it has a button, an
    // image, a length, and `isVisible == true`. The only witness is the window
    // AppKit gives the button, and it says one of two very different things.
    //
    // MEASURED on a MacBook Neo (Mac17,5, macOS 27), with a bare probe and with
    // this app, not inferred:
    //
    //   Not allowed   System Settings › Menu Bar › Allow in the Menu Bar has the
    //                 app switched off. Every item sits at (0, 0, w, 0) — zero
    //                 height, never laid out — for as long as the switch is off.
    //                 This is what WIDGET-BUG.md first saw and put down to
    //                 LaunchServices: the switch is remembered per bundle PATH, so
    //                 a copy anywhere else "fixed" it.
    //   Overflow      The bar is full. Items that do not fit are parked below the
    //                 screen at (0, -h, w, h), full height; the last item to fit
    //                 can also be stacked on the frame of its neighbour.
    //
    // Only overflow is helped by squeezing, so the two are kept apart: labels go
    // first, then everything folds into one item that still carries the headline
    // reading and opens the full panel. A switched-off app is told how to switch
    // it back on instead, and is watched so the widgets appear the moment it is.
    // Either way the app keeps a Dock tile while nothing is visible, so there is
    // always something to click.

    /// How far the bar has had to squeeze to be seen. Only ever tightens within a
    /// screen configuration; a screen change or a new arrangement starts over.
    enum Density: Int, Comparable {
        /// As configured.
        case full
        /// Labels dropped, value at the labelled size, AppKit padding trimmed.
        case compact
        /// One item: the app's glyph plus the first widget's reading.
        case single

        var tighter: Density? { Density(rawValue: rawValue + 1) }
        static func < (a: Density, b: Density) -> Bool { a.rawValue < b.rawValue }
    }

    /// What macOS actually did with the items, as far as can be seen from here.
    public enum Placement: Equatable {
        /// Not looked yet, or nothing to look at (switched off).
        case unknown
        case allShown
        case partlyHidden(shown: Int, total: Int)
        /// Nothing this app put in the menu bar is on screen: the bar is full.
        case noneShown
        /// macOS is withholding every item — Anode is switched off under
        /// System Settings › Menu Bar › Allow in the Menu Bar.
        case notAllowed

        /// Whether the widgets can serve as the app's only door.
        public var isReachable: Bool { self != .noneShown && self != .notAllowed }
    }

    /// What one item's window says about it.
    enum ItemState: Equatable {
        case shown
        /// Laid out, but somewhere nobody can see it: the overflow case.
        case parked
        /// Never laid out at all: the not-allowed case, or a look taken before
        /// AppKit got to it.
        case unplaced
    }

    /// One screen, reduced to what placement needs: its frame, and the span of
    /// its camera housing if it has one. Plain values so the rule is testable
    /// without a display.
    struct ScreenGeometry: Equatable {
        var frame: NSRect
        /// The x-range hidden behind the notch, in the same coordinates as `frame`.
        var notch: ClosedRange<CGFloat>?

        init(frame: NSRect, notch: ClosedRange<CGFloat>? = nil) {
            self.frame = frame
            self.notch = notch
        }

        /// Built from widths only. The auxiliary areas' origins are documented
        /// loosely enough that their coordinate space is a guess; their widths
        /// are not, and the notch is whatever lies between them.
        init(_ screen: NSScreen) {
            frame = screen.frame
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                let lo = frame.minX + l.width, hi = frame.maxX - r.width
                notch = hi > lo ? lo...hi : nil
            } else {
                notch = nil
            }
        }
    }

    /// Is a status item whose window has `frame` sitting in the menu bar of one
    /// of `screens`? Zero height is the never-placed case; off every screen or
    /// down in the bottom half is the overflow case; across a notch is the
    /// hidden-behind-the-camera case.
    ///
    /// The bar is judged by the top HALF of a screen rather than by the screen
    /// itself, because an auto-hidden menu bar is allowed to slide its items up
    /// past the top edge while they are still very much in the bar — and a parked
    /// overflow item at (0, -h) is horizontally on screen and must not pass.
    static func isPlaced(_ frame: NSRect?, on screens: [ScreenGeometry]) -> Bool {
        guard let f = frame, f.width >= 1, f.height >= 1 else { return false }
        return screens.contains { s in
            // Wholly on this screen horizontally: an item half off the edge is
            // an item macOS has pushed out of the bar.
            guard f.minX >= s.frame.minX - 1, f.maxX <= s.frame.maxX + 1,
                  f.minY >= s.frame.midY, f.minY <= s.frame.maxY + f.height
            else { return false }
            if let n = s.notch, f.maxX > n.lowerBound + 1, f.minX < n.upperBound - 1 {
                return false
            }
            return true
        }
    }

    /// Every item's state, in the order given. Pure, for tests.
    ///
    /// Two items of ONE app never legitimately overlap, so an item stacked on a
    /// neighbour that is already counted is parked too: that is how the last
    /// slot before the frontmost app's menus looks when two items compete for it.
    static func states(frames: [NSRect?], windowsVisible: [Bool],
                       on screens: [ScreenGeometry]) -> [ItemState] {
        var kept: [NSRect] = []
        return zip(frames, windowsVisible).map { frame, visible in
            guard let f = frame, f.width >= 1, f.height >= 1 else { return .unplaced }
            guard visible, isPlaced(f, on: screens) else { return .parked }
            if kept.contains(where: { $0.intersection(f).width > 1 }) { return .parked }
            kept.append(f)
            return .shown
        }
    }

    /// Classify a set of per-item states.
    static func placement(_ states: [ItemState]) -> Placement {
        guard !states.isEmpty else { return .unknown }
        let shown = states.filter { $0 == .shown }.count
        if shown == states.count { return .allShown }
        if shown > 0 { return .partlyHidden(shown: shown, total: states.count) }
        return states.allSatisfy { $0 == .unplaced } ? .notAllowed : .noneShown
    }

    /// Squeezing only helps a bar that is full, which is the one case with items
    /// laid out where nobody can see them. Squeezing a switched-off app would
    /// just leave it one item wide when the user switches it back on.
    static func shouldSqueeze(_ states: [ItemState]) -> Bool {
        states.contains(.parked)
    }

    /// The arrangement actually put in the bar at `density`. Pure, for tests.
    static func effectiveConfigs(_ stored: [WidgetConfig], density: Density) -> [WidgetConfig] {
        let enabled = stored.filter(\.enabled)
        switch density {
        case .full:
            return enabled
        case .compact:
            return enabled.map { c in
                var c = c
                if c.style == .textWithLabel { c.style = .text }
                return c
            }
        case .single:
            // One item. It carries the first real reading so the bar still says
            // something at a glance, and opens the panel, which has everything.
            let headline = enabled.first { $0.style != .group }?.metricID
            return [WidgetConfig(metricID: headline ?? MetricID.groupPlaceholder.rawValue,
                                 style: .group)]
        }
    }

    /// Posted on the main thread whenever `placement` changes.
    public static let placementDidChange = Notification.Name("AnodeWidgetPlacementDidChange")

    /// The most recent verdict, for anything that decides whether the menu bar
    /// can be relied on as the app's only door (the Dock tile, chiefly).
    public private(set) static var lastPlacement: Placement = .unknown

    /// True unless the widgets are known to be invisible. Unknown counts as
    /// reachable: it is the state before the first look, and every launch passes
    /// through it.
    public static var menuBarIsReachable: Bool { lastPlacement.isReachable }

    public private(set) var placement: Placement = .unknown {
        didSet {
            guard placement != oldValue else { return }
            Self.lastPlacement = placement
            onPlacementChange?(placement)
            NotificationCenter.default.post(name: Self.placementDidChange, object: self)
        }
    }

    /// Told when macOS starts or stops showing the widgets.
    public var onPlacementChange: ((Placement) -> Void)?

    private(set) var density: Density = .full
    private var placementCheck: DispatchWorkItem?
    private var lastScreens = NSScreen.screens.map { ScreenGeometry($0) }
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private let onClick: (MetricID?) -> Void
    private let defaults: UserDefaults
    private var storedConfigs: [WidgetConfig] = []
    /// Master switch. Deliberately separate from `storedConfigs` and NOT persisted
    /// here: which widgets are bound is the user's arrangement, and switching the
    /// menu bar off and on again must give it back rather than reset to defaults.
    /// Settings owns the durable flag; this is the controller's view of it.
    private var isEnabled: Bool
    /// Only the widgets that materialized — an item whose button failed to appear is
    /// dropped here but its config is kept, so it can come back next rebuild.
    private var items: [(config: WidgetConfig, item: NSStatusItem)] = []
    private var history: [String: [Double]] = [:]

    public var configs: [WidgetConfig] { storedConfigs }

    /// `onClick` is the integrator's "open the main window", told WHICH widget was
    /// clicked so it can open on the matching destination. The argument is the
    /// clicked widget's metric, or nil when the click carries no destination (an
    /// item whose config could not be resolved) — nil means "just open", never
    /// "open on some default lens". Mapping metric → destination is deliberately
    /// the integrator's job: this controller knows metrics, not navigation.
    /// `defaults` is injectable for tests; production uses .standard.
    /// `enabled: false` constructs the controller with its configs intact and
    /// nothing in the menu bar, which is what the master switch means.
    public init(onClick: @escaping (MetricID?) -> Void, defaults: UserDefaults = .standard,
                enabled: Bool = true) {
        self.onClick = onClick
        self.defaults = defaults
        self.isEnabled = enabled
        super.init()
        storedConfigs = Self.load(from: defaults) ?? Self.fallbackConfigs
        let center = NotificationCenter.default
        // A different screen is a different bar: start from the full layout and
        // let the check squeeze again if it has to.
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Posted on every wake and on changes that move no screen at all;
                // only a real change is worth tearing the widgets down for.
                let now = NSScreen.screens.map { ScreenGeometry($0) }
                guard now != self.lastScreens else { return }
                self.lastScreens = now
                self.density = .full
                self.rebuild()
            })
        // While this app is frontmost its own menus hide whatever status items
        // they reach, which says nothing about the bar. The moment another app
        // takes over is the first moment a look means something.
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.schedulePlacementCheck(after: 0.5)
            })
        // Whichever app is frontmost decides how much bar its menus leave, so a
        // switch between two OTHER apps can hide or reveal widgets too.
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                // Leaving System Settings is the likeliest moment for a
                // switched-off app to have been switched back on, and fresh items
                // are placed whether or not macOS revisits the old ones.
                if self.placement == .notAllowed {
                    self.rebuild()
                } else {
                    self.schedulePlacementCheck(after: 1)
                }
            })
        onMain { self.rebuild() }
    }

    deinit {
        placementCheck?.cancel()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    public func setConfigs(_ configs: [WidgetConfig]) {
        storedConfigs = configs
        persist()
        onMain {
            // A new arrangement gets a fresh chance at full width.
            self.density = .full
            self.rebuild()
            self.refresh()
        }
    }

    /// Turn the whole menu bar on or off. `rebuild()` already tears down every
    /// status item before it decides what to create, so off is just "stop after
    /// the teardown" and the configs survive untouched.
    public func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        onMain { self.rebuild() }
    }

    /// Pull current values from MetricRegistry and redraw every widget. Call after
    /// each `MetricRegistry.shared.update(with:)`. Values are read through the
    /// registry (thread-safe); the AppKit mutation is trampolined to the main thread.
    public func refresh() {
        onMain {
            for entry in self.items { self.render(entry) }
            self.refreshOpenPanel()
        }
    }

    /// Push current readings into the panel's existing rows.
    ///
    /// `refresh()` used to redraw the status item images and nothing else, so a
    /// panel that was open showed whatever the registry held at the instant it was
    /// built and never moved again. Combined with the tick not running at all
    /// during menu tracking, that is why three rows could sit at "—" for as long
    /// as anyone cared to look at them.
    private func refreshOpenPanel() {
        guard let panel = openPanel else { return }
        let registry = MetricRegistry.shared
        for item in panel.items {
            guard let id = item.representedObject as? MetricID,
                  let row = item.view as? MetricRowView else { continue }
            let value = registry.value(for: id)
            let shown = value.map { $0.text + ($0.isEstimate ? "*" : "") } ?? "\u{2014}"
            row.update(value: shown, hasReading: value != nil)
            item.title = registry.descriptors().first { $0.id == id }.map {
                $0.title + "\t" + shown
            } ?? item.title
        }
    }

    // ── Internals ───────────────────────────────────────────────────────────────

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func persist() {
        // Encoding [WidgetConfig] cannot realistically fail, but "cannot fail" is how
        // startup crashes are born — fail soft and keep the in-memory configs.
        if let data = try? JSONEncoder().encode(storedConfigs) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func load(from defaults: UserDefaults) -> [WidgetConfig]? {
        guard let data = defaults.data(forKey: defaultsKey),
              let configs = try? JSONDecoder().decode([WidgetConfig].self, from: data)
        else { return nil }
        return configs.isEmpty ? nil : configs
    }

    private func rebuild() {
        lastRendered.removeAll()
        for entry in items { NSStatusBar.system.removeStatusItem(entry.item) }
        items.removeAll()
        placementCheck?.cancel()
        // New items slide in afresh; nothing seen of the old ones carries over.
        unsettledLooks = 0
        // Master switch off: the teardown above IS the whole job. Everything below
        // creates status items, and `items` staying empty means render() and
        // refresh() have nothing to walk, so no cost is paid anywhere downstream.
        guard isEnabled else {
            placement = .unknown
            return
        }

        // New status items are inserted to the LEFT of existing ones, so create in
        // reverse for configs[0] to land leftmost. autosaveName additionally lets
        // macOS remember a position the user cmd-dragged to.
        for config in Self.effectiveConfigs(storedConfigs, density: density).reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // A dying WindowServer connection (or a headless agent context) hands back
            // an item with no button. Drop that ONE widget and keep going — one bad
            // widget must never take down the rest.
            guard let button = item.button else {
                NSStatusBar.system.removeStatusItem(item)
                continue
            }
            // The single item gets a name of its own: it is not the widget it
            // borrows a reading from, and must not inherit that one's position.
            item.autosaveName = density == .single
                ? Self.autosaveName(for: "single") : Self.autosaveName(for: config.metricID)
            // EXPLICITLY VISIBLE, every rebuild, and this is not redundant.
            //
            // macOS persists isVisible PER autosaveName, in its own store rather
            // than in this app's defaults — so it survives a relaunch, a rebuild,
            // and a reinstall, and nothing in `dev.anode.app` records it. An item
            // a user once cmd-dragged off the bar therefore comes back HIDDEN
            // forever, while its WidgetConfig still says enabled: a widget that
            // cannot be recovered through any control this app offers.
            //
            // Measured, not assumed: create an item with an autosaveName, set
            // isVisible = false, destroy it, recreate it with the same name, and
            // it reads back false. See the probe in the commit that added this.
            item.isVisible = true
            button.target = self
            button.action = #selector(widgetClicked)
            // Right-click has to be requested explicitly. Without it the app is
            // unquittable once it drops out of the Dock: no tile, no application
            // menu, and a left-click only opens the window.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            items.append((config, item))
        }
        items.reverse()   // back to config order for renders and test seams
        for entry in items { render(entry) }
        Self.debugDump(items, density: density)
        // AppKit lays status items out asynchronously, so a look taken now would
        // see every one of them unplaced.
        schedulePlacementCheck(after: 1.5)
    }

    private func schedulePlacementCheck(after delay: TimeInterval) {
        placementCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkPlacement() }
        placementCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Look at where macOS put the items, and squeeze if the bar is full.
    private func checkPlacement() {
        guard isEnabled, !items.isEmpty else { return }
        // Never rebuild out from under an open panel; look once it has closed.
        guard !isPanelOpen else {
            schedulePlacementCheck(after: 2)
            return
        }
        let screens = NSScreen.screens.map { ScreenGeometry($0) }
        let windows = items.map { $0.item.button?.window }
        let states = Self.states(frames: windows.map { $0?.frame },
                                 windowsVisible: windows.map { $0?.isVisible ?? false },
                                 on: screens)
        let verdict = Self.placement(states)
        Self.debugDump(items, density: density, verdict: "\(verdict)")

        // Deliberately NOT gated on `NSMenu.menuBarVisible()`. It is false for the
        // whole life of an auto-hidden menu bar, and gating on it meant a Mac set
        // to hide the bar never looked at all: never squeezed, never said a word.
        // Measured on macOS 27: the items keep their real frames while the bar is
        // hidden, and `isPlaced` accepts a bar slid up past the top edge.

        if verdict == .allShown {
            unsettledLooks = 0
            placement = .allShown
            return
        }

        // Nothing but "all shown" is believed on one look. Items slide in: 1.5 s
        // after a rebuild on a MacBook Neo, three were mid-flight and six still
        // sat at (0, -30) — overflow, to a single look — and settled a moment
        // later with all nine in the bar. Squeezing on that would have cost the
        // labels for the rest of the session. The same goes for zero height,
        // which is also what a look taken before AppKit's first layout sees.
        unsettledLooks += 1
        guard unsettledLooks >= 2 else {
            schedulePlacementCheck(after: 2)
            return
        }

        if verdict == .notAllowed {
            // Zero height everywhere does not depend on whose menus are showing,
            // so it is judged even while this app is frontmost.
            placement = .notAllowed
            schedulePlacementCheck(after: 5)
            return
        }

        // Frontmost with a menu bar of our own: our menus hide whatever items
        // they reach, which says nothing about the bar. See the resign-active
        // observer. An `.accessory` app has no menus to collide with. Anything
        // laid out at all does mean the switch is on, though — the likeliest
        // moment for that is the user coming straight back from turning it on.
        if NSApp.isActive && NSApp.activationPolicy() == .regular {
            if placement == .notAllowed { placement = .unknown }
            unsettledLooks = 0
            return
        }

        if Self.shouldSqueeze(states), let next = density.tighter {
            density = next
            unsettledLooks = 0
            rebuild()     // schedules the next look
            return
        }
        placement = verdict
        unsettledLooks = 0
        // Space can come back without any notification saying so (another menu
        // bar app quits). Looking again costs a few frame reads.
        schedulePlacementCheck(after: 30)
    }

    /// Consecutive looks that found something not shown. See `checkPlacement`.
    private var unsettledLooks = 0

    /// One-shot dump of what the menu bar ACTUALLY holds, gated behind
    /// ANODE_WIDGET_DEBUG=1 so it costs a getenv on rebuild and nothing else.
    ///
    /// It exists because a widget reported as "empty space that still highlights"
    /// cannot be diagnosed from source: every render path in this file draws
    /// something, and a bitmap of `textImage` proved it draws for a 0 B swap value
    /// too. So the failure is not in what we draw, it is in what happens to the
    /// item AFTER we draw it — length, visibility, or a frame the window never
    /// gave it. Those are AppKit's answers, not ours, and only the affected
    /// machine can be asked.
    ///
    /// `isVisible` is the specific suspicion. It is persisted by macOS PER
    /// `autosaveName`, and this file sets an autosaveName and never sets
    /// isVisible — so an item a user once cmd-dragged off the bar stays off,
    /// permanently, with the config still saying enabled.
    static func debugDump(_ items: [(config: WidgetConfig, item: NSStatusItem)],
                          density: Density = .full, verdict: String? = nil) {
        guard ProcessInfo.processInfo.environment["ANODE_WIDGET_DEBUG"] == "1" else { return }
        let bar = NSStatusBar.system
        // stderr, not stdout: stdout is block-buffered when redirected to a file,
        // so a dump taken from a menu bar app that is then quit arrives empty —
        // which is exactly how this was first tested, and it looked like the dump
        // had never run.
        func print(_ s: String) { fputs(s + "\n", stderr) }
        print("── ANODE WIDGET DUMP ─────────────────────────────────────────────")
        print(String(format: "thickness %.1f   screen %.0f wide   items %d",
                     bar.thickness, NSScreen.main?.frame.width ?? -1, items.count))
        var total: CGFloat = 0
        for (i, e) in items.enumerated() {
            let b = e.item.button
            let img = b?.image
            let w = b?.frame.width ?? -1
            total += max(w, 0)
            // The window frame is the line that matters: zero height means the
            // item was never placed, whatever every other column says.
            print(String(format: "%2d %-28s style=%-13s visible=%@ winVisible=%@ len=%6.1f btnW=%6.1f img=%@ win=%@",
                         i, (e.config.metricID as NSString).utf8String!,
                         (e.config.style.rawValue as NSString).utf8String!,
                         e.item.isVisible ? "YES" : "NO ",
                         (b?.window?.isVisible ?? false) ? "YES" : "NO ",
                         e.item.length, w,
                         img.map { String(format: "%.0fx%.0f", $0.size.width, $0.size.height) } ?? "NIL",
                         b?.window.map { NSStringFromRect($0.frame) } ?? "NIL"))
        }
        print(String(format: "total widget width %.0f pt   density %@", total,
                     String(describing: density)))
        if let verdict { print("placement check: \(verdict)") }
        print("──────────────────────────────────────────────────────────────────")
    }

    /// Every widget opens the main window — the widgets ARE the app's front door.
    /// The clicked widget's metric goes with the call, so the door opens onto what
    /// the user just pointed at rather than wherever the window was left.
    /// Right-click gets the menu instead, because with no Dock tile there is
    /// nowhere else to quit from.
    @objc private func widgetClicked(_ sender: NSStatusBarButton) {
        let metric = metricID(of: sender)
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "Open Anode",
                                    action: #selector(openFromMenu), keyEquivalent: "")
            open.target = self
            // The menu outlives this call, so the identity of the widget it was
            // raised from has to travel with the item — by then `sender` is gone.
            open.representedObject = metric
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Anode",
                         action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            // popUp(positioning:at:in:) — NOT assigning item.menu and calling
            // performClick. That re-enters this very action handler from inside
            // itself, which is a recursion waiting to happen and is the likely
            // cause of the crash reported right after this menu was added.
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 5),
                       in: sender)
            return
        }
        onClick(metric)
    }

    /// Which widget a button belongs to. Matched by object identity, not by
    /// metric: the same metric may legitimately be bound to two widgets (a value
    /// and a sparkline, say), and both must resolve to their own entry.
    private func metricID(of button: NSStatusBarButton) -> MetricID? {
        items.first { $0.item.button === button }
            .map { MetricID(rawValue: $0.config.metricID) }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        onClick(sender.representedObject as? MetricID)
    }

    /// What each widget last drew, so an unchanged value costs nothing.
    ///
    /// Menu bar figures are short strings that change slowly — "11%" stays "11%"
    /// for several ticks — but the image behind one was being redrawn on every
    /// tick regardless: an NSImage allocation, a text layout and a template
    /// composite, on the main thread, for pixels identical to the ones already
    /// there. Only the sparkline is exempt, because its history moves even when
    /// the latest value does not.
    private var lastRendered: [String: String] = [:]

    private func render(_ entry: (config: WidgetConfig, item: NSStatusItem)) {
        guard let button = entry.item.button else { return }
        let id = MetricID(rawValue: entry.config.metricID)
        let registry = MetricRegistry.shared
        let descriptor = registry.descriptor(for: id)
        // Unknown ID never reaches a provider; known ID may still be nil (no data
        // yet, or honestly unavailable — e.g. time remaining on AC). Both render as
        // a placeholder, not an error.
        let value = descriptor == nil ? nil : registry.value(for: id)

        if entry.config.style == .sparkline, let v = value?.value, v.isFinite {
            var h = history[entry.config.metricID, default: []]
            h.append(v)
            if h.count > Self.historyCap { h.removeFirst(h.count - Self.historyCap) }
            history[entry.config.metricID] = h
        }

        // Assigned only when it CHANGES, which is the whole point.
        //
        // A tooltip is backed by a cursor rect, so setting one invalidates the
        // window's tracking areas — and this ran on every tick whatever the value
        // was. Profiled with the window covered, the app's largest remaining cost
        // was AppKit walking the view tree to rebuild those:
        //
        //   displayCycleUpdateStructuralRegions
        //     -> updateTrackingAreasWithInvalidCursorRects:
        //       -> -[NSNextStepFrame updateTrackingAreas]
        //
        // The value below it was already guarded against no-op redraws; this line
        // sat above that guard and undid it, every eight seconds, for a tooltip
        // nobody was pointing at.
        let tip = WidgetRenderer.toolTip(
            metricID: entry.config.metricID, descriptor: descriptor, value: value,
            style: entry.config.style)
        if button.toolTip != tip { button.toolTip = tip }

        if entry.config.style == .group {
            // A menu attached to the status item opens directly beneath it, which is
            // the behaviour asked for. Assigning `menu` also makes AppKit own the
            // click, so the widget's normal open-the-window action is bypassed here.
            // Built LAZILY, when the menu is about to open. It was being rebuilt
            // on every tick — an NSMenu plus an item per metric, constructed and
            // thrown away for a menu nobody had opened. The delegate defers that
            // to the moment it is actually needed, which is also the moment its
            // values are guaranteed current.
            if entry.item.menu == nil {
                let menu = NSMenu()
                menu.delegate = self
                entry.item.menu = menu
            }
            // A plain group's glyph is constant, so it is drawn once. A group
            // bound to a real metric is the single-item fallback, which carries
            // that metric's reading beside the glyph and redraws when it moves.
            let headline = id == .groupPlaceholder ? nil : (value?.text ?? "\u{2014}")
            let key = "group\u{1}\(headline ?? "")"
            if lastRendered[entry.config.metricID] != key {
                lastRendered[entry.config.metricID] = key
                button.attributedTitle = NSAttributedString()
                button.imagePosition = .imageOnly
                button.image = WidgetRenderer.groupImage(headline: headline)
            }
            return
        }
        entry.item.menu = nil

        switch entry.config.style {
        case .text, .textWithLabel:
            // Rendered as an image rather than an attributedTitle. AppKit centres a
            // button title using its own line metrics, which for a two-line string
            // put the label too high and left the value baseline above every
            // neighbouring menu bar item. Drawing it ourselves makes the geometry
            // exact. Template rendering also means macOS tints it like every other
            // item, so it stays legible on any wallpaper in either appearance.
            let label = entry.config.style == .textWithLabel
                ? (value?.label ?? descriptor?.shortTitle ?? "?") : nil
            let text = value?.text ?? "\u{2014}"
            let key = "\(label ?? "")\u{1}\(text)"
            guard lastRendered[entry.config.metricID] != key else { return }
            lastRendered[entry.config.metricID] = key

            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            let image = WidgetRenderer.textImage(
                label: label,
                // No "*" here. It means "gain not yet calibrated against the gas
                // gauge", a condition that clears within ~60 s — but a bare asterisk
                // beside a number in the menu bar is uninterpretable and reads as an
                // error. The tooltip carries it, where there is room to say so.
                value: text, compact: density == .compact)
            button.image = image
            // AppKit pads every variable-length item by 8 pt a side — 16 pt per
            // widget, more than a whole label saves. A squeezed bar sizes the item
            // to its drawing instead, which is where compact's width comes from.
            entry.item.length = density == .compact
                ? ceil(image.size.width) + Self.compactPadding
                : NSStatusItem.variableLength
        case .group:
            break   // handled above, before this switch
        case .bar, .sparkline, .dot:
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            button.image = WidgetRenderer.image(
                style: entry.config.style, descriptor: descriptor, value: value,
                history: history[entry.config.metricID] ?? [])
        }
    }

    /// Every metric with its current reading, one uninterrupted column. Rebuilt on
    /// each refresh so the panel is current the moment it opens — a stale popover
    /// is worse than none, and building ~15 rows is far cheaper than the sampling
    /// that produced them.
    ///
    /// No category headers and no separators, on request: the rows are
    /// self-labelling ("CPU usage", "Network down"), and the headers and dividers
    /// were each other's redundancy — every header sat on a divider, both
    /// announcing the same break. The registry's category ORDER still groups
    /// related rows next to each other; the grouping is in the sequence, not in
    /// chrome.
    static func buildGroupMenu(settings: Settings = .shared) -> NSMenu {
        let menu = NSMenu()
        let registry = MetricRegistry.shared
        let byID = Dictionary(registry.descriptors().map { ($0.id.rawValue, $0) },
                              uniquingKeysWith: { a, _ in a })
        let ids = PanelOrder.visible(saved: settings.panelOrder,
                                     hidden: settings.panelHidden,
                                     available: registry.descriptors().map(\.id))

        for d in ids.compactMap({ byID[$0] }) {
            let value = registry.value(for: d.id)
            let shown = value.map { $0.text + ($0.isEstimate ? "*" : "") } ?? "\u{2014}"
            // The title is redundant beside the view, but it is what VoiceOver
            // reads, and it is how the tests tell a row from a header.
            let row = NSMenuItem(title: d.title + "\t" + shown,
                                 action: nil, keyEquivalent: "")
            row.view = MetricRowView(name: d.title, value: shown,
                                     hasReading: value != nil)
            // So an open panel can find the row for a metric without rebuilding.
            row.representedObject = d.id
            row.isEnabled = false
            menu.addItem(row)
        }
        return menu
    }

    /// The ink for a metric row: STRAIGHT white on a dark menu, straight black on
    /// a light one — deliberately not `labelColor`, which is ~85 % opacity and
    /// reads as gray against the vibrant menu material. Requested from the field
    /// after two rounds of gray.
    static let rowInk = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }
    /// A value with no reading stays de-emphasised — the em-dash is a
    /// placeholder, not a measurement — but at 45 % of the SAME straight ink, so
    /// it dims relative to its row and not into the menu material.
    static let placeholderInk = NSColor(name: nil) { appearance in
        (appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white : NSColor.black).withAlphaComponent(0.45)
    }

    /// Test seam: materialized buttons in config order. Internal on purpose.
    var _buttons: [NSStatusBarButton] { items.compactMap { $0.item.button } }
}

/// One reading row of the group menu, drawn by US and not by NSMenu.
///
/// A VIEW, not an attributed title, because the attributed-title route was tried
/// and defeated: these items are disabled (readings, not commands), and on this
/// machine's macOS the menu dims a disabled item's ENTIRE title — explicit
/// `.foregroundColor` attributes included — so the panel stayed gray through a
/// fix that named its colors. A custom view is the one surface AppKit renders
/// untouched: no disabled-state recolor, no hover highlight, and the ink below
/// is exactly the ink on screen.
final class MetricRowView: NSView {

    let nameField: NSTextField
    let valueField: NSTextField

    /// Matches the old attributed layout: name at the menu's standard content
    /// inset, value right-aligned so the numbers form a column.
    private static let width: CGFloat = 240
    private static let height: CGFloat = 22
    private static let inset: CGFloat = 14

    init(name: String, value: String, hasReading: Bool) {
        nameField = NSTextField(labelWithString: name)
        nameField.font = .systemFont(ofSize: 12)
        nameField.textColor = MenuBarWidgetController.rowInk

        valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueField.textColor = hasReading
            ? MenuBarWidgetController.rowInk
            : MenuBarWidgetController.placeholderInk

        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))

        for field in [nameField, valueField] {
            field.drawsBackground = false
            field.sizeToFit()
            addSubview(field)
        }
        nameField.setFrameOrigin(NSPoint(
            x: Self.inset,
            y: (Self.height - nameField.frame.height) / 2))
        valueField.setFrameOrigin(NSPoint(
            x: Self.width - Self.inset - valueField.frame.width,
            y: (Self.height - valueField.frame.height) / 2))
        // The menu is often WIDER than `width` — the "Quit Anode ⌘Q" row sets it —
        // and NSMenu stretches a custom view to the menu only if it is allowed to.
        // Without this the row stayed 240 pt wide and left-aligned, leaving a
        // 40 pt dead strip to the right of the value column. Pinning the value to
        // the right edge keeps its inset from the edge whatever the width.
        autoresizingMask = [.width]
        valueField.autoresizingMask = [.minXMargin]
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Re-point an EXISTING row at a new reading, rather than rebuilding the menu.
    ///
    /// An open NSMenu cannot have its items swapped out from under it, and the
    /// panel has to keep moving while someone is looking at it — that is the whole
    /// complaint. Updating the field in place is the one thing that is safe to do
    /// to a menu that is currently on screen.
    func update(value: String, hasReading: Bool) {
        guard valueField.stringValue != value
            || (valueField.textColor == MenuBarWidgetController.placeholderInk) == hasReading
        else { return }
        valueField.stringValue = value
        valueField.textColor = hasReading
            ? MenuBarWidgetController.rowInk
            : MenuBarWidgetController.placeholderInk
        valueField.sizeToFit()
        // Right-aligned, so the origin moves whenever the width does.
        valueField.setFrameOrigin(NSPoint(
            x: bounds.width - Self.inset - valueField.frame.width,
            y: (Self.height - valueField.frame.height) / 2))
        needsDisplay = true
    }

    /// The menu material desaturates vibrant content; this row opts out so the
    /// straight ink stays straight.
    override var allowsVibrancy: Bool { false }
}

/// Pure rendering — (style, descriptor, value) → attributed string / image — kept
/// free of NSStatusItem so it can be exercised headlessly.
enum WidgetRenderer {

    static func toolTip(metricID: String, descriptor: MetricDescriptor?,
                        value: MetricValue?, style: WidgetStyle? = nil) -> String {
        // Before the descriptor check: the group binds to no metric, so it never
        // has one, and "no descriptor" would otherwise call it a stale metric.
        if metricID == MetricID.groupPlaceholder.rawValue {
            return "All readings — click for the list"
        }
        // The single-item fallback binds a real metric to the group style.
        if style == .group {
            let reading = descriptor.map { d in
                value.map { "\(d.title): \($0.text)" } ?? "\(d.title): no data"
            }
            return [reading, "Click for all readings"].compactMap { $0 }.joined(separator: "\n")
        }
        guard let d = descriptor else {
            return "Unknown metric “\(metricID)” — it may belong to another version of Anode"
        }
        guard let v = value else { return "\(d.title): no data" }
        return "\(d.title): \(v.text)\(v.isEstimate ? " (estimate)" : "")"
    }

    /// Draws label-over-value at exact pixel positions, as a TEMPLATE image so the
    /// system tints it to match the rest of the menu bar.
    ///
    /// Alignment rule: the value line is placed where a normal single-line menu bar
    /// item's text would sit, and the label is stacked above it. Centring the pair
    /// as a block instead pushes the value up and it no longer lines up with its
    /// neighbours — which is exactly what the attributedTitle version did wrong.
    ///
    /// `compact` is the squeezed bar's single line: the labelled value's own
    /// 10.5 pt rather than 12, because the label sits ABOVE the value and so
    /// dropping it narrows nothing — at 12 pt a "compact" bar measured wider than
    /// the full one it replaced (474 pt against 447 on a MacBook Neo).
    static func textImage(label: String?, value: String, compact: Bool = false) -> NSImage {
        let h = NSStatusBar.system.thickness          // 22pt today, but ask, do not assume
        let valueFont = NSFont.monospacedDigitSystemFont(
            ofSize: label == nil && !compact ? 12 : 10.5, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)

        let vAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
        let lAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]

        let vStr = NSAttributedString(string: value, attributes: vAttrs)
        let lStr = label.map { NSAttributedString(string: $0, attributes: lAttrs) }

        let vSize = vStr.size()
        let lSize = lStr?.size() ?? .zero
        let pad: CGFloat = compact ? 0 : 3
        let w = max(vSize.width, lSize.width) + pad * 2

        let img = NSImage(size: NSSize(width: ceil(w), height: h), flipped: false) { _ in
            if let lStr {
                // Two lines: sit the pair low enough that the VALUE keeps a normal
                // single-line baseline, with the label riding above it. The 1pt
                // overlap closes the natural leading gap between the two fonts.
                let vy = (h - vSize.height) / 2 - lSize.height / 2 + 1
                let ly = vy + vSize.height - 1
                lStr.draw(at: NSPoint(x: (w - lSize.width) / 2, y: ly))
                vStr.draw(at: NSPoint(x: (w - vSize.width) / 2, y: vy))
            } else {
                vStr.draw(at: NSPoint(x: pad, y: (h - vSize.height) / 2))
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// The group widget's glyph: the app's own icon, three ascending bars on a
    /// plinth, drawn small enough to read at menu bar size.
    ///
    /// It was `⌄` — a lone down-arrowhead, which said "this opens" and nothing
    /// else. Sitting in a row of other apps' marks with no mark of its own, it
    /// read as a floating caret rather than as anything belonging to Anode. A
    /// menu bar item is the only part of this app most people see most of the
    /// time, so it should say whose it is.
    ///
    /// Drawn rather than shipped as an asset: it is nine rectangles, it has to be
    /// a template so macOS can tint it for the wallpaper and the appearance, and
    /// at this size a scaled-down PNG of the real icon is mud.
    static func groupImage(headline: String? = nil) -> NSImage {
        let h = NSStatusBar.system.thickness
        let glyphW: CGFloat = 18
        // The single-item fallback: the glyph says whose item it is, the reading
        // says why it is worth the space.
        let text = headline.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.black,
            ])
        }
        let textW = text.map { ceil($0.size().width) + 3 } ?? 0
        let w = glyphW + textW
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            if let text {
                text.draw(at: NSPoint(x: glyphW, y: (h - text.size().height) / 2))
            }
            NSColor.black.setFill()

            // Proportions taken from the app icon: bars a third of their own
            // width apart, each step up about a third taller than the last, and
            // a base they all stand on.
            let barW: CGFloat = 3
            let gap: CGFloat = 1.5
            let heights: [CGFloat] = [5, 8, 11]
            let baseH: CGFloat = 1.5
            let totalW = barW * 3 + gap * 2
            let x0 = (glyphW - totalW) / 2
            // Centred on the bar group INCLUDING its base, so the glyph sits on
            // the same optical line as the text widgets beside it.
            let y0 = (h - (heights.max()! + baseH)) / 2

            for (i, barH) in heights.enumerated() {
                let r = NSRect(x: x0 + CGFloat(i) * (barW + gap), y: y0 + baseH,
                               width: barW, height: barH)
                NSBezierPath(roundedRect: r, xRadius: 0.75, yRadius: 0.75).fill()
            }
            let base = NSRect(x: x0 - 0.75, y: y0, width: totalW + 1.5, height: baseH)
            NSBezierPath(roundedRect: base, xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        // Template, so macOS tints it like every other menu bar item and it stays
        // legible on any wallpaper in either appearance.
        img.isTemplate = true
        return img
    }

    static func image(style: WidgetStyle, descriptor: MetricDescriptor?,
                      value: MetricValue?, history: [Double]) -> NSImage? {
        switch style {
        case .dot:       return dotImage(color: severityColor(descriptor, value))
        case .bar:       return barImage(descriptor: descriptor, value: value)
        case .sparkline: return sparklineImage(history: history)
        case .text, .textWithLabel, .group: return nil
        }
    }

    // ── Severity ────────────────────────────────────────────────────────────────

    /// 0…1 "how full is this reading" against a per-unit scale. nil where no
    /// universal bound exists (count, bytes, either rate) — those stay neutral
    /// rather than pretending a threshold we don't have.
    static func normalizedFraction(_ unit: MetricUnit, _ v: Double) -> Double? {
        guard v.isFinite else { return nil }
        func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
        switch unit {
        case .percent:        return clamp(v / 100)
        case .ratio:          return clamp(v)
        case .percentPerHour: return clamp(v / 25)          // 25 %/hr ≈ a 4 h battery: fully bad
        case .minutes:        return clamp(v / 600)         // the "10 hr power" anchor: 10 h = full
        case .celsius:        return clamp((v - 30) / 70)   // 30 °C idle … 100 °C throttle
        case .rpm:            return clamp(v / 6000)
        // No universal bound exists for these, so they stay neutral rather than
        // implying a threshold we cannot justify. Throughput in particular depends
        // entirely on the link — 12 MB/s is saturation on Wi-Fi and idle on Thunderbolt.
        //
        // `.bytesPerDay` is here on different grounds, worth writing down because a
        // write rate LOOKS like it has a bound. The only bound available would be a
        // claim about every machine, and the only measurement behind it is one
        // machine's habit — 52.2 GB/day lifetime against 47.2 GB/day over a fresh
        // window is two views of the same drive, n = 1. Scaled to that, a bar
        // colours a developer's laptop yellow and a video editor's red having
        // measured neither. And no scale may be derived from endurance: the 612 TB
        // figure is falsified, not merely uncertain (ARCHITECTURE.md section 8), and
        // a lower bound is not a scale — it can say a rate is safer than assumed,
        // never how much of anything it uses.
        case .count, .bytes, .bytesPerSecond, .bytesPerDay: return nil
        }
    }

    /// green → yellow → red by badness; `higherIsWorse` flips the direction so a
    /// full battery and a low drain are both green. Neutral (secondaryLabel) when
    /// there is no value or no meaningful scale.
    static func severityColor(_ descriptor: MetricDescriptor?, _ value: MetricValue?) -> NSColor {
        // The metric's own verdict first: it knows what "bad" is where a scale
        // on the value cannot (memory pressure, a fan's own maximum).
        if let sev = value?.severity, sev.isFinite {
            let badness = min(max(sev, 0), 1)
            if badness < 0.5 { return .systemGreen }
            if badness < 0.8 { return .systemYellow }
            return .systemRed
        }
        guard let d = descriptor, let v = value,
              let f = normalizedFraction(d.unit, v.value) else {
            return .secondaryLabelColor
        }
        let badness = d.higherIsWorse ? f : 1 - f
        if badness < 0.5 { return .systemGreen }
        if badness < 0.8 { return .systemYellow }
        return .systemRed
    }

    // ── Glyphs ──────────────────────────────────────────────────────────────────
    // All drawn via NSImage(size:flipped:drawingHandler:): the handler re-runs per
    // destination appearance, so semantic colours resolve against the actual menu
    // bar (light or dark) at draw time. No hardcoded greys, no isTemplate needed.

    static func dotImage(color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    static func barImage(descriptor: MetricDescriptor?, value: MetricValue?) -> NSImage {
        let fraction = descriptor.flatMap { d in
            value.flatMap { normalizedFraction(d.unit, $0.value) }
        }
        let fill = severityColor(descriptor, value)
        return NSImage(size: NSSize(width: 26, height: 10), flipped: false) { rect in
            let outline = rect.insetBy(dx: 0.5, dy: 0.5)
            NSColor.labelColor.withAlphaComponent(0.4).setStroke()
            NSBezierPath(roundedRect: outline, xRadius: 2.5, yRadius: 2.5).stroke()
            if let f = fraction, f > 0 {
                let inner = rect.insetBy(dx: 2, dy: 2)
                var filled = inner
                filled.size.width = max(inner.width * CGFloat(f), 1)
                fill.setFill()
                NSBezierPath(roundedRect: filled, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
    }

    static func sparklineImage(history: [Double]) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 12), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 2)
            let finite = history.filter { $0.isFinite }
            guard finite.count >= 2,
                  let lo = finite.min(), let hi = finite.max() else {
                // Not enough history yet: a quiet baseline, not an empty (invisible,
                // unclickable-looking) slot.
                NSColor.secondaryLabelColor.setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: inset.minX, y: inset.midY))
                line.line(to: NSPoint(x: inset.maxX, y: inset.midY))
                line.lineWidth = 1
                line.stroke()
                return true
            }
            let span = hi - lo
            let path = NSBezierPath()
            for (i, v) in finite.enumerated() {
                let x = inset.minX + inset.width * CGFloat(i) / CGFloat(finite.count - 1)
                // Flat history draws mid-height rather than dividing by zero.
                let t = span > 0 ? (v - lo) / span : 0.5
                let y = inset.minY + inset.height * CGFloat(t)
                i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            }
            NSColor.labelColor.setStroke()
            path.lineWidth = 1
            path.lineJoinStyle = .round
            path.stroke()
            return true
        }
    }
}

extension MenuBarWidgetController {

    public func menuWillOpen(_ menu: NSMenu) {
        openPanel = menu
        isPanelOpen = true
        onPanelVisibilityChange?(true)
    }

    public func menuDidClose(_ menu: NSMenu) {
        openPanel = nil
        isPanelOpen = false
        onPanelVisibilityChange?(false)
    }

    /// Fill the group menu only when it is about to be shown.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = Self.buildGroupMenu()
        // Items belong to exactly one menu, so they are MOVED. Taking them from
        // index 0 repeatedly empties `fresh` as it fills `menu`; adding an item
        // that still has a supermenu throws.
        while let item = fresh.items.first {
            fresh.removeItem(item)
            menu.addItem(item)
        }
        // The group item's click belongs to its menu, so without these a menu bar
        // holding only the group — which is what the single-item fallback is —
        // could neither open the window nor quit. Added here rather than in
        // `buildGroupMenu`, which is the readings and nothing else.
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open Anode",
                                action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(withTitle: "Quit Anode",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
