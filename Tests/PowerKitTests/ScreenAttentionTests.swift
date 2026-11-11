import XCTest
@testable import AnodeApp
@testable import PowerKit

/// "Can anyone see a screen?" — the rule that keeps a MacBook running with its lid shut from drawing for nobody.
/// (Measured: 102 minutes of that, at 400-600 mW, was 23 % of the whole Mac's energy over the period.)
final class ScreenAttentionTests: XCTestCase {

    func testAnOpenLidIsWatchedWhateverElseIsPlugged() {
        XCTAssertTrue(ScreenAttention.someoneCanSee(lidClosed: false, externalDisplayActive: false))
        XCTAssertTrue(ScreenAttention.someoneCanSee(lidClosed: false, externalDisplayActive: true))
    }

    func testAShutLidWithNothingElsePluggedInIsNotWatched() {
        XCTAssertFalse(ScreenAttention.someoneCanSee(lidClosed: true, externalDisplayActive: false))
    }

    func testAShutLidWithAMonitorIsStillWatchedBecauseThatIsClamshellMode() {
        XCTAssertTrue(ScreenAttention.someoneCanSee(lidClosed: true, externalDisplayActive: true))
    }

    /// A desktop has no lid and a laptop's lid can be unreadable. Neither may ever make the app go quiet.
    func testAnUnknownLidIsWatched() {
        XCTAssertTrue(ScreenAttention.someoneCanSee(lidClosed: nil, externalDisplayActive: false))
    }
}

final class ScreenWatchTests: XCTestCase {

    private final class FakeLid: LidStateReader {
        var closed: Bool? = false
        func isClosed() -> Bool? { closed }
    }

    private struct Rig {
        let lid = FakeLid()
        var external = false
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var cpu = 0.0
    }

    /// A watch over fakes. `state` is mutated by the test, and read through the closures at the moment of each update.
    private func make(_ state: Box<Rig>, log: @escaping (String) -> Void = { _ in }) -> ScreenWatch {
        ScreenWatch(lid: state.value.lid,
                    externalDisplayActive: { state.value.external },
                    now: { state.value.clock },
                    cpuSeconds: { state.value.cpu },
                    log: log)
    }

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    func testItStartsWatched() {
        let rig = Box(Rig())
        XCTAssertTrue(make(rig).isWatched)
    }

    func testShuttingTheLidWithNothingElseOnSaysNobodyIsWatchingAndOpeningItSaysTheyAre() {
        let rig = Box(Rig())
        let watch = make(rig)
        var told: [Bool] = []
        watch.onChange = { told.append($0) }

        rig.value.lid.closed = true
        XCTAssertFalse(watch.update())
        XCTAssertFalse(watch.isWatched)

        rig.value.lid.closed = false
        XCTAssertTrue(watch.update())
        XCTAssertEqual(told, [false, true])
    }

    func testAskingAgainWithNothingChangedTellsNobodyTwice() {
        let rig = Box(Rig())
        let watch = make(rig)
        var told = 0
        watch.onChange = { _ in told += 1 }
        rig.value.lid.closed = true
        watch.update(); watch.update(); watch.update()
        XCTAssertEqual(told, 1)
    }

    func testPluggingInAMonitorWhileTheLidIsShutBringsTheAppBack() {
        let rig = Box(Rig())
        let watch = make(rig)
        rig.value.lid.closed = true
        watch.update()
        XCTAssertFalse(watch.isWatched)
        rig.value.external = true
        watch.update()
        XCTAssertTrue(watch.isWatched, "clamshell mode: lid shut, the owner is looking at the monitor")
    }

    func testAnUnreadableLidLeavesItWatched() {
        let rig = Box(Rig())
        let watch = make(rig)
        rig.value.lid.closed = nil
        XCTAssertTrue(watch.update())
    }

    /// The tick asks this once per tick, so with the lid open (nearly always) it must not go looking at displays.
    func testItDoesNotListDisplaysWhileTheLidIsOpen() {
        var asked = 0
        let lid = FakeLid()
        let watch = ScreenWatch(lid: lid, externalDisplayActive: { asked += 1; return false },
                                now: Date.init, cpuSeconds: { 0 }, log: { _ in })
        for _ in 0..<5 { watch.update() }
        XCTAssertEqual(asked, 0)
    }

    /// The evidence for the next "why is it using battery" is in the log: how long nobody was looking and what the app
    /// used meanwhile. 600 s at 3 CPU-seconds is half a percent of a core.
    func testTheLogSaysHowLongNobodyWasLookingAndWhatTheAppUsedMeanwhile() {
        let rig = Box(Rig())
        var lines: [String] = []
        let watch = make(rig) { lines.append($0) }

        rig.value.lid.closed = true
        rig.value.cpu = 100
        watch.update()
        rig.value.clock.addTimeInterval(600)
        rig.value.cpu = 103
        rig.value.lid.closed = false
        watch.update()

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("nobody can see it"), lines[0])
        XCTAssertTrue(lines[1].contains("after 600 s"), lines[1])
        XCTAssertTrue(lines[1].contains("0.50 % of a core"), lines[1])
    }

    func testTheProcessCPUClockMovesForward() {
        let a = ScreenWatch.processCPUSeconds()
        var x = 0.0
        for i in 0..<2_000_000 { x += Double(i).squareRoot() }
        XCTAssertGreaterThan(x, 0)
        XCTAssertGreaterThanOrEqual(ScreenWatch.processCPUSeconds(), a)
    }
}
