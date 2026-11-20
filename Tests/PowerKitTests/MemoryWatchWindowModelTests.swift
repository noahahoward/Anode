import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Findings and plans the three Memory Watch window test files share.
enum MemoryWatchFixtures {

    static let wall = Date(timeIntervalSince1970: 1_700_000_000)   // 22:13:20 UTC

    static func mib(_ n: UInt64) -> UInt64 { n << 20 }

    /// Five readings climbing from 1024 MiB to 1836 MiB, the last at awake second 1000 (the moment of the flag).
    static func history() -> [MemorySample] {
        [(900.0, 1024), (925.0, 1224), (950.0, 1424), (975.0, 1624), (1000.0, 1836)]
            .map { MemorySample(seconds: $0.0, bytes: mib(UInt64($0.1))) }
    }

    /// Safari's helper: +412 MiB over 75 s from 1424 MiB (+29%).
    static func finding(pid: pid_t = 4412, start: UInt64 = 777, name: String = "Safari",
                        path: String = "/Applications/Safari.app/Contents/Frameworks/WebContent",
                        identityKey: String = "/Applications/Safari.app", isApp: Bool = true,
                        history: [MemorySample]? = nil) -> Finding {
        Finding(processKey: ProcessKey(pid: pid, startAbsTime: start), pid: pid, name: name, path: path,
                identityKey: identityKey, isApp: isApp,
                startBytes: mib(1424), nowBytes: mib(1836), netGrowthBytes: mib(412),
                windowSeconds: 75, bucketSeconds: 18.75,
                flaggedAtWall: wall, flaggedAtAwake: 1000,
                risingSamples: 21, totalSamples: 24, largestDipBytes: mib(6),
                history: history ?? Self.history(), shouldNotify: true)
    }

    /// The Mac running low: Safari's helper at 1836 MiB on a 16 GB Mac with 91% of memory in use and 3 GB of swap.
    static func pressureFinding(nonApp: Bool = false) -> Finding {
        var f = nonApp ? nodeFinding() : finding()
        f.tier = .pressure
        f.reason = .oneAppDominates
        f.system = SystemMemoryReading(totalBytes: mib(16384), usedBytes: mib(14909), swapUsedBytes: 3 << 30, pressureLevel: 2)
        return f
    }

    /// A lone `node`: not an app, so its identity is its own executable path.
    static func nodeFinding(pid: pid_t = 100, start: UInt64 = 5) -> Finding {
        finding(pid: pid, start: start, name: "node", path: "/opt/homebrew/bin/node",
                identityKey: "/opt/homebrew/bin/node", isApp: false)
    }

    static func plan(wholeApp: Bool, pids: [pid_t], refused: [(pid: pid_t, owner: String)] = [],
                     gone: Bool = false) -> MemoryWatchQuitPlan {
        MemoryWatchQuitPlan(wholeApp: wholeApp, appName: wholeApp ? "Safari" : "node", flaggedPID: pids.first ?? 0,
                            flaggedStart: 777, signalable: pids, refused: refused, alreadyGone: gone)
    }
}

final class MemoryWatchWindowModelTests: XCTestCase {

    private func model(_ finding: Finding = MemoryWatchFixtures.finding(), live: [MemorySample] = [],
                       plan: MemoryWatchQuitPlan? = nil, bundleID: String? = nil) -> MemoryWatchWindowModel {
        MemoryWatchWindowModel(finding: finding, live: live, plan: plan, bundleID: bundleID,
                               timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    // MARK: Header

    func testHeaderNamesTheAppTheProcessThePidAndTheBundle() {
        let m = model(bundleID: "com.apple.Safari")
        XCTAssertEqual(m.title, "Safari")
        XCTAssertEqual(MemoryWatchWindowModel.heading, "Possible memory leak")
        XCTAssertEqual(m.detailLine, "WebContent · pid 4412 · com.apple.Safari")
    }

    func testAnAppWithNoKnownBundleIdShowsItsPathAndANonAppShowsItsExecutable() {
        XCTAssertEqual(model().detailLine, "WebContent · pid 4412 · /Applications/Safari.app")
        XCTAssertEqual(model(MemoryWatchFixtures.nodeFinding()).detailLine, "node · pid 100 · /opt/homebrew/bin/node")
    }

    // MARK: Stats

    func testStatsAreNowGrewAndRate() {
        let m = model()
        XCTAssertEqual(m.stats.map(\.label), ["Now", "Grew", "Rate"])
        XCTAssertEqual(m.nowText, "1.8 GB")
        XCTAssertEqual(m.grewText, "+412 MB (+29%)")
        XCTAssertEqual(m.rateText, "~5.5MB/s")
        XCTAssertEqual(m.stats.map(\.value), ["1.8 GB", "+412 MB (+29%)", "~5.5MB/s"])
    }

    func testTheGrowthLineSaysHowLongAndSinceWhen() {
        // 22:13:20 UTC is the moment of the flag; the window began 75 s earlier.
        XCTAssertEqual(model().grewDetail, "over 75 s, since 22:12:05")
    }

    /// A slow finding reads in hours, not seconds, and its rate per hour.
    func testASlowFindingReadsInHoursAndAPerHourRate() {
        var f = MemoryWatchFixtures.finding()
        f.tier = .slow
        f.windowSeconds = 7800
        f.netGrowthBytes = MemoryTestKit.mib(1170)
        let m = MemoryWatchWindowModel(finding: f, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(m.grewDetail.hasPrefix("over 2 hours 10 minutes, since "), m.grewDetail)
        XCTAssertTrue(m.rateText.hasSuffix("/hour"), m.rateText)
    }

    func testNowFollowsTheLatestLivePoint() {
        let live = [MemorySample(seconds: 1008, bytes: MemoryWatchFixtures.mib(2048))]
        XCTAssertEqual(model(live: live).nowText, "2.0 GB")
        XCTAssertEqual(model().nowText, "1.8 GB")
    }

    // MARK: Explanation

    func testTheExplanationIsTheFindingsOwnSentence() {
        let finding = MemoryWatchFixtures.finding()
        let m = model(finding)
        XCTAssertEqual(m.explanation, finding.explanation)
        XCTAssertTrue(m.explanation.contains("rose in 21 of 24 samples"))
        XCTAssertTrue(m.explanation.contains("never fell back by more than 6.0 MB"))
        XCTAssertEqual(MemoryWatchWindowModel.whyHeading, "Why Anode flagged this")
    }

    // MARK: Buttons and captions

    func testAnAppOffersQuitAppAndForceQuitApp() {
        let m = model()
        XCTAssertTrue(m.wholeApp)
        XCTAssertEqual(m.quitTitle, "Quit App")
        XCTAssertEqual(m.forceQuitTitle, "Force Quit App")
    }

    func testANonAppOffersQuitProcessAndForceQuitProcess() {
        let m = model(MemoryWatchFixtures.nodeFinding())
        XCTAssertFalse(m.wholeApp)
        XCTAssertEqual(m.quitTitle, "Quit Process")
        XCTAssertEqual(m.forceQuitTitle, "Force Quit Process")
    }

    func testCaptionsSayTheWholeAppAndHowManyProcesses() {
        let plan = MemoryWatchFixtures.plan(wholeApp: true, pids: [1, 2, 3, 4, 5, 6, 7])
        let m = model(plan: plan)
        XCTAssertEqual(m.quitCaption, "Asks the whole app to quit: all 7 processes.")
        XCTAssertEqual(m.forceQuitCaption, "Kills the whole app: all 7 processes.")
    }

    func testCaptionsBeforeThePlanStillSayWholeApp() {
        let m = model()
        XCTAssertTrue(m.quitCaption.contains("whole app"))
        XCTAssertTrue(m.forceQuitCaption.contains("whole app"))
        XCTAssertFalse(m.buttonsEnabled, "the buttons wait for the plan")
    }

    func testCaptionsSayOnlyThisOneProcessAndItsPid() {
        let m = model(MemoryWatchFixtures.nodeFinding(), plan: MemoryWatchFixtures.plan(wholeApp: false, pids: [100]))
        XCTAssertEqual(m.quitCaption, "Asks only this one process (pid 100) to quit. Nothing else is touched.")
        XCTAssertEqual(m.forceQuitCaption, "Kills only this one process (pid 100). Nothing else is touched.")
        XCTAssertFalse(m.quitCaption.contains("whole app"))
        XCTAssertFalse(m.forceQuitCaption.contains("whole app"))
    }

    func testAnAppWithOneProcessSaysSo() {
        let m = model(plan: MemoryWatchFixtures.plan(wholeApp: true, pids: [4412]))
        XCTAssertEqual(m.forceQuitCaption, "Kills the whole app: its 1 process.")
    }

    func testButtonsAreEnabledOnlyWhenThePlanCanAct() {
        XCTAssertTrue(model(plan: MemoryWatchFixtures.plan(wholeApp: true, pids: [4412])).buttonsEnabled)
        let gone = MemoryWatchFixtures.plan(wholeApp: true, pids: [], gone: true)
        let m = model(plan: gone)
        XCTAssertFalse(m.buttonsEnabled)
        XCTAssertEqual(m.planNote, "That process already exited")
        XCTAssertTrue(m.planNoteIsProblem)
    }

    func testARootOwnedProcessIsExplainedNotOffered() {
        let plan = MemoryWatchFixtures.plan(wholeApp: false, pids: [], refused: [(pid: 100, owner: "root")])
        let m = model(MemoryWatchFixtures.nodeFinding(), plan: plan)
        XCTAssertFalse(m.buttonsEnabled)
        XCTAssertEqual(m.planNote, "Owned by root — Anode cannot signal it")
    }

    func testTheProcessesLineAppearsOnlyForAnAppWithSeveralProcesses() {
        let many = MemoryWatchFixtures.plan(wholeApp: true, pids: [1, 2, 3, 4, 5, 6], refused: [(pid: 7, owner: "root")])
        XCTAssertEqual(model(plan: many).processesLine,
                       "Safari has 7 processes running. The one growing is pid 4412.")
        XCTAssertNil(model(plan: MemoryWatchFixtures.plan(wholeApp: true, pids: [4412])).processesLine)
        XCTAssertNil(model().processesLine)
        XCTAssertNil(model(MemoryWatchFixtures.nodeFinding(),
                           plan: MemoryWatchFixtures.plan(wholeApp: false, pids: [100])).processesLine)
    }

    func testTheLinksNameTheApp() {
        let m = model()
        XCTAssertEqual(m.ignoreTitle, "Don't warn about Safari")
        XCTAssertEqual(m.ignoredLine, "Anode won't warn about Safari again.")
        XCTAssertEqual(MemoryWatchWindowModel.showInProcessesTitle, "Show in Processes")
    }


    // MARK: A low-memory warning

    private func low(_ finding: Finding = MemoryWatchFixtures.pressureFinding(), live: [MemorySample] = [],
                     plan: MemoryWatchQuitPlan? = nil) -> MemoryWatchWindowModel {
        model(finding, live: live, plan: plan)
    }

    func testALowMemoryWindowHasItsOwnHeadingsAndALeakKeepsItsOwn() {
        let m = low()
        XCTAssertTrue(m.isPressure)
        XCTAssertEqual(m.headingText, "Memory is running low")
        XCTAssertEqual(m.whyHeadingText, "Why Anode warned you")
        XCTAssertEqual(m.windowTitle, "Memory Is Running Low")
        for tier in [GrowthTier.fast, .slow] {
            var f = MemoryWatchFixtures.finding()
            f.tier = tier
            let leak = model(f)
            XCTAssertFalse(leak.isPressure)
            XCTAssertEqual(leak.headingText, "Possible memory leak", "\(tier)")
            XCTAssertEqual(leak.whyHeadingText, "Why Anode flagged this", "\(tier)")
            XCTAssertEqual(leak.windowTitle, "Possible Memory Leak", "\(tier)")
        }
        XCTAssertEqual(MemoryWatchWindowModel.heading, "Possible memory leak")
        XCTAssertEqual(MemoryWatchWindowModel.whyHeading, "Why Anode flagged this")
    }

    func testALowMemoryWindowShowsTheAppsMemoryItsShareOfRAMAndTheSwap() {
        let m = low()
        XCTAssertEqual(m.stats.map(\.label), ["Now", "Of your RAM", "Swap"])
        XCTAssertEqual(m.nowText, "1.8 GB")
        XCTAssertEqual(m.ofRAMText, "11%", "1836 MiB of 16384 MiB")
        XCTAssertEqual(m.swapText, MetricUnit.bytes.format(Double(3 << 30)))
        XCTAssertEqual(m.stats.map(\.value), ["1.8 GB", "11%", MetricUnit.bytes.format(Double(3 << 30))])
        XCTAssertNil(m.emphasizedStat, "no growth to colour")
        XCTAssertEqual(m.underStatsLine, "Mac: 91% of memory in use")
    }

    func testTheShareFollowsTheLatestPointAndHasWordsForWhatIsMissing() {
        let live = [MemorySample(seconds: 1008, bytes: MemoryWatchFixtures.mib(4096))]
        XCTAssertEqual(low(live: live).nowText, "4.0 GB")
        XCTAssertEqual(low(live: live).ofRAMText, "25%")

        var tiny = MemoryWatchFixtures.pressureFinding()
        tiny.history = [MemorySample(seconds: 1000, bytes: MemoryWatchFixtures.mib(10))]
        XCTAssertEqual(low(tiny).ofRAMText, "<1%")

        var unknown = MemoryWatchFixtures.pressureFinding()
        unknown.system = nil
        XCTAssertEqual(low(unknown).ofRAMText, "\u{2014}")
        XCTAssertEqual(low(unknown).swapText, "\u{2014}")
        XCTAssertEqual(low(unknown).underStatsLine, "")

        var empty = MemoryWatchFixtures.pressureFinding()
        empty.system = SystemMemoryReading(totalBytes: 0, usedBytes: 0)
        XCTAssertEqual(low(empty).ofRAMText, "\u{2014}", "never a division by zero")
    }

    func testALowMemoryGraphIsTheAppsMemoryAndHasNoFlaggedSpan() {
        let m = low()
        XCTAssertEqual(m.graphSeriesName, "Safari memory (GB)")
        XCTAssertEqual(m.memoryPoints.count, 5, "the same series as a leak's")
        XCTAssertTrue(m.flaggedPoints.isEmpty, "no overlay")
        XCTAssertEqual(model().graphSeriesName, "Memory (GB)")
        XCTAssertEqual(model().flaggedPoints.count, 4, "a leak still marks the span the verdict rested on")
    }

    func testALowMemoryWindowExplainsWithTheFindingsWordsAndAddsTheHint() {
        let f = MemoryWatchFixtures.pressureFinding()
        let m = low(f)
        XCTAssertEqual(m.explanation, f.explanation)
        XCTAssertEqual(m.explanationHint, "Quit App closes the whole app; save your work first")
        let tool = low(MemoryWatchFixtures.pressureFinding(nonApp: true))
        XCTAssertEqual(tool.explanationHint, "Quit Process asks only this process to quit; save your work first")
        XCTAssertNil(model().explanationHint, "a leak's window has no hint")
    }

    func testALowMemoryWindowHasTheSameButtonsCaptionsAndSafetyAsALeaks() {
        let plan = MemoryWatchFixtures.plan(wholeApp: true, pids: [1, 2, 3, 4, 5, 6, 7])
        let m = low(plan: plan)
        XCTAssertEqual(m.quitTitle, "Quit App")
        XCTAssertEqual(m.forceQuitTitle, "Force Quit App")
        XCTAssertEqual(m.quitCaption, "Asks the whole app to quit: all 7 processes.")
        XCTAssertEqual(m.forceQuitCaption, "Kills the whole app: all 7 processes.")
        XCTAssertTrue(m.buttonsEnabled)
        XCTAssertEqual(m.processesLine, "Safari has 7 processes running. The largest is pid 4412.", "nothing is growing")
        XCTAssertEqual(model(plan: plan).processesLine, "Safari has 7 processes running. The one growing is pid 4412.")

        let tool = low(MemoryWatchFixtures.pressureFinding(nonApp: true), plan: MemoryWatchFixtures.plan(wholeApp: false, pids: [100]))
        XCTAssertEqual(tool.quitTitle, "Quit Process")
        XCTAssertEqual(tool.quitCaption, "Asks only this one process (pid 100) to quit. Nothing else is touched.")

        let gone = low(plan: MemoryWatchFixtures.plan(wholeApp: true, pids: [], gone: true))
        XCTAssertFalse(gone.buttonsEnabled)
        XCTAssertEqual(gone.planNote, "That process already exited")
    }

    func testALowMemoryWindowNamesTheMacWhenNoAppIsNamed() {
        var f = MemoryWatchFixtures.pressureFinding()
        f.name = ""
        XCTAssertEqual(low(f).title, "Your Mac")
        XCTAssertEqual(low().title, "Safari")
        var leak = MemoryWatchFixtures.finding()
        leak.name = ""
        XCTAssertEqual(model(leak).title, "", "a leak's header is as it was")
    }

    func testALeaksNumbersAreAsTheyWere() {
        let m = model()
        XCTAssertFalse(m.isPressure)
        XCTAssertEqual(m.stats.map(\.label), ["Now", "Grew", "Rate"])
        XCTAssertEqual(m.emphasizedStat, 1)
        XCTAssertEqual(m.underStatsLine, m.grewDetail)
        XCTAssertEqual(m.underStatsLine, "over 75 s, since 22:12:05")
    }

    // MARK: Graph

    func testTheGraphPlotsGigabytesWithTheReadoutInTheDetail() {
        let m = model()
        XCTAssertFalse(m.historyUnavailable)
        let points = m.memoryPoints
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points[0].value, 1.0, accuracy: 1e-9)
        XCTAssertEqual(points[1].value, 1224.0 / 1024, accuracy: 1e-9)
        XCTAssertEqual(points[4].value, 1836.0 / 1024, accuracy: 1e-9)
        XCTAssertEqual(points[0].detail, "1.0 GB")
        XCTAssertEqual(points[4].detail, "1.8 GB")
    }

    func testPointsSitOnTheWallClockRelativeToTheFlag() {
        let points = model().memoryPoints
        XCTAssertEqual(points[4].time.timeIntervalSince(MemoryWatchFixtures.wall), 0, accuracy: 1e-6)
        XCTAssertEqual(points[0].time.timeIntervalSince(MemoryWatchFixtures.wall), -100, accuracy: 1e-6)
    }

    func testLivePointsExtendTheLineAndStalePointsAreDropped() {
        let live = [MemorySample(seconds: 990, bytes: MemoryWatchFixtures.mib(1)),   // older than the history's end
                    MemorySample(seconds: 1008, bytes: MemoryWatchFixtures.mib(2048)),
                    MemorySample(seconds: 1016, bytes: MemoryWatchFixtures.mib(2100))]
        let points = model(live: live).memoryPoints
        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points[5].value, 2.0, accuracy: 1e-9)
        XCTAssertEqual(points[5].detail, "2.0 GB")
        XCTAssertEqual(points[5].time.timeIntervalSince(MemoryWatchFixtures.wall), 8, accuracy: 1e-6)
    }

    func testTheFlaggedSpanIsTheWindowTheVerdictRestedOn() {
        // The window is 75 s ending at second 1000, so it starts at 925: four of the five points.
        let flagged = model().flaggedPoints
        XCTAssertEqual(flagged.count, 4)
        XCTAssertEqual(flagged.first?.value ?? 0, 1224.0 / 1024, accuracy: 1e-9)
        XCTAssertEqual(flagged.last?.value ?? 0, 1836.0 / 1024, accuracy: 1e-9)
        // A live point after the flag is not part of the flagged span.
        let live = [MemorySample(seconds: 1008, bytes: MemoryWatchFixtures.mib(2048))]
        XCTAssertEqual(model(live: live).flaggedPoints.count, 4)
    }

    func testNoHistoryMeansAMessageInsteadOfAGraph() {
        let m = model(MemoryWatchFixtures.finding(history: []))
        XCTAssertTrue(m.historyUnavailable)
        XCTAssertEqual(MemoryWatchWindowModel.historyUnavailableText, "History isn't available after Anode restarted.")
        XCTAssertTrue(m.memoryPoints.isEmpty)
        XCTAssertEqual(m.nowText, "1.8 GB", "the numbers still come from the finding")
    }
}
