import Foundation
import ObjectiveC

/// What macOS's own charge limit and Optimized Battery Charging say right now.
///
/// Codable because Charge Control stores the state it found, as JSON in `Settings.chargeRestoreRecord` (the record
/// shared by every account, `ChargeRecordStore`, holds the same three fields), to put back when it is switched off.
/// The property names are that storage format.
public struct NativeChargeState: Equatable, Codable {
    /// Apple's manual charge limit (MCL) is on.
    public var mclEnabled: Bool
    /// The limit it holds, in percent. Only meaningful while `mclEnabled`: with none set the OS read 100 (plan 0 baseline).
    public var mclLimit: Int
    /// Optimized Battery Charging is on.
    public var optimizedChargingEnabled: Bool

    public init(mclEnabled: Bool, mclLimit: Int, optimizedChargingEnabled: Bool) {
        self.mclEnabled = mclEnabled
        self.mclLimit = mclLimit
        self.optimizedChargingEnabled = optimizedChargingEnabled
    }
}

/// The app-side half of Charge Control's route to the OS limit. A protocol so the controller's
/// tests can script it: the real client changes the real Mac's charge limit.
///
/// What macOS does with these calls, measured on Mac17,9, macOS 27.0, on 2026-11-13 with unprivileged calls on
/// `PowerUISmartChargeClient`, each read back from the client and from `pmset -g battlimit`:
///   (a) `enableMCL` does not merely turn the limit switch on: it sets the limit to 80 every time (set 95, enable: 80;
///       set 90, enable: 80);
///   (b) `setMCLLimit(n)` with n below 100 turns the switch on by itself (from "off, 100" a set of 90 gave "on, 90"),
///       and `setMCLLimit(100)` turns it off;
///   (c) `disableMCL` gives "off, 100";
///   (d) a limit written through the root helper's preference write is stored by macOS at once (the client reads it
///       back) but, while the battery is charging, is enforced only when the battery level next changes (31 s in one
///       run); when the battery is not charging it is enforced within a second; when the charger is cut it is enforced
///       on reconnect.
/// So the switch is turned on by setting a limit, and this protocol has no way to enable it: enabling would set 80.
/// It can be turned off, which gives "off, 100".
public protocol ChargeLimitClient: AnyObject {
    /// nil when the OS refuses a read; callers treat that as "charge control unavailable".
    func read() -> NativeChargeState?
    /// Only for `NativeChargeLimit.clientValues`. Any other value returns false without asking the OS. A value below
    /// 100 turns the limit's switch on, and 100 turns it off (b).
    func setLimit(_ percent: Int) -> Bool
    /// Turns the limit's switch off, which gives "off, 100" (c).
    func turnLimitOff() -> Bool
    /// Turns the limit's switch on, WHICH SETS THE LIMIT TO 80 (a). Never called on its own: only by
    /// `setLimitInForce`, which sets the wanted limit again straight after. False where the OS has no such call.
    func turnLimitOn() -> Bool
    func setOptimizedCharging(_ on: Bool) -> Bool
}

public extension ChargeLimitClient {
    /// Set `percent` and leave it in force: the one way a limit is set.
    ///
    /// On the Mac this was measured on (Mac17,9, macOS 27.0) setting a limit below 100 turns the switch on by itself
    /// (b), and nothing more happens here. Charge Control also runs on macOS 26.4 and later, where that was not
    /// measured: if the switch reads off after the set, it is turned on (which makes the limit 80) and the limit is set
    /// again, so the limit ends on and at `percent` either way. Without this a limit could be stored and not in force
    /// while Charge Control says it is held.
    func setLimitInForce(_ percent: Int) -> Bool {
        guard setLimit(percent) else { return false }
        guard percent < 100, let after = read(), !after.mclEnabled else { return true }
        guard turnLimitOn(), setLimit(percent) else { return false }
        return read()?.mclEnabled ?? true
    }
}

public enum NativeChargeLimit {
    /// The only limits the client API takes. Measured on Mac17,9 (macOS 27):
    /// `availableChargeLimitsWithError` reads (80, 85, 90, 95, 100), `setMCLLimit:85` succeeds and
    /// `setMCLLimit:45` fails with PowerUISmartChargingErrorDomain code 4. Anything else needs the
    /// root helper's preference write (plan 0 results, Task 6).
    public static let clientValues: [Int] = [80, 85, 90, 95, 100]

    public static func isClientSettable(_ p: Int) -> Bool { clientValues.contains(p) }
}

/// Apple's `PowerUISmartChargeClient`: the unprivileged route to the OS charge limit.
///
/// This is a PRIVATE API, found and measured on a Mac17,9 with macOS 27.0 (probes in docs/superpowers/spikes/
/// 2026-11-11-charge-control/; what the calls do to the limit and its switch is in `ChargeLimitClient`). `enableMCL`
/// is not bound at all: it sets the limit to 80, and nothing here needs it. An unprivileged, ad-hoc signed probe read the limit and set 85
/// through it, and the limit stayed in force after the probe exited: macOS keeps it in its own
/// preferences, so it outlives the process that set it. That is why Charge Control puts macOS's own settings back
/// when Anode quits, and why the launch after a crash lifts the limit before anything else.
///
/// IMPLEMENTATION NOTE: the methods are called through their IMPs, cast to C function types, the
/// way the probes did. Before a cast the method's runtime type encoding must equal the one
/// measured: a signature that changed in a later macOS would otherwise be called with the wrong
/// arguments, and one of these calls changes the charge limit. A framework, class, selector or
/// encoding that is not exactly what was measured makes `make()` return nil, and says which step failed
/// (`lastFailure`). Charge Control then reads as unavailable; it never crashes.
///
/// The `NSError **` argument is a raw pointer slot on purpose. The OS stores an autoreleased error
/// there; a Swift `NSError?` variable would release that error again and over-release it.
/// Nothing reads the error object, only whether one was set.
public final class PowerUIChargeClient: ChargeLimitClient {

    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    private static let className = "PowerUISmartChargeClient"
    /// What this app calls itself when it opens the client.
    private static let clientName = "dev.anode.app"

    private typealias ErrorSlot = UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private typealias InitWithName = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
    private typealias GetUInt8 = @convention(c) (AnyObject, Selector, ErrorSlot) -> UInt8
    private typealias GetUInt64 = @convention(c) (AnyObject, Selector, ErrorSlot) -> UInt64
    private typealias SetUInt8 = @convention(c) (AnyObject, Selector, UInt8, ErrorSlot) -> Bool
    private typealias Action = @convention(c) (AnyObject, Selector, ErrorSlot) -> Bool

    private struct Call<Fn> {
        let selector: Selector
        let function: Fn
    }

    private let object: AnyObject
    private let getLimit: Call<GetUInt8>
    private let isLimitEnabled: Call<GetUInt64>
    private let setLimitValue: Call<SetUInt8>
    private let disableLimit: Call<Action>
    private let enableLimit: Call<Action>?
    private let isOptimizedEnabled: Call<GetUInt64>
    private let enableOptimized: Call<Action>
    private let disableOptimized: Call<Action>

    /// Which step of opening the client failed, in a sentence for the charge log. Nothing in it is shown to the
    /// person: the section says only whether the Mac is too old (`ChargeController.unavailableText`) or not.
    public struct OpenFailure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Why the last `make()` returned nil; nil after one that worked. Read by whoever has to say why Charge Control is
    /// unavailable (it is not an old macOS every time).
    public static var lastFailure: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return recordedFailure
    }
    private static let failureLock = NSLock()
    private static var recordedFailure: String?

    /// The real client, or nil, with the reason in `lastFailure`.
    public static func make() -> PowerUIChargeClient? {
        let result = open()
        failureLock.lock()
        defer { failureLock.unlock() }
        switch result {
        case .success(let client):
            recordedFailure = nil
            return client
        case .failure(let why):
            recordedFailure = why.description
            return nil
        }
    }

    /// `frameworkPath` and `className` are parameters for the tests, which point them at things that are not there (or
    /// at a class whose methods differ) to see each step report itself; nothing else passes them.
    static func open(frameworkPath: String = PowerUIChargeClient.frameworkPath,
                     className: String = PowerUIChargeClient.className) -> Result<PowerUIChargeClient, OpenFailure> {
        func fail<T>(_ why: String) -> Result<T, OpenFailure> { .failure(OpenFailure(description: why)) }
        guard dlopen(frameworkPath, RTLD_NOW) != nil else { return fail("the framework \(frameworkPath) did not load") }
        guard let cls = NSClassFromString(className) as? NSObject.Type else {
            return fail("the class \(className) is not there")
        }
        // A selector is bound only when it is there and its encoding is exactly the measured one.
        func bind<Fn>(_ name: String, _ encoding: String, _ type: Fn.Type) -> Result<Call<Fn>, OpenFailure> {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cls, selector) else {
                return fail("the method \(name) is not there")
            }
            guard let found = method_getTypeEncoding(method), String(cString: found) == encoding else {
                let was = method_getTypeEncoding(method).map { String(cString: $0) } ?? "none"
                return fail("the method \(name) takes a different signature than the one measured (\(was), "
                            + "expected \(encoding))")
            }
            let function = unsafeBitCast(method_getImplementation(method), to: type)
            return .success(Call(selector: selector, function: function))
        }
        var failure: OpenFailure?
        func get<Fn>(_ result: Result<Call<Fn>, OpenFailure>) -> Call<Fn>? {
            switch result {
            case .success(let call): return call
            case .failure(let why):
                failure = failure ?? why
                return nil
            }
        }
        // Each step stops the chain at the first that fails, which is the one reported.
        guard let initWithName = get(bind("initWithClientName:", "@24@0:8@16", InitWithName.self)),
              let getLimit = get(bind("getMCLLimitWithError:", "C24@0:8^@16", GetUInt8.self)),
              let isLimitEnabled = get(bind("isMCLCurrentlyEnabled:", "Q24@0:8^@16", GetUInt64.self)),
              let setLimitValue = get(bind("setMCLLimit:error:", "B28@0:8C16^@20", SetUInt8.self)),
              let disableLimit = get(bind("disableMCL:", "B24@0:8^@16", Action.self)),
              let isOptimizedEnabled = get(bind("isSmartChargingCurrentlyEnabled:", "Q24@0:8^@16", GetUInt64.self)),
              let enableOptimized = get(bind("enableSmartCharging:", "B24@0:8^@16", Action.self)),
              let disableOptimized = get(bind("disableSmartCharging:", "B24@0:8^@16", Action.self))
        else { return .failure(failure ?? OpenFailure(description: "a method of \(className) did not bind")) }
        // +alloc hands back an owned object and -init passes that ownership on, so the
        // result is adopted as retained.
        guard let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let made = initWithName.function(allocated, initWithName.selector, Self.clientName as NSString)?
                  .takeRetainedValue()
        else { return fail("the class \(className) could not make a client") }
        return .success(PowerUIChargeClient(object: made, getLimit: getLimit, isLimitEnabled: isLimitEnabled,
                                            setLimitValue: setLimitValue, disableLimit: disableLimit,
                                            // Optional: only `setLimitInForce` uses it, on an OS where setting a limit
                                            // leaves the switch off. A client without it still opens.
                                            enableLimit: get(bind("enableMCL:", "B24@0:8^@16", Action.self)),
                                            isOptimizedEnabled: isOptimizedEnabled,
                                            enableOptimized: enableOptimized, disableOptimized: disableOptimized))
    }

    private init(object: AnyObject, getLimit: Call<GetUInt8>, isLimitEnabled: Call<GetUInt64>,
                 setLimitValue: Call<SetUInt8>, disableLimit: Call<Action>, enableLimit: Call<Action>?,
                 isOptimizedEnabled: Call<GetUInt64>, enableOptimized: Call<Action>, disableOptimized: Call<Action>) {
        self.object = object
        self.getLimit = getLimit
        self.isLimitEnabled = isLimitEnabled
        self.setLimitValue = setLimitValue
        self.disableLimit = disableLimit
        self.enableLimit = enableLimit
        self.isOptimizedEnabled = isOptimizedEnabled
        self.enableOptimized = enableOptimized
        self.disableOptimized = disableOptimized
    }

    public func read() -> NativeChargeState? {
        var error: UnsafeMutableRawPointer?
        let limit = getLimit.function(object, getLimit.selector, &error)
        guard error == nil else { return nil }
        let limitOn = isLimitEnabled.function(object, isLimitEnabled.selector, &error)
        guard error == nil else { return nil }
        let optimizedOn = isOptimizedEnabled.function(object, isOptimizedEnabled.selector, &error)
        guard error == nil else { return nil }
        return NativeChargeState(mclEnabled: limitOn != 0, mclLimit: Int(limit), optimizedChargingEnabled: optimizedOn != 0)
    }

    public func setLimit(_ percent: Int) -> Bool {
        // Checked first so a value Apple would refuse (code 4) never reaches the OS.
        guard NativeChargeLimit.isClientSettable(percent) else { return false }
        var error: UnsafeMutableRawPointer?
        return setLimitValue.function(object, setLimitValue.selector, UInt8(percent), &error)
    }

    public func turnLimitOff() -> Bool { run(disableLimit) }

    public func turnLimitOn() -> Bool { enableLimit.map(run) ?? false }

    public func setOptimizedCharging(_ on: Bool) -> Bool { run(on ? enableOptimized : disableOptimized) }

    private func run(_ call: Call<Action>) -> Bool {
        var error: UnsafeMutableRawPointer?
        return call.function(object, call.selector, &error)
    }
}
