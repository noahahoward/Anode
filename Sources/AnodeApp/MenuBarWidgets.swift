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

    static let historyCap = 60   // sparkline samples kept per metric

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
        onMain { self.rebuild() }
    }

    public func setConfigs(_ configs: [WidgetConfig]) {
        storedConfigs = configs
        persist()
        onMain {
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
        // Master switch off: the teardown above IS the whole job. Everything below
        // creates status items, and `items` staying empty means render() and
        // refresh() have nothing to walk, so no cost is paid anywhere downstream.
        guard isEnabled else { return }

        // New status items are inserted to the LEFT of existing ones, so create in
        // reverse for configs[0] to land leftmost. autosaveName additionally lets
        // macOS remember a position the user cmd-dragged to.
        for (index, config) in storedConfigs.enumerated().reversed() where config.enabled {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // A dying WindowServer connection (or a headless agent context) hands back
            // an item with no button. Drop that ONE widget and keep going — one bad
            // widget must never take down the rest.
            guard let button = item.button else {
                NSStatusBar.system.removeStatusItem(item)
                continue
            }
            item.autosaveName = "AnodeWidget.\(index).\(config.metricID)"
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
            metricID: entry.config.metricID, descriptor: descriptor, value: value)
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
            // The glyph is constant, so it is drawn once. The MENU is rebuilt
            // every tick because its contents are the live values.
            if lastRendered[entry.config.metricID] == nil {
                lastRendered[entry.config.metricID] = "group"
                button.attributedTitle = NSAttributedString()
                button.imagePosition = .imageOnly
                button.image = WidgetRenderer.groupImage()
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
            button.image = WidgetRenderer.textImage(
                label: label,
                // No "*" here. It means "gain not yet calibrated against the gas
                // gauge", a condition that clears within ~60 s — but a bare asterisk
                // beside a number in the menu bar is uninterpretable and reads as an
                // error. The tooltip carries it, where there is room to say so.
                value: text)
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
            x: Self.width - Self.inset - valueField.frame.width,
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
                        value: MetricValue?) -> String {
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
    static func textImage(label: String?, value: String) -> NSImage {
        let h = NSStatusBar.system.thickness          // 22pt today, but ask, do not assume
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: label == nil ? 12 : 10.5,
                                                         weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)

        let vAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
        let lAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]

        let vStr = NSAttributedString(string: value, attributes: vAttrs)
        let lStr = label.map { NSAttributedString(string: $0, attributes: lAttrs) }

        let vSize = vStr.size()
        let lSize = lStr?.size() ?? .zero
        let pad: CGFloat = 3
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
    static func groupImage() -> NSImage {
        let h = NSStatusBar.system.thickness
        let w: CGFloat = 18
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            NSColor.black.setFill()

            // Proportions taken from the app icon: bars a third of their own
            // width apart, each step up about a third taller than the last, and
            // a base they all stand on.
            let barW: CGFloat = 3
            let gap: CGFloat = 1.5
            let heights: [CGFloat] = [5, 8, 11]
            let baseH: CGFloat = 1.5
            let totalW = barW * 3 + gap * 2
            let x0 = (w - totalW) / 2
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
    /// universal bound exists (count, bytes) — those stay neutral rather than
    /// pretending a threshold we don't have.
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
        case .count, .bytes, .bytesPerSecond: return nil
        }
    }

    /// green → yellow → red by badness; `higherIsWorse` flips the direction so a
    /// full battery and a low drain are both green. Neutral (secondaryLabel) when
    /// there is no value or no meaningful scale.
    static func severityColor(_ descriptor: MetricDescriptor?, _ value: MetricValue?) -> NSColor {
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
    }
}
