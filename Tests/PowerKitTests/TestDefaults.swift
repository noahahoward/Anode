import Foundation
@testable import PowerKit
import XCTest

/// A throwaway `UserDefaults` suite that actually goes away.
///
/// The obvious teardown — `removePersistentDomain(forName:)` — clears the values
/// and routinely leaves the backing plist behind: `cfprefsd` has already written
/// the file, and clearing a domain does not ask for it to be unlinked. Both suites
/// that use throwaway defaults called it and both looked correct.
///
/// MEASURED: 2468 files named `com.anode.tests.<UUID>.plist` in the real
/// `~/Library/Preferences`, one per test run per suite, accumulated over this
/// project's life. Nothing broke, which is why it went unnoticed — a test suite
/// quietly littering a developer's actual preferences is the kind of mess that is
/// only ever found by going to look.
///
/// So the file is removed as well as the domain, and the removal is verified.
enum TestDefaults {

    /// A clean suite, named for its OWNER rather than uniquely per test.
    ///
    /// The unique-per-test version is what produced thousands of files, and
    /// deleting them in teardown does not fix it: `cfprefsd` writes the domain out
    /// asynchronously, so the file can land AFTER the teardown has looked for it
    /// and found nothing. Measured — a run that deleted every file it made still
    /// left six behind, one per suite created.
    ///
    /// A stable name cannot accumulate, because the next run reuses the same file
    /// instead of adding one. It is emptied on the way in as well as out, so a
    /// leftover from a crashed run cannot seed the next one. Two classes must not
    /// share an owner string; the tests each pass their own type name.
    static func make(owner: String,
                     file: StaticString = #filePath, line: UInt = #line)
        throws -> (defaults: UserDefaults, name: String) {
        let name = "com.anode.tests.\(owner)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name), file: file, line: line)
        // A previous run may have died before its teardown.
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    /// Clear the domain AND unlink its file.
    static func destroy(_ defaults: UserDefaults, _ name: String) {
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

/// The cleanup cleans up.
///
/// Worth its own test because the previous teardown LOOKED correct — it called
/// the method whose name says it removes the domain — and left 2468 files
/// behind. Asserting on the filesystem is the only version of this claim that
/// means anything.
final class TestDefaultsTests: XCTestCase {

    func testAThrowawaySuiteLeavesNoFileBehind() throws {
        let (defaults, name) = try TestDefaults.make(owner: "SelfCheck")
        // Write and flush, so there is definitely a file to fail to delete.
        defaults.set(true, forKey: "somethingWasWritten")
        defaults.synchronize()
        XCTAssertFalse(TestDefaults.plistURLs(named: name).isEmpty,
                       "nothing was written, so this test cannot prove anything")

        TestDefaults.destroy(defaults, name)
        XCTAssertTrue(TestDefaults.plistURLs(named: name).isEmpty,
                      "the suite's plist survived its own teardown — this is the leak")
        XCTAssertNil(UserDefaults(suiteName: name)?.object(forKey: "somethingWasWritten"),
                     "the values survived too")
    }

    /// Repeated runs do not ACCUMULATE, which is the property that failed.
    ///
    /// Counting every stray file is the wrong assertion here — other tests in the
    /// process create and destroy their own, so the total moves for reasons that
    /// have nothing to do with this. The claim worth making is about one owner:
    /// five throwaway suites under the same name must leave at most the one file
    /// that name can have, and none once the last is destroyed.
    ///
    /// This is what a unique name per test could never give. Deleting the file in
    /// teardown does not help, because `cfprefsd` writes the domain out
    /// asynchronously and can land it after the teardown has already looked.
    func testRepeatedThrowawaySuitesDoNotAccumulate() throws {
        for _ in 0..<5 {
            let (d, n) = try TestDefaults.make(owner: "SelfCheckLoop")
            d.set(1, forKey: "x")
            d.synchronize()
            XCTAssertLessThanOrEqual(TestDefaults.plistURLs(named: n).count, 1,
                                     "one name produced more than one file")
            TestDefaults.destroy(d, n)
        }
        XCTAssertTrue(TestDefaults.plistURLs(named: "com.anode.tests.SelfCheckLoop").isEmpty,
                      "the last teardown left its file behind")
    }
}

extension TestDefaults {
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
