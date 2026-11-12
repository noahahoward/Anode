import Foundation
import ObjectiveC

/// What macOS's own charge limit and Optimized Battery Charging say right now.
public struct NativeChargeState: Equatable {
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
public protocol ChargeLimitClient: AnyObject {
    /// nil when the OS refuses a read; callers treat that as "charge control unavailable".
    func read() -> NativeChargeState?
    /// Only for `NativeChargeLimit.clientValues`. Any other value returns false without asking the OS.
    func setLimit(_ percent: Int) -> Bool
    func setLimitEnabled(_ on: Bool) -> Bool
    func setOptimizedCharging(_ on: Bool) -> Bool
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
/// This is a PRIVATE API, found and measured in plan 0 (docs/superpowers/plans/
/// 2026-11-11-charge-control-plan-0-results.md; probes in docs/superpowers/spikes/
/// 2026-11-11-charge-control/). An unprivileged, ad-hoc signed probe read the limit and set 85
/// through it, and the limit stayed in force after the probe exited: macOS keeps it in its own
/// preferences, so it outlives Anode.
///
/// IMPLEMENTATION NOTE: the methods are called through their IMPs, cast to C function types, the
/// way the probes did. Before a cast the method's runtime type encoding must equal the one
/// measured: a signature that changed in a later macOS would otherwise be called with the wrong
/// arguments, and one of these calls changes the charge limit. A framework, class, selector or
/// encoding that is not exactly what was measured makes `init?` return nil. Charge Control then
/// reads as unavailable; it never crashes.
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
    private let enableLimit: Call<Action>
    private let disableLimit: Call<Action>
    private let isOptimizedEnabled: Call<GetUInt64>
    private let enableOptimized: Call<Action>
    private let disableOptimized: Call<Action>

    public init?() {
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString(Self.className) as? NSObject.Type,
              let initWithName = Self.bind(cls, "initWithClientName:", "@24@0:8@16", InitWithName.self),
              let getLimit = Self.bind(cls, "getMCLLimitWithError:", "C24@0:8^@16", GetUInt8.self),
              let isLimitEnabled = Self.bind(cls, "isMCLCurrentlyEnabled:", "Q24@0:8^@16", GetUInt64.self),
              let setLimitValue = Self.bind(cls, "setMCLLimit:error:", "B28@0:8C16^@20", SetUInt8.self),
              let enableLimit = Self.bind(cls, "enableMCL:", "B24@0:8^@16", Action.self),
              let disableLimit = Self.bind(cls, "disableMCL:", "B24@0:8^@16", Action.self),
              let isOptimizedEnabled = Self.bind(cls, "isSmartChargingCurrentlyEnabled:", "Q24@0:8^@16", GetUInt64.self),
              let enableOptimized = Self.bind(cls, "enableSmartCharging:", "B24@0:8^@16", Action.self),
              let disableOptimized = Self.bind(cls, "disableSmartCharging:", "B24@0:8^@16", Action.self),
              // +alloc hands back an owned object and -init passes that ownership on, so the
              // result is adopted as retained.
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let made = initWithName.function(allocated, initWithName.selector, Self.clientName as NSString)?.takeRetainedValue()
        else { return nil }
        self.object = made
        self.getLimit = getLimit
        self.isLimitEnabled = isLimitEnabled
        self.setLimitValue = setLimitValue
        self.enableLimit = enableLimit
        self.disableLimit = disableLimit
        self.isOptimizedEnabled = isOptimizedEnabled
        self.enableOptimized = enableOptimized
        self.disableOptimized = disableOptimized
    }

    private static func bind<Fn>(_ cls: AnyClass, _ name: String, _ encoding: String, _ type: Fn.Type) -> Call<Fn>? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector),
              let found = method_getTypeEncoding(method),
              String(cString: found) == encoding
        else { return nil }
        return Call(selector: selector, function: unsafeBitCast(method_getImplementation(method), to: type))
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

    public func setLimitEnabled(_ on: Bool) -> Bool { run(on ? enableLimit : disableLimit) }

    public func setOptimizedCharging(_ on: Bool) -> Bool { run(on ? enableOptimized : disableOptimized) }

    private func run(_ call: Call<Action>) -> Bool {
        var error: UnsafeMutableRawPointer?
        return call.function(object, call.selector, &error)
    }
}
