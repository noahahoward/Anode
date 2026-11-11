import AppKit
import PowerKit

// ── Menu Bar Hider: the controller ──────────────────────────────────────────
//
// The one place that decides what the owner sees. Everything it touches is behind a small protocol, so it is tested with
// fakes and never creates a real window, status item or accessibility call in a test:
//
//   BarReading       reads every item in the menu bar (Accessibility) and presses one
//   CoverPresenting  the solid panels over the items that are behind the chevron
//   PillPresenting   the floating panel under the notch that shows those items
//   ChevronPresenting the one status item that opens the pill
//   WidgetFolding    Anode's own widgets, which fold into the pill instead of sitting on the bar
//
// The rule that matters most: a stale cover is worse than none. A cover is drawn only from two reads that agree, and any
// failed read, refusal or disagreement takes it away.

protocol BarReading: AnyObject {
    /// Calls back on the main queue with every item in the bar, or nil when the bar could not be read in time.
    func read(completion: @escaping ([BarItem]?) -> Void)
    /// Opens the item's own menu, as a click on it would.
    func press(_ item: BarItem)
}

protocol CoverPresenting: AnyObject {
    var rects: [CGRect] { get }
    /// `rects` are in top-left screen points on `screen`.
    func show(_ rects: [CGRect], on screen: CGRect)
    func removeAll()
}

protocol PillPresenting: AnyObject {
    var isShowing: Bool { get }
    /// `origin` is the pill's top-left corner in top-left screen points, nil to let the pill choose.
    func show(items: [BarItem], origin: CGPoint?, press: @escaping (BarItem) -> Void)
    func hide()
}

protocol ChevronPresenting: AnyObject {
    var onToggle: (() -> Void)? { get set }
    func install()
    func remove()
}

protocol WidgetFolding: AnyObject {
    /// Anode's own widgets, each filed under the key `MenuBarWidgetController.key(forMetricID:)`.
    var widgetKeys: [(key: String, metricID: String, title: String)] { get }
    func setFolded(_ metricIDs: Set<String>)
    /// Opens the widget's menu, anchored to the pill.
    func openWidgetMenu(metricID: String)
}

/// What the world looks like now; asked for on every evaluation.
struct HiderEnvironment: Equatable {
    var trusted: Bool
    var fullScreen: Bool
    var secondsSinceChange: TimeInterval
    /// The screen carrying the status items, top-left global points.
    var screen: CGRect
    var notch: CGRect?
    var menuBarHeight: CGFloat
}

final class MenuBarHiderController {

    /// Set by the app so Beta Features can reach the live controller.
    static var current: MenuBarHiderController?

    private static let anodePrefix = MenuBarWidgetController.key(forMetricID: "")

    private let settings: Settings
    private let reader: BarReading
    private let covers: CoverPresenting
    private let pill: PillPresenting
    private let chevron: ChevronPresenting
    private let widgets: WidgetFolding
    private let environment: () -> HiderEnvironment
    private let now: () -> Date
    private let ownPID: pid_t
    private let log: (String) -> Void

    private(set) var decision: HiderDecision = .standDown(.disabled)
    var isCollapsed: Bool { decision == .collapsed }
    private(set) var pillState = PillState()
    var isPillOpen: Bool { pillState.isOpen }
    /// The items behind the chevron, the last time the layout was settled.
    private(set) var items: [BarItem] = []
    /// Every item the owner can arrange: other apps' items and Anode's own widgets (its chevron is not among them).
    private(set) var allItems: [BarItem] = []
    /// Told when the decision or the pill's open state changes.
    var onChange: (() -> Void)?

    /// The last layout two reads agreed on.
    private var confirmed: [BarItem]?
    private var generation = 0
    private var lastLogged: String?

    init(settings: Settings, reader: BarReading, covers: CoverPresenting, pill: PillPresenting, chevron: ChevronPresenting,
         widgets: WidgetFolding, environment: @escaping () -> HiderEnvironment, now: @escaping () -> Date = Date.init,
         ownPID: pid_t = getpid(), log: @escaping (String) -> Void = { FeatureLog.append("menubarhider.log", $0) }) {
        self.settings = settings
        self.reader = reader
        self.covers = covers
        self.pill = pill
        self.chevron = chevron
        self.widgets = widgets
        self.environment = environment
        self.now = now
        self.ownPID = ownPID
        self.log = log
        chevron.onToggle = { [weak self] in self?.togglePill() }
    }

    // ── Entry points ────────────────────────────────────────────────────────

    /// Read the settings and the world, and make the bar match. Safe to call as often as anything changes.
    func reevaluate() {
        generation += 1
        let env = environment()
        let pre = HiderPolicy.decide(enabled: settings.menuBarHiderEnabled, accessibilityTrusted: env.trusted,
                                     layoutReadable: true, fullScreen: env.fullScreen,
                                     secondsSinceSpaceOrDisplayChange: env.secondsSinceChange, itemsOnThisScreen: true)
        if case .standDown(let why) = pre {
            standDown(why)
        } else {
            chevron.install()
            startRead(attempt: 0, previous: confirmed)
        }
    }

    /// Something that moves the bar happened (an app started or quit, a Space or screen change, Anode's own widgets were
    /// rebuilt). `screenChanged` also closes the pill, which was placed for the old screen.
    func layoutMayHaveChanged(screenChanged: Bool = false) {
        if screenChanged { closePill() }
        reevaluate()
    }

    func togglePill() {
        guard isCollapsed else { return }
        pillState.toggle(now: now(), autoClose: settings.menuBarHiderAutoCloseSeconds)
        syncPill()
        onChange?()
    }

    /// The owner clicked away from the pill.
    func dismissPill() {
        guard pillState.isOpen else { return }
        closePill()
        onChange?()
    }

    /// Close the pill when its time is up. Called by a timer that runs only while the pill is open.
    func tick() {
        let was = pillState.isOpen
        pillState.tick(now: now())
        if was != pillState.isOpen { syncPill(); onChange?() }
    }

    func shutdown() {
        generation += 1
        pillState.close()
        pill.hide()
        covers.removeAll()
        chevron.remove()
        widgets.setFolded([])
        confirmed = nil
        decision = .standDown(.disabled)
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    /// Two reads that agree before anything is covered. `previous` is the layout already settled (or the first read of a
    /// pair): when the new read matches it, it is settled; when it does not, read once more and require that read to match
    /// this one. Anything else removes the cover.
    private func startRead(attempt: Int, previous: [BarItem]?) {
        let gen = generation
        reader.read { [weak self] result in
            guard let self, gen == self.generation else { return }
            guard let result else { self.standDown(.layoutUnreadable); return }
            if let previous, Self.sameLayout(previous, result) {
                self.apply(result)
            } else if attempt == 0 {
                self.startRead(attempt: 1, previous: result)
            } else {
                self.covers.removeAll()
                self.note("layout still moving; no cover")
            }
        }
    }

    private static func sameLayout(_ a: [BarItem], _ b: [BarItem]) -> Bool {
        func shape(_ list: [BarItem]) -> [String] {
            list.map { "\($0.key)@\(Int($0.frame.minX.rounded())),\(Int($0.frame.minY.rounded())),\(Int($0.frame.width.rounded())),\(Int($0.frame.height.rounded()))" }.sorted()
        }
        return shape(a) == shape(b)
    }

    // ── Acting ──────────────────────────────────────────────────────────────

    private func apply(_ read: [BarItem]) {
        confirmed = read
        let env = environment()
        let verdict = HiderPolicy.decide(enabled: settings.menuBarHiderEnabled, accessibilityTrusted: env.trusted,
                                         layoutReadable: true, fullScreen: env.fullScreen,
                                         secondsSinceSpaceOrDisplayChange: env.secondsSinceChange,
                                         itemsOnThisScreen: read.contains { $0.isOnBar(screens: [env.screen]) })
        if case .standDown(let why) = verdict { standDown(why); return }

        // Anode's own status items (pinned widgets, the chevron) stay on the bar and are never covered; its folded widgets
        // are listed separately, below, from the widget controller.
        let others = read.filter { $0.pid != ownPID }
        let own = widgets.widgetKeys.map {
            BarItem(key: $0.key, bundleID: "dev.anode.app", appName: "Anode", title: $0.title, frame: .zero,
                    isLocked: false, hasPress: false, pid: nil)
        }
        let all = others + own
        let arrangement = settings.menuBarHiderArrangement ?? {
            let first = BarArrangement.defaultArrangement(for: all)
            settings.menuBarHiderArrangement = first
            return first
        }()

        let foldedIDs = Set(widgets.widgetKeys.filter { arrangement.group(of: $0.key, items: all) == .behindChevron }.map(\.metricID))
        widgets.setFolded(foldedIDs)

        let rects = CoverPlanner.covers(items: others, arrangement: arrangement, screen: env.screen)
        if rects != covers.rects {
            rects.isEmpty ? covers.removeAll() : covers.show(rects, on: env.screen)
        }
        items = arrangement.pillItems(from: all)
        allItems = all
        decision = .collapsed
        note("collapsed: \(rects.count) cover(s), \(items.count) behind the chevron")
        if pillState.isOpen { syncPill() }
        onChange?()
    }

    private func standDown(_ why: HiderRefusal) {
        let changed = decision != .standDown(why)
        decision = .standDown(why)
        if !covers.rects.isEmpty { covers.removeAll() }
        closePill()
        if why == .disabled {
            generation += 1
            confirmed = nil
            allItems = []
            items = []
            chevron.remove()
        } else {
            chevron.install()
        }
        // Anode's widgets go back on the bar when the hider can do nothing for them. A passing refusal (full screen, a
        // moving layout, one failed read) leaves them folded: rebuilding the bar for a moment would only make it jump.
        switch why {
        case .disabled, .noAccessibility, .itemsNotOnThisScreen: widgets.setFolded([])
        case .layoutUnreadable, .fullScreen, .settling: break
        }
        note("stand down: \(why)")
        if changed { onChange?() }
    }

    // ── The pill ────────────────────────────────────────────────────────────

    private func closePill() {
        guard pillState.isOpen || pill.isShowing else { return }
        pillState.close()
        pill.hide()
    }

    private func syncPill() {
        guard pillState.isOpen else { pill.hide(); return }
        let env = environment()
        let cell = CGSize(width: 40, height: 30)
        let size = PillLayout.frames(count: items.count, cell: cell, maxWidth: 520, padding: 10, spacing: 6).size
        let origin = PillLayout.origin(size: size, screen: env.screen, notch: env.notch, menuBarHeight: env.menuBarHeight)
        pill.show(items: items, origin: origin) { [weak self] item in self?.pressed(item) }
    }

    private func pressed(_ item: BarItem) {
        if item.key.hasPrefix(Self.anodePrefix) {
            let metricID = String(item.key.dropFirst(Self.anodePrefix.count))
            widgets.openWidgetMenu(metricID: metricID)
        } else {
            closePill()
            reader.press(item)
            onChange?()
        }
    }

    private func note(_ text: String) {
        guard text != lastLogged else { return }
        lastLogged = text
        log(text)
    }
}
