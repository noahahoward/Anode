import XCTest
@testable import PowerKit

/// The rules Ultra Low Power Mode applies to the screen and to Anode's own measuring, and the guard that asks whether
/// a freeze made something burn. All of them are pure: made-up numbers and made-up processes go in, a decision comes
/// out, and nothing is read from the Mac.
final class UltraScreenTests: XCTestCase {

    // ── Brightness ──────────────────────────────────────────────────────────

    func testBrightnessAboveHalfIsPulledToHalf() {
        XCTAssertEqual(BrightnessCeiling.clamp(0.8), 0.5)
        XCTAssertEqual(BrightnessCeiling.clamp(1.0), 0.5)
        XCTAssertEqual(BrightnessCeiling.clamp(0.52), 0.5, "past what the display's rounding can explain")
    }

    func testBrightnessAtOrBelowHalfIsLeftAlone() {
        XCTAssertNil(BrightnessCeiling.clamp(0.5))
        XCTAssertNil(BrightnessCeiling.clamp(0.505), "the display reports the half it was given a little high")
        XCTAssertNil(BrightnessCeiling.clamp(0.2))
        XCTAssertNil(BrightnessCeiling.clamp(0))
    }

    func testOldBrightnessComesBackWhenStillAtTheCeiling() {
        XCTAssertEqual(BrightnessCeiling.restore(before: 0.8, now: 0.5), 0.8)
        XCTAssertEqual(BrightnessCeiling.restore(before: 0.8, now: 0.505), 0.8)
        XCTAssertEqual(BrightnessCeiling.restore(before: 0.8, now: 0.495), 0.8)
    }

    func testBrightnessIsNotRaisedBackWhenTheOwnerWentDimmer() {
        XCTAssertNil(BrightnessCeiling.restore(before: 0.8, now: 0.3))
    }

    func testNothingToRestoreWhenTheModeDidNotLowerIt() {
        XCTAssertNil(BrightnessCeiling.restore(before: nil, now: 0.5))
        XCTAssertNil(BrightnessCeiling.restore(before: nil, now: nil))
    }

    func testBrightnessIsNotRestoredWhenItIsUnreadableOrWasMovedPastTheCeiling() {
        XCTAssertNil(BrightnessCeiling.restore(before: 0.8, now: nil), "no way to tell the owner did not go dimmer")
        XCTAssertNil(BrightnessCeiling.restore(before: 0.9, now: 0.7), "someone chose that, it is not the mode's doing")
    }

    // ── Refresh rate ────────────────────────────────────────────────────────

    private func mode(_ index: Int, _ rate: Double, size: (Int, Int) = (1800, 1169), pixels: (Int, Int) = (3600, 2338),
                      usable: Bool = true) -> DisplayModeInfo {
        DisplayModeInfo(index: index, width: size.0, height: size.1, pixelWidth: pixels.0, pixelHeight: pixels.1,
                        rate: rate, usable: usable)
    }

    private let builtIn: [DisplayModeInfo] = [120, 60, 59.94, 50, 48, 47.95].enumerated().map {
        DisplayModeInfo(index: $0.offset, width: 1800, height: 1169, pixelWidth: 3600, pixelHeight: 2338,
                        rate: $0.element, usable: true)
    }

    func testLowestRateAtTheSameResolution() {
        let picked = RefreshRatePicker.lowest(of: builtIn, current: builtIn[0])
        XCTAssertEqual(picked?.rate, 47.95)
        XCTAssertEqual(picked?.index, 5)
        // From the middle of the list too.
        XCTAssertEqual(RefreshRatePicker.lowest(of: builtIn, current: builtIn[2])?.index, 5)
    }

    func testOtherResolutionsAndUnusableModesAreIgnored() {
        let modes = builtIn + [
            mode(6, 30, size: (1512, 982), pixels: (3024, 1964)),       // a lower rate, but another size
            mode(7, 24, pixels: (1800, 1169)),                           // the same size, not scaled up: another mode
            mode(8, 20, usable: false),                                 // the right size, the display will not take it
            mode(9, 40),                                                // the lowest that can be chosen
        ]
        XCTAssertEqual(RefreshRatePicker.lowest(of: modes, current: builtIn[0])?.index, 9)
    }

    func testASixtyHertzOnlyScreenHasNothingLower() {
        let only = mode(0, 60)
        XCTAssertNil(RefreshRatePicker.lowest(of: [only], current: only))
        XCTAssertNil(RefreshRatePicker.lowest(of: [], current: only))
    }

    func testAlreadyAtTheLowestRateReturnsNil() {
        XCTAssertNil(RefreshRatePicker.lowest(of: builtIn, current: builtIn[5]))
        // The same rate listed twice is not a lower rate.
        let twice = builtIn + [mode(6, 47.95)]
        XCTAssertNil(RefreshRatePicker.lowest(of: twice, current: builtIn[5]))
    }

    func testARateOfZeroIsUnknownAndNeverChosen() {
        // Some displays report no rate at all for a mode: that is not "the lowest".
        let modes = [mode(0, 120), mode(1, 0), mode(2, 60)]
        XCTAssertEqual(RefreshRatePicker.lowest(of: modes, current: modes[0])?.index, 2)
        XCTAssertNil(RefreshRatePicker.lowest(of: [mode(0, 0), mode(1, 60)], current: mode(0, 0)))
    }

    func testTwoModesAtTheLowestRateGiveTheSameOneEveryTime() {
        let modes = [mode(0, 120), mode(4, 48), mode(2, 48), mode(3, 60)]
        XCTAssertEqual(RefreshRatePicker.lowest(of: modes, current: modes[0])?.index, 2)
        XCTAssertEqual(RefreshRatePicker.lowest(of: modes.reversed(), current: modes[0])?.index, 2)
    }

    // ── When Anode measures ─────────────────────────────────────────────────

    func testTickRunsNormallyWhenTheModeIsOff() {
        for window in [false, true] {
            for fans in [false, true] {
                for floor in [false, true] {
                    XCTAssertTrue(MeasurementPause.ticks(ultraOn: false, windowWorthDrawing: window, drivingFans: fans,
                                                         chargeWatching: floor))
                }
            }
        }
    }

    func testTickStopsWhenOnAndTheWindowIsClosed() {
        XCTAssertFalse(MeasurementPause.ticks(ultraOn: true, windowWorthDrawing: false, drivingFans: false,
                                              chargeWatching: false))
    }

    func testTickRunsWhileTheWindowIsOpen() {
        XCTAssertTrue(MeasurementPause.ticks(ultraOn: true, windowWorthDrawing: true, drivingFans: false,
                                             chargeWatching: false))
    }

    func testTickNeverStopsWhileFansAreDrivenOrTheChargeFloorIsWatched() {
        XCTAssertTrue(MeasurementPause.ticks(ultraOn: true, windowWorthDrawing: false, drivingFans: true,
                                             chargeWatching: false))
        XCTAssertTrue(MeasurementPause.ticks(ultraOn: true, windowWorthDrawing: false, drivingFans: false,
                                             chargeWatching: true))
        XCTAssertTrue(MeasurementPause.ticks(ultraOn: true, windowWorthDrawing: false, drivingFans: true,
                                             chargeWatching: true))
    }

    // ── After a freeze: did it make something burn? ─────────────────────────

    /// The start time follows the pid, so a group member and its process agree and two processes never look alike.
    private func start(_ pid: pid_t) -> UInt64 { UInt64(pid) * 10 }

    private func proc(_ pid: pid_t, _ path: String, team: String? = nil) -> UltraProcess {
        UltraProcess(pid: pid, parent: 1, uid: 501, startTime: start(pid), path: path,
                     name: path.split(separator: "/").last.map(String.init) ?? "p\(pid)", team: team)
    }

    private func group(_ id: String, _ pids: [pid_t]) -> FreezeGroup {
        FreezeGroup(id: id, name: id, members: pids.map { FreezeGroup.Member(pid: $0, startTime: start($0)) })
    }

    // The editor is kept. The sync app and the notes app are frozen; a team and a bundle each tie a stray process to
    // one of them.
    private let editor = 10 as pid_t
    private let sync = [30, 31] as [pid_t]
    private let notes = [40] as [pid_t]

    private var processes: [UltraProcess] {
        [proc(10, "/Applications/Editor.app/Contents/MacOS/Editor", team: "TEAM0003"),
         proc(30, "/Applications/Sync.app/Contents/MacOS/Sync", team: "TEAM0001"),
         proc(31, "/Applications/Sync.app/Contents/Helpers/SyncHelper", team: "TEAM0001"),
         proc(40, "/Applications/Notes.app/Contents/MacOS/Notes", team: "TEAM0002"),
         // Burners. 90 and 94 share the sync team, 91 nothing with anyone, 92 sits inside the notes app, 93 shares the
         // sync team and the notes bundle.
         proc(90, "/usr/local/bin/syncd", team: "TEAM0001"),
         proc(91, "/usr/local/bin/stray"),
         proc(92, "/Applications/Notes.app/Contents/XPCServices/Fetch.xpc/Contents/MacOS/Fetch"),
         proc(93, "/Applications/Notes.app/Contents/XPCServices/Share.xpc/Contents/MacOS/Share", team: "TEAM0001"),
         proc(94, "/usr/local/bin/syncd-index", team: "TEAM0001")]
    }

    private var frozen: [FreezeGroup] { [group("com.example.sync", sync), group("com.example.notes", notes)] }

    private func verdict(before: [pid_t: Double] = [:], after: [pid_t: Double],
                         busyBefore: Double = 0.5, busyAfter: Double = 0.5, kept: Set<pid_t> = [10],
                         frozen: [FreezeGroup]? = nil, processes: [UltraProcess]? = nil) -> SpinGuard.Verdict {
        SpinGuard.verdict(ownBefore: before, ownAfter: after, busyCoresBefore: busyBefore, busyCoresAfter: busyAfter,
                          kept: kept, frozen: frozen ?? self.frozen, processes: processes ?? self.processes)
    }

    func testNothingBurningIsFine() {
        XCTAssertEqual(verdict(before: [10: 0.1, 90: 0.02], after: [10: 0.12, 90: 0.03, 91: 0.01]), .fine)
        XCTAssertEqual(verdict(before: [:], after: [:]), .fine)
    }

    func testAProcessThatStartedBurningReleasesTheGroupOfItsProduct() {
        XCTAssertEqual(verdict(before: [90: 0.02], after: [90: 1.4]), .release(["com.example.sync"]))
    }

    func testABurnerTiedToNoGroupReleasesEverything() {
        XCTAssertEqual(verdict(before: [91: 0.02], after: [91: 1.4]), .releaseAll)
    }

    func testAKeptAppWorkingHardIsNotASpin() {
        // The editor goes from 0.1 to 2 cores and the Mac as a whole with it: the owner is working, nothing is wrong.
        XCTAssertEqual(verdict(before: [10: 0.1], after: [10: 2.0], busyBefore: 0.5, busyAfter: 2.4), .fine)
    }

    func testAnUnexplainedRiseOfTheWholeMacReleasesEverything() {
        // Every process of the user's is flat; something Anode cannot see (a root process) is spinning.
        XCTAssertEqual(verdict(before: [10: 0.1, 90: 0.02], after: [10: 0.1, 90: 0.02], busyBefore: 0.3, busyAfter: 1.6),
                       .releaseAll)
    }

    func testAProcessAlreadyBusyBeforeTheFreezeIsNotBlamed() {
        XCTAssertEqual(verdict(before: [91: 1.2], after: [91: 1.3], busyBefore: 1.5, busyAfter: 1.6), .fine)
    }

    // The tie-breaks.

    func testABurnerInsideAFrozenAppsBundleReleasesThatApp() {
        // 92 has no team: the app it sits inside is what ties it.
        XCTAssertEqual(verdict(before: [92: 0.0], after: [92: 0.9]), .release(["com.example.notes"]))
    }

    func testAnEmptyTeamNeverTiesAProcessToAGroup() {
        let bare = [proc(10, "/Applications/Editor.app/Contents/MacOS/Editor"),
                    proc(30, "/Applications/Sync.app/Contents/MacOS/Sync", team: ""),
                    proc(91, "/usr/local/bin/stray", team: "")]
        XCTAssertEqual(verdict(before: [91: 0.0], after: [91: 1.0], frozen: [group("com.example.sync", [30])],
                               processes: bare), .releaseAll)
    }

    func testABurnerThatSharesTwoProductsReleasesBothInOrder() {
        // 93 is of the notes bundle and of the sync team.
        XCTAssertEqual(verdict(before: [93: 0.0], after: [93: 1.0]),
                       .release(["com.example.notes", "com.example.sync"]))
    }

    func testSeveralGroupsOfOneProductAreNamedInOrder() {
        // Four groups of one team, listed out of order: a set's own order is different from run to run.
        let team = "TEAM0009"
        let ids = ["com.example.zed", "com.example.alpha", "com.example.mid", "com.example.beta"]
        let pids: [pid_t] = [51, 52, 53, 54]
        let list = pids.map { proc($0, "/Applications/App\($0).app/Contents/MacOS/App", team: team) }
            + [proc(80, "/usr/local/bin/agent", team: team)]
        XCTAssertEqual(verdict(before: [:], after: [80: 1.0], frozen: zip(ids, pids).map { group($0, [$1]) },
                               processes: list),
                       .release(ids.sorted()))
    }

    func testTwoBurnersOfOneProductNameItOnce() {
        XCTAssertEqual(verdict(before: [:], after: [90: 1.0, 94: 0.8]), .release(["com.example.sync"]))
    }

    func testOneBurnerTiedAndOneNotReleasesEverything() {
        XCTAssertEqual(verdict(before: [:], after: [90: 1.0, 91: 1.0]), .releaseAll)
    }

    func testABurnerUnknownToTheProcessListReleasesEverything() {
        XCTAssertEqual(verdict(before: [:], after: [77: 1.0]), .releaseAll)
    }

    func testAMemberWhosePidWasRecycledTiesNothing() {
        // The sync group's member 30 was another process when the group was frozen: its team is not the group's.
        var list = processes
        list[1] = UltraProcess(pid: 30, parent: 1, uid: 501, startTime: 999, path: "/opt/other/thing", name: "thing",
                               team: "TEAM0001")
        list[2] = proc(31, "/opt/other/helper")
        XCTAssertEqual(verdict(before: [:], after: [90: 1.0], processes: list), .releaseAll)
    }

    func testMembersOfAStillFrozenGroupAreNotBlamed() {
        // A frozen process does not run; a reading above the line for one is not a spin to chase.
        XCTAssertEqual(verdict(before: [:], after: [30: 1.5, 40: 1.0]), .fine)
    }

    func testAKeptProcessIsNeverTheBurner() {
        XCTAssertEqual(verdict(before: [:], after: [10: 3.0]), .fine)
        XCTAssertEqual(verdict(before: [:], after: [10: 3.0], busyBefore: 0.5, busyAfter: 3.5), .fine)
    }

    func testAMissingEarlierReadingCountsAsQuiet() {
        XCTAssertEqual(verdict(before: [:], after: [90: 0.9]), .release(["com.example.sync"]))
    }

    func testTheLineForBurningAndForTheRise() {
        // At the line counts; just under does not. (0.5, 0.9 and their difference are exact in binary.)
        XCTAssertEqual(verdict(before: [:], after: [90: 0.5]), .release(["com.example.sync"]))
        XCTAssertEqual(verdict(before: [:], after: [90: 0.45]), .fine)
        XCTAssertEqual(verdict(before: [90: 0.5], after: [90: 0.9]), .release(["com.example.sync"]))
        XCTAssertEqual(verdict(before: [90: 0.5], after: [90: 0.85]), .fine)
    }

    func testATiedBurnerIsNamedEvenWhenTheWholeMacRoseMore() {
        XCTAssertEqual(verdict(before: [90: 0.0], after: [90: 1.0], busyBefore: 0.5, busyAfter: 4.0),
                       .release(["com.example.sync"]))
    }

    func testTheKeptAppsShareOfTheRiseDecidesWhetherItExplainsIt() {
        // The Mac rose by 2 cores. The kept app rose by 1: half of it, so it explains it.
        XCTAssertEqual(verdict(before: [10: 0.5], after: [10: 1.5], busyBefore: 0.5, busyAfter: 2.5), .fine)
        // By 0.75: less than half, so something else is burning.
        XCTAssertEqual(verdict(before: [10: 0.5], after: [10: 1.25], busyBefore: 0.5, busyAfter: 2.5), .releaseAll)
        // A kept app that went quieter explains nothing.
        XCTAssertEqual(verdict(before: [10: 1.0], after: [10: 0.2], busyBefore: 1.0, busyAfter: 2.0), .releaseAll)
    }

    func testARiseOfTheWholeMacBelowTheLineIsNotChased() {
        XCTAssertEqual(verdict(before: [10: 0.1], after: [10: 0.1], busyBefore: 0.5, busyAfter: 0.9), .fine)
        XCTAssertEqual(verdict(before: [:], after: [:], busyBefore: 2.0, busyAfter: 0.4), .fine, "it fell")
    }
}
