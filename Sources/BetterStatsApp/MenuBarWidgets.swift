import AppKit
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

public final class MenuBarWidgetController: NSObject {

    public static let defaultsKey = "com.betterstats.menubar.widgets.v1"

    /// If persistence is empty or unreadable we still show *something* clickable, or
    /// the main window becomes unreachable from the menu bar.
    static let fallbackConfigs = [
        WidgetConfig(metricID: MetricID.batteryDrain.rawValue, style: .textWithLabel)
    ]

    static let historyCap = 60   // sparkline samples kept per metric

    private let onClick: () -> Void
    private let defaults: UserDefaults
    private var storedConfigs: [WidgetConfig] = []
    /// Only the widgets that materialized — an item whose button failed to appear is
    /// dropped here but its config is kept, so it can come back next rebuild.
    private var items: [(config: WidgetConfig, item: NSStatusItem)] = []
    private var history: [String: [Double]] = [:]

    public var configs: [WidgetConfig] { storedConfigs }

    /// `onClick` is the integrator's "open the main window". `defaults` is injectable
    /// for tests; production uses .standard.
    public init(onClick: @escaping () -> Void, defaults: UserDefaults = .standard) {
        self.onClick = onClick
        self.defaults = defaults
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

    /// Pull current values from MetricRegistry and redraw every widget. Call after
    /// each `MetricRegistry.shared.update(with:)`. Values are read through the
    /// registry (thread-safe); the AppKit mutation is trampolined to the main thread.
    public func refresh() {
        onMain {
            for entry in self.items { self.render(entry) }
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
        for entry in items { NSStatusBar.system.removeStatusItem(entry.item) }
        items.removeAll()

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
            item.autosaveName = "BetterStatsWidget.\(index).\(config.metricID)"
            button.target = self
            button.action = #selector(widgetClicked)
            items.append((config, item))
        }
        items.reverse()   // back to config order for renders and test seams
        for entry in items { render(entry) }
    }

    /// Every widget opens the main window — the widgets ARE the app's front door.
    @objc private func widgetClicked() { onClick() }

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

        button.toolTip = WidgetRenderer.toolTip(
            metricID: entry.config.metricID, descriptor: descriptor, value: value)

        switch entry.config.style {
        case .text, .textWithLabel:
            button.image = nil
            button.imagePosition = .noImage
            // Status item buttons default to a single clipped line.
            (button.cell as? NSButtonCell)?.usesSingleLineMode = false
            button.lineBreakMode = .byClipping
            button.attributedTitle = WidgetRenderer.attributedTitle(
                style: entry.config.style, descriptor: descriptor, value: value)
        case .bar, .sparkline, .dot:
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            button.image = WidgetRenderer.image(
                style: entry.config.style, descriptor: descriptor, value: value,
                history: history[entry.config.metricID] ?? [])
        }
    }

    /// Test seam: materialized buttons in config order. Internal on purpose.
    var _buttons: [NSStatusBarButton] { items.compactMap { $0.item.button } }
}

/// Pure rendering — (style, descriptor, value) → attributed string / image — kept
/// free of NSStatusItem so it can be exercised headlessly.
enum WidgetRenderer {

    static func attributedTitle(style: WidgetStyle, descriptor: MetricDescriptor?,
                                value: MetricValue?) -> NSAttributedString {
        // Stacked label-over-value, matching the density convention menu bar
        // monitors use. Two small lines occupy less horizontal space than one
        // medium line plus a separator, and horizontal space is the scarce
        // resource up there.
        //
        // Both lines use labelColor. secondaryLabelColor is a low-contrast grey
        // that is legible against a plain desktop and effectively invisible against
        // a busy or light wallpaper — every other menu bar element uses full-weight
        // label colour for exactly this reason.
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        // The menu bar is only ~22pt tall, so the two lines have to be pulled
        // tight or the second one is clipped.
        para.maximumLineHeight = 10
        para.minimumLineHeight = 10
        para.lineSpacing = 0

        let out = NSMutableAttributedString()

        let stacked = (style == .textWithLabel)
        if stacked {
            // "?" for an unknown metric: neutral, and the tooltip carries the detail.
            // A per-reading label wins over the descriptor's: see MetricValue.label.
            let label = value?.label ?? descriptor?.shortTitle ?? "?"
            out.append(NSAttributedString(string: label + "\n", attributes: [
                .font: labelFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: para]))
        }

        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        if let v = value {
            out.append(NSAttributedString(string: v.text, attributes: valueAttrs))
            if v.isEstimate {
                // Same marker the app uses for an uncalibrated total. Never hidden.
                out.append(NSAttributedString(string: "*", attributes: valueAttrs))
            }
        } else {
            out.append(NSAttributedString(string: "\u{2014}", attributes: valueAttrs))
        }
        return out
    }

    static func toolTip(metricID: String, descriptor: MetricDescriptor?,
                        value: MetricValue?) -> String {
        guard let d = descriptor else {
            return "Unknown metric “\(metricID)” — it may belong to another version of BetterStats"
        }
        guard let v = value else { return "\(d.title): no data" }
        return "\(d.title): \(v.text)\(v.isEstimate ? " (estimate)" : "")"
    }

    static func image(style: WidgetStyle, descriptor: MetricDescriptor?,
                      value: MetricValue?, history: [Double]) -> NSImage? {
        switch style {
        case .dot:       return dotImage(color: severityColor(descriptor, value))
        case .bar:       return barImage(descriptor: descriptor, value: value)
        case .sparkline: return sparklineImage(history: history)
        case .text, .textWithLabel: return nil
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
        case .count, .bytes:  return nil
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
