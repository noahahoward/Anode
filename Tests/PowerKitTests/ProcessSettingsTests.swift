import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Where `Settings.shared`, `Settings(defaults: nil)` and the command-line tool's reader point in a test run: at a
/// throwaway suite of the process's own, never at the person's. This is the source of the guarantee; the scan of the
/// tests' text (`NoSharedSettingsInTestsTests`) is a second line behind it.
final class ProcessSettingsTests: XCTestCase {

    /// The detection: XCTest's class is in the process. True here, and false for a process that has none.
    func testThisProcessIsATestRun() {
        XCTAssertTrue(Settings.isTestRun)
    }

    func testAProcessWithoutXCTestIsNotATestRun() {
        XCTAssertFalse(Settings.isTestRun(classNamed: { _ in nil }), "a process with no XCTest was taken for a test run")
        var asked: [String] = []
        XCTAssertTrue(Settings.isTestRun(classNamed: { asked.append($0); return NSObject.self }))
        XCTAssertEqual(asked, ["XCTestCase"], "the detection looks for XCTest's own class, by name, and nothing else")
    }

    /// The other half of "false for a plain process": none of the products that ship links XCTest, so its class is never
    /// in their processes. Read from the built products next to the test bundle when they are there.
    func testNoShippedProductLinksXCTest() throws {
        let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let otool = "/usr/bin/otool"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: otool), "no otool here")
        var checked: [String] = []
        for product in ["AnodeApp", "AnodeHelper", "anode"] {
            let url = build.appendingPathComponent(product)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: otool)
            process.arguments = ["-L", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let libraries = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(libraries.contains("XCTest"), "\(product) links XCTest:\n\(libraries)")
            XCTAssertFalse(libraries.isEmpty, "otool said nothing about \(product)")
            checked.append(product)
        }
        try XCTSkipIf(checked.isEmpty, "no product is built next to the tests")
    }

    func testSharedSettingsAreTheProcessesThrowawaySuiteAndNotThePersons() throws {
        let name = Settings.throwawayProcessSuiteName
        XCTAssertTrue(name.hasPrefix("com.anode.tests.process."))
        XCTAssertNotEqual(name, Settings.suiteName)
        XCTAssertNotEqual(name, Settings.previousSuiteName)
        let defaults = try XCTUnwrap(Settings.appDefaults(), "a test run has no settings to default to")
        let old = Settings.shared.sampleInterval
        defer { Settings.shared.sampleInterval = old }
        Settings.shared.sampleInterval = 7
        // A second handle on the nil suite reads it, and so does the one the command-line tool would be given.
        XCTAssertEqual(Settings(defaults: nil).sampleInterval, 7)
        XCTAssertEqual(Settings(defaults: defaults).sampleInterval, 7)
        XCTAssertNotNil(defaults.object(forKey: "anode.sampleInterval"), "the write did not land in the throwaway suite")
        // The default reader of the command-line tool is the same suite.
        let monitor = PowerMonitor.forCommandLine(scale: nil, effectiveUID: 501)
        XCTAssertNotNil(monitor)
    }

    /// Only the tests' own kind of suite is ever removed by name.
    func testOnlyThrowawaySuitesAreRemovedByName() {
        for real in [Settings.suiteName, Settings.previousSuiteName, "dev.anode.app", "dev.noah.anode", "com.apple.dock"] {
            XCTAssertFalse(Settings.isThrowawaySuiteName(real), "\(real) would be removed")
        }
        XCTAssertTrue(Settings.isThrowawaySuiteName(Settings.throwawayProcessSuiteName))
    }

    func testRemovingAThrowawaySuiteTakesItsFileToo() throws {
        let (defaults, name) = try TestDefaults.make(owner: "ProcessSettingsRemoval")
        defaults.set(true, forKey: "written")
        defaults.synchronize()
        XCTAssertFalse(TestDefaults.plistURLs(named: name).isEmpty, "nothing was written, so this proves nothing")
        Settings.removeThrowawaySuite(named: name)
        XCTAssertTrue(TestDefaults.plistURLs(named: name).isEmpty)
    }
}

/// A small test class whose tests make suites in each way a test can, and tidy none of them. It is run by hand by
/// `TestSuitesAreRemovedTests`; its methods do not begin with "test", so the run does not pick them up itself.
final class SuiteMakingProbe: XCTestCase {
    @objc func makesSuitesAndTidiesNone() throws {
        let (made, _) = try TestDefaults.make(owner: "LeakProbe")
        made.set(1, forKey: "x"); made.synchronize()
        let adHoc = TestDefaults.throwaway("LeakProbeAdHoc")
        adHoc.set(2, forKey: "y"); adHoc.synchronize()
        let (settingsDefaults, _) = try TestDefaults.make(owner: "LeakProbeSettings")
        Settings(defaults: settingsDefaults).sampleInterval = 3
        let named = TestDefaults.named("com.anode.tests.LeakProbe.named.\(UUID().uuidString)")
        named.set(3, forKey: "z"); named.synchronize()
    }
}

/// Every suite a test makes is gone when its test ends, with no teardown of the test's own.
final class TestSuitesAreRemovedTests: XCTestCase {

    func testASmallTestClassLeavesNoSuiteBehind() throws {
        let before = Set(TestSuiteRegistry.shared.allRegistered())
        let suite = XCTestSuite(name: "LeakProbe")
        suite.addTest(SuiteMakingProbe(selector: #selector(SuiteMakingProbe.makesSuitesAndTidiesNone)))
        suite.addTest(SuiteMakingProbe(selector: #selector(SuiteMakingProbe.makesSuitesAndTidiesNone)))
        suite.run()
        XCTAssertEqual(suite.testRun?.totalFailureCount, 0, "the probe itself failed")
        XCTAssertEqual(suite.testRun?.executionCount, 2, "the probe did not run")
        let made = Set(TestSuiteRegistry.shared.allRegistered()).subtracting(before)
        XCTAssertGreaterThanOrEqual(made.count, 6, "the probe's suites were not noted: \(made)")
        // As soon as its test ends, a suite holds nothing...
        for name in made {
            let values = UserDefaults(suiteName: name)?.persistentDomain(forName: name) ?? [:]
            XCTAssertTrue(values.isEmpty, "\(name) still held \(values.keys) when its test had ended")
        }
        // ...and once the preferences service has settled, as it does at the end of the process, its file is gone. (A file
        // that was in the folder before this run, under the same fixed name, is not this run's to remove.)
        Settings.sweepThrowawaySuiteFilesNow()
        for name in made where !TestSuiteRegistry.shared.wasThereBeforeThisRun(name) {
            XCTAssertTrue(TestDefaults.plistURLs(named: name).isEmpty, "\(name) left its file behind")
        }
    }
}
