import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The Hardware View's controller, over fakes: no window server is asked for anything and nothing reads this Mac.
final class HardwareViewControllerTests: XCTestCase {

    // MARK: Fakes

    private final class FakeHost: HardwareViewHosting {
        struct Update {
            let layout: HardwareLayout
            let readings: HardwareReadings?
            let history: HardwareHistory
            let chargeHistory: [Double?]
            let menuBarWidgets: [MenuBarWidgetText]
        }

        var onFanSlider: ((Int, Double?) -> Void)?
        var onInstallHelper: (() -> Void)?
        /// What the real pane answers for "can anyone see me" (covered, hidden or minimised: false).
        var isDrawingNow = true
        var resetCount = 0
        var updates: [Update] = []

        func update(layout: HardwareLayout, readings: HardwareReadings?, history: HardwareHistory,
                    chargeHistory: [Double?], menuBarWidgets: [MenuBarWidgetText]) {
            updates.append(Update(layout: layout, readings: readings, history: history,
                                  chargeHistory: chargeHistory, menuBarWidgets: menuBarWidgets))
        }

        func reset() { resetCount += 1 }
    }

    /// Everything the controller is given, with counters.
    private final class Rig {
        var hosts: [FakeHost] = []
        var traits = MacTraits(model: "Mac17,9", chip: "Apple M5 Pro", fans: .fans(2), hasBattery: true,
                               builtInDisplayPixelWidth: 3024)
        var swap: UInt64? = 123
        var helper = false
        /// What the app's fan session says it is holding (empty is automatic): the only source of MANUAL.
        var held: [Int: Double] = [:]
        var widgets = [MenuBarWidgetText(label: "CPU", value: "41\u{00B0}")]
        var now = Date(timeIntervalSince1970: 1_000_000)

        var traitsCalls = 0
        var swapCalls = 0
        var otherCalls = 0
        var fetchCompletions: [([Double?]) -> Void] = []
        var sent: [(index: Int, rpm: Double?)] = []
        var installs = 0

        var providerCalls: Int { traitsCalls + swapCalls + otherCalls + fetchCompletions.count }
        var host: FakeHost { hosts[hosts.count - 1] }

        func providers() -> HardwareViewController.Providers {
            HardwareViewController.Providers(
                traits: { self.traitsCalls += 1; return self.traits },
                swapBytes: { self.swapCalls += 1; return self.swap },
                brightness: { self.otherCalls += 1; return 0.5 },
                nvme: { self.otherCalls += 1; return nil },
                volume: { self.otherCalls += 1; return (freeBytes: 100, totalBytes: 400) },
                helperInstalled: { self.otherCalls += 1; return self.helper },
                heldFans: { self.otherCalls += 1; return self.held },
                menuBarWidgets: { self.otherCalls += 1; return self.widgets },
                fetchChargeHistory: { completion in self.fetchCompletions.append(completion) })
        }
    }

    private func make(rig: Rig) -> HardwareViewController {
        let controller = HardwareViewController(
            providers: rig.providers(),
            makeHost: { let h = FakeHost(); rig.hosts.append(h); return h },
            sendFan: { rig.sent.append((index: $0, rpm: $1)) },
            installHelper: { rig.installs += 1 },
            now: { rig.now })
        addTeardownBlock { controller.shutdown() }
        return controller
    }

    private func twoFans() -> SystemMetrics.Snapshot {
        HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2500), HardwareFixtures.fan(1, rpm: 2600)],
                                memory: HardwareFixtures.memory())
    }

    // MARK: Nothing exists before the pane appears

    func testNothingHappensBeforeThePaneAppears() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.feed(system: twoFans(), power: nil)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertTrue(rig.hosts.isEmpty, "no pane is made before the tab is shown")
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(rig.providerCalls, 0, "no provider is called before the tab is shown")
        // Leaving a tab that was never shown changes nothing either.
        controller.paneDisappeared()
        XCTAssertTrue(rig.hosts.isEmpty)
        XCTAssertEqual(rig.providerCalls, 0)
    }

    func testThePaneAppearingMakesTheHostOnceAndDrawsAtOnce() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        XCTAssertEqual(rig.hosts.count, 1)
        XCTAssertTrue(controller.isShowing)
        XCTAssertEqual(rig.traitsCalls, 1)
        XCTAssertEqual(rig.swapCalls, 0, "appearing reads no swap")
        XCTAssertEqual(rig.fetchCompletions.count, 1, "the charge history is asked for right away")
        let first = try XCTUnwrap(rig.host.updates.first, "the drawing is handed over at once")
        XCTAssertEqual(first.layout.family, .macBookPro14ProMax)
        XCTAssertNil(first.readings)
        XCTAssertEqual(first.menuBarWidgets, rig.widgets)
        // Appearing again while it is showing does nothing.
        controller.paneAppeared()
        XCTAssertEqual(rig.hosts.count, 1)
        XCTAssertEqual(rig.host.updates.count, 1)
        XCTAssertEqual(rig.traitsCalls, 1)
    }

    func testLeavingTheTabClearsHistoryAndCachedReadings() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        rig.fetchCompletions[0]([10, 20])
        controller.feed(system: twoFans(), power: nil)
        controller.feed(system: twoFans(), power: nil)
        let host = rig.host
        XCTAssertEqual(host.updates.last?.history.count, 2)
        XCTAssertEqual(host.updates.last?.chargeHistory.count, 2)

        controller.paneDisappeared()
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(host.resetCount, 1, "the pane forgets its card and its readings")
        let updatesBefore = host.updates.count
        let calls = rig.providerCalls
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(host.updates.count, updatesBefore, "feed is a no-op once the tab is left")
        XCTAssertEqual(rig.providerCalls, calls, "nothing is read for a tab that is not showing")
        // Leaving twice resets once.
        controller.paneDisappeared()
        XCTAssertEqual(host.resetCount, 1)
    }

    func testComingBackStartsCleanAndResolvesTheFamilyAgain() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        rig.fetchCompletions[0]([1, 2, 3])
        let oneFan = HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2500)], sensorsSampled: true)
        controller.feed(system: oneFan, power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .generic)
        controller.paneDisappeared()

        rig.traits.fans = .fans(2)
        let traitsBefore = rig.traitsCalls
        controller.paneAppeared()
        XCTAssertEqual(rig.hosts.count, 1, "the same pane is used again")
        XCTAssertEqual(rig.traitsCalls, traitsBefore + 1, "the family is worked out again from the traits")
        let first = try XCTUnwrap(rig.host.updates.last)
        XCTAssertEqual(first.layout.family, .macBookPro14ProMax)
        XCTAssertNil(first.readings)
        XCTAssertEqual(first.history.count, 0, "the history of the last visit is gone")
        XCTAssertEqual(first.chargeHistory.count, 0, "so is its charge history")
        XCTAssertEqual(rig.fetchCompletions.count, 2, "the charge lookup starts again at once")
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.history.count, 1)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .macBookPro14ProMax)
    }

    // MARK: Feeding

    func testFeedWhileShowingUpdatesTheHostWithReadingsAndHistory() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        XCTAssertEqual(rig.fetchCompletions.count, 1, "the charge history is asked for right after the pane appears")
        rig.fetchCompletions[0]([10, nil, 30])
        controller.feed(system: twoFans(), power: nil)
        controller.feed(system: twoFans(), power: nil)

        let host = rig.host
        XCTAssertEqual(host.updates.count, 3)
        let last = try XCTUnwrap(host.updates.last)
        let readings = try XCTUnwrap(last.readings)
        XCTAssertEqual(readings.fans.count, 2)
        XCTAssertEqual(readings.cpuTemp.value ?? 0, 41.4, accuracy: 0.001)
        XCTAssertEqual(readings.memory?.swapBytes.value, 123)
        XCTAssertEqual(readings.storage?.freeBytes, 100)
        XCTAssertFalse(readings.helperInstalled)
        XCTAssertEqual(last.history.count, 2)
        XCTAssertEqual(last.chargeHistory.count, 3)
        XCTAssertEqual(last.chargeHistory[0], 10)
        XCTAssertNil(last.chargeHistory[1])
        XCTAssertEqual(last.menuBarWidgets, rig.widgets)
        XCTAssertEqual(last.layout.family, .macBookPro14ProMax)

        rig.helper = true
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.readings?.helperInstalled, true)
    }

    func testAReadingIsStillHandedOverWhileTheHostIsNotDrawing() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        rig.host.isDrawingNow = false
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.count, 2, "the host stores it; it decides whether to draw")
        XCTAssertNotNil(rig.host.updates.last?.readings)
    }

    func testSwapIsReadAtMostOncePerFeed() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        XCTAssertEqual(rig.swapCalls, 0, "appearing reads no swap")
        for tick in 1...3 {
            controller.feed(system: twoFans(), power: nil)
            XCTAssertEqual(rig.swapCalls, tick)
        }
    }

    // MARK: Charge history

    func testChargeHistoryIsFetchedAtMostOncePerMinute() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        XCTAssertEqual(rig.fetchCompletions.count, 1)
        controller.feed(system: twoFans(), power: nil)
        rig.now.addTimeInterval(30)
        controller.feed(system: twoFans(), power: nil)
        rig.now.addTimeInterval(29)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.fetchCompletions.count, 1, "59 s after the first lookup is too soon")
        rig.now.addTimeInterval(1)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.fetchCompletions.count, 2)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.fetchCompletions.count, 2)
    }

    func testALateChargeHistoryAfterTheTabIsLeftIsIgnored() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        let late = rig.fetchCompletions[0]
        controller.paneDisappeared()
        late([1, 2, 3])
        // Coming back must not inherit the old answer.
        controller.paneAppeared()
        XCTAssertEqual(rig.host.updates.last?.chargeHistory.count, 0)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.chargeHistory.count, 0)
        // And one that arrives for this visit is kept.
        rig.fetchCompletions[1]([5])
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.chargeHistory.count, 1)
        // The old visit's answer arriving once more still changes nothing.
        late([9, 9, 9, 9])
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.chargeHistory.count, 1)
    }

    func testALateChargeHistoryAfterShutdownIsIgnored() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        let late = rig.fetchCompletions[0]
        controller.shutdown()
        late([1, 2, 3])
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.count, 1, "nothing is drawn after the shutdown")
    }

    // MARK: Family

    func testFanCountMismatchUsesTheGenericLayout() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        let oneFan = HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2500)], sensorsSampled: false)
        controller.feed(system: oneFan, power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .macBookPro14ProMax,
                       "no reading of the sensors, no change of family")
        XCTAssertEqual(rig.traitsCalls, 1, "only the one read when the pane appeared")

        let measured = HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2500)], sensorsSampled: true)
        controller.feed(system: measured, power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .generic,
                       "a real reading of one fan overrides a drawing of two")
        controller.feed(system: measured, power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .generic)
        XCTAssertEqual(rig.traitsCalls, 2, "the traits are asked again only when the count changes")
    }

    func testMatchingFanCountKeepsTheFamily() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .macBookPro14ProMax)
        XCTAssertEqual(rig.traitsCalls, 1)
    }

    func testAFanCountTheTraitsDidNotKnowIsResolvedFromTheFirstMeasuredCount() {
        let rig = Rig()
        rig.traits.fans = .unknown
        let controller = make(rig: rig)
        controller.paneAppeared()
        XCTAssertEqual(rig.host.updates.last?.layout.family, .generic, "unknown fans are the generic drawing")
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .macBookPro14ProMax,
                       "two fans measured: the family is worked out again with them")
        XCTAssertEqual(rig.traitsCalls, 2)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.traitsCalls, 2, "the same count is not resolved again")
    }

    func testAChangedMeasuredCountIsResolvedAgainEachTimeItChanges() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        let one = HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2500)], sensorsSampled: true)
        controller.feed(system: one, power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .generic)
        XCTAssertEqual(rig.traitsCalls, 2)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.host.updates.last?.layout.family, .macBookPro14ProMax, "the second fan is back")
        XCTAssertEqual(rig.traitsCalls, 3)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.traitsCalls, 3)
    }

    // MARK: Fans

    func testAHeldFanReadsManualAndIsForgottenOnRelease() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        // A slider gesture alone does not make a fan manual: the session decides (the helper may refuse the request).
        rig.host.onFanSlider?(1, 4200)
        controller.feed(system: twoFans(), power: nil)
        XCTAssertTrue(try XCTUnwrap(rig.host.updates.last?.readings?.fans).allSatisfy { !$0.isManual })

        rig.held = [1: 4200]
        controller.feed(system: twoFans(), power: nil)
        let manual = try XCTUnwrap(rig.host.updates.last?.readings?.fans.first { $0.index == 1 })
        XCTAssertTrue(manual.isManual)
        XCTAssertEqual(manual.targetRPM, 4200)
        XCTAssertFalse(try XCTUnwrap(rig.host.updates.last?.readings?.fans.first { $0.index == 0 }).isManual)

        rig.host.onFanSlider?(1, nil)
        rig.held = [:]
        controller.feed(system: twoFans(), power: nil)
        let released = try XCTUnwrap(rig.host.updates.last?.readings?.fans.first { $0.index == 1 })
        XCTAssertFalse(released.isManual)
    }

    /// One chip press hands every fan back (the session has no per-fan release): when the session holds nothing, no fan reads
    /// as manual.
    func testOneNilReleasesEveryManualFan() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        rig.held = [0: 3000, 1: 4200]
        controller.feed(system: twoFans(), power: nil)
        let fans = try XCTUnwrap(rig.host.updates.last?.readings?.fans)
        XCTAssertTrue(fans.allSatisfy { $0.isManual })

        rig.host.onFanSlider?(1, nil)
        XCTAssertEqual(rig.sent.last?.index, 1)
        XCTAssertNil(rig.sent.last?.rpm)
        rig.held = [:]
        controller.feed(system: twoFans(), power: nil)
        let after = try XCTUnwrap(rig.host.updates.last?.readings?.fans)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.allSatisfy { !$0.isManual }, "fan 0 was handed back too")
    }

    /// A tab left and opened again knows nothing of its own, so a fan the session still holds reads MANUAL at once.
    func testAHeldFanStillReadsManualWhenTheTabIsOpenedAgain() throws {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        rig.held = [1: 4200]
        controller.feed(system: twoFans(), power: nil)
        XCTAssertTrue(try XCTUnwrap(rig.host.updates.last?.readings?.fans.first { $0.index == 1 }).isManual)

        controller.paneDisappeared()
        controller.paneAppeared()
        XCTAssertEqual(rig.hosts.count, 1)
        controller.feed(system: twoFans(), power: nil)
        let again = try XCTUnwrap(rig.host.updates.last?.readings?.fans.first { $0.index == 1 })
        XCTAssertTrue(again.isManual, "the session still holds fan 1")
        XCTAssertEqual(again.targetRPM, 4200)
    }

    func testSendFanIsForwarded() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        rig.host.onFanSlider?(0, 3000)
        rig.host.onFanSlider?(0, nil)
        XCTAssertEqual(rig.sent.count, 2)
        XCTAssertEqual(rig.sent[0].index, 0)
        XCTAssertEqual(rig.sent[0].rpm, 3000)
        XCTAssertNil(rig.sent[1].rpm)
        rig.host.onInstallHelper?()
        XCTAssertEqual(rig.installs, 1)
    }

    func testTheHostIsWiredOnceAndKeepsItsCallbacksAcrossVisits() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        controller.paneDisappeared()
        controller.paneAppeared()
        XCTAssertEqual(rig.hosts.count, 1)
        rig.host.onFanSlider?(1, 3500)
        XCTAssertEqual(rig.sent.count, 1)
    }

    // MARK: The controller itself

    func testShutdownIsIdempotent() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.paneAppeared()
        let host = rig.host
        controller.shutdown()
        XCTAssertEqual(host.resetCount, 1)
        XCTAssertNil(host.onFanSlider, "the pane no longer reaches back")
        XCTAssertNil(host.onInstallHelper)
        XCTAssertFalse(controller.isShowing)
        XCTAssertNil(HardwareViewController.current)
        controller.shutdown()
        XCTAssertEqual(host.resetCount, 1, "a second shutdown does nothing")
        let calls = rig.providerCalls
        controller.feed(system: twoFans(), power: nil)
        XCTAssertEqual(rig.providerCalls, calls)
        XCTAssertEqual(host.updates.count, 1)
    }

    func testShutdownBeforeAnythingWasShownDoesNothing() {
        let rig = Rig()
        let controller = make(rig: rig)
        controller.shutdown()
        controller.shutdown()
        XCTAssertTrue(rig.hosts.isEmpty)
        XCTAssertEqual(rig.providerCalls, 0)
    }

    func testTheRunningControllerIsFoundThroughCurrent() {
        let rig = Rig()
        let controller = make(rig: rig)
        XCTAssertTrue(HardwareViewController.current === controller)
    }
}
