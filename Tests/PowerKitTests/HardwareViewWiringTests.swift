import XCTest
@testable import AnodeApp
@testable import PowerKit

/// How the Hardware tab is joined to the app: the one call that feeds it and where it sits, that the tab's appearing and
/// leaving are told to the controller, that none of its files has a clock of its own, that nothing of the old Beta feature,
/// window or menu entry is left, and where the tab sits in the rail. Mostly source assertions, as `MemoryWatchWiringTests`
/// makes them: they read the files and run nothing.
final class HardwareViewWiringTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text with comments taken out (a comment says what is not done) and string literals blanked.
    private func code(_ path: String) throws -> String {
        NoSharedSettingsInTestsTests.codeOnly(try source(path), keepStrings: false)
    }

    /// The text of `text` from the first `start` up to the first `end` after it.
    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(text.range(of: start), "no \(start)")
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), "no \(end) after \(start)")
        return String(text[a.lowerBound..<b.lowerBound])
    }

    // ── The tick ────────────────────────────────────────────────────────────

    func testTheTabIsFedFromExactlyOnePlaceAndItIsRefreshPane() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        XCTAssertEqual(main.components(separatedBy: "hardwareView?.feed(").count - 1, 1, "one call site")
        XCTAssertEqual(main.components(separatedBy: "hardwareView?.feed(system: sys, power: lastSnapshot)").count - 1, 1)
        let refresh = try slice(main, from: "func refreshPane()", to: "static func lens(forWidget")
        XCTAssertTrue(refresh.contains("case .hardware: hardwareView?.feed(system: sys, power: lastSnapshot)"),
                      "the feed is not in refreshPane's switch")
    }

    func testTheFeedIsOnTheMainThreadSideAndNotInTheSamplingQueue() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        // Everything the sampling queue runs for a tick: from the gate's submit to the end of the tick.
        let sampled = try slice(main, from: "sampleGate.submit(on: sampling)", to: "update(droppedSamples:")
        XCTAssertFalse(sampled.contains("hardwareView"), "the sampling queue must not touch the Hardware controller")
        // And refreshPane is reached from `apply`, which runs after a hop to the main queue.
        XCTAssertTrue(sampled.contains("self.apply(snap)"))
        let apply = try slice(main, from: "func apply(", to: "refreshPane()")
        XCTAssertFalse(apply.isEmpty)
    }

    // ── The tab appearing and leaving ───────────────────────────────────────

    func testSelectTellsTheControllerWhenTheTabAppearsAndGoes() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        XCTAssertEqual(main.components(separatedBy: "hardwareView?.paneAppeared()").count - 1, 1)
        XCTAssertEqual(main.components(separatedBy: "hardwareView?.paneDisappeared()").count - 1, 1)
        let select = try slice(main, from: "func select(_ lens: SidebarView.Lens)", to: "var visibleNeeds")
        XCTAssertTrue(select.contains("hardwareView?.paneAppeared()"))
        XCTAssertTrue(select.contains("hardwareView?.paneDisappeared()"))
        // Leaving is detected against the lens that was showing, so it holds whatever called select.
        XCTAssertTrue(select.contains("let previous = self.lens"))
        XCTAssertTrue(select.contains("previous == .hardware, lens != .hardware"))
        // The pane is put in the window on every entry, after the controller has made it.
        let appeared = try XCTUnwrap(select.range(of: "hardwareView?.paneAppeared()"))
        let shown = try XCTUnwrap(select.range(of: "main.showPane(pane)"))
        XCTAssertLessThan(appeared.lowerBound, shown.lowerBound)
        XCTAssertTrue(select.contains("case .hardware:"))
    }

    func testThePaneIsMadeLazilyByTheControllerAndTheControllerIsShutDownWithTheApp() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        XCTAssertTrue(main.contains("var hardwareView: HardwareViewController?"))
        XCTAssertTrue(main.contains("var hardwarePane: HardwarePane?"))
        XCTAssertEqual(main.components(separatedBy: "HardwareViewRuntime.live(").count - 1, 1)
        XCTAssertEqual(main.components(separatedBy: "hardwareView?.shutdown()").count - 1, 1)
        let live = try slice(main, from: "HardwareViewRuntime.live(", to: "soundMenu = SoundMenuRuntime.live(")
        XCTAssertTrue(live.contains("makeHost:"))
        XCTAssertTrue(live.contains("HardwarePane(frame: .zero)"))
        XCTAssertTrue(live.contains("self?.hardwarePane = pane"))
        XCTAssertFalse(live.contains("onChange:"), "the tab has no window to tell the timer about")
        // The controller is asked once for the pane; nothing here builds one eagerly.
        XCTAssertEqual(main.components(separatedBy: "HardwarePane(").count - 1, 1)
    }

    func testTheTabAddsNothingToTheTimerOrTheSamplingRules() throws {
        let main = try code("Sources/AnodeApp/main.swift")
        XCTAssertTrue(main.contains("static func tickIsHidden(visible: Bool, panelOpen: Bool, gameShowing: Bool) -> Bool"))
        XCTAssertTrue(main.contains("static func samplingNeeds(base: SystemMetrics.Needs, gameShowing: Bool) -> SystemMetrics.Needs"))
        XCTAssertTrue(main.contains("guard tickRuns(windowDrawn: !hidden) else"))
        XCTAssertTrue(main.contains("guard tickRuns(windowDrawn: visible || panelOpen) else"))
        XCTAssertTrue(main.contains("sysMetrics.fansAreDriven = visible && fansPane.isDrivingFans"))
    }

    // ── No clock of its own ─────────────────────────────────────────────────

    func testNoFileOfTheViewHasATimer() throws {
        let files = ["HardwarePane", "HardwareViewController", "HardwareViewRuntime", "HardwareCanvasView",
                     "HardwareCanvasDrawing", "HardwareDesktopDrawing", "HardwareFanPipeDrawing",
                     "HardwareComponentDrawing", "HardwareStageView", "HardwareFanBlades",
                     "HardwareChassisDrawing", "HardwareDetailCards", "SVGPath"]
        for name in files {
            let text = try code("Sources/AnodeApp/\(name).swift")
            for forbidden in ["Timer(", "Timer.scheduled", "scheduledTimer", "DispatchSource.makeTimerSource",
                              "CADisplayLink", "CVDisplayLink"] {
                XCTAssertFalse(text.contains(forbidden), "\(name).swift has \(forbidden)")
            }
        }
    }

    func testTheFanBladesTurnOnTheSharedMotionClockOnly() throws {
        // The one thing in the view that moves on its own does it through the app's `Motion` registry, which already stops
        // when nothing needs a frame; it makes no clock of its own.
        let text = try code("Sources/AnodeApp/HardwareFanBlades.swift")
        XCTAssertTrue(text.contains("Motion.shared.start("))
    }

    func testTheRuntimeMakesNoObserverAndOneUtilityHopOnly() throws {
        let text = try code("Sources/AnodeApp/HardwareViewRuntime.swift")
        XCTAssertFalse(text.contains("addObserver"))
        XCTAssertFalse(text.contains(".observe("))
        XCTAssertFalse(text.contains("Thread"))
        XCTAssertEqual(text.components(separatedBy: "DispatchQueue.global(").count - 1, 1)
    }

    // ── Nothing of the Beta feature is left ─────────────────────────────────

    func testNothingOfTheOldBetaFeatureWindowOrMenuEntryIsLeft() throws {
        let forbidden = ["hardwareViewEnabled", "HardwareViewFeature", "HardwareViewWindowing", "wantsTick",
                         "hardwareViewShowing", "showHardwareView", "hardwareViewEntryID"]
        let sources = root.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = NoSharedSettingsInTestsTests.codeOnly(try String(contentsOf: url, encoding: .utf8), keepStrings: true)
            scanned += 1
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(url.lastPathComponent) still has \(word)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan found almost nothing")
        let menu = try source("Sources/AnodeApp/AppMenu.swift")
        XCTAssertFalse(menu.contains("Hardware View"), "the menu entry is gone: the View menu lists the lens instead")
    }

    // ── The lens ────────────────────────────────────────────────────────────

    func testHardwareIsTheLastTabOfTheRail() {
        XCTAssertEqual(SidebarView.Lens.allCases.last, .hardware)
        for state: FanPresence.State in [.fanless, .unknown, .fans(1), .fans(2)] {
            XCTAssertEqual(SidebarView.Lens.order(whenFans: state).last, .hardware, "\(state)")
        }
    }

    func testHardwareIsOfferedOnAMacWithAKnownLayoutWhateverItsFans() {
        for state: FanPresence.State in [.fanless, .unknown, .fans(1), .fans(2)] {
            XCTAssertTrue(SidebarView.Lens.hardware.isOffered(whenFans: state, hardwareKnown: true), "\(state)")
            XCTAssertTrue(SidebarView.Lens.order(whenFans: state, hardwareKnown: true).contains(.hardware), "\(state)")
        }
    }

    func testHardwareIsNotOfferedOnAMacWhoseLayoutHasNotBeenAddedYet() {
        for state: FanPresence.State in [.fanless, .unknown, .fans(1), .fans(2)] {
            XCTAssertFalse(SidebarView.Lens.hardware.isOffered(whenFans: state, hardwareKnown: false), "\(state)")
            let rail = SidebarView.Lens.order(whenFans: state, hardwareKnown: false)
            XCTAssertFalse(rail.contains(.hardware), "\(state)")
            // Everything else is untouched, and the menu numbers follow the rail.
            XCTAssertEqual(rail, SidebarView.Lens.order(whenFans: state).filter { $0 != .hardware }, "\(state)")
            XCTAssertEqual(ViewMenu.lensItems(for: rail).count, rail.count, "\(state)")
        }
    }

    func testTheRailAsksTheResolverNotAList() throws {
        let side = try code("Sources/AnodeApp/SidebarView.swift")
        XCTAssertTrue(side.contains("MacFamilyResolver.resolve(HardwareViewRuntime.traits()) != .generic"))
        XCTAssertTrue(side.contains("hardwareKnown: thisMacHasHardwareLayout"))
    }

    func testHardwareIsAWholeMachineTabWithTheSixReadingsItDraws() {
        let lens = SidebarView.Lens.hardware
        XCTAssertFalse(lens.isPerProcess)
        XCTAssertEqual(lens.title, "Hardware")
        XCTAssertEqual(lens.symbolName, "laptopcomputer")
        XCTAssertNil(lens.metric)
        XCTAssertEqual(lens.needs, [.cpu, .memory, .gpu, .network, .disk, .sensors])
        XCTAssertEqual(lens.needs.rawValue, SystemMetrics.Needs.all.rawValue)
        XCTAssertGreaterThan(lens.summary.count, 20)
    }

    func testTheHardwareTabKeepsTheBatteryUnderneath() {
        XCTAssertEqual(BottomContext.forLens(.hardware, sortKey: "cpu", resource: .cpu), .battery)
    }

    // ── The fan slider ──────────────────────────────────────────────────────

    func testTheSliderForwarderSendsTheStripsGesturesAndNeverInstalls() throws {
        let panel = try code("Sources/AnodeApp/FanControlPanel.swift")
        let forwarder = try slice(panel, from: "func hardwareViewFan(", to: "private func wanted(")
        XCTAssertTrue(forwarder.contains("gesture(.setSpeed("))
        XCTAssertTrue(forwarder.contains("gesture(.release)"))
        XCTAssertFalse(forwarder.contains("install("), "a slider never installs the helper; only the install button does")
        XCTAssertFalse(forwarder.contains("installHelper"))
        XCTAssertFalse(forwarder.contains("elevate("))
    }

    func testTheInstallPromptUsesTheStripsInstallAction() throws {
        let runtime = try code("Sources/AnodeApp/HardwareViewRuntime.swift")
        XCTAssertTrue(runtime.contains("installHelper(report: { _ in }, from: .fansTab)"))
        XCTAssertTrue(runtime.contains("hardwareViewFan(index: index, rpm: rpm, fans: currentFans())"))
    }

    // ── What the runtime reads for the view ─────────────────────────────────

    private func registry() -> MetricRegistry {
        let r = MetricRegistry()
        r.register(MetricDescriptor(id: MetricID("test.a"), title: "Alpha", shortTitle: "A", unit: .count,
                                    category: "Test", higherIsWorse: true)) {
            MetricValue(value: 12, text: "12%", isEstimate: false)
        }
        r.register(MetricDescriptor(id: MetricID("test.none"), title: "Nothing yet", shortTitle: "N", unit: .count,
                                    category: "Test", higherIsWorse: true)) { nil }
        return r
    }

    func testTheWidgetsAreTheOwnersEnabledOnesWithTheirReadings() {
        let configs = [WidgetConfig(metricID: "test.a", style: .text),
                       WidgetConfig(metricID: "test.a", style: .textWithLabel),
                       WidgetConfig(metricID: "test.a", style: .bar, enabled: false),
                       WidgetConfig(metricID: MetricID.groupPlaceholder.rawValue, style: .group)]
        let out = HardwareViewRuntime.menuBarWidgets(configs: configs, enabled: true, registry: registry())
        XCTAssertEqual(out, [MenuBarWidgetText(label: nil, value: "12%"),
                             MenuBarWidgetText(label: "A", value: "12%")])
    }

    func testAMetricWithNoReadingShowsADashNotZero() {
        let configs = [WidgetConfig(metricID: "test.none", style: .textWithLabel),
                       WidgetConfig(metricID: "no.such.metric", style: .text)]
        let out = HardwareViewRuntime.menuBarWidgets(configs: configs, enabled: true, registry: registry())
        XCTAssertEqual(out, [MenuBarWidgetText(label: "N", value: "\u{2014}"),
                             MenuBarWidgetText(label: nil, value: "\u{2014}")])
    }

    func testNoWidgetsAreDrawnWhileTheMenuBarWidgetsAreOff() {
        let configs = [WidgetConfig(metricID: "test.a", style: .text)]
        XCTAssertEqual(HardwareViewRuntime.menuBarWidgets(configs: configs, enabled: false, registry: registry()), [])
    }

    func testNoMoreWidgetsThanThePictureHasRoomFor() {
        let configs = (0..<9).map { _ in WidgetConfig(metricID: "test.a", style: .text) }
        XCTAssertEqual(HardwareViewRuntime.menuBarWidgets(configs: configs, enabled: true, registry: registry()).count,
                       HardwareViewRuntime.maxMenuBarWidgets)
    }

    func testTheNativeWidthIsTheFlaggedModesNotTheWidestScaledOne() {
        let native: UInt32 = 0x0200_0000
        // A 14-inch panel: a scaled "More Space" mode renders wider than the panel, and is not flagged native.
        let modes: [(pixelWidth: Int, ioFlags: UInt32)] = [(3024, native), (3600, 0), (2688, 0), (3024, 0)]
        XCTAssertEqual(HardwareViewRuntime.nativePixelWidth(of: modes), 3024)
        // No mode flagged: the widest there is. None at all: unknown, never a number.
        XCTAssertEqual(HardwareViewRuntime.nativePixelWidth(of: [(2000, 0), (3000, 0)]), 3000)
        XCTAssertNil(HardwareViewRuntime.nativePixelWidth(of: []))
    }

    func testTheChargeHistoryIsARealTimeAxisWithGapsKept() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let width = 24.0 * 3600 / 96
        func point(_ seconds: Double, _ soc: Double?) -> HistoryStore.SeriesPoint {
            HistoryStore.SeriesPoint(time: since.addingTimeInterval(seconds), watts: 5, onBattery: true, socPercent: soc)
        }
        let points = [
            point(-60, 99),                 // before the window: skipped
            point(10, 80),                  // slot 0
            point(width * 2 + 5, 70),       // slot 2 (slot 1 recorded nothing: a gap, not a 0)
            point(width * 2 + 100, 65),     // same slot: the later point wins
            point(width * 3 + 1, nil),      // slot 3 recorded no charge
            point(width * 95 + 1, 40),      // the last slot
            point(width * 96 + 500, 30),    // past the end: clamped into the last slot
        ]
        let series = HardwareViewRuntime.chargeSeries(from: points, since: since, width: width)
        XCTAssertEqual(series.count, HardwareViewRuntime.chargeHistoryMaxPoints)
        XCTAssertEqual(series.count, 96)
        XCTAssertEqual(series[0] ?? nil, 80)
        XCTAssertNil(series[1])
        XCTAssertEqual(series[2] ?? nil, 65)
        XCTAssertNil(series[3])
        XCTAssertEqual(series[95] ?? nil, 30)
        XCTAssertEqual(series.compactMap { $0 }.count, 3)
        // A 24 hour range with no rows at all is 96 gaps, not an empty array.
        let empty = HardwareViewRuntime.chargeSeries(from: [], since: since, width: width)
        XCTAssertEqual(empty.count, 96)
        XCTAssertTrue(empty.allSatisfy { $0 == nil })
    }
}
