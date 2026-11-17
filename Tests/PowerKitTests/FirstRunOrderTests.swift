import XCTest

/// The order of a fresh install's first launch, read from the source like the other first-run rules: the welcome goes first, a quit
/// that dismissed it leaves it owed, and nothing else is asked while it is.
final class FirstRunOrderTests: XCTestCase {

    private var main: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        }
    }

    func testLaunchOffersTheWelcomeNotTheUpdateQuestionDirectly() throws {
        let text = try main
        let show = try XCTUnwrap(text.range(of: "            main.show()\n"))
        let after = String(text[show.upperBound...].prefix(400))
        XCTAssertTrue(after.contains("offerWelcome()"), after)
        XCTAssertFalse(after.contains("offerAutoUpdate()"), "the update question goes after the welcome, not instead of it")
    }

    func testTheWelcomeIsOnlyMarkedSeenWhenItWasAnswered() throws {
        let text = try main
        let sheet = try XCTUnwrap(text.range(of: "notice.beginSheetModal(for: self.main.window) { answer in"))
        let seen = try XCTUnwrap(text.range(of: "Settings.shared.welcomeSeen = true", range: sheet.upperBound..<text.endIndex))
        let between = String(text[sheet.upperBound..<seen.lowerBound])
        XCTAssertTrue(between.contains("guard answer == .alertFirstButtonReturn else { return }"), between)
    }

    func testTheUpdateQuestionAndTheHelperFollowTheWelcome() throws {
        let text = try main
        let seen = try XCTUnwrap(text.range(of: "Settings.shared.welcomeSeen = true"))
        let after = String(text[seen.upperBound...].prefix(400))
        XCTAssertTrue(after.contains("self.offerAutoUpdate()"), after)
        XCTAssertTrue(after.contains("self.helperOffer.runAfterLaunch"), after)
    }

    func testTheHelpersOfferWaitsWhileTheWelcomeIsOwed() throws {
        let text = try main
        let offer = try XCTUnwrap(text.range(of: "private lazy var helperOffer = HelperOfferAtLaunch.live"))
        let body = String(text[offer.upperBound...].prefix(700))
        XCTAssertTrue(body.contains("self.welcomeIsOwed"), body)
    }
}
