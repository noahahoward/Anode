import XCTest
@testable import PowerKit

/// The values macOS's own charge limit accepts from a client, and the contract the rest of
/// Charge Control codes against.
///
/// Nothing here may call a PowerUI setter: a setter changes the real Mac's charge limit.
final class NativeChargeLimitTests: XCTestCase {

    func testClientValuesAreAppleSet() {
        // Measured on Mac17,9 (macOS 27): availableChargeLimitsWithError is (80, 85, 90, 95, 100),
        // setMCLLimit:85 succeeds and setMCLLimit:45 fails with PowerUISmartChargingErrorDomain code 4.
        XCTAssertEqual(NativeChargeLimit.clientValues, [80, 85, 90, 95, 100])
    }

    func testIsClientSettable() {
        XCTAssertTrue(NativeChargeLimit.isClientSettable(80))
        XCTAssertTrue(NativeChargeLimit.isClientSettable(95))
        XCTAssertFalse(NativeChargeLimit.isClientSettable(79))
        XCTAssertFalse(NativeChargeLimit.isClientSettable(81))
        XCTAssertFalse(NativeChargeLimit.isClientSettable(63))
        XCTAssertFalse(NativeChargeLimit.isClientSettable(101))
    }

    /// Constructing the client only loads the framework and creates the object. Nil (no framework,
    /// class or matching selector on this macOS) is as acceptable as non-nil; a crash is not.
    func testRealClientInitNeverCrashes() {
        _ = PowerUIChargeClient.make()
    }

    /// Which step failed is said, so that "unavailable" is not taken for "an old macOS" every time.
    func testOpenSaysWhichStepFailed() {
        func why(_ r: Result<PowerUIChargeClient, PowerUIChargeClient.OpenFailure>) -> String? {
            if case .failure(let f) = r { return f.description }
            return nil
        }
        let loadable = "/usr/lib/libSystem.B.dylib"
        XCTAssertTrue(why(PowerUIChargeClient.open(frameworkPath: "/nonexistent/PowerUI"))?
            .contains("did not load") == true)
        XCTAssertTrue(why(PowerUIChargeClient.open(frameworkPath: loadable, className: "NoSuchPowerUIClass"))?
            .contains("class NoSuchPowerUIClass is not there") == true)
        // A class that is there and has none of the methods.
        XCTAssertTrue(why(PowerUIChargeClient.open(frameworkPath: loadable, className: "NSObject"))?
            .contains("the method initWithClientName: is not there") == true)
        // A class with the first method and the wrong signature for the next: never bound, since one of these changes
        // the charge limit and a call with the wrong arguments must not be made.
        let found = why(PowerUIChargeClient.open(frameworkPath: loadable, className: "AnodeTestPowerUILookalike"))
        XCTAssertTrue(found?.contains("takes a different signature than the one measured") == true, found ?? "opened")
    }

    /// `make()` keeps the reason for the last nil, and forgets it after a client.
    func testMakeKeepsTheReasonForTheLastNil() {
        let client = PowerUIChargeClient.make()
        XCTAssertEqual(client == nil, PowerUIChargeClient.lastFailure != nil,
                       "a reason without a failure, or a failure without one")
    }

    /// The fake is what the controller's tests stand on, so it is pinned to what was measured (see its comment).
    func testFakeBehavesAsMeasured() {
        let client = FakeChargeLimitClient(state: NativeChargeState(mclEnabled: false, mclLimit: 100,
                                                                    optimizedChargingEnabled: true))
        XCTAssertTrue(client.setLimit(90))
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true),
                       "a limit below 100 did not turn the switch on")
        XCTAssertTrue(client.setLimit(100))
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true),
                       "a limit of 100 did not turn the switch off")
        XCTAssertTrue(client.setLimit(85))
        XCTAssertTrue(client.turnLimitOff())
        XCTAssertEqual(client.state, NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true),
                       "turning off did not give off, 100")
        XCTAssertEqual(client.history.count, 4)
        client.succeeds = false
        let before = client.state
        XCTAssertFalse(client.setLimit(90))
        XCTAssertFalse(client.turnLimitOff())
        XCTAssertEqual(client.state, before, "a refusal changed something")
    }

    /// Later tests rely on the fake having the real client's gate, so a controller that asks for 63 sees
    /// a refusal and no recorded call, as it would from macOS.
    func testFakeRefusesValuesTheRealClientRefuses() {
        let client = FakeChargeLimitClient()
        XCTAssertFalse(client.setLimit(63))
        XCTAssertTrue(client.limitCalls.isEmpty)
        XCTAssertTrue(client.setLimit(85))
        XCTAssertEqual(client.limitCalls, [85])
        XCTAssertEqual(client.read()?.mclLimit, 85)
    }
}

/// A scripted stand-in for the PowerUI client, so the controller's tests never touch the real
/// charge limit. It refuses what the real client refuses, without recording the call, and it behaves as the real one
/// was measured on Mac17,9, macOS 27.0, 2026-11-13 (unprivileged calls, each read back from the client and from
/// `pmset -g battlimit`):
///   * enabling the limit does not leave the limit alone: it sets it to 80 every time (95 then enable gave 80, and so
///     did 90 then enable), which is why nothing enables it except `setLimitInForce`, on an OS where a set leaves the switch off;
///   * `setLimit(n)` with n below 100 turns the switch on by itself (off, 100 then set 90 gave on, 90), and
///     `setLimit(100)` turns it off;
///   * disabling gives off, 100.
/// Whatever Charge Control wants of the switch, it gets by setting the limit.
public final class FakeChargeLimitClient: ChargeLimitClient {
    public var state: NativeChargeState?
    /// What every setter returns while true; flip it to make the OS "refuse". A refusal changes nothing.
    public var succeeds = true

    public private(set) var limitCalls: [Int] = []
    /// How many times the switch was asked to turn off. (The client has no way to turn it on: that is `enableMCL`,
    /// which sets the limit to 80; the limit goes in by being set.)
    public private(set) var turnOffCalls = 0
    /// How many times the switch was turned on by itself (`turnLimitOn`, which sets the limit to 80). Zero on the OS
    /// that was measured, where a set turns it on; only `setLimitInForce` calls it, and only when it does not.
    public private(set) var turnOnCalls = 0
    /// False models an OS where setting a limit below 100 leaves the switch as it was (not seen; macOS 27.0 turns it
    /// on). Charge Control has to end "on, n" there too.
    public var setTurnsTheSwitchOn = true
    public private(set) var optimizedChargingCalls: [Bool] = []
    /// The state after every setter that changed it, in order: what macOS held on the way, not only where it ended.
    public private(set) var history: [NativeChargeState] = []

    public init(state: NativeChargeState? = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true)) {
        self.state = state
    }

    public func read() -> NativeChargeState? { state }

    public func setLimit(_ percent: Int) -> Bool {
        guard NativeChargeLimit.isClientSettable(percent) else { return false }
        limitCalls.append(percent)
        guard succeeds else { return false }
        state?.mclLimit = percent
        if percent >= NativeChargeLimit.clientValues.last! {
            state?.mclEnabled = false
        } else if setTurnsTheSwitchOn {
            state?.mclEnabled = true
        }
        remember()
        return true
    }

    public func turnLimitOn() -> Bool {
        turnOnCalls += 1
        guard succeeds else { return false }
        state?.mclEnabled = true
        state?.mclLimit = 80
        remember()
        return true
    }

    public func turnLimitOff() -> Bool {
        turnOffCalls += 1
        guard succeeds else { return false }
        state?.mclEnabled = false
        state?.mclLimit = 100
        remember()
        return true
    }

    public func setOptimizedCharging(_ on: Bool) -> Bool {
        optimizedChargingCalls.append(on)
        guard succeeds else { return false }
        state?.optimizedChargingEnabled = on
        return true
    }

    private func remember() {
        if let state { history.append(state) }
    }
}

/// A class with a method of the real client's name and another signature, to see a changed signature refused.
@objc(AnodeTestPowerUILookalike)
final class PowerUILookalike: NSObject {
    @objc(initWithClientName:)
    init(clientName: NSString) { super.init() }
    @objc(getMCLLimitWithError:)
    func getLimit(_ error: UnsafeMutableRawPointer?) -> Int { 0 }
}
