import XCTest
import AppKit
import Carbon.HIToolbox
@testable import AnodeApp
@testable import PowerKit

/// What the owner sees and touches of Ultra Low Power Mode: the confirm box's words and its one-answer rule, the menu, the
/// section in Beta Features, the status icon's constants and the app menu's entry. No panel is shown, no status item is made
/// and no real setting is read: the pure functions are called, the menu's items are performed as a click would, and the
/// section runs on throwaway settings over a controller built from the controller tests' fakes.
final class UltraLowPowerFeatureTests: XCTestCase {

    private typealias Fakes = UltraLowPowerControllerTests

    private func group(_ id: String, _ name: String, pid: pid_t = 100) -> FreezeGroup {
        FreezeGroup(id: id, name: name, members: [FreezeGroup.Member(pid: pid, startTime: UInt64(pid))])
    }

    // ── The confirm box's words ─────────────────────────────────────────────

    func testConfirmTextNamesWhatIsKeptAndCountsWhatFreezes() {
        XCTAssertEqual(UltraMenu.confirmText(kept: ["Editor", "Meetings"], frozenCount: 9),
                       "Keeps Editor and Meetings. Freezes 9 apps and tools until you turn this off.")
    }

    func testConfirmTextJoinsTheKeptNamesInPlainEnglish() {
        XCTAssertTrue(UltraMenu.confirmText(kept: ["Editor"], frozenCount: 2).hasPrefix("Keeps Editor. "))
        XCTAssertTrue(UltraMenu.confirmText(kept: ["A", "B", "C"], frozenCount: 2).hasPrefix("Keeps A, B and C. "))
        XCTAssertTrue(UltraMenu.confirmText(kept: ["A", "B", "C", "D"], frozenCount: 2).hasPrefix("Keeps A, B, C and D. "))
    }

    func testConfirmTextWithNothingKeptSaysSo() {
        XCTAssertEqual(UltraMenu.confirmText(kept: [], frozenCount: 3),
                       "Keeps nothing in particular. Freezes 3 apps and tools until you turn this off.")
    }

    func testConfirmTextForOneAndForNothingToFreeze() {
        XCTAssertEqual(UltraMenu.confirmText(kept: ["Editor"], frozenCount: 1),
                       "Keeps Editor. Freezes 1 app or tool until you turn this off.")
        XCTAssertEqual(UltraMenu.confirmText(kept: ["Editor"], frozenCount: 0),
                       "Keeps Editor. Nothing else is running that can be frozen.")
    }

    // ── The menu ────────────────────────────────────────────────────────────

    private func menu(_ state: UltraLowPowerController.State, starting: Bool = false, frozen: [FreezeGroup] = [],
                      leftRunning: [FreezeGroup] = [],
                      released: [String] = [], names: [String: String] = [:], start: @escaping () -> Void = {},
                      off: @escaping () -> Void = {}, release: @escaping (String) -> Void = { _ in },
                      beta: @escaping () -> Void = {}) -> NSMenu {
        UltraMenu.build(state: state, starting: starting, frozen: frozen, leftRunning: leftRunning, releasedForLoad: released,
                        names: names, onStart: start, onTurnOff: off, onRelease: release, onOpenBeta: beta)
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    /// `performActionForItem` does nothing without a menu on screen; performing the item's action on its target is what a click does.
    private func fire(_ menu: NSMenu, at index: Int) {
        guard let item = menu.item(at: index), let action = item.action else { return XCTFail("no item at \(index)") }
        _ = (item.target as? NSObject)?.perform(action)
    }

    func testMenuWhenOffOffersToStart() {
        var started = 0
        let m = menu(.off, start: { started += 1 })
        XCTAssertEqual(titles(m), ["Ultra Low Power Mode…"])
        XCTAssertTrue(m.items[0].isEnabled)
        fire(m, at: 0)
        XCTAssertEqual(started, 1)
    }

    /// An item with a target and an action is switched on again by the menu itself unless the menu is told not to.
    func testMenuWhileTheBoxIsUpShowsTheSameItemSwitchedOff() {
        let m = menu(.confirming)
        XCTAssertEqual(titles(m), ["Ultra Low Power Mode…"])
        XCTAssertFalse(m.items[0].isEnabled)
        XCTAssertFalse(m.autoenablesItems, "the menu must not switch the item back on")
    }

    /// Once the owner has confirmed and until the mode is on, the one item is Cancel, and it turns the mode off.
    func testMenuWhileTheStartIsRunningOffersCancelAndItTurnsOff() {
        var off = 0, started = 0
        let m = menu(.confirming, starting: true, start: { started += 1 }, off: { off += 1 })
        XCTAssertEqual(titles(m), ["Cancel"])
        XCTAssertTrue(m.items[0].isEnabled)
        fire(m, at: 0)
        XCTAssertEqual([off, started], [1, 0])
    }

    func testMenuWhenOnListsTurnOffAndEveryFrozenGroup() {
        let frozen = [group("com.example.browser", "Browser"), group("job:db", "db"), group("exe:worker", "worker")]
        let m = menu(.on, frozen: frozen)
        XCTAssertEqual(titles(m), ["Turn off", "-", "Frozen (click to bring back):", "Browser", "db", "worker", "-",
                                   "Open Beta Features…"])
        XCTAssertFalse(m.items[2].isEnabled, "the header is a label")
        XCTAssertTrue(m.items[3...5].allSatisfy(\.isEnabled))
    }

    func testTurnOffAndOpenBetaRunTheirClosures() {
        var off = 0, beta = 0
        let m = menu(.on, frozen: [group("a", "A")], off: { off += 1 }, beta: { beta += 1 })
        fire(m, at: 0)
        fire(m, at: m.items.count - 1)
        XCTAssertEqual([off, beta], [1, 1])
    }

    func testChoosingAFrozenGroupReleasesIt() {
        var released: [String] = []
        let m = menu(.on, frozen: [group("com.example.browser", "Browser"), group("job:db", "db")], release: { released.append($0) })
        fire(m, at: 4)
        fire(m, at: 3)
        XCTAssertEqual(released, ["job:db", "com.example.browser"])
    }

    /// The group's name is only what is read; what is released is its id, which two groups may not share by name.
    func testTwoGroupsWithOneNameAreReleasedByTheirOwnIds() {
        var released: [String] = []
        let m = menu(.on, frozen: [group("job:one", "Helper"), group("job:two", "Helper")], release: { released.append($0) })
        fire(m, at: 4)
        XCTAssertEqual(released, ["job:two"])
    }

    func testTheMenuSaysWhenNothingIsFrozenAnyMore() {
        let m = menu(.on, frozen: [])
        XCTAssertEqual(titles(m), ["Turn off", "-", "Nothing is frozen now.", "-", "Open Beta Features…"])
        XCTAssertFalse(m.items[2].isEnabled)
    }

    func testTheMenuNamesAppsLeftRunning() {
        let m = menu(.on, frozen: [group("com.example.browser", "Browser")], leftRunning: [group("com.example.cloud", "Cloud")],
                     released: ["com.example.sync"], names: ["com.example.sync": "Sync"])
        XCTAssertEqual(titles(m), ["Turn off", "-", "Frozen (click to bring back):", "Browser",
                                   "Left running: Cloud (it has a part Anode cannot freeze).",
                                   "Left running: Sync (it reacted badly to being frozen).", "-", "Open Beta Features…"])
        XCTAssertFalse(m.items[4].isEnabled)
        XCTAssertFalse(m.items[5].isEnabled)
    }

    // ── The section's lines ─────────────────────────────────────────────────

    func testEachSkippedPartHasAPlainLine() {
        let all: [UltraSkipped] = [.lowPowerNoHelper, .lowPowerOldHelper, .oneRefreshRate, .keyboardLight, .lowPowerRefused,
                                   .rateRefused, .ceilingRefused, .noEfficiencyCores]
        let lines = UltraLowPowerFeature.describe(all)
        XCTAssertEqual(lines.count, all.count)
        XCTAssertEqual(Set(lines).count, all.count, "each part has its own words")
        for line in lines {
            XCTAssertTrue(line.hasSuffix("."), line)
            XCTAssertFalse(line.contains("\n"), line)
        }
        // A missing helper names the helper and says what to do about it, by the route Charge Control already offers.
        let noHelper = UltraLowPowerFeature.describe([.lowPowerNoHelper])[0]
        XCTAssertTrue(noHelper.contains("Anode helper"), noHelper)
        XCTAssertTrue(noHelper.contains("Install Helper…"), noHelper)
        let oldHelper = UltraLowPowerFeature.describe([.lowPowerOldHelper])[0]
        XCTAssertTrue(oldHelper.contains("older"), oldHelper)
        XCTAssertTrue(oldHelper.contains("Install Helper…"), oldHelper)
        // Lines a Mac without the hardware gets every session say so, and do not blame the Mac or the screen.
        XCTAssertEqual(UltraLowPowerFeature.describe([.oneRefreshRate]),
                       ["The screen's refresh rate was left as it was: it offers only one, or this Mac has no built-in screen."])
        XCTAssertEqual(UltraLowPowerFeature.describe([.keyboardLight]),
                       ["This Mac's keyboard light could not be read or switched off, so it was left as it was."])
        // A Mac with no built-in screen gets this line every time: it says what could not be done, and blames nothing.
        XCTAssertEqual(UltraLowPowerFeature.describe([.ceilingRefused]),
                       ["The screen's brightness could not be held at a quarter, so it was left as it was."])
        // A Mac without efficiency cores (an Intel one) says so, and says what was done instead.
        XCTAssertEqual(UltraLowPowerFeature.describe([.noEfficiencyCores]),
                       ["This Mac has no efficiency cores, so work was left on the cores it has."])
    }

    func testSkippedLinesComeInTheOrderOfTheEnumAndNeverRepeat() {
        let shuffled: [UltraSkipped] = [.ceilingRefused, .keyboardLight, .lowPowerNoHelper, .keyboardLight, .oneRefreshRate,
                                        .ceilingRefused]
        XCTAssertEqual(UltraLowPowerFeature.describe(shuffled),
                       UltraLowPowerFeature.describe([.lowPowerNoHelper, .oneRefreshRate, .keyboardLight, .ceilingRefused]))
        XCTAssertEqual(UltraLowPowerFeature.describe([]), [])
    }

    func testAppsLeftRunningAreNamedWithTheReason() {
        let cloud = group("com.example.cloud", "Cloud"), sync = group("com.example.sync", "Sync")
        XCTAssertEqual(UltraLowPowerFeature.leftRunningLines(leftRunning: [sync], releasedForLoad: [], names: [:]),
                       ["Left running: Sync (it has a part Anode cannot freeze)."])
        XCTAssertEqual(UltraLowPowerFeature.leftRunningLines(leftRunning: [cloud, sync], releasedForLoad: [], names: [:]),
                       ["Left running: Cloud, Sync (each has a part Anode cannot freeze)."])
        XCTAssertEqual(UltraLowPowerFeature.leftRunningLines(leftRunning: [], releasedForLoad: ["com.example.sync"],
                                                             names: ["com.example.sync": "Sync"]),
                       ["Left running: Sync (it reacted badly to being frozen)."])
        XCTAssertEqual(UltraLowPowerFeature.leftRunningLines(leftRunning: [], releasedForLoad: ["a", "b"], names: ["a": "A", "b": "B"]),
                       ["Left running: A, B (each reacted badly to being frozen)."])
        // Both, the part Anode cannot freeze first.
        XCTAssertEqual(UltraLowPowerFeature.leftRunningLines(leftRunning: [cloud], releasedForLoad: ["com.example.sync"],
                                                             names: ["com.example.sync": "Sync"]),
                       ["Left running: Cloud (it has a part Anode cannot freeze).",
                        "Left running: Sync (it reacted badly to being frozen)."])
        XCTAssertEqual(UltraLowPowerFeature.leftRunningLines(leftRunning: [], releasedForLoad: [], names: [:]), [])
    }

    /// A group the guard continued is no longer in the frozen list, so nothing may know its name: it is read from its id.
    func testAGroupReleasedForLoadWithNoNameIsReadFromItsId() {
        XCTAssertEqual(UltraLowPowerFeature.leftRunningLines(leftRunning: [], releasedForLoad: ["job:com.example.indexer"], names: [:]),
                       ["Left running: com.example.indexer (it reacted badly to being frozen)."])
    }

    func testTheNoteMakesNoPromiseOfRunningTime() {
        let note = UltraLowPowerFeature.note
        XCTAssertTrue(note.contains("no running time is promised"), note)
        XCTAssertFalse(note.contains("hours"), note)
        XCTAssertFalse(note.contains("hour"), note)
    }

    /// At rest the refresh rate, Low Power Mode and freezing measured nothing that can be told from noise, but with something
    /// running they save a great deal: the note says so, and no longer says they save "little or nothing".
    func testTheNoteNoLongerSaysTheOtherPartsSaveLittleOrNothing() {
        let note = UltraLowPowerFeature.note
        XCTAssertFalse(note.contains("little or nothing"), note)
        XCTAssertTrue(note.contains("a great deal"), note)
    }

    /// What it says, in the order the owner reads it: at rest only a darker screen lowers the draw; what saves when something
    /// is running, with the figures; what it costs (slower, and the disk and the network); what frozen apps lose; what is left
    /// running; and that no running time is promised.
    func testTheNoteSaysItsPartsInOrder() throws {
        let note = UltraLowPowerFeature.note
        let parts = ["only a darker screen lowers the draw",
                     "the black backdrop",
                     "a quarter",
                     "a busy app frozen in the background",
                     "7.5 W down to 3.2 W",
                     "kept on the efficiency cores",
                     "27 W down to 5 W",
                     "Low Power Mode alone",
                     "13 W",
                     "lowest refresh rate",
                     "about 2 W",
                     "while a video played",
                     "Work is slower in this mode",
                     "disk and network use by the apps left running is slowed too",
                     "Frozen apps stop keeping their network connections going, so some may drop",
                     "An app with a part Anode cannot freeze is left running",
                     "no running time is promised"]
        var from = note.startIndex
        for part in parts {
            let found = try XCTUnwrap(note.range(of: part, range: from..<note.endIndex), "\"\(part)\" comes next in: \(note)")
            from = found.upperBound
        }
    }

    /// At rest only a darker screen lowers the draw, and the note does not say the other parts do.
    func testTheNoteSaysThatAtRestOnlyADarkerScreenHelps() {
        let note = UltraLowPowerFeature.note
        XCTAssertTrue(note.hasPrefix("At rest, only a darker screen lowers the draw"), note)
        XCTAssertFalse(note.contains("half"), "the ceiling is a quarter now: \(note)")
    }

    /// Every number in the note is one the trial measured on the owner's 14-inch MacBook Pro, and none is a promise.
    func testTheNoteGivesOnlyTheMeasuredFigures() {
        let note = UltraLowPowerFeature.note
        XCTAssertTrue(note.contains("14-inch MacBook Pro"), note)
        for figure in ["7.5 W", "3.2 W", "27 W", "5 W", "13 W", "about 2 W"] { XCTAssertTrue(note.contains(figure), figure) }
        // The figures of the first note (10, 4 and 3 W by brightness) are not in it any more.
        for figure in ["about 10 W", "about 4 W", "about 3 W"] { XCTAssertFalse(note.contains(figure), figure) }
        XCTAssertNil(note.range(of: #"\d+\s?%"#, options: .regularExpression), "no percentage was measured")
        XCTAssertFalse(note.contains("was not measured"), "the figures are the measurements")
        XCTAssertTrue(note.contains("cannot freeze"))
    }

    func testReadableNamesForTheAlwaysKeepList() {
        let resolve: (String) -> String? = { $0 == "com.example.editor" ? "Editor" : nil }
        XCTAssertEqual(UltraLowPowerFeature.displayName(forGroupID: "com.example.editor", appName: resolve), "Editor")
        XCTAssertEqual(UltraLowPowerFeature.displayName(forGroupID: "com.example.gone", appName: resolve), "com.example.gone")
        XCTAssertEqual(UltraLowPowerFeature.displayName(forGroupID: "job:com.example.database", appName: resolve),
                       "com.example.database")
        XCTAssertEqual(UltraLowPowerFeature.displayName(forGroupID: "exe:worker", appName: resolve), "worker")
        XCTAssertEqual(UltraLowPowerFeature.displayName(forGroupID: "exe:", appName: resolve), "exe:", "nothing to read: the id")
    }

    func testOnlyGroupsNotAlreadyKeptAreOfferedToAdd() {
        let all = [group("a", "A"), group("b", "B"), group("c", "C")]
        XCTAssertEqual(UltraLowPowerFeature.addable(all, keeping: ["b"]).map(\.id), ["a", "c"])
        XCTAssertEqual(UltraLowPowerFeature.addable(all, keeping: []).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(UltraLowPowerFeature.addable([], keeping: ["b"]).map(\.id), [])
    }

    func testTheStartButtonFollowsTheStateAndTheBox() {
        typealias Look = UltraLowPowerFeature.ButtonLook
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: true, state: .off), Look(title: "Start…", isEnabled: true))
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: true, state: .confirming), Look(title: "Start…", isEnabled: false))
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: true, state: .on), Look(title: "Turn Off", isEnabled: true))
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: false, state: .off), Look(title: "Start…", isEnabled: false))
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: true, state: nil), Look(title: "Start…", isEnabled: false),
                       "with no controller there is nothing to start")
        // Unticking while the mode runs must not take the way out away.
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: false, state: .on), Look(title: "Turn Off", isEnabled: true))
    }

    func testTheButtonIsCancelWhileTheStartIsRunning() {
        typealias Look = UltraLowPowerFeature.ButtonLook
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: true, state: .confirming, starting: true),
                       Look(title: "Cancel", isEnabled: true))
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: false, state: .confirming, starting: true),
                       Look(title: "Cancel", isEnabled: true), "unticking ends the start, and until it has the way out stays")
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: true, state: .confirming, starting: false),
                       Look(title: "Start…", isEnabled: false), "the box is up: as before")
        XCTAssertEqual(UltraLowPowerFeature.buttonLook(ticked: true, state: .on, starting: false),
                       Look(title: "Turn Off", isEnabled: true))
    }

    // ── What a press does, and the app menu's entry ─────────────────────────

    func testPressCancelsWhileTheStartIsRunning() {
        XCTAssertEqual(UltraMenu.press(for: .confirming, starting: true), .turnOff)
        XCTAssertNil(UltraMenu.press(for: .confirming, starting: false), "the box is up: a second press must not ask again")
    }

    func testTheAppMenuEntryReadsCancelWhileTheStartIsRunning() {
        XCTAssertEqual(UltraMenu.appEntry(ticked: true, state: .confirming, starting: true),
                       UltraMenu.AppEntry(title: "Cancel", isHidden: false, isEnabled: true))
        XCTAssertEqual(UltraMenu.appEntry(ticked: true, state: .confirming, starting: false),
                       UltraMenu.AppEntry(title: "Ultra Low Power Mode…", isHidden: false, isEnabled: false))
    }

    func testPressStartsWhenOffTurnsOffWhenOnAndDoesNothingWhileTheBoxIsUp() {
        XCTAssertEqual(UltraMenu.press(for: .off), .start)
        XCTAssertEqual(UltraMenu.press(for: .on), .turnOff)
        XCTAssertNil(UltraMenu.press(for: .confirming))
    }

    func testTheAppMenuEntryIsShownOnlyWhileTheBoxIsTicked() {
        typealias Entry = UltraMenu.AppEntry
        XCTAssertEqual(UltraMenu.appEntry(ticked: false, state: .off),
                       Entry(title: "Ultra Low Power Mode…", isHidden: true, isEnabled: true))
        XCTAssertEqual(UltraMenu.appEntry(ticked: true, state: .off),
                       Entry(title: "Ultra Low Power Mode…", isHidden: false, isEnabled: true))
        XCTAssertEqual(UltraMenu.appEntry(ticked: true, state: .on),
                       Entry(title: "Turn Off Ultra Low Power Mode", isHidden: false, isEnabled: true))
        XCTAssertEqual(UltraMenu.appEntry(ticked: true, state: .confirming),
                       Entry(title: "Ultra Low Power Mode…", isHidden: false, isEnabled: false))
        XCTAssertEqual(UltraMenu.appEntry(ticked: true, state: nil),
                       Entry(title: "Ultra Low Power Mode…", isHidden: false, isEnabled: false))
    }

    /// The mode may be running when the box is unticked; the entry that ends it stays until it has.
    func testARunningModeKeepsItsEntryEvenUnticked() {
        XCTAssertEqual(UltraMenu.appEntry(ticked: false, state: .on),
                       UltraMenu.AppEntry(title: "Turn Off Ultra Low Power Mode", isHidden: false, isEnabled: true))
        XCTAssertTrue(UltraMenu.appEntry(ticked: false, state: .confirming).isHidden)
    }

    /// The menu is built once, so the entry is there from the start, hidden until the box is ticked.
    func testTheAppMenuCarriesTheEntryHiddenToBeginWith() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        NSApp.mainMenu = nil
        delegate.buildMenu()
        let anode = NSApp.mainMenu?.items.first?.submenu
        let item = anode?.items.first { $0.identifier == UltraMenu.appEntryID }
        XCTAssertNotNil(item, "Anode → Ultra Low Power Mode…")
        XCTAssertTrue(item?.isHidden ?? false)
        XCTAssertTrue(item?.target === delegate)
        XCTAssertNotNil(item?.action)
        XCTAssertTrue(anode?.delegate === delegate, "the menu asks before it opens whether to show the entry")
        XCTAssertEqual(NSApp.mainMenu?.items.compactMap { $0.submenu }.flatMap(\.items).filter { $0.identifier == UltraMenu.appEntryID }.count, 1)
    }

    // ── The status icon ─────────────────────────────────────────────────────

    func testTheIconIsASmallTemplateSymbolWithAPlainLabel() {
        XCTAssertEqual(UltraIcon.accessibilityLabel, "Ultra Low Power Mode")
        XCTAssertNotNil(NSImage(systemSymbolName: UltraIcon.symbolName, accessibilityDescription: nil),
                        "the symbol exists on the oldest macOS Anode supports")
        XCTAssertFalse(UltraIcon.autosaveName.isEmpty)
        XCTAssertNotEqual(UltraIcon.autosaveName, BarChevron.autosaveName)
    }

    // ── The confirm box's one answer ────────────────────────────────────────

    func testTheBoxAnswersExactlyOnce() {
        var answers: [Bool] = []
        let pending = UltraPendingAnswer()
        pending.replace { answers.append($0) }
        XCTAssertTrue(pending.isPending)
        pending.give(true)
        pending.give(false)      // closing the box after Confirm: nobody is waiting any more
        pending.give(true)
        XCTAssertEqual(answers, [true])
        XCTAssertFalse(pending.isPending)
    }

    func testAnyOtherWayOfClosingAnswersNo() {
        var answers: [Bool] = []
        let pending = UltraPendingAnswer()
        pending.replace { answers.append($0) }
        pending.give(false)      // the close button, or the system closing the window
        pending.give(false)
        XCTAssertEqual(answers, [false])
    }

    func testAskingAgainWhileOpenAnswersTheOldOneNoAndLeavesTheNewOnePending() {
        var first: [Bool] = [], second: [Bool] = []
        let pending = UltraPendingAnswer()
        pending.replace { first.append($0) }
        pending.replace { second.append($0) }
        XCTAssertEqual(first, [false])
        XCTAssertEqual(second, [])
        XCTAssertTrue(pending.isPending)
        pending.give(true)
        XCTAssertEqual(first, [false], "the old one is never answered twice")
        XCTAssertEqual(second, [true])
    }

    /// The old answer runs after the new one is in place: when it answers again (a controller told No may ask once more), the
    /// new question is the one that hears it, and the old one is not answered twice.
    func testTheNewQuestionIsInPlaceBeforeTheOldOneIsAnswered() {
        var first: [Bool] = [], second: [Bool] = []
        let pending = UltraPendingAnswer()
        pending.replace { first.append($0); pending.give(true) }
        pending.replace { second.append($0) }
        XCTAssertEqual(first, [false])
        XCTAssertEqual(second, [true])
        XCTAssertFalse(pending.isPending)
    }

    func testNothingPendingMeansNothingToAnswer() {
        let pending = UltraPendingAnswer()
        pending.give(true)
        XCTAssertFalse(pending.isPending)
    }

    // ── The confirm box itself (built, and never put on screen) ─────────────

    /// A box whose `present` and `dismiss` only write down that they were called, so nothing is shown.
    private final class BoxRig {
        /// What the box is told to say about the screen. It is asked at every ask, so a test can change it between two.
        final class Words { var text = "The screen is held at a quarter brightness or lower." }
        let words = Words()
        let box: UltraConfirmPanel
        var events: [String] = []
        var answers: [Bool] = []
        init() {
            // The words come from here, so the box never reads the owner's settings.
            let words = self.words
            box = UltraConfirmPanel(screenText: { words.text })
            _ = NSApplication.shared
            box.present = { [unowned self] _ in events.append("present") }
            box.putAway = { [unowned self] _ in events.append("dismiss") }
        }
        func ask(kept: [String] = ["Editor"], frozen: [String] = ["Browser", "Sync"]) {
            box.ask(kept: kept, frozen: frozen) { [unowned self] yes in answers.append(yes) }
        }
    }

    func testTheBoxIsANonActivatingPanelThatDoesNotHideWhenAnodeIsNotActive() {
        let r = BoxRig()
        r.ask()
        guard let panel = r.box.panel else { return XCTFail("no panel was built") }
        // The load-bearing one: without it, asking would make Anode the front app and take the owner's app out of front.
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate, "Anode is never the active app while the box is up")
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.delegate === r.box, "the window closing on its own account must reach the box")
        XCTAssertFalse(panel.isVisible, "the test never shows it")
        XCTAssertEqual(r.events, ["present"])
    }

    func testConfirmAnswersYesAndCancelAnswersNoEachOnce() {
        let r = BoxRig()
        r.ask()
        r.box.confirmButton.performClick(nil)
        r.box.confirmButton.performClick(nil)
        r.box.cancelButton.performClick(nil)
        XCTAssertEqual(r.answers, [true])
        r.ask()
        r.box.cancelButton.performClick(nil)
        r.box.confirmButton.performClick(nil)
        XCTAssertEqual(r.answers, [true, false])
    }

    /// The session ended while the box was up (unticked, a quit): the box goes away and its question is answered No, once.
    func testPuttingTheBoxAwayAnswersNoOnceAndPutsThePanelAway() {
        let r = BoxRig()
        r.ask()
        r.box.dismiss()
        XCTAssertEqual(r.answers, [false])
        XCTAssertEqual(r.events, ["present", "dismiss"])
        r.box.dismiss()
        XCTAssertEqual(r.answers, [false], "answered once")
        XCTAssertEqual(r.events, ["present", "dismiss"], "nothing was up the second time")
    }

    func testPuttingTheBoxAwayWhenNoneIsUpDoesNothing() {
        let r = BoxRig()
        r.box.dismiss()
        XCTAssertEqual(r.events, [])
        r.ask()
        r.box.confirmButton.performClick(nil)
        XCTAssertEqual(r.events, ["present", "dismiss"])
        r.box.dismiss()
        XCTAssertEqual(r.events, ["present", "dismiss"], "it was answered already: it is not put away again")
        XCTAssertEqual(r.answers, [true])
    }

    func testCancelIsEscapeAndReturnDoesNotConfirm() {
        let r = BoxRig()
        r.ask()
        XCTAssertEqual(r.box.cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertEqual(r.box.confirmButton.keyEquivalent, "", "a stray Return while typing must not freeze the Mac")
    }

    func testTheBoxShowsTheHeadlineTheScreenLineAndTheNamesToBeFrozen() throws {
        let r = BoxRig()
        r.words.text = UltraConfirmPanel.screenLine(backdrop: false, efficiencyCores: false, hasEfficiencyCores: true)
        r.ask(kept: ["Editor", "Meetings"], frozen: ["Browser", "Sync", "Database"])
        XCTAssertEqual(r.box.headline.stringValue,
                       "Keeps Editor and Meetings. Freezes 3 apps and tools until you turn this off.")
        let stack = try XCTUnwrap(r.box.panel?.contentView as? NSStackView)
        XCTAssertTrue(stack.arrangedSubviews[0] === r.box.headline)
        XCTAssertTrue(stack.arrangedSubviews[1] === r.box.screenLabel, "under the headline")
        XCTAssertEqual(r.box.screenLabel.stringValue,
                       "The screen is held at a quarter brightness or lower, and Low Power Mode is switched on if Anode's helper "
                       + "is installed.")
        XCTAssertFalse(r.box.screenLabel.isHidden)
        XCTAssertEqual(r.box.listedNames, ["Browser", "Sync", "Database"])
        r.ask(kept: ["Editor"], frozen: [])
        XCTAssertEqual(r.box.headline.stringValue, "Keeps Editor. Nothing else is running that can be frozen.")
        XCTAssertEqual(r.box.listedNames, [])
    }

    /// The line is asked for at each ask, not once when the box is made: the choices may change between two questions.
    func testTheBoxSaysWhatIsAboutToHappenAtEachAsk() {
        let r = BoxRig()
        let both = UltraConfirmPanel.screenLine(backdrop: true, efficiencyCores: true, hasEfficiencyCores: true)
        let neither = UltraConfirmPanel.screenLine(backdrop: false, efficiencyCores: false, hasEfficiencyCores: true)
        r.words.text = both
        r.ask()
        XCTAssertEqual(r.box.screenLabel.stringValue, both)
        r.box.cancelButton.performClick(nil)
        r.words.text = neither
        r.ask()
        XCTAssertEqual(r.box.screenLabel.stringValue, neither)
    }

    /// One sentence, built from what will happen: each clause is there when its part is on, and only then. The cores clause
    /// needs both the owner's choice and a Mac that has efficiency cores: all eight combinations of the three inputs.
    func testTheScreenLineNamesEachPartThatWillHappen() {
        let head = "The screen is held at a quarter brightness or lower"
        let tail = ", and Low Power Mode is switched on if Anode's helper is installed."
        for backdrop in [false, true] {
            for choice in [false, true] {
                for hasCores in [false, true] {
                    var expected = head
                    if backdrop { expected += ", the desktop goes black" }
                    if choice && hasCores { expected += ", what still runs is kept on the efficiency cores" }
                    XCTAssertEqual(UltraConfirmPanel.screenLine(backdrop: backdrop, efficiencyCores: choice, hasEfficiencyCores: hasCores),
                                   expected + tail, "backdrop \(backdrop), choice \(choice), cores \(hasCores)")
                }
            }
        }
    }

    /// The two lines the owner is given, word for word.
    func testTheScreenLineInTheWordsTheOwnerIsGiven() {
        XCTAssertEqual(UltraConfirmPanel.screenLine(backdrop: true, efficiencyCores: true, hasEfficiencyCores: true),
                       "The screen is held at a quarter brightness or lower, the desktop goes black, what still runs is kept on the "
                       + "efficiency cores, and Low Power Mode is switched on if Anode's helper is installed.")
        XCTAssertEqual(UltraConfirmPanel.screenLine(backdrop: false, efficiencyCores: false, hasEfficiencyCores: true),
                       "The screen is held at a quarter brightness or lower, and Low Power Mode is switched on if Anode's helper "
                       + "is installed.")
        // A Mac with no efficiency cores is not told they are in use, whatever the box says.
        XCTAssertEqual(UltraConfirmPanel.screenLine(backdrop: true, efficiencyCores: true, hasEfficiencyCores: false),
                       "The screen is held at a quarter brightness or lower, the desktop goes black, and Low Power Mode is switched on "
                       + "if Anode's helper is installed.")
    }

    func testTheScreenLineNeverSaysHalf() {
        for backdrop in [false, true] {
            for choice in [false, true] {
                for hasCores in [false, true] {
                    let line = UltraConfirmPanel.screenLine(backdrop: backdrop, efficiencyCores: choice, hasEfficiencyCores: hasCores)
                    XCTAssertFalse(line.contains("half"), line)
                }
            }
        }
    }

    func testTheCloseButtonAndAnyOtherClosingAnswerNoOnce() {
        let r = BoxRig()
        r.ask()
        // The close button asks first, and the box answers and goes by itself.
        XCTAssertFalse(r.box.windowShouldClose(r.box.panel!), "the box is put away, not closed")
        XCTAssertEqual(r.answers, [false])
        XCTAssertEqual(r.events, ["present", "dismiss"])
        // The system closing the window: nobody is waiting any more.
        r.box.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(r.answers, [false])
        r.ask()
        r.box.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        r.box.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(r.answers, [false, false], "one answer for the second question, however often it closes")
    }

    func testAskingAgainWhileOpenAnswersTheOldQuestionNoAndKeepsTheNew() {
        let r = BoxRig()
        var second: [Bool] = []
        r.ask()
        r.box.ask(kept: ["Editor"], frozen: ["Sync"]) { second.append($0) }
        XCTAssertEqual(r.answers, [false])
        XCTAssertEqual(second, [])
        r.box.confirmButton.performClick(nil)
        XCTAssertEqual(r.answers, [false])
        XCTAssertEqual(second, [true])
    }

    /// The box is put away first and the answer given after: an answer that asks again is then the last thing to happen to the
    /// panel, and the new question stays on screen.
    func testAnAnswerThatAsksAgainLeavesTheNewQuestionOnScreen() {
        let r = BoxRig()
        var again: [Bool] = []
        r.box.ask(kept: ["Editor"], frozen: ["Browser"]) { [unowned r] yes in
            r.events.append("answer \(yes)")
            r.box.ask(kept: ["Editor"], frozen: ["Sync"]) { again.append($0) }
        }
        r.box.confirmButton.performClick(nil)
        XCTAssertEqual(r.events, ["present", "dismiss", "answer true", "present"],
                       "the last thing done to the panel is to show it, or the new question has no box")
        r.box.cancelButton.performClick(nil)
        XCTAssertEqual(again, [false], "and the new question can still be answered")
    }

    func testTheBoxIsCentredOnTheScreenWithTheMenuBar() {
        let area = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let frame = UltraConfirmPanel.centred(NSSize(width: 420, height: 300), in: area)
        XCTAssertEqual(frame, NSRect(x: 510, y: 320, width: 420, height: 300))
        // Larger than the area: the corner stays on screen.
        let big = UltraConfirmPanel.centred(NSSize(width: 2000, height: 1200), in: area)
        XCTAssertEqual(big.minX, area.minX)
        XCTAssertEqual(big.maxY, area.maxY)
    }

    // ── The section ─────────────────────────────────────────────────────────

    /// What the injected closures were asked, and what they answer.
    private final class Probe {
        var controller: UltraLowPowerController?
        var candidates: [FreezeGroup] = []
        var candidateAsks = 0
        var installAsks = 0
        var installReport: ((String) -> Void)?
        var appNames: [String: String] = [:]
        var shortcutLabel: String? = "⌃⌥⌘U"
    }

    private func section(_ probe: Probe = Probe(), ticked: Bool = false, buildView: Bool = true) throws
        -> (feature: UltraLowPowerFeature, settings: Settings) {
        _ = NSApplication.shared
        let settings = try throwawaySettings(owner: "UltraLowPowerFeature", test: name)
        settings.ultraLowPowerEnabled = ticked
        let feature = UltraLowPowerFeature(
            settings: settings,
            controller: { probe.controller },
            candidates: { done in probe.candidateAsks += 1; done(probe.candidates) },
            appName: { probe.appNames[$0] },
            shortcutLabel: { probe.shortcutLabel },
            installHelper: { report in probe.installAsks += 1; probe.installReport = report })
        if buildView { _ = feature.makeView() }
        return (feature, settings)
    }

    /// A controller over a made-up Mac, as the controller's own tests have it. `work` runs inline and nothing is scheduled.
    private final class ControllerRig {
        let calls = Fakes.Calls()
        let confirm = Fakes.FakeConfirm()
        let processes = Fakes.FakeProcesses(ControllerRig.world)
        let power: Fakes.FakePower
        let controller: UltraLowPowerController

        private static func proc(_ pid: pid_t, uid: uid_t = 501, path: String, app: AppKind = .none, bundle: String? = nil,
                                 name: String) -> UltraProcess {
            UltraProcess(pid: pid, parent: 1, uid: uid, startTime: UInt64(pid) * 10, path: path, app: app, bundleID: bundle, name: name)
        }

        /// Anode (1000); the editor in front (10); a browser (20) that freezes; a cloud app (40) with a part that is root's (41).
        static let world: [UltraProcess] = [
            proc(1000, path: "/Applications/Anode.app/Contents/MacOS/Anode", app: .regular, bundle: "dev.example.self", name: "Anode"),
            proc(10, path: "/Applications/Editor.app/Contents/MacOS/Editor", app: .regular, bundle: "com.example.editor", name: "Editor"),
            proc(20, path: "/Applications/Browser.app/Contents/MacOS/Browser", app: .regular, bundle: "com.example.browser", name: "Browser"),
            proc(40, path: "/Applications/Cloud.app/Contents/MacOS/Cloud", app: .regular, bundle: "com.example.cloud", name: "Cloud"),
            proc(41, uid: 0, path: "/Applications/Cloud.app/Contents/Library/clouddaemon", name: "clouddaemon")]

        init(settings: Settings, hasEfficiencyCores: Bool = true) {
            power = Fakes.FakePower(calls)
            controller = UltraLowPowerController(
                settings: settings, processes: processes, freezer: Fakes.FakeFreezer(calls),
                throttler: Fakes.FakeThrottler(calls), processTable: { Self.world }, startTime: { UInt64($0) * 10 },
                hasEfficiencyCores: hasEfficiencyCores,
                hider: Fakes.FakeHider(calls), backlight: Fakes.FakeBacklight(calls), ownBrightness: OwnBrightness(),
                rate: Fakes.FakeRate(calls), keyboard: Fakes.FakeKeyboard(calls), power: power, lowPowerOn: { true },
                watchdog: Fakes.FakeWatchdog(calls), store: Fakes.FakeStore(calls), confirm: confirm,
                backdrop: Fakes.FakeBackdrop(calls), load: Fakes.FakeLoad(calls),
                lastOtherFrontApp: { 10 }, ownPIDs: { [1000] }, user: 501, work: { $0() }, waitForWork: { _ in true }, schedule: { _, _ in },
                alert: {}, log: { _ in })
        }
    }

    private func press(_ button: NSButton) { button.performClick(nil) }

    func testSectionIsInTheBetaFeaturesList() throws {
        let list = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false,
                                                               settings: try throwawaySettings(owner: "UltraLowPowerFeature", test: name))
        XCTAssertTrue(list.contains { $0 is UltraLowPowerFeature })
        XCTAssertEqual(list.first { $0 is UltraLowPowerFeature }?.title, "Ultra Low Power Mode")
    }

    func testTheSectionIsUntickedByDefaultAndTheCheckboxWritesTheSetting() throws {
        let probe = Probe()
        let (f, settings) = try section(probe)
        XCTAssertEqual(f.enableCheckbox.state, .off)
        XCTAssertFalse(settings.ultraLowPowerEnabled)
        press(f.enableCheckbox)
        XCTAssertTrue(settings.ultraLowPowerEnabled)
        XCTAssertEqual(f.enableCheckbox.state, .on)
        press(f.enableCheckbox)
        XCTAssertFalse(settings.ultraLowPowerEnabled)
    }

    func testTickingTheBoxNeverStartsTheMode() throws {
        let probe = Probe()
        let (f, settings) = try section(probe)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        press(f.enableCheckbox)
        XCTAssertEqual(rig.controller.state, .off)
        XCTAssertTrue(rig.confirm.keptNames.isEmpty, "nobody was asked anything")
    }

    func testWithNoControllerTheSectionShowsTheCheckboxAndADisabledButton() throws {
        let (f, _) = try section(ticked: true)
        XCTAssertEqual(f.enableCheckbox.state, .on)
        XCTAssertEqual(f.startButton.title, "Start…")
        XCTAssertFalse(f.startButton.isEnabled)
    }

    func testTheButtonIsDisabledWhileUntickedAndStartsTheMode() throws {
        let probe = Probe()
        let (f, settings) = try section(probe)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        f.refresh()
        XCTAssertFalse(f.startButton.isEnabled, "unticked")
        press(f.enableCheckbox)
        XCTAssertTrue(f.startButton.isEnabled)
        press(f.startButton)
        XCTAssertEqual(rig.controller.state, .confirming)
        XCTAssertEqual(rig.confirm.keptNames, [["Editor"]], "the box was asked, by names")
        XCTAssertEqual(rig.confirm.frozenNames, [["Browser"]])
        XCTAssertFalse(f.startButton.isEnabled, "the box is up")
        rig.confirm.press(false)
        XCTAssertEqual(rig.controller.state, .off)
        XCTAssertTrue(f.startButton.isEnabled)
    }

    /// Confirmed, and the mode is not on yet (the helper has not answered): the button is the way out of the start.
    func testTheButtonIsCancelWhileTheStartIsRunningAndPressingItTurnsTheModeOff() throws {
        let probe = Probe()
        let (f, settings) = try section(probe)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        press(f.enableCheckbox)
        rig.power.hold = true
        press(f.startButton)
        XCTAssertEqual(f.startButton.title, "Start…", "the box is up")
        XCTAssertFalse(f.startButton.isEnabled)
        rig.confirm.press(true)
        XCTAssertEqual(rig.controller.state, .confirming)
        XCTAssertEqual(f.startButton.title, "Cancel")
        XCTAssertTrue(f.startButton.isEnabled)
        press(f.startButton)
        XCTAssertEqual(rig.controller.state, .off)
        XCTAssertFalse(rig.controller.isStarting)
        XCTAssertEqual(f.startButton.title, "Start…")
        XCTAssertTrue(f.startButton.isEnabled)
    }

    func testTheShortcutCancelsAStartThatIsRunning() throws {
        let probe = Probe()
        let (_, settings) = try section(probe)
        let rig = ControllerRig(settings: settings)
        rig.power.hold = true
        rig.controller.request()
        UltraMenu.toggle(rig.controller)
        XCTAssertEqual(rig.controller.state, .confirming, "the box is up: the key does not ask again")
        XCTAssertEqual(rig.confirm.keptNames.count, 1)
        rig.confirm.press(true)
        XCTAssertTrue(rig.controller.isStarting)
        UltraMenu.toggle(rig.controller)
        XCTAssertEqual(rig.controller.state, .off)
    }

    /// The list of running apps could not be read: one line under the button, until the next ask.
    func testTheSectionSaysWhenTheAppsCouldNotBeReadUnderTheButtonUntilTheNextAsk() throws {
        let probe = Probe()
        let (f, settings) = try section(probe)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        press(f.enableCheckbox)
        XCTAssertTrue(f.failureLabel.isHidden)
        rig.processes.list = nil
        press(f.startButton)
        XCTAssertEqual(rig.controller.state, .off)
        XCTAssertFalse(f.failureLabel.isHidden)
        XCTAssertEqual(f.failureLabel.stringValue, "Anode could not read the running apps. Try again.")
        let column = try XCTUnwrap(f.failureLabel.superview as? NSStackView)
        let order = column.arrangedSubviews
        XCTAssertEqual(order.firstIndex(of: f.failureLabel), order.firstIndex(of: f.startButton).map { $0 + 1 },
                       "one line, right under the button")
        rig.processes.list = ControllerRig.world
        press(f.startButton)
        XCTAssertTrue(f.failureLabel.isHidden)
        XCTAssertEqual(f.failureLabel.stringValue, "")
    }

    func testTheButtonTurnsTheModeOff() throws {
        let probe = Probe()
        let (f, settings) = try section(probe, ticked: true)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        f.refresh()
        press(f.startButton)
        rig.confirm.press(true)
        XCTAssertEqual(rig.controller.state, .on)
        XCTAssertEqual(f.startButton.title, "Turn Off")
        XCTAssertTrue(f.startButton.isEnabled)
        press(f.startButton)
        XCTAssertEqual(rig.controller.state, .off)
        XCTAssertEqual(f.startButton.title, "Start…")
    }

    /// Unticked while the mode runs: the section still has a way out.
    func testUntickingWhileTheModeRunsLeavesTurnOffEnabled() throws {
        let probe = Probe()
        let (f, settings) = try section(probe, ticked: true)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        f.refresh()
        press(f.startButton)
        rig.confirm.press(true)
        press(f.enableCheckbox)
        XCTAssertFalse(settings.ultraLowPowerEnabled)
        XCTAssertEqual(f.startButton.title, "Turn Off")
        XCTAssertTrue(f.startButton.isEnabled)
    }

    func testTheSectionNamesWhatTheModeSkippedAndWhatItLeftRunning() throws {
        let probe = Probe()
        let (f, settings) = try section(probe, ticked: true)
        let rig = ControllerRig(settings: settings)
        rig.power.availability = .noHelper
        probe.controller = rig.controller
        f.refresh()
        XCTAssertTrue(f.skippedLabel.isHidden)
        XCTAssertTrue(f.leftRunningLabel.isHidden)
        XCTAssertTrue(f.installButton.isHidden)
        press(f.startButton)
        rig.confirm.press(true)
        XCTAssertEqual(rig.controller.state, .on)
        XCTAssertFalse(f.skippedLabel.isHidden)
        XCTAssertEqual(f.skippedLabel.stringValue, UltraLowPowerFeature.describe([.lowPowerNoHelper]).joined(separator: "\n"))
        XCTAssertEqual(f.leftRunningLabel.stringValue, "Left running: Cloud (it has a part Anode cannot freeze).")
        XCTAssertFalse(f.installButton.isHidden, "a missing helper comes with the way to install it")
        // Ending the mode takes the lines away with it.
        press(f.startButton)
        XCTAssertTrue(f.skippedLabel.isHidden)
        XCTAssertTrue(f.leftRunningLabel.isHidden)
        XCTAssertTrue(f.installButton.isHidden)
    }

    func testTheInstallButtonUsesTheRouteChargeControlUsesAndShowsWhatItReports() throws {
        let probe = Probe()
        let (f, settings) = try section(probe, ticked: true)
        let rig = ControllerRig(settings: settings)
        rig.power.availability = .oldHelper
        probe.controller = rig.controller
        f.refresh()
        press(f.startButton)
        rig.confirm.press(true)
        XCTAssertFalse(f.installButton.isHidden)
        XCTAssertTrue(f.installNoteLabel.isHidden)
        press(f.installButton)
        XCTAssertEqual(probe.installAsks, 1)
        probe.installReport?("The Anode helper is installed. Fan control is as it was.")
        XCTAssertEqual(f.installNoteLabel.stringValue, "The Anode helper is installed. Fan control is as it was.")
        XCTAssertFalse(f.installNoteLabel.isHidden)
    }

    func testTheSectionListensForTheControllerOnlyOnceItsViewExists() throws {
        let probe = Probe()
        let (f, settings) = try section(probe, ticked: true, buildView: false)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        settings.ultraLowPowerEnabled = false
        f.enableCheckbox.state = .on                        // stale on screen
        NotificationCenter.default.post(name: UltraLowPowerController.didChange, object: nil)
        XCTAssertEqual(f.enableCheckbox.state, .on, "no view yet: nothing is listening")
        _ = f.makeView()
        XCTAssertEqual(f.enableCheckbox.state, .off)
        f.enableCheckbox.state = .on
        NotificationCenter.default.post(name: UltraLowPowerController.didChange, object: nil)
        XCTAssertEqual(f.enableCheckbox.state, .off, "now it follows")
    }

    func testTheSectionFollowsTheSettings() throws {
        let (f, settings) = try section()
        settings.ultraLowPowerEnabled = true
        XCTAssertEqual(f.enableCheckbox.state, .on)
        settings.ultraLowPowerAlwaysKeep = ["job:db"]
        XCTAssertEqual(f.keptNames, ["db"])
    }

    func testTheNoteIsOnTheSectionAndSaysWhatWasMeasured() throws {
        let (f, _) = try section()
        XCTAssertEqual(f.noteLabel.stringValue, UltraLowPowerFeature.note)
        XCTAssertFalse(f.summary.contains("hours"))
    }

    /// What is left running (the always-keep list, apps with a part Anode cannot freeze, what the guard let go, macOS's own
    /// services) is why the summary may not say "every app", and the screen is held at a quarter brightness or lower, not just dim.
    func testTheSummarySaysOnlyWhatIsTrueAndNamesTheShortcut() throws {
        let probe = Probe()
        probe.shortcutLabel = "⌃⌥⌘J"
        let (f, _) = try section(probe)
        XCTAssertTrue(f.summary.hasPrefix("Freezes the apps and tools you are not using, and holds the screen at a quarter "
                                          + "brightness or lower, until you turn it off."), f.summary)
        XCTAssertFalse(f.summary.contains("every app"), f.summary)
        XCTAssertFalse(f.summary.contains("dim"), f.summary)
        XCTAssertTrue(f.summary.contains("(or choose it from a menu, or press ⌃⌥⌘J)"), "the key the owner has chosen: \(f.summary)")
    }

    /// A key the owner has cleared does nothing, so the summary does not send them to it.
    func testTheSummaryDropsThePressClauseWhenThereIsNoKey() throws {
        let probe = Probe()
        probe.shortcutLabel = nil
        let (f, _) = try section(probe)
        XCTAssertTrue(f.summary.hasPrefix("Freezes the apps and tools you are not using, and holds the screen at a quarter "
                                          + "brightness or lower, until you turn it off."), f.summary)
        XCTAssertTrue(f.summary.contains("press Start (or choose it from a menu) and confirm"), f.summary)
        XCTAssertFalse(f.summary.contains("⌃"), f.summary)
        XCTAssertFalse(f.summary.contains("or press"), f.summary)
    }

    /// The key the summary names is the one the store holds: a cleared key is nil, not the default again.
    func testTheKeyIsReadFromTheStoreAndAClearedKeyIsNone() {
        let store = ShortcutStore(defaults: TestDefaults.throwaway("ultra-summary"))
        XCTAssertEqual(UltraLowPowerFeature.keyLabel(in: store), "⌃⌥⌘U")
        store.assign(Shortcut(key: kVK_ANSI_J, modifiers: Shortcut.control | Shortcut.command), to: ShortcutCommands.ultraToggle,
                     among: ShortcutCommands.all)
        XCTAssertEqual(UltraLowPowerFeature.keyLabel(in: store), "⌃⌘J")
        store.assign(nil, to: ShortcutCommands.ultraToggle, among: ShortcutCommands.all)
        XCTAssertNil(UltraLowPowerFeature.keyLabel(in: store), "cleared: the default must not come back")
    }

    // ── What the mode does besides freezing ─────────────────────────────────

    func testTheEfficiencyCoresBoxSaysWhatItCostsAndWritesItsSetting() throws {
        let (f, settings) = try section()
        XCTAssertEqual(f.efficiencyCheckbox.title, "Keep everything on the efficiency cores (slower)")
        XCTAssertEqual(f.efficiencyCheckbox.state, .on, "on by default")
        XCTAssertTrue(settings.ultraLowPowerEfficiencyCores)
        press(f.efficiencyCheckbox)
        XCTAssertFalse(settings.ultraLowPowerEfficiencyCores)
        XCTAssertEqual(f.efficiencyCheckbox.state, .off)
        press(f.efficiencyCheckbox)
        XCTAssertTrue(settings.ultraLowPowerEfficiencyCores)
        XCTAssertFalse(settings.ultraLowPowerEnabled, "a separate setting")
    }

    func testTheEfficiencyCoresBoxFollowsTheSettingWhenItChangesElsewhere() throws {
        let (f, settings) = try section()
        settings.ultraLowPowerEfficiencyCores = false
        XCTAssertEqual(f.efficiencyCheckbox.state, .off)
        settings.ultraLowPowerEfficiencyCores = true
        XCTAssertEqual(f.efficiencyCheckbox.state, .on)
    }

    func testTheChoicesAreUnderTheEnableBox() throws {
        let (f, _) = try section(buildView: false)
        let column = try XCTUnwrap(f.makeView() as? NSStackView)
        XCTAssertTrue(column.arrangedSubviews[0] === f.enableCheckbox)
        XCTAssertTrue(column.arrangedSubviews[1] === f.efficiencyCheckbox)
        XCTAssertTrue(column.arrangedSubviews[2] === f.backdropCheckbox)
    }

    func testTheBackdropBoxSaysWhatItDoesAndWritesItsSetting() throws {
        let (f, settings) = try section()
        XCTAssertEqual(f.backdropCheckbox.title, "Black out the desktop behind your windows")
        XCTAssertEqual(f.backdropCheckbox.state, .on, "on by default")
        XCTAssertTrue(settings.ultraLowPowerBlackBackdrop)
        press(f.backdropCheckbox)
        XCTAssertFalse(settings.ultraLowPowerBlackBackdrop)
        XCTAssertEqual(f.backdropCheckbox.state, .off)
        XCTAssertTrue(settings.ultraLowPowerEfficiencyCores, "a separate setting")
        press(f.backdropCheckbox)
        XCTAssertTrue(settings.ultraLowPowerBlackBackdrop)
    }

    func testTheBackdropBoxFollowsTheSettingWhenItChangesElsewhere() throws {
        let (f, settings) = try section()
        settings.ultraLowPowerBlackBackdrop = false
        XCTAssertEqual(f.backdropCheckbox.state, .off)
        settings.ultraLowPowerBlackBackdrop = true
        XCTAssertEqual(f.backdropCheckbox.state, .on)
    }

    /// The choices are read when the mode starts, so they are not changed under it: not while the box is up (it lists what is
    /// about to happen) and not while it runs.
    func testTheChoicesAreSwitchedOffExactlyWhileTheModeIsAskedForOrRuns() {
        XCTAssertTrue(UltraLowPowerFeature.optionsEnabled(state: .off))
        XCTAssertTrue(UltraLowPowerFeature.optionsEnabled(state: nil), "no controller: nothing is running")
        XCTAssertFalse(UltraLowPowerFeature.optionsEnabled(state: .confirming))
        XCTAssertFalse(UltraLowPowerFeature.optionsEnabled(state: .on))
    }

    func testTheChoiceBoxesAreDisabledWhileTheModeRunsAndEnabledAgainAfter() throws {
        let probe = Probe()
        let (f, settings) = try section(probe, ticked: true)
        let rig = ControllerRig(settings: settings)
        probe.controller = rig.controller
        f.refresh()
        XCTAssertTrue(f.efficiencyCheckbox.isEnabled)
        XCTAssertTrue(f.backdropCheckbox.isEnabled)
        press(f.startButton)
        XCTAssertFalse(f.efficiencyCheckbox.isEnabled, "the box is up")
        XCTAssertFalse(f.backdropCheckbox.isEnabled, "the box is up")
        rig.confirm.press(true)
        XCTAssertEqual(rig.controller.state, .on)
        XCTAssertFalse(f.efficiencyCheckbox.isEnabled)
        XCTAssertFalse(f.backdropCheckbox.isEnabled)
        press(f.startButton)
        XCTAssertEqual(rig.controller.state, .off)
        XCTAssertTrue(f.efficiencyCheckbox.isEnabled)
        XCTAssertTrue(f.backdropCheckbox.isEnabled)
    }

    func testTheSectionNamesAMacWithoutEfficiencyCores() throws {
        let probe = Probe()
        let (f, settings) = try section(probe, ticked: true)
        let rig = ControllerRig(settings: settings, hasEfficiencyCores: false)
        probe.controller = rig.controller
        f.refresh()
        press(f.startButton)
        rig.confirm.press(true)
        XCTAssertEqual(f.skippedLabel.stringValue, "This Mac has no efficiency cores, so work was left on the cores it has.")
        XCTAssertFalse(f.skippedLabel.isHidden)
    }

    // ── The always-keep list ────────────────────────────────────────────────

    func testTheListShowsEachStoredIdByAReadableName() throws {
        let probe = Probe()
        probe.appNames = ["com.example.editor": "Editor"]
        let (f, settings) = try section(probe)
        settings.ultraLowPowerAlwaysKeep = ["com.example.editor", "job:com.example.database", "exe:worker", "com.example.unknown"]
        XCTAssertEqual(f.keptNames, ["Editor", "com.example.database", "worker", "com.example.unknown"])
        XCTAssertEqual(f.removeButtons.count, 4, "a remove button for each row")
    }

    func testANameSeenInTheCandidatesIsRememberedForTheList() throws {
        let probe = Probe()
        probe.candidates = [group("com.example.browser", "Browser")]
        let (f, settings) = try section(probe)
        settings.ultraLowPowerAlwaysKeep = ["com.example.browser"]
        XCTAssertEqual(f.keptNames, ["Browser"], "the app is not running by a name macOS gives, but the picker knew it")
    }

    func testAddingAndRemovingWriteTheSetting() throws {
        let probe = Probe()
        probe.candidates = [group("com.example.browser", "Browser"), group("job:db", "db")]
        let (f, settings) = try section(probe)
        settings.ultraLowPowerAlwaysKeep = ["com.example.editor"]
        f.refresh()
        XCTAssertEqual(f.addChoices, ["Browser", "db"])
        choose("db", in: f)
        XCTAssertEqual(settings.ultraLowPowerAlwaysKeep, ["com.example.editor", "job:db"])
        XCTAssertEqual(f.addChoices, ["Browser"], "an app already kept is not offered again")
        XCTAssertEqual(f.keptNames, ["com.example.editor", "db"])
        press(f.removeButtons[0])
        XCTAssertEqual(settings.ultraLowPowerAlwaysKeep, ["job:db"])
        XCTAssertEqual(f.keptNames, ["db"])
    }

    func testAddingWhatIsAlreadyThereChangesNothing() throws {
        let (f, settings) = try section()
        settings.ultraLowPowerAlwaysKeep = ["a", "b"]
        f.add(groupID: "a", name: "A")
        XCTAssertEqual(settings.ultraLowPowerAlwaysKeep, ["a", "b"])
    }

    func testWithNothingToAddThePopupSaysSo() throws {
        let (f, _) = try section()
        f.refresh()
        XCTAssertEqual(f.addPopup.menu?.items.map(\.title), ["Add…", "Nothing else is running"])
        XCTAssertEqual(f.addChoices, [])
        XCTAssertEqual(f.addPopup.menu?.items.last?.isEnabled, false)
    }

    func testTheCandidatesAreAskedForWhenTheWindowComesForwardNotOnEveryChange() throws {
        let probe = Probe()
        let (f, settings) = try section(probe)
        let before = probe.candidateAsks
        settings.ultraLowPowerAlwaysKeep = ["a"]
        settings.ultraLowPowerEnabled = true
        NotificationCenter.default.post(name: UltraLowPowerController.didChange, object: nil)
        XCTAssertEqual(probe.candidateAsks, before, "a change redraws; it does not read the process list again")
        f.refresh()
        XCTAssertEqual(probe.candidateAsks, before + 1)
    }

    private func choose(_ name: String, in f: UltraLowPowerFeature) {
        guard let item = f.addPopup.menu?.items.first(where: { $0.title == name && $0.representedObject != nil }),
              let action = item.action else {
            return XCTFail("\(name) is not offered")
        }
        // The section is not an NSObject: the application sends the action, as a click on the item would.
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
    }
}
