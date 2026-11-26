import AppKit
import PowerKit

// ── Hardware View: the controller ───────────────────────────────────────────
//
// Decides what the Hardware tab's pane is told, and when. The pane (`HardwarePane`) is behind `HardwareViewHosting` and every
// reading of the Mac is behind `Providers`, so the whole controller is tested with fakes and nothing in a test shows a window
// or reads this Mac.
//
// BEFORE THE TAB IS SHOWN NOTHING EXISTS. Until `paneAppeared()` the controller holds nothing: no pane, no history, no provider
// is ever called, and `feed` returns on a flag. The pane is made once, on the first `paneAppeared()`. There is no timer, no
// thread and no observer here: the app's tick calls `feed`, and the 24 h charge history is asked for by `feed` itself (at most
// once a minute, through a provider that answers on the main queue). Leaving the tab (`paneDisappeared()`) clears everything
// again.
//
// Main thread only.

final class HardwareViewController {

    /// The running controller, for the tick to find.
    static weak var current: HardwareViewController?

    /// The charge history is looked up at most this often (seconds of `now()`) while the tab is showing.
    static let chargeHistoryInterval: TimeInterval = 60

    /// Everything the view reads about this Mac that the tick's snapshots do not carry. Each is called only while the tab is
    /// showing, and `swapBytes` at most once per `feed`.
    struct Providers {
        var traits: () -> MacTraits
        var swapBytes: () -> UInt64?
        var brightness: () -> Double?
        var nvme: () -> NVMeHealth.Sample?
        var volume: () -> (freeBytes: UInt64, totalBytes: UInt64)?
        var helperInstalled: () -> Bool
        /// The fans the app's one fan session is holding at a target, by index, with the rpm asked. Empty is automatic. The
        /// session is the only truth for MANUAL: this controller keeps no copy of it.
        var heldFans: () -> [Int: Double]
        var menuBarWidgets: () -> [MenuBarWidgetText]
        /// Reads the last 24 hours of battery charge off the main thread and calls back on the main queue.
        var fetchChargeHistory: (@escaping ([Double?]) -> Void) -> Void
    }

    private let providers: Providers
    private let makeHost: () -> HardwareViewHosting
    private let sendFan: (Int, Double?) -> Void
    private let installHelper: () -> Void
    private let now: () -> Date

    /// Made on the first `paneAppeared()` and kept until `shutdown()`: the main window owns the view it is.
    private var host: HardwareViewHosting?
    private var showing = false

    // State that exists only while the tab is showing.
    private var layout: HardwareLayout?
    private var history = HardwareHistory()
    private var chargeHistory: [Double?] = []
    private var lastChargeFetch: Date?
    /// Bumped whenever the state is cleared, so a charge history that arrives after the tab was left is dropped.
    private var chargeGeneration = 0
    /// The fan count the layout was last resolved for: the traits' own count at `paneAppeared()` (nil when the traits did not
    /// know), then each measured count the family was worked out again for. The traits are asked for again only when a sampled
    /// tick measures a different count, never on every tick.
    private var lastResolvedFanCount: Int?

    /// True between `paneAppeared()` and `paneDisappeared()`.
    var isShowing: Bool { showing }

    init(providers: Providers,
         makeHost: @escaping () -> HardwareViewHosting,
         sendFan: @escaping (Int, Double?) -> Void, installHelper: @escaping () -> Void,
         now: @escaping () -> Date = Date.init) {
        self.providers = providers
        self.makeHost = makeHost
        self.sendFan = sendFan
        self.installHelper = installHelper
        self.now = now
        HardwareViewController.current = self
    }

    deinit {
        if HardwareViewController.current === self { HardwareViewController.current = nil }
    }

    // MARK: The tab appearing and going

    /// The Hardware tab is on screen: makes the pane (once), works the family out from the traits, starts the charge lookup and
    /// draws the picture at once, before the first reading arrives.
    func paneAppeared() {
        guard !showing else { return }
        let traits = providers.traits()
        let resolved = HardwareLayout.layout(for: MacFamilyResolver.resolve(traits))
        let pane = host ?? makeAndWireHost()
        host = pane
        layout = resolved
        lastResolvedFanCount = Self.fanCount(of: traits.fans)
        showing = true
        fetchChargeHistoryIfDue()
        pane.update(layout: resolved, readings: nil, history: history, chargeHistory: chargeHistory,
                    menuBarWidgets: providers.menuBarWidgets())
    }

    /// The tab was left: everything kept for it is dropped (history, readings, the charge history), a charge history still on
    /// its way is ignored when it lands, and the pane forgets its pinned card.
    func paneDisappeared() {
        guard showing else { return }
        showing = false
        clearState()
        host?.reset()
    }

    /// Ends the controller's part with the app: the pane lets go of its callbacks and is reset. Safe to call again.
    func shutdown() {
        let old = host
        host = nil
        showing = false
        clearState()
        old?.onFanSlider = nil
        old?.onInstallHelper = nil
        old?.reset()
        if HardwareViewController.current === self { HardwareViewController.current = nil }
    }

    private func makeAndWireHost() -> HardwareViewHosting {
        let new = makeHost()
        new.onFanSlider = { [weak self] index, rpm in self?.fanSlider(index, rpm) }
        new.onInstallHelper = { [weak self] in self?.installHelper() }
        return new
    }

    private func clearState() {
        layout = nil
        history = HardwareHistory()
        chargeHistory = []
        lastChargeFetch = nil
        lastResolvedFanCount = nil
        chargeGeneration += 1
    }

    // MARK: Fans

    /// Only forwards: whether a fan reads MANUAL comes from the session (`providers.heldFans`), which is what knows whether the
    /// helper took the request, refused it, or let every fan go.
    private func fanSlider(_ index: Int, _ rpm: Double?) {
        sendFan(index, rpm)
    }

    // MARK: The tick

    /// Called by the app's tick, on the main thread. A flag check only when the tab is not showing.
    func feed(system: SystemMetrics.Snapshot, power: PowerMonitor.Snapshot?) {
        guard showing, let host, var current = layout else { return }

        current = reconciled(current, with: system)
        layout = current

        fetchChargeHistoryIfDue()

        // Read once and only here, so a tick reads the swap at most once.
        let swap = providers.swapBytes()
        let readings = HardwareReadings.make(system: system, power: power,
                                             swapBytes: swap,
                                             brightness: providers.brightness(),
                                             nvme: providers.nvme(),
                                             helperInstalled: providers.helperInstalled(),
                                             manualTargets: providers.heldFans(),
                                             volume: providers.volume())
        history.append(readings)
        host.update(layout: current, readings: readings, history: history,
                    chargeHistory: chargeHistory, menuBarWidgets: providers.menuBarWidgets())
    }

    /// The fan count a `FanPresence.State` states: nil when nobody measured it.
    private static func fanCount(of state: FanPresence.State) -> Int? {
        switch state {
        case .fans(let n): return n
        case .fanless: return 0
        case .unknown: return nil
        }
    }

    /// A real reading overrides the drawing: when the fans the sensors found are not the count the family was resolved for
    /// (the traits' own at `paneAppeared()`, or the last measured one), the family is worked out again with the measured count
    /// (a mismatch resolves to `.generic`; a measured count the traits did not know can resolve to a real family). Never while
    /// the sensors were not read this tick: no fans listed then means "not measured", not "none".
    private func reconciled(_ current: HardwareLayout, with system: SystemMetrics.Snapshot) -> HardwareLayout {
        guard system.sensorsSampled else { return current }
        let measured = system.fans.count
        guard measured != lastResolvedFanCount else { return current }
        lastResolvedFanCount = measured
        var traits = providers.traits()
        traits.fans = measured == 0 ? .fanless : .fans(measured)
        let family = MacFamilyResolver.resolve(traits)
        return family == current.family ? current : HardwareLayout.layout(for: family)
    }

    // MARK: Charge history

    private func fetchChargeHistoryIfDue() {
        let at = now()
        if let last = lastChargeFetch, at >= last, at.timeIntervalSince(last) < Self.chargeHistoryInterval { return }
        lastChargeFetch = at
        let generation = chargeGeneration
        providers.fetchChargeHistory { [weak self] values in
            guard let self, self.showing, self.chargeGeneration == generation else { return }
            self.chargeHistory = values
        }
    }
}
