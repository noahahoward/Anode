import Foundation

/// Where Anode keeps its files, with one answer for a test run: nowhere of the person's.
public enum AnodeFiles {

    /// The person's Application Support folder, under which Anode keeps `Anode/` (its logs, its history, what it has
    /// learned). In a test run it is a folder of the test process's own under the temporary directory, removed when
    /// the process exits: a test that builds a part of the app without saying where its files go must not write
    /// lines into the person's logs, or make the folder on a Mac where Anode is not installed (both were seen).
    public static var applicationSupport: URL? {
        Settings.isTestRun ? testSupport
                           : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// The test run's stand-in. Made once, at the first use.
    static let testSupport: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.anode.tests.support.\(getpid()).\(UUID().uuidString)", isDirectory: true)
        // With Anode's own folder in it, as a Mac that has run Anode has: the logs are appended to, not made room for.
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("Anode", isDirectory: true),
                                                 withIntermediateDirectories: true)
        testSupportPath = url.path
        atexit { if let path = AnodeFiles.testSupportPath { try? FileManager.default.removeItem(atPath: path) } }
        return url
    }()

    /// For the exit handler, which can capture nothing.
    private static var testSupportPath: String?
}

/// Settings that live in memory and nowhere else: what a test run uses where the app uses a preferences domain.
///
/// A `UserDefaults` suite is a file in the person's preferences folder, written by the preferences service some
/// seconds after the process that made it has gone, so a suite made for a test was a file left behind: hundreds of
/// them after one run, however carefully each was removed (removing a domain makes the service write it out once
/// more). Nothing is left behind by what was never written. Everything that reads or writes goes through the
/// dictionary here, with the answers `UserDefaults` gives: a number read as a string, a string read as a number, a
/// missing key as nil, 0 or false. A change posts `UserDefaults.didChangeNotification`, as a real one does.
public final class VolatileDefaults: UserDefaults {

    private let lock = NSRecursiveLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    /// The name it was asked for under, which nothing is stored under: for the tests that pass a suite's name on.
    public let name: String

    public init(name: String) {
        self.name = name
        // The designated initialiser has to be called; nothing is ever read from or written to what it opens,
        // because every accessor is overridden below.
        super.init(suiteName: nil)!
    }

    // One store for one name within a process, as two handles on one suite were one store.
    private static let storesLock = NSLock()
    private static var stores: [String: VolatileDefaults] = [:]

    public static func named(_ name: String) -> VolatileDefaults {
        storesLock.lock(); defer { storesLock.unlock() }
        if let d = stores[name] { return d }
        let d = VolatileDefaults(name: name)
        stores[name] = d
        return d
    }

    /// The store of that name is emptied and forgotten.
    public static func forget(_ name: String) {
        storesLock.lock()
        let d = stores.removeValue(forKey: name)
        storesLock.unlock()
        d?.removeAll()
    }

    public func removeAll() {
        lock.lock()
        let had = !values.isEmpty
        values = [:]
        lock.unlock()
        if had { changed() }
    }

    private func changed() {
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    private func number(_ key: String) -> NSNumber? {
        switch object(forKey: key) {
        case let n as NSNumber: return n
        case let s as String: return Double(s).map { NSNumber(value: $0) }
        default: return nil
        }
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    public override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName] ?? registered[defaultName]
    }

    public override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    public override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }

    public override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    public override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }

    public override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    public override func integer(forKey defaultName: String) -> Int {
        if let s = object(forKey: defaultName) as? String { return (s as NSString).integerValue }
        return number(defaultName)?.intValue ?? 0
    }

    public override func float(forKey defaultName: String) -> Float { number(defaultName)?.floatValue ?? 0 }

    public override func double(forKey defaultName: String) -> Double { number(defaultName)?.doubleValue ?? 0 }

    public override func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let n as NSNumber: return n.boolValue
        case let s as String: return (s as NSString).boolValue
        default: return false
        }
    }

    public override func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let u as URL: return u
        case let s as String: return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        default: return nil
        }
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return registered.merging(values) { _, mine in mine }
    }

    public override func objectIsForced(forKey key: String) -> Bool { false }

    // ── Writing ─────────────────────────────────────────────────────────────

    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
        lock.unlock()
        changed()
    }

    public override func set(_ value: Int, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ value: Float, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ value: Double, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ value: Bool, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }

    public override func removeObject(forKey defaultName: String) {
        lock.lock()
        let had = values.removeValue(forKey: defaultName) != nil
        lock.unlock()
        if had { changed() }
    }

    public override func register(defaults registrationDictionary: [String: Any]) {
        lock.lock()
        registered.merge(registrationDictionary) { _, new in new }
        lock.unlock()
    }

    @discardableResult
    public override func synchronize() -> Bool { true }

    // ── Domains: there is one, this one, whatever name is given ─────────────

    public override func persistentDomain(forName domainName: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty ? nil : values
    }

    public override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        lock.lock()
        values = domain
        lock.unlock()
        changed()
    }

    public override func removePersistentDomain(forName domainName: String) { removeAll() }

    public override func addSuite(named suiteName: String) {}
    public override func removeSuite(named suiteName: String) {}
}
