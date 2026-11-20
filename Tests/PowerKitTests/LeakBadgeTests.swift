import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

// The "Possible Memory Leak" badge at the right of a Processes row. The matcher is pure; the table side is driven through
// the seams on `LeakBadge`, so no test needs a real process, a real Memory Watch or a window on screen.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Fixtures

private func badgeRow(name: String, bundlePath: String?, isApp: Bool, pids: [pid_t] = [1]) -> Row {
    let drain = AppDrain(identity: AppIdentity(name: name, bundlePath: bundlePath, bundleID: nil, isApp: isApp),
                         joules: 0.08, watts: 0.04, percentPerHour: 0.06,
                         processCount: pids.count, pids: pids,
                         cpuPercent: 1, memoryBytes: 512 << 20,
                         diskReadPerSec: 0, diskWrittenPerSec: 0)
    return Row(app: drain, system: nil, gpu: nil, gpuTimeShare: nil, gpuPercent: nil,
               windowPct: nil, costMin: nil, totalMemoryBytes: 16 << 30)
}

private func safariRow() -> Row {
    badgeRow(name: "Safari", bundlePath: "/Applications/Safari.app", isApp: true, pids: [4412, 4413])
}

private func nodeRow(pid: pid_t = 100) -> Row {
    badgeRow(name: "node", bundlePath: nil, isApp: false, pids: [pid])
}

private func safariFinding(pid: pid_t = 4412, start: UInt64 = 777, at seconds: TimeInterval = 0) -> Finding {
    var f = MemoryWatchFixtures.finding(pid: pid, start: start)
    f.flaggedAtWall = MemoryWatchFixtures.wall.addingTimeInterval(seconds)
    return f
}

private let everythingIsRunning: (Finding) -> Bool = { _ in true }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Matching

final class LeakBadgeMatcherTests: XCTestCase {

    func testAnAppRowMatchesItsOwnAppFinding() {
        let f = safariFinding()
        XCTAssertEqual(LeakBadge.leakFinding(for: safariRow(), among: [f], isAlive: everythingIsRunning), f)
    }

    func testAnAppRowDoesNotMatchAnotherAppsFinding() {
        let other = MemoryWatchFixtures.finding(pid: 900, start: 1, name: "Mail",
                                                path: "/Applications/Mail.app/Contents/MacOS/Mail",
                                                identityKey: "/Applications/Mail.app")
        XCTAssertNil(LeakBadge.leakFinding(for: safariRow(), among: [other], isAlive: everythingIsRunning))
    }

    func testAnAppRowIgnoresAToolFindingThatSharesItsPid() {
        let tool = MemoryWatchFixtures.nodeFinding(pid: 4412)
        XCTAssertNil(LeakBadge.leakFinding(for: safariRow(), among: [tool], isAlive: everythingIsRunning))
    }

    func testASlowFindingCountsAsALeak() {
        var f = safariFinding()
        f.tier = .slow
        XCTAssertEqual(LeakBadge.leakFinding(for: safariRow(), among: [f], isAlive: everythingIsRunning), f)
    }

    func testAToolRowMatchesByPid() {
        let f = MemoryWatchFixtures.nodeFinding(pid: 100)
        XCTAssertEqual(LeakBadge.leakFinding(for: nodeRow(pid: 100), among: [f], isAlive: everythingIsRunning), f)
    }

    func testADifferentToolWithTheSameNameDoesNotMatch() {
        // Both are "node", at the same path; only the pid tells them apart.
        let other = MemoryWatchFixtures.nodeFinding(pid: 200)
        XCTAssertNil(LeakBadge.leakFinding(for: nodeRow(pid: 100), among: [other], isAlive: everythingIsRunning))
    }

    func testAToolRowIgnoresAnAppFindingWithItsPid() {
        let app = safariFinding(pid: 100)
        XCTAssertNil(LeakBadge.leakFinding(for: nodeRow(pid: 100), among: [app], isAlive: everythingIsRunning))
    }

    func testAPressureFindingNeverMatches() {
        XCTAssertNil(LeakBadge.leakFinding(for: safariRow(), among: [MemoryWatchFixtures.pressureFinding()],
                                           isAlive: everythingIsRunning))
        XCTAssertNil(LeakBadge.leakFinding(for: nodeRow(pid: 100),
                                           among: [MemoryWatchFixtures.pressureFinding(nonApp: true)],
                                           isAlive: everythingIsRunning))
    }

    func testAFindingWhoseProcessHasQuitNeverMatches() {
        XCTAssertNil(LeakBadge.leakFinding(for: safariRow(), among: [safariFinding()], isAlive: { _ in false }))
    }

    func testTheNewestMatchingFindingWinsWhateverTheOrderOfTheList() {
        let older = safariFinding(pid: 4412, start: 1, at: 0)
        let newer = safariFinding(pid: 4413, start: 2, at: 60)
        XCTAssertEqual(LeakBadge.leakFinding(for: safariRow(), among: [older, newer], isAlive: everythingIsRunning), newer)
        XCTAssertEqual(LeakBadge.leakFinding(for: safariRow(), among: [newer, older], isAlive: everythingIsRunning), newer)
    }

    func testWhenTheNewestHasQuitTheOlderOneThatIsStillRunningShows() {
        let older = safariFinding(pid: 4412, start: 1, at: 0)
        let newer = safariFinding(pid: 4413, start: 2, at: 60)
        let shown = LeakBadge.leakFinding(for: safariRow(), among: [newer, older],
                                          isAlive: { $0.processKey.startAbsTime == 1 })
        XCTAssertEqual(shown, older)
    }

    func testNoFindingsAnswersNilWithoutAskingWhetherAnythingIsRunning() {
        var asked = 0
        XCTAssertNil(LeakBadge.leakFinding(for: safariRow(), among: [], isAlive: { _ in asked += 1; return true }))
        XCTAssertEqual(asked, 0)
    }

    func testOnlyAFindingThatMatchesTheRowIsAskedAbout() {
        var asked = 0
        let other = MemoryWatchFixtures.nodeFinding(pid: 200)
        _ = LeakBadge.leakFinding(for: safariRow(), among: [other], isAlive: { _ in asked += 1; return true })
        XCTAssertEqual(asked, 0)
    }

    func testARowWithNoMeasuredProcessNeverMatches() {
        let system = SystemAttribution.Row(bundleID: "", name: "WindowServer", watts: 0.3, percentPerHour: 0.5,
                                           cpu_ms: 100, gpu_ms: 0, cpuRate_msPerS: 1, gpuRate_msPerS: 0,
                                           isSystem: true)
        let row = Row(app: nil, system: system, gpu: nil, gpuTimeShare: nil, gpuPercent: nil,
                      windowPct: nil, costMin: nil, totalMemoryBytes: 16 << 30)
        XCTAssertNil(LeakBadge.leakFinding(for: row, among: [safariFinding()], isAlive: everythingIsRunning))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: The table and the cell

final class LeakBadgeTableTests: XCTestCase {

    private var savedFindings: (() -> [Finding])!
    private var savedOpen: ((Finding) -> Void)!
    private var savedAlive: ((Finding) -> Bool)!

    override func setUp() {
        super.setUp()
        savedFindings = LeakBadge.findings
        savedOpen = LeakBadge.openLeak
        savedAlive = LeakBadge.isAlive
    }

    override func tearDown() {
        LeakBadge.findings = savedFindings
        LeakBadge.openLeak = savedOpen
        LeakBadge.isAlive = savedAlive
        super.tearDown()
    }

    private func makeController() -> MainWindowController {
        let controller = MainWindowController()
        controller.setColumns(Array(ProcessColumns.all(powerWindowHours: 10).prefix(4)))
        return controller
    }

    private func badgeColumn(_ controller: MainWindowController) throws -> NSTableColumn {
        try XCTUnwrap(controller.table.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier(LeakBadge.columnID)))
    }

    // ── The column ──────────────────────────────────────────────────────────

    func testTheColumnIsHiddenWithNoFindingsShownWithOneAndHiddenAgainWhenTheProcessQuits() throws {
        let controller = makeController()
        let column = try badgeColumn(controller)
        let rows = [safariRow(), nodeRow()]
        XCTAssertTrue(column.isHidden)

        LeakBadge.findings = { [] }
        controller.updateLeakBadges(rows: rows)
        XCTAssertTrue(column.isHidden, "nothing is flagged")

        var running = true
        LeakBadge.findings = { [safariFinding()] }
        LeakBadge.isAlive = { _ in running }
        controller.updateLeakBadges(rows: rows)
        XCTAssertFalse(column.isHidden, "a running flagged app shows the column")
        XCTAssertEqual(controller.leakBadges.finding(for: rows[0]), safariFinding())
        XCTAssertNil(controller.leakBadges.finding(for: rows[1]))

        running = false
        controller.updateLeakBadges(rows: rows)
        XCTAssertTrue(column.isHidden, "the process quit")
        XCTAssertNil(controller.leakBadges.finding(for: rows[0]))
    }

    func testTheColumnSitsBetweenTheDataColumnsAndTheSpacerAndSurvivesRebuildingTheColumns() throws {
        let controller = makeController()
        let ids = controller.table.tableColumns.map { $0.identifier.rawValue }
        XCTAssertEqual(Array(ids.suffix(2)), [LeakBadge.columnID, ProcessColumns.spacerID])

        LeakBadge.findings = { [safariFinding()] }
        LeakBadge.isAlive = everythingIsRunning
        controller.updateLeakBadges(rows: [safariRow()])
        controller.setColumns(Array(ProcessColumns.all(powerWindowHours: 2).prefix(4)))
        XCTAssertFalse(try badgeColumn(controller).isHidden, "a rebuild must not lose the shown state")
    }

    func testTheColumnTakesNoPartInSortingOrTheColumnList() throws {
        let controller = makeController()
        let column = try badgeColumn(controller)
        XCTAssertNil(column.sortDescriptorPrototype)
        XCTAssertFalse(ProcessColumns.all(powerWindowHours: 10).contains { $0.id == LeakBadge.columnID })
        XCTAssertNil(ProcessColumns.byID(10)[LeakBadge.columnID])
    }

    func testTheColumnIsWideEnoughForItsTitle() {
        let text = (LeakBadge.title as NSString).size(withAttributes: [.font: LeakBadge.font]).width
        XCTAssertGreaterThanOrEqual(LeakBadge.columnWidth, text)
        XCTAssertEqual(LeakBadge.font.pointSize, 11)
    }

    // ── The cell ────────────────────────────────────────────────────────────

    func testTheCellShowsTheExactTitleInRedAtElevenPoints() throws {
        let cell = LeakBadgeCellView()
        cell.configure(finding: safariFinding(), name: "Safari")
        XCTAssertFalse(cell.button.isHidden)
        XCTAssertEqual(cell.button.title, "⚠️ Possible Memory Leak")
        XCTAssertFalse(cell.button.isBordered)
        let title = cell.button.attributedTitle
        XCTAssertEqual(title.string, "⚠️ Possible Memory Leak")
        let colour = try XCTUnwrap(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(colour, Palette.critical)
        let font = try XCTUnwrap(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 11)
    }

    func testTheCellNamesTheAppForVoiceOver() {
        let cell = LeakBadgeCellView()
        cell.configure(finding: safariFinding(), name: "Safari")
        XCTAssertEqual(cell.button.accessibilityLabel(), "Possible memory leak in Safari. Opens its details.")
    }

    func testPressingTheButtonOpensThatFinding() {
        var opened: [Finding] = []
        LeakBadge.openLeak = { opened.append($0) }
        let f = safariFinding()
        let cell = LeakBadgeCellView()
        cell.configure(finding: f, name: "Safari")
        cell.button.sendAction(cell.button.action, to: cell.button.target)
        XCTAssertEqual(opened, [f])
    }

    func testARowWithoutAFindingHasNoButtonAndPressingDoesNothing() {
        var opened: [Finding] = []
        LeakBadge.openLeak = { opened.append($0) }
        let cell = LeakBadgeCellView()
        cell.configure(finding: safariFinding(), name: "Safari")
        cell.configure(finding: nil, name: "Safari")
        XCTAssertTrue(cell.button.isHidden, "a recycled cell must lose its button")
        cell.button.sendAction(cell.button.action, to: cell.button.target)
        XCTAssertTrue(opened.isEmpty)
    }

    // ── Cost ────────────────────────────────────────────────────────────────

    func testWithMemoryWatchOffNothingIsReadAboutAnyProcess() throws {
        let controller = makeController()
        var asked = 0
        LeakBadge.findings = { [] }
        LeakBadge.isAlive = { _ in asked += 1; return true }
        let rows = [safariRow(), nodeRow()]
        controller.updateLeakBadges(rows: rows)
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(controller.leakBadges.hasBadges)
        XCTAssertTrue(try badgeColumn(controller).isHidden)
    }

    func testEachFlaggedProcessIsReadOncePerRefreshNoMatterHowManyRowsAsk() {
        var asked = 0
        LeakBadge.findings = { [safariFinding()] }
        LeakBadge.isAlive = { _ in asked += 1; return true }
        let tracker = LeakBadgeTracker()
        // Two rows of the same app is not something the table builds, but the read must still be shared.
        XCTAssertTrue(tracker.update(rows: [safariRow(), safariRow(), nodeRow()]))
        XCTAssertEqual(asked, 1)
    }
}
