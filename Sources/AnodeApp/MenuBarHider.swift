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
    /// Posted (main thread) whenever the decision, the item lists or the pill's open state change, for the settings section.
    static let didChange = Notification.Name("AnodeMenuBarHiderDidChange")

    private static let anodePrefix = MenuBarWidgetController.key(forMetricID: "")
    /// The accessibility label `BarChevron` gives itself, which is how the chevron is found among the items read.
    static let chevronLabel = "Menu bar icons"

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
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// Between the two reads that must agree, and before the first read after the chevron appears: AppKit and macOS lay the
    /// bar out a moment after anything changes it, so two reads back to back can both see the old layout.
    static let readGap: TimeInterval = 0.4
    /// Before a layout that would not hold still is read again.
    static let retryDelay: TimeInterval = 1.0
    static let maxRetries = 3

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
    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The last layout two reads agreed on.
    private var confirmed: [BarItem]?
    private var generation = 0
    private var lastLogged: String?
    /// The widgets the last pass folded: a change moves everything on the bar, so nothing is covered from the read before it.
    private var appliedFolded: Set<String> = []
    private var chevronOn = false
    private var retries = 0

    init(settings: Settings, reader: BarReading, covers: CoverPresenting, pill: PillPresenting, chevron: ChevronPresenting,
         widgets: WidgetFolding, environment: @escaping () -> HiderEnvironment, now: @escaping () -> Date = Date.init,
         ownPID: pid_t = getpid(), log: @escaping (String) -> Void = { FeatureLog.append("menubarhider.log", $0) },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
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
        self.schedule = schedule
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
            let fresh = !chevronOn
            chevronOn = true
            chevron.install()
            if fresh {
                let gen = generation
                schedule(Self.readGap + 0.1) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.startRead(attempt: 0, previous: self.confirmed)
                }
            } else {
                startRead(attempt: 0, previous: confirmed)
            }
        }
    }

    /// The display or the bar is changing under the covers: take them down now, and trust nothing read before this. The
    /// re-read that follows (the caller's) puts them back if there is still something to cover.
    func invalidateCovers() {
        guard settings.menuBarHiderEnabled else { return }
        generation += 1
        confirmed = nil
        if !covers.rects.isEmpty { covers.removeAll() }
    }

    /// Something that moves the bar happened (an app started or quit, a Space or screen change, Anode's own widgets were
    /// rebuilt). `screenChanged` also closes the pill, which was placed for the old screen.
    func layoutMayHaveChanged(screenChanged: Bool = false) {
        if screenChanged { closePill() }
        reevaluate()
    }

    /// The pill can be opened while the bar is collapsed, and also while it is only briefly unreadable or settling: Anode's
    /// folded widgets would otherwise have no route. Never in full screen, nor when the hider is off or has nothing to show
    /// (an open pill can always be closed).
    var canTogglePill: Bool {
        guard !items.isEmpty || pillState.isOpen else { return false }
        switch decision {
        case .collapsed, .standDown(.layoutUnreadable), .standDown(.settling): return true
        case .standDown: return false
        }
    }

    func togglePill() {
        guard canTogglePill else { return }
        pillState.toggle(now: now(), autoClose: settings.menuBarHiderAutoCloseSeconds)
        syncPill()
        changed()
    }

    /// The owner clicked away from the pill.
    func dismissPill() {
        guard pillState.isOpen else { return }
        closePill()
        changed()
    }

    /// Close the pill when its time is up. Called by a timer that runs only while the pill is open.
    func tick() {
        let was = pillState.isOpen
        pillState.tick(now: now())
        if was != pillState.isOpen { syncPill(); changed() }
    }

    func shutdown() {
        generation += 1
        pillState.close()
        pill.hide()
        covers.removeAll()
        chevron.remove()
        widgets.setFolded([])
        confirmed = nil
        chevronOn = false
        appliedFolded = []
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
            if let previous, self.sameCovers(previous, result) {
                self.apply(result)
            } else if attempt == 0 {
                // The layout is not the one the covers were drawn for: they come down now, not after the confirming read.
                self.covers.removeAll()
                self.schedule(Self.readGap) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.startRead(attempt: 1, previous: result)
                }
            } else {
                self.covers.removeAll()
                self.note("layout still moving; no cover")
                self.scheduleRetry(gen)
            }
        }
    }

    private func scheduleRetry(_ gen: Int) {
        guard retries < Self.maxRetries else { return }
        retries += 1
        schedule(Self.retryDelay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.reevaluate()
        }
    }

    /// How far apart, per edge, two reads' covers can be and still be the same layout: Accessibility's rounding, not a move.
    static let coverTolerance: CGFloat = 2

    /// Whether two reads would put up the same covers, and agree on where the chevron is. Only what the covers are drawn
    /// from is compared: an item that stays on the bar and changes width every second (a CPU reading, a clock) would
    /// otherwise make every pair of reads disagree. Both are planned with the arrangement the newer read would use.
    private func sameCovers(_ older: [BarItem], _ newer: [BarItem]) -> Bool {
        let screen = environment().screen
        func chevronOnBar(_ read: [BarItem]) -> Bool? { read.first(where: isChevron).map { $0.isOnBar(screens: [screen]) } }
        guard chevronOnBar(older) == chevronOnBar(newer) else { return false }
        let arrangement = self.arrangement(for: newer)
        let a = coverPlan(older, arrangement: arrangement, screen: screen)
        let b = coverPlan(newer, arrangement: arrangement, screen: screen)
        guard a.count == b.count else { return false }
        let t = Self.coverTolerance
        return zip(a, b).allSatisfy {
            abs($0.minX - $1.minX) <= t && abs($0.maxX - $1.maxX) <= t && abs($0.minY - $1.minY) <= t && abs($0.maxY - $1.maxY) <= t
        }
    }

    /// The covers for one read. Other apps' items are what can be hidden. Anode's own items on the bar (its chevron, widgets
    /// it keeps there) stay: they are given to the planner as locked, so a run of hidden items is split around them and no
    /// cover reaches over them.
    private func coverPlan(_ read: [BarItem], arrangement: BarArrangement, screen: CGRect) -> [CGRect] {
        let others = read.filter { $0.pid != ownPID }
        let ownOnBar: [BarItem] = read.filter { $0.pid == ownPID && $0.isOnBar(screens: [screen]) }.map { item in
            var stays = item
            stays.isLocked = true
            return stays
        }
        return CoverPlanner.covers(items: others + ownOnBar, arrangement: arrangement, screen: screen)
    }

    /// Every item the owner can arrange in this read: other apps' items and Anode's own widgets.
    private func arrangeable(_ read: [BarItem]) -> [BarItem] { read.filter { $0.pid != ownPID } + ownPseudoItems() }

    /// The owner's arrangement, or the first one for this read when there is none yet. Stored only by `apply`.
    private func arrangement(for read: [BarItem]) -> BarArrangement {
        settings.menuBarHiderArrangement ?? BarArrangement.defaultArrangement(for: arrangeable(read))
    }

    // ── Acting ──────────────────────────────────────────────────────────────

    private func apply(_ read: [BarItem]) {
        confirmed = read
        let env = environment()
        // The chevron is the owner's only way to the hidden icons. macOS gives a new status item the leftmost place and, on a
        // full bar, parks it off the bar where it cannot be clicked: then nothing may be hidden.
        let chevronItem = read.first(where: isChevron)
        let verdict = HiderPolicy.decide(enabled: settings.menuBarHiderEnabled, accessibilityTrusted: env.trusted,
                                         layoutReadable: true, fullScreen: env.fullScreen,
                                         secondsSinceSpaceOrDisplayChange: env.secondsSinceChange,
                                         itemsOnThisScreen: read.contains { $0.isOnBar(screens: [env.screen]) },
                                         chevronOnBar: chevronItem?.isOnBar(screens: [env.screen]) ?? true)
        if case .standDown(let why) = verdict { retries = 0; standDown(why); return }
        guard chevronItem != nil else {
            // Not laid out yet (it was just created, or the bar is being rebuilt): not a layout to cover from. Read again
            // shortly; `retries` is not reset here, so a chevron that never shows does not keep the Mac reading.
            note("no chevron in the read; reading again")
            standDown(.layoutUnreadable)
            scheduleRetry(generation)
            return
        }
        retries = 0

        // Anode's folded widgets are listed from the widget controller, not the read: they have no place on the bar.
        let all = arrangeable(read)
        let arrangement = self.arrangement(for: read)
        // A read without the system's own items (battery, sound, Wi-Fi) is not a first arrangement worth keeping.
        if settings.menuBarHiderArrangement == nil, !arrangement.pinned.isEmpty { settings.menuBarHiderArrangement = arrangement }

        let foldedIDs = Set(widgets.widgetKeys.filter { arrangement.group(of: $0.key, items: all) == .behindChevron }.map(\.metricID))
        items = arrangement.pillItems(from: all)
        allItems = all
        if foldedIDs != appliedFolded {
            // Folding or unfolding moves everything on the bar. Nothing is covered from the read taken before it: the covers
            // come down and the bar is read again once macOS has laid it out.
            appliedFolded = foldedIDs
            widgets.setFolded(foldedIDs)
            covers.removeAll()
            confirmed = nil
            decision = .collapsed
            let gen = generation
            schedule(Self.readGap + 0.1) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.startRead(attempt: 0, previous: nil)
            }
            changed()
            return
        }

        let rects = coverPlan(read, arrangement: arrangement, screen: env.screen)
        if rects != covers.rects {
            rects.isEmpty ? covers.removeAll() : covers.show(rects, on: env.screen)
        }
        decision = .collapsed
        note("collapsed: \(rects.count) cover(s), \(items.count) behind the chevron")
        if pillState.isOpen { syncPill() }
        changed()
    }

    /// Anode's chevron among the items read: one of Anode's own, named by the label `BarChevron` gives it (or, should macOS
    /// report the status item's autosave name as its identifier, keyed by that).
    private func isChevron(_ item: BarItem) -> Bool {
        item.pid == ownPID && (item.title == Self.chevronLabel || item.key.hasSuffix("|" + BarChevron.autosaveName))
    }

    /// Anode's own widgets, as items the owner can arrange (they have no place on the bar to read).
    private func ownPseudoItems() -> [BarItem] {
        widgets.widgetKeys.map {
            BarItem(key: $0.key, bundleID: "dev.anode.app", appName: "Anode", title: $0.title, frame: .zero,
                    isLocked: false, hasPress: false, pid: nil)
        }
    }

    private func standDown(_ why: HiderRefusal) {
        let didChange = decision != .standDown(why)
        decision = .standDown(why)
        if !covers.rects.isEmpty { covers.removeAll() }
        let passing = why == .layoutUnreadable || why == .settling
        if !passing { closePill() }
        if why == .disabled {
            generation += 1
            confirmed = nil
            allItems = []
            items = []
            chevronOn = false
            appliedFolded = []
            chevron.remove()
        } else {
            chevronOn = true
            chevron.install()
            if passing && items.isEmpty {
                // Never read yet: Anode's own widgets are still known, and are what the pill can show.
                let own = ownPseudoItems()
                let arrangement = settings.menuBarHiderArrangement ?? BarArrangement.defaultArrangement(for: own)
                items = arrangement.pillItems(from: own)
            }
        }
        // Anode's widgets go back on the bar when the hider can do nothing for them. A passing refusal (full screen, a
        // moving layout, one failed read) leaves them folded: rebuilding the bar for a moment would only make it jump.
        switch why {
        case .disabled, .noAccessibility, .itemsNotOnThisScreen, .chevronOffBar:
            appliedFolded = []
            widgets.setFolded([])
        case .layoutUnreadable, .fullScreen, .settling: break
        }
        note("stand down: \(why)")
        if didChange { changed() }
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
            changed()
        }
    }

    private func note(_ text: String) {
        guard text != lastLogged else { return }
        lastLogged = text
        log(text)
    }
}
