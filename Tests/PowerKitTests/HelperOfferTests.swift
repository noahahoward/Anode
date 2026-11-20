import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The Anode helper is offered on the first launch of a newly installed or updated Anode: installed when there is none,
/// updated when the one installed speaks less than this app, and asked about once for each build.
final class HelperOfferTests: XCTestCase {

    // ── The rule ────────────────────────────────────────────────────────────

    private func offer(installed: Bool, helper: Int?, app: Int = 4, build: String = "abc1234", offeredFor: String = "",
                       canInstall: Bool = true) -> HelperOffer? {
        HelperOfferRule.offer(installed: installed, helperVersion: helper, appVersion: app, thisBuild: build,
                              offeredForBuild: offeredFor, canInstall: canInstall)
    }

    /// A fresh install asks for nothing: no notice, no administrator password, until the person turns something on.
    func testWithNoHelperInstalledNothingIsOffered() {
        XCTAssertNil(offer(installed: false, helper: nil))
        XCTAssertNil(offer(installed: false, helper: nil, build: "never-offered-before", offeredFor: ""))
    }

    func testAHelperThatSpeaksLessThanThisAppIsOfferedAnUpdate() {
        XCTAssertEqual(offer(installed: true, helper: 3), .update)
        XCTAssertEqual(offer(installed: true, helper: 1), .update)
    }

    func testAHelperThatSpeaksWhatThisAppSpeaksIsLeftAlone() {
        XCTAssertNil(offer(installed: true, helper: 4))
        // A newer helper than the app (an older app opened beside a newer install) is not this app's to replace.
        XCTAssertNil(offer(installed: true, helper: 5))
    }

    /// An installed helper that did not answer says nothing about what it speaks, and a password is not asked for on a guess.
    func testAnInstalledHelperThatDidNotAnswerIsNotGuessedAt() {
        XCTAssertNil(offer(installed: true, helper: nil))
    }

    /// "Not Now", a cancelled password and a failed install are all answers: the same build does not ask again.
    func testTheSameBuildNeverAsksTwice() {
        XCTAssertNil(offer(installed: false, helper: nil, build: "abc1234", offeredFor: "abc1234"))
        XCTAssertNil(offer(installed: true, helper: 3, build: "abc1234", offeredFor: "abc1234"))
    }

    func testTheNextBuildAsksAgain() {
        XCTAssertNil(offer(installed: false, helper: nil, build: "def5678", offeredFor: "abc1234"))
        XCTAssertEqual(offer(installed: true, helper: 3, build: "def5678", offeredFor: "abc1234"), .update)
    }

    func testABuildThatCannotInstallOrCannotBeNamedOffersNothing() {
        XCTAssertNil(offer(installed: false, helper: nil, canInstall: false))
        XCTAssertNil(offer(installed: false, helper: nil, build: ""))
    }

    // ── What the owner reads ────────────────────────────────────────────────

    func testTheNoticeSaysWhyNowWhatTheHelperIsForAndThatThePasswordIsAsked() {
        for (kind, title, button, why) in [(HelperOffer.install, "Install the Anode helper?", "Install", "Anode was just installed."),
                                           (.update, "Update the Anode helper?", "Update",
                                            "Anode was just updated, and its helper is an older one.")] {
            XCTAssertEqual(HelperOfferNotice.title(kind), title)
            XCTAssertEqual(HelperOfferNotice.button(kind), button)
            let text = HelperOfferNotice.text(kind)
            XCTAssertTrue(text.hasPrefix(why), text)
            XCTAssertTrue(text.contains(HelperVocabulary.whatItIsFor), text)
            XCTAssertTrue(text.contains(HelperVocabulary.sentence), "every ability is named: \(text)")
            XCTAssertTrue(text.contains("macOS will ask for your password."), text)
            XCTAssertTrue(text.contains("You can also do this later from the Fans tab, Charge Control or Ultra Low Power Mode."), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("fan helper"), text)
        }
        XCTAssertEqual(HelperOfferNotice.notNow, "Not Now")
        XCTAssertEqual(HelperOfferNotice.finished(.install), "The Anode helper is installed. " + HelperVocabulary.whatItIsFor)
        XCTAssertEqual(HelperOfferNotice.finished(.update), "The Anode helper is up to date. " + HelperVocabulary.whatItIsFor)
    }

    /// The route's one confirmation is this notice for the two new origins: one dialog before the password, not two.
    func testTheInstallRoutesConfirmationIsTheNoticeForAnOfferAtLaunch() {
        let install = FanControlPanel.installAlert(helper: "/x", origin: .afterInstall)
        XCTAssertEqual(install.messageText, HelperOfferNotice.title(.install))
        XCTAssertEqual(install.informativeText, HelperOfferNotice.text(.install))
        XCTAssertEqual(install.buttons.map(\.title), ["Install", "Not Now"])
        let update = FanControlPanel.installAlert(helper: "/x", origin: .afterUpdate)
        XCTAssertEqual(update.messageText, HelperOfferNotice.title(.update))
        XCTAssertEqual(update.informativeText, HelperOfferNotice.text(.update))
        XCTAssertEqual(update.buttons.map(\.title), ["Update", "Not Now"])
        // The buttons in the sections keep their own.
        XCTAssertEqual(FanControlPanel.installAlert(helper: "/x", origin: .fansTab).buttons.map(\.title), ["Install", "Cancel"])
    }

    func testTheFinishedLineForAnOfferIsNotAboutFans() {
        XCTAssertEqual(FanControlPanel.installedText(from: .afterInstall), HelperOfferNotice.finished(.install))
        XCTAssertEqual(FanControlPanel.installedText(from: .afterUpdate), HelperOfferNotice.finished(.update))
        XCTAssertEqual(FanControlPanel.installedText(from: .chargeControl), FanControlPanel.installedForChargeControlText)
        XCTAssertEqual(FanControlPanel.installedText(from: .ultraLowPower), FanControlPanel.installedForUltraLowPowerText)
        XCTAssertTrue(FanControlPanel.installedText(from: .fansTab).hasPrefix("Fan control is installed and ON."))
    }

    // ── The step at launch ──────────────────────────────────────────────────

    private final class Rig {
        var offeredFor = ""
        var installed = false
        var helperVersion: Int?
        var mayAsk = true
        var canInstall = true
        var greets = 0
        var started: [HelperOffer] = []
        /// What the setting held at the moment the install route was called.
        var offeredForWhenStarted: [String] = []
        lazy var step = HelperOfferAtLaunch(
            thisBuild: "abc1234",
            offeredForBuild: { [unowned self] in self.offeredFor },
            rememberOffered: { [unowned self] in self.offeredFor = $0 },
            canInstall: { [unowned self] in self.canInstall },
            isInstalled: { [unowned self] in self.installed },
            greet: { [unowned self] done in self.greets += 1; done(self.helperVersion) },
            mayAsk: { [unowned self] in self.mayAsk },
            start: { [unowned self] kind in self.started.append(kind); self.offeredForWhenStarted.append(self.offeredFor) })
    }

    /// The requirement: a fresh install, nothing turned on, shows no notice, asks for no password and wakes no helper.
    func testAFreshInstallOffersNothingAndWakesNothing() {
        let rig = Rig()
        rig.step.run()
        rig.step.run()
        XCTAssertEqual(rig.started, [], "no helper offer on a fresh install")
        XCTAssertEqual(rig.greets, 0, "there is no helper to ask")
        XCTAssertEqual(rig.offeredFor, "", "nothing was offered, so nothing is remembered")
    }

    /// An update for someone who chose to install the helper is offered once, and remembered before the notice appears.
    func testAnOlderInstalledHelperIsOfferedTheUpdateOnceAndRemembersBeforeItAsks() {
        let rig = Rig()
        rig.installed = true
        rig.helperVersion = 3
        rig.step.run()
        XCTAssertEqual(rig.started, [.update])
        XCTAssertEqual(rig.offeredForWhenStarted, ["abc1234"], "written before the notice, so a crash cannot bring it back")
        rig.step.run()
        XCTAssertEqual(rig.started, [.update], "the same build does not ask twice")
    }

    func testAnUpdateWhoseHelperIsOlderOffersTheUpdate() {
        let rig = Rig()
        rig.installed = true
        rig.helperVersion = 3
        rig.step.run()
        XCTAssertEqual(rig.greets, 1)
        XCTAssertEqual(rig.started, [.update])
        XCTAssertEqual(rig.offeredFor, "abc1234")
    }

    func testAnUpdateWhoseHelperIsCurrentAsksNothingAndIsNotRemembered() {
        let rig = Rig()
        rig.installed = true
        rig.helperVersion = FanDaemon.protocolVersion
        rig.step.run()
        XCTAssertEqual(rig.started, [])
        // Nothing was offered, so nothing is remembered: a helper removed later in this build is still offered once.
        XCTAssertEqual(rig.offeredFor, "")
    }

    /// The first-run question about automatic updates, or a mode that is on, has the screen: this launch asks nothing and
    /// the question is left for the next.
    func testALaunchThatMayNotAskLeavesTheOfferForTheNext() {
        let rig = Rig()
        rig.installed = true
        rig.helperVersion = 3
        rig.mayAsk = false
        rig.step.run()
        XCTAssertEqual(rig.started, [])
        XCTAssertEqual(rig.offeredFor, "")
        rig.mayAsk = true
        rig.step.run()
        XCTAssertEqual(rig.started, [.update])
    }

    func testABuildOfferedAlreadyDoesNotEvenWakeTheHelper() {
        let rig = Rig()
        rig.installed = true
        rig.helperVersion = 3
        rig.offeredFor = "abc1234"
        rig.step.run()
        XCTAssertEqual(rig.greets, 0)
        XCTAssertEqual(rig.started, [])
    }

    func testABuildThatCannotInstallAsksNothing() {
        let rig = Rig()
        rig.canInstall = false
        rig.step.run()
        XCTAssertEqual(rig.started, [])
        XCTAssertEqual(rig.offeredFor, "")
    }

    /// May-ask is looked at again after the helper answered: the answer can take a moment, and a mode can have started.
    func testWhatMayBeAskedIsCheckedAgainAfterTheHelperAnswers() {
        let rig = Rig()
        rig.installed = true
        rig.helperVersion = 3
        var held: ((Int?) -> Void)?
        let step = HelperOfferAtLaunch(
            thisBuild: "abc1234", offeredForBuild: { rig.offeredFor }, rememberOffered: { rig.offeredFor = $0 },
            canInstall: { true }, isInstalled: { true }, greet: { held = $0 }, mayAsk: { rig.mayAsk },
            start: { rig.started.append($0) })
        step.run()
        rig.mayAsk = false
        held?(3)
        XCTAssertEqual(rig.started, [])
        XCTAssertEqual(rig.offeredFor, "")
    }

    /// `live` is not made in a test, so what it connects is read from its text.
    func testTheLiveStepIsConnectedToTheRealParts() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/HelperOfferAtLaunch.swift"), encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for needed in ["isInstalled: { FanDaemon.isInstalled() }",
                       "canInstall: { FanControlPanel.helperIsBundled && !AppSandbox.isOn }",
                       "connection.connect(for: .offer)",
                       "connection.release(.offer)",
                       "UltraLowPowerController.current?.state ?? .off) == .off",
                       "!autoUpdateQuestionDue()",
                       "panel.installHelper(report: { _ in }, from: kind == .install ? .afterInstall : .afterUpdate)"] {
            XCTAssertTrue(code.contains(needed), "live() no longer has: \(needed)")
        }
        let main = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("HelperOfferAtLaunch.live(panel: fansPane.control, autoUpdateQuestionDue:"),
                      "the app no longer makes the step")
        XCTAssertTrue(main.contains("helperOffer.runAfterLaunch()"), "the app no longer runs the step at launch")
        // A fresh install is asked about automatic updates first; the helper is offered as soon as that is answered, not
        // at the launch after.
        XCTAssertTrue(main.contains("self.helperOffer.runAfterLaunch(delay: 1)"),
                      "the offer no longer follows the answer to the automatic-updates question")
    }

    // ── The notice has no logo ──────────────────────────────────────────────

    /// The notice had the app's logo in a column of its own beside three paragraphs of text. It has none now, and the
    /// text begins where the logo did and is as wide as the column the logo took. Read from the alert as it is laid
    /// out, for every way the helper is offered; nothing is shown.
    func testTheHelperNoticesHaveNoLogoAndTheirTextTakesTheWholeWidth() throws {
        for origin in [FanControlPanel.InstallOrigin.afterInstall, .afterUpdate, .fansTab, .chargeControl, .ultraLowPower] {
            // The same alert as `NSAlert` lays it out by itself, to compare with.
            let plain = NSAlert()
            let made = FanControlPanel.installAlert(helper: "/Applications/Anode.app/Contents/MacOS/AnodeHelper", origin: origin)
            plain.messageText = made.messageText
            plain.informativeText = made.informativeText
            for b in made.buttons { plain.addButton(withTitle: b.title) }
            plain.layout()
            let plainContent = try XCTUnwrap(plain.window.contentView)
            let plainIcon = try XCTUnwrap(plainContent.subviews.first { $0 is NSImageView }, "an alert has no icon view on this macOS")
            let plainText = try XCTUnwrap(plainContent.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == made.informativeText })

            let content = try XCTUnwrap(made.window.contentView)
            let icon = try XCTUnwrap(content.subviews.first { $0 is NSImageView })
            XCTAssertTrue(icon.isHidden, "\(origin): the logo is still shown")
            let texts = content.subviews.compactMap { $0 as? NSTextField }
            let title = try XCTUnwrap(texts.first { $0.stringValue == made.messageText })
            let body = try XCTUnwrap(texts.first { $0.stringValue == made.informativeText })
            XCTAssertEqual(title.frame.minX, plainIcon.frame.minX, accuracy: 0.5, "\(origin): the title does not begin where the logo did")
            XCTAssertEqual(body.frame.minX, plainIcon.frame.minX, accuracy: 0.5, "\(origin)")
            XCTAssertEqual(body.frame.width, plainText.frame.width + (plainText.frame.minX - plainIcon.frame.minX), accuracy: 0.5,
                           "\(origin): the text did not take the logo's column")
            XCTAssertLessThanOrEqual(made.window.frame.height, plain.window.frame.height + 0.5, "\(origin): it grew")
            XCTAssertLessThanOrEqual(body.frame.maxX, content.bounds.maxX, "\(origin): the text runs off the dialog")
            // Nothing that was in the alert went missing, and the buttons are where they were.
            XCTAssertEqual(made.buttons.map(\.title), plain.buttons.map(\.title))
            if let accessory = made.accessoryView {
                XCTAssertGreaterThanOrEqual(accessory.frame.minX, 0, "\(origin)")
                XCTAssertLessThanOrEqual(accessory.frame.maxX, content.bounds.maxX + 0.5, "\(origin): the command runs off the dialog")
            }
        }
    }

    /// An alert that is not built as expected (no icon view to be found) is left as it is, and says so.
    func testAnAlertItDoesNotKnowIsLeftAlone() {
        let strange = NSAlertWithNothing()
        XCTAssertFalse(AlertWithoutIcon.apply(to: strange))
        XCTAssertEqual(strange.window.contentView?.subviews.count, 0)
    }
}

/// An alert whose window has nothing in it, to stand for a macOS that builds alerts another way.
private final class NSAlertWithNothing: NSAlert {
    private let empty = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
    override var window: NSWindow { empty }
    override func layout() {}
}
