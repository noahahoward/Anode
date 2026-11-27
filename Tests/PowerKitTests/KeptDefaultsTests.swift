import XCTest
@testable import PowerKit

/// An update does not change what somebody had: the two settings 1.29.0 starts at new values.
final class KeptDefaultsTests: XCTestCase {

    private func with(_ test: (UserDefaults) -> Void) throws {
        let (defaults, suite) = try TestDefaults.make(owner: "KeptDefaults", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        test(defaults)
    }

    func testAnExistingInstallThatNeverChoseKeepsFifty() throws {
        try with { d in
            let s = Settings(defaults: d)
            s.keepEarlierDefaults(existingInstall: true)
            XCTAssertEqual(s.chargeReadyByHoldAtMost, 50)
            XCTAssertEqual(Settings(defaults: d).chargeReadyByHoldAtMost, 50, "and it is saved")
        }
    }

    func testASavedHoldLevelIsNeverTouched() throws {
        for chosen in [50, 65, 80, 90] {
            try with { d in
                let s = Settings(defaults: d)
                s.chargeReadyByHoldAtMost = chosen
                s.keepEarlierDefaults(existingInstall: true)
                XCTAssertEqual(s.chargeReadyByHoldAtMost, chosen)
            }
        }
    }

    func testANewInstallGetsTheNewValuesAndKeepsThemAtLaterLaunches() throws {
        try with { d in
            let s = Settings(defaults: d)
            s.keepEarlierDefaults(existingInstall: false)
            XCTAssertEqual(s.chargeReadyByHoldAtMost, 80)
            s.ultraLowPowerEnabled = true
            s.keepEarlierDefaults(existingInstall: true)   // the next launch, by when it is an install that has run
            XCTAssertEqual(s.chargeReadyByHoldAtMost, 80)
            XCTAssertEqual(s.ultraLowPowerBrightnessCap, 0.5)
        }
    }

    func testSomeoneWhoHadUltraLowPowerKeepsAQuarter() throws {
        for was in [true, false] {
            try with { d in
                let s = Settings(defaults: d)
                s.ultraLowPowerEnabled = true
                s.ultraLowPowerEnabled = was
                s.keepEarlierDefaults(existingInstall: true)
                XCTAssertEqual(s.ultraLowPowerBrightnessCap, 0.25)
            }
        }
    }

    func testSomeoneWhoNeverTouchedUltraLowPowerGetsTheNewCap() throws {
        try with { d in
            let s = Settings(defaults: d)
            s.keepEarlierDefaults(existingInstall: true)
            XCTAssertEqual(s.ultraLowPowerBrightnessCap, 0.5)
        }
    }

    func testASavedCapIsNeverTouched() throws {
        try with { d in
            let s = Settings(defaults: d)
            s.ultraLowPowerEnabled = true
            s.ultraLowPowerBrightnessCap = 0.4
            s.keepEarlierDefaults(existingInstall: true)
            XCTAssertEqual(s.ultraLowPowerBrightnessCap, 0.4, accuracy: 0.0001)
        }
    }

    func testTheAppDecidesBeforeItOpensTheHistory() throws {
        let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)
        let kept = try XCTUnwrap(source.range(of: "Settings.shared.keepEarlierDefaults(existingInstall: !welcomeIsOwed || HistoryStore.existsOnThisMac)"))
        let opened = try XCTUnwrap(source.range(of: "store = HistoryStore()"))
        XCTAssertLessThan(kept.lowerBound, opened.lowerBound, "opening the history makes the file that is the sign of an earlier run")
    }
}
