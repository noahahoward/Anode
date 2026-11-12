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
        _ = PowerUIChargeClient()
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
/// charge limit. It refuses what the real client refuses, without recording the call.
public final class FakeChargeLimitClient: ChargeLimitClient {
    public var state: NativeChargeState?
    /// What every setter returns while true; flip it to make the OS "refuse".
    public var succeeds = true

    public private(set) var limitCalls: [Int] = []
    public private(set) var limitEnabledCalls: [Bool] = []
    public private(set) var optimizedChargingCalls: [Bool] = []

    public init(state: NativeChargeState? = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true)) {
        self.state = state
    }

    public func read() -> NativeChargeState? { state }

    public func setLimit(_ percent: Int) -> Bool {
        guard NativeChargeLimit.isClientSettable(percent) else { return false }
        limitCalls.append(percent)
        guard succeeds else { return false }
        state?.mclLimit = percent
        return true
    }

    public func setLimitEnabled(_ on: Bool) -> Bool {
        limitEnabledCalls.append(on)
        guard succeeds else { return false }
        state?.mclEnabled = on
        return true
    }

    public func setOptimizedCharging(_ on: Bool) -> Bool {
        optimizedChargingCalls.append(on)
        guard succeeds else { return false }
        state?.optimizedChargingEnabled = on
        return true
    }
}
