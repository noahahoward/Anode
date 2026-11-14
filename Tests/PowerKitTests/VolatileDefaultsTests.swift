import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The store a test run keeps settings in: in memory, with the answers `UserDefaults` gives, and nothing on disk.
final class VolatileDefaultsTests: XCTestCase {

    private func store() -> VolatileDefaults { VolatileDefaults(name: "com.anode.tests.volatile.\(UUID().uuidString)") }

    func testAMissingKeyReadsAsUserDefaultsReadsIt() {
        let d = store()
        XCTAssertNil(d.object(forKey: "k"))
        XCTAssertNil(d.string(forKey: "k"))
        XCTAssertNil(d.array(forKey: "k"))
        XCTAssertNil(d.dictionary(forKey: "k"))
        XCTAssertNil(d.data(forKey: "k"))
        XCTAssertNil(d.stringArray(forKey: "k"))
        XCTAssertEqual(d.integer(forKey: "k"), 0)
        XCTAssertEqual(d.double(forKey: "k"), 0)
        XCTAssertEqual(d.float(forKey: "k"), 0)
        XCTAssertFalse(d.bool(forKey: "k"))
    }

    func testEachKindComesBackAsItWent() {
        let d = store()
        d.set(7, forKey: "int")
        d.set(2.5, forKey: "double")
        d.set(true, forKey: "bool")
        d.set("text", forKey: "string")
        d.set(Data([1, 2]), forKey: "data")
        d.set(["a", "b"], forKey: "strings")
        d.set(["k": 1], forKey: "dictionary")
        XCTAssertEqual(d.integer(forKey: "int"), 7)
        XCTAssertEqual(d.double(forKey: "double"), 2.5)
        XCTAssertTrue(d.bool(forKey: "bool"))
        XCTAssertEqual(d.string(forKey: "string"), "text")
        XCTAssertEqual(d.data(forKey: "data"), Data([1, 2]))
        XCTAssertEqual(d.stringArray(forKey: "strings") ?? [], ["a", "b"])
        XCTAssertEqual(d.dictionary(forKey: "dictionary")?["k"] as? Int, 1)
        XCTAssertEqual(d.object(forKey: "int") as? Int, 7)
        XCTAssertEqual(d.object(forKey: "bool") as? Bool, true)
    }

    /// A number asked for as a string, a string as a number: what `UserDefaults` does with a value of the other kind.
    func testAValueOfAnotherKindIsReadAsUserDefaultsReadsIt() {
        let d = store()
        d.set(41, forKey: "number")
        d.set("41", forKey: "digits")
        d.set("YES", forKey: "yes")
        d.set([1, 2], forKey: "numbers")
        XCTAssertEqual(d.string(forKey: "number"), "41")
        XCTAssertEqual(d.integer(forKey: "digits"), 41)
        XCTAssertEqual(d.double(forKey: "digits"), 41)
        XCTAssertTrue(d.bool(forKey: "yes"))
        XCTAssertTrue(d.bool(forKey: "number"))
        XCTAssertNil(d.stringArray(forKey: "numbers"), "an array that is not all strings is no string array")
        XCTAssertNil(d.string(forKey: "numbers"))
        XCTAssertEqual(d.integer(forKey: "numbers"), 0)
    }

    func testSettingNilAndRemovingBothTakeTheValueAway() {
        let d = store()
        d.set(1, forKey: "a")
        d.set(1, forKey: "b")
        d.set(nil, forKey: "a")
        d.removeObject(forKey: "b")
        XCTAssertNil(d.object(forKey: "a"))
        XCTAssertNil(d.object(forKey: "b"))
        XCTAssertNil(d.persistentDomain(forName: d.name), "an empty domain reads as none, as a real one does")
    }

    func testRegisteredDefaultsAnswerOnlyUntilAValueIsSet() {
        let d = store()
        d.register(defaults: ["k": 5])
        XCTAssertEqual(d.integer(forKey: "k"), 5)
        d.set(9, forKey: "k")
        XCTAssertEqual(d.integer(forKey: "k"), 9)
        d.removeObject(forKey: "k")
        XCTAssertEqual(d.integer(forKey: "k"), 5)
        XCTAssertNil(d.persistentDomain(forName: d.name), "a registered default is not a stored value")
    }

    func testTheDomainIsWhatWasStored() {
        let d = store()
        d.set(1, forKey: "a")
        d.set("x", forKey: "b")
        XCTAssertEqual(d.persistentDomain(forName: d.name)?.count, 2)
        XCTAssertEqual(d.dictionaryRepresentation().count, 2)
        d.setPersistentDomain(["c": 3], forName: d.name)
        XCTAssertNil(d.object(forKey: "a"))
        XCTAssertEqual(d.integer(forKey: "c"), 3)
        d.removePersistentDomain(forName: d.name)
        XCTAssertNil(d.object(forKey: "c"))
    }

    /// `Settings` hears a change made through another handle by this notification, as it does from a real suite.
    func testAChangePostsTheNotificationUserDefaultsPosts() {
        let d = store()
        var heard = 0
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: d,
                                                           queue: nil) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        d.set(1, forKey: "k")
        d.removeObject(forKey: "k")
        d.removeObject(forKey: "k")
        XCTAssertEqual(heard, 2, "one for the set and one for the removal; removing nothing changes nothing")
    }

    func testTwoSettingsOnOneStoreSeeEachOther() {
        let d = store()
        let a = Settings(defaults: d), b = Settings(defaults: d)
        var heard = 0
        let token = b.observe(Settings.Key.chargeLimit) { heard += 1 }
        a.chargeLimit = 63
        XCTAssertEqual(b.chargeLimit, 63)
        XCTAssertEqual(heard, 1, "a write through another Settings on the same store did not reach the observer")
        _ = token
    }

    /// The point of it: nothing is written, however it is used.
    func testNothingReachesThePreferencesFolderOrThePreferencesService() {
        let d = store()
        d.set(1, forKey: "a")
        d.set("x", forKey: "b")
        d.synchronize()
        d.removePersistentDomain(forName: d.name)
        d.set(2, forKey: "a")
        d.synchronize()
        XCTAssertTrue(TestDefaults.plistURLs(named: d.name).isEmpty, "a file was written")
        XCTAssertFalse(TestDefaults.preferencesServiceHolds(d.name))
    }

    func testOneNameIsOneStoreUntilItIsForgotten() {
        let name = "com.anode.tests.volatile.named.\(UUID().uuidString)"
        let first = VolatileDefaults.named(name)
        first.set(1, forKey: "k")
        XCTAssertTrue(VolatileDefaults.named(name) === first)
        VolatileDefaults.forget(name)
        XCTAssertNil(first.object(forKey: "k"), "forgetting did not empty it")
        XCTAssertFalse(VolatileDefaults.named(name) === first)
        VolatileDefaults.forget(name)
    }

    // ── Where Anode's files go in a test run ────────────────────────────────

    /// A test that builds a part of the app without saying where its files go wrote lines into the person's logs, and
    /// made Anode's folder on a Mac where Anode was not installed. In a test run the folder is the process's own.
    func testInATestRunAnodesSupportFolderIsNotThePersons() throws {
        let support = try XCTUnwrap(AnodeFiles.applicationSupport)
        XCTAssertEqual(support, AnodeFiles.testSupport)
        XCTAssertFalse(support.path.hasPrefix(NSHomeDirectory() + "/Library"), support.path)
        XCTAssertTrue(support.lastPathComponent.hasPrefix("com.anode.tests.support.\(getpid())."), support.path)
    }

    func testAFeatureLogLineGoesToTheTestRunsFolder() throws {
        let name = "volatile-test-\(UUID().uuidString).log"
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anode").appendingPathComponent(name)
        let mine = AnodeFiles.testSupport.appendingPathComponent("Anode").appendingPathComponent(name)
        FeatureLog.append(name, "a line from a test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path), "a test wrote into the person's Anode folder")
        XCTAssertTrue(try String(contentsOf: mine, encoding: .utf8).hasSuffix("a line from a test\n"))
        try FileManager.default.removeItem(at: mine)
    }

    /// The features' own logs, by the default each is built with.
    func testTheFeaturesDefaultLogsDoNotReachThePersonsFolder() throws {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anode/keepawake.log")
        func stamp() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: real.path))?[.modificationDate] as? Date
        }
        let before = stamp()
        let d = TestDefaults.throwaway("VolatileKeepAwake")
        let controller = KeepAwakeController(settings: Settings(defaults: d), defaults: d)
        controller.log("a line from a test")
        let mine = AnodeFiles.testSupport.appendingPathComponent("Anode/keepawake.log")
        XCTAssertTrue((try? String(contentsOf: mine, encoding: .utf8))?.contains("a line from a test") ?? false)
        XCTAssertEqual(stamp(), before, "the person's keepawake.log was written to")
    }

    /// Every place a file of Anode's is found goes through the one function: a new one that asks the system for the
    /// person's folder itself would be the leak again.
    func testNothingInTheSourcesAsksForThePersonsSupportFolderItself() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var asked: [String] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".applicationSupportDirectory"), url.lastPathComponent != "VolatileDefaults.swift" {
                asked.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(asked, [], "use AnodeFiles.applicationSupport")
    }
}
