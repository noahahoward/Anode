import Foundation
@testable import PowerKit
import XCTest

/// Throwaway settings for a test: a store in memory (`VolatileDefaults`), never a `UserDefaults` suite.
///
/// A suite is a file in the preferences folder of whoever runs the tests, written by the preferences service some
/// seconds after the test has moved on, and every way of removing it afterwards left some behind. MEASURED: 2468 files
/// named `com.anode.tests.<UUID>.plist` in the real `~/Library/Preferences` when each test made a suite of its own
/// name; then, with fixed names, a teardown that unlinked the file and a sweep at the end of the process, still 508 of
/// them after an afternoon of runs. So nothing is written: the tests further down hold that to the file system.
enum TestDefaults {

    /// A clean store, named for its owner and its test. The name is stable per TEST, not per class: `swift test
    /// --parallel` puts the tests of one class in separate processes, and within one process an earlier test of the
    /// same name must not seed this one, so it is emptied on the way in. `test` defaults to the caller's function,
    /// which is the test itself when called from one; a `setUp` passes the case's `name`.
    static func make(owner: String, test: String = #function,
                     file: StaticString = #filePath, line: UInt = #line)
        throws -> (defaults: UserDefaults, name: String) {
        let name = "com.anode.tests.\(owner).\(suffix(test))"
        // In memory (`VolatileDefaults`): a suite is a file in the preferences folder of whoever runs the tests, and
        // every way of removing it afterwards left some behind. Emptied on the way in, as the suite was: an earlier
        // test of the same name in this process must not seed this one.
        let defaults = VolatileDefaults.named(name)
        defaults.removeAll()
        return (defaults, name)
    }

    /// A store of exactly this name (it has to be under `com.anode.tests.`), emptied.
    static func named(_ name: String) -> UserDefaults {
        precondition(name.hasPrefix("com.anode.tests."), "a throwaway store is named under com.anode.tests.")
        let defaults = VolatileDefaults.named(name)
        defaults.removeAll()
        return defaults
    }

    /// A store of its own for a test that needs one more than `make` gives, or a name per call (a `UUID` in it).
    /// `UserDefaults(suiteName: "x-\(UUID())")` left one file in the preferences folder per call, thousands of them.
    static func throwaway(_ owner: String) -> UserDefaults {
        VolatileDefaults(name: "com.anode.tests.adhoc.\(owner).\(UUID().uuidString)")
    }

    /// "-[PowerKitTests.StartupSettingsTests testX]" or "testX()" -> "testX".
    static func suffix(_ test: String) -> String {
        let method = test.split(separator: " ").last.map(String.init) ?? test
        return String(method.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// Empty it and forget it. (Nothing was ever written to disk for it. A real suite handed in by a test that makes
    /// its own is cleared and its file unlinked, as before.)
    static func destroy(_ defaults: UserDefaults, _ name: String) {
        if defaults is VolatileDefaults {
            VolatileDefaults.forget(name)
            return
        }
        defaults.removePersistentDomain(forName: name)
        // Let cfprefsd act on the removal before the file is taken out from under
        // it, or it can write the domain back out afterwards.
        defaults.synchronize()
        for url in plistURLs(named: name) { try? FileManager.default.removeItem(at: url) }
    }

    /// Where a suite's file can land. `~/Library/Preferences` is the usual one;
    /// sandboxed and per-host variants are checked too so a stray copy is not left
    /// somewhere this does not look.
    static func plistURLs(named name: String) -> [URL] {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return [] }
        let prefs = library.appendingPathComponent("Preferences")
        var out = [prefs.appendingPathComponent("\(name).plist")]
        if let byHost = try? fm.contentsOfDirectory(
            at: prefs.appendingPathComponent("ByHost"),
            includingPropertiesForKeys: nil) {
            out += byHost.filter { $0.lastPathComponent.hasPrefix(name) }
        }
        return out.filter { fm.fileExists(atPath: $0.path) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// A throwaway store writes nothing.
///
/// Worth its own test because every earlier version LOOKED correct (it called the method whose name says it removes
/// the domain, then it unlinked the file, then it swept at exit) and each left files behind. Asserting on the
/// filesystem is the only version of this claim that means anything.
final class TestDefaultsTests: XCTestCase {

    func testAThrowawayStoreWritesNoFile() throws {
        let before = TestDefaults.strayDomainCount()
        let (defaults, name) = try TestDefaults.make(owner: "SelfCheck")
        defaults.set(true, forKey: "somethingWasWritten")
        defaults.synchronize()
        XCTAssertEqual(defaults.object(forKey: "somethingWasWritten") as? Bool, true, "the store does not hold what it is given")
        XCTAssertTrue(defaults is VolatileDefaults, "a throwaway store is a UserDefaults suite again")
        XCTAssertTrue(TestDefaults.plistURLs(named: name).isEmpty, "a file was written for a throwaway store")
        // The preferences service knows nothing of it either: a suite of that name, opened for real, is empty. (Opening
        // and reading a suite writes nothing.)
        XCTAssertFalse(TestDefaults.preferencesServiceHolds(name), "the values reached the preferences service")

        TestDefaults.destroy(defaults, name)
        XCTAssertNil(defaults.object(forKey: "somethingWasWritten"), "the values survived the teardown")
        XCTAssertTrue(TestDefaults.plistURLs(named: name).isEmpty)
        XCTAssertEqual(TestDefaults.strayDomainCount(), before, "the number of test files in the preferences folder moved")
    }

    /// One name is one store within a process, as two handles on one suite were, and it starts empty each time.
    func testTheSameNameIsTheSameStoreAndStartsEmpty() throws {
        let (first, name) = try TestDefaults.make(owner: "SelfCheckLoop")
        first.set(1, forKey: "x")
        XCTAssertEqual(VolatileDefaults.named(name).integer(forKey: "x"), 1)
        let (second, again) = try TestDefaults.make(owner: "SelfCheckLoop")
        XCTAssertEqual(again, name)
        XCTAssertNil(second.object(forKey: "x"), "an earlier test of the same name seeded this one")
        XCTAssertTrue(TestDefaults.plistURLs(named: name).isEmpty)
    }

    /// Each way a test can make one: none is a suite, and none writes.
    func testEveryWayOfMakingOneIsInMemory() throws {
        let made = [try TestDefaults.make(owner: "SelfCheckKinds").defaults,
                    TestDefaults.named("com.anode.tests.SelfCheckKinds.named"),
                    TestDefaults.throwaway("SelfCheckKinds")]
        for d in made {
            XCTAssertTrue(d is VolatileDefaults, "\(type(of: d))")
            d.set("x", forKey: "k")
            d.synchronize()
        }
        XCTAssertTrue(TestDefaults.plistURLs(named: "com.anode.tests.SelfCheckKinds.named").isEmpty)
    }
}

extension TestDefaults {
    /// Whether the preferences service holds anything under this name: a real suite of the name, opened and read
    /// (which writes nothing), has a value in it. A file an earlier run left under the same name is an empty domain,
    /// and counts as nothing. The one place outside `TestDefaults` a suite is opened by name, so it lives here.
    static func preferencesServiceHolds(_ name: String) -> Bool {
        !(UserDefaults(suiteName: name)?.persistentDomain(forName: name) ?? [:]).isEmpty
    }

    /// Takes out of the test tool's own defaults (the standard defaults of a test process) the entries whose key
    /// contains `fragment`: what AppKit wrote there for a test that used a name of its own. Nothing else is touched.
    static func removeFromTheTestToolsDefaults(keysContaining fragment: String) {
        let standard = UserDefaults.standard
        for key in standard.dictionaryRepresentation().keys where key.contains(fragment) {
            standard.removeObject(forKey: key)
        }
    }

    /// How many of this project's throwaway suites are currently on disk.
    static func strayDomainCount() -> Int {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first,
              let files = try? fm.contentsOfDirectory(
                at: library.appendingPathComponent("Preferences"),
                includingPropertiesForKeys: nil)
        else { return 0 }
        return files.filter { $0.lastPathComponent.hasPrefix("com.anode.tests.") }.count
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// No test writes to a domain a real machine uses.
///
/// Added after one did. A migration test seeded the live
/// `com.betterstats.settings` domain and cleared it in its teardown, which wiped
/// a working machine's preferences — and it did so hours after this very file was
/// written to stop test suites touching real preferences. Discipline did not
/// catch it; a test does.
final class NoProductionDomainsInTestsTests: XCTestCase {

    /// Every domain this suite is allowed to write to.
    ///
    /// The prefix is the contract: `TestDefaults.make` is the only way to get a
    /// suite, and everything it hands out is under `com.anode.tests.`. Anything
    /// else in Preferences with our name on it was written by a test that went
    /// around the helper.
    func testEveryDomainThisSuiteTouchesIsAThrowawayOne() throws {
        let (defaults, name) = try TestDefaults.make(owner: "ContractCheck")
        defer { TestDefaults.destroy(defaults, name) }
        XCTAssertTrue(name.hasPrefix("com.anode.tests."),
                      "the helper handed out a domain outside the test namespace")

        // And the names a real machine uses are NOT in that namespace, so the
        // check above is a real constraint rather than a tautology.
        for live in [Settings.suiteName, Settings.previousSuiteName] {
            XCTAssertFalse(live.hasPrefix("com.anode.tests."),
                           "\(live) is a domain a real machine keeps settings in")
        }
    }

    /// The source of a migration is injectable, which is what lets the test above
    /// be true. Without the seam the only way to test a migration is to seed the
    /// domain it migrates FROM — and that domain belongs to the user.
    func testTheMigrationSourceCanBePointedSomewhereHarmless() throws {
        let (source, sourceName) = try TestDefaults.make(owner: "ContractSource")
        defer { TestDefaults.destroy(source, sourceName) }
        source.set(3.0, forKey: "betterstats.sampleInterval")

        let (into, intoName) = try TestDefaults.make(owner: "ContractInto")
        defer { TestDefaults.destroy(into, intoName) }
        Settings.migrateFromPreviousName(into: into, from: sourceName)

        XCTAssertEqual(into.double(forKey: "anode.sampleInterval"), 3.0,
                       "the seam does not actually work, so tests will reach for the real one")
    }
}
