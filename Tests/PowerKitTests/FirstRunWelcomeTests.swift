import XCTest
@testable import PowerKit

/// The notice a newly installed Anode shows before anything else: what it asks of the Mac, and what macOS will show for it.
final class FirstRunWelcomeTests: XCTestCase {

    // ── When ────────────────────────────────────────────────────────────────

    func testItIsDueOnTheFirstLaunchOfAFreshInstall() {
        XCTAssertTrue(FirstRunWelcome.isDue(welcomeSeen: false, autoUpdatePromptSeen: false, helperOfferedForBuild: ""))
    }

    func testItIsNotDueOnceItWasShown() {
        XCTAssertFalse(FirstRunWelcome.isDue(welcomeSeen: true, autoUpdatePromptSeen: false, helperOfferedForBuild: ""))
    }

    func testItIsNotDueForSomeoneWhoAlreadyUsesAnode() {
        // They answered the automatic-update question, or were offered the helper, in an earlier version: this is not a first install.
        XCTAssertFalse(FirstRunWelcome.isDue(welcomeSeen: false, autoUpdatePromptSeen: true, helperOfferedForBuild: ""))
        XCTAssertFalse(FirstRunWelcome.isDue(welcomeSeen: false, autoUpdatePromptSeen: false, helperOfferedForBuild: "d950805"))
    }

    func testTheFlagIsKeptLikeTheOtherFirstRunAnswers() throws {
        let (defaults, name) = try TestDefaults.make(owner: "FirstRunWelcome", test: self.name)
        defer { TestDefaults.destroy(defaults, name) }
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.welcomeSeen, "a fresh install has not been welcomed")
        s.welcomeSeen = true
        XCTAssertTrue(Settings(defaults: defaults).welcomeSeen)
    }

    // ── What it says ────────────────────────────────────────────────────────

    func testItWelcomesAndSaysWhatToExpect() {
        XCTAssertEqual(FirstRunWelcome.title, "Welcome to Anode!")
        let said = FirstRunWelcome.text
        for word in ["Accessibility", "Screen Recording", "password"] { XCTAssertTrue(said.contains(word), "it does not say \(word)") }
    }

    func testItSaysWhatMacOSWillShow() {
        // macOS 27.3 lists an app that controls others in the menu bar, "Accessing all apps": the person should know it is macOS's.
        XCTAssertTrue(FirstRunWelcome.text.contains("Accessing all apps"))
        XCTAssertTrue(FirstRunWelcome.text.contains("macOS"))
    }

    func testItSaysEverythingIsOptionalAndWhereToChangeIt() {
        XCTAssertTrue(FirstRunWelcome.text.lowercased().contains("optional"))
        XCTAssertTrue(FirstRunWelcome.text.contains("Privacy & Security"))
    }

    func testItStaysShortEnoughToReadAtOnce() {
        XCTAssertLessThan(FirstRunWelcome.text.count, 750)
        XCTAssertEqual(FirstRunWelcome.button, "Continue")
    }

    func testItNamesWhatTheHelperIsForTheSameWayTheHelperNoticeDoes() {
        // The password it mentions is the helper's; the next notice explains the helper itself.
        XCTAssertTrue(FirstRunWelcome.text.contains("helper"))
    }
}
