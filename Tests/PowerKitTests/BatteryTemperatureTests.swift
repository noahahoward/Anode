import XCTest
import IOKit
@testable import PowerKit

/// The pack temperature Charge Control's Heat Protection holds and resumes
/// charging on.
///
/// Two things can go wrong with it and both are silent. WHERE the gauge
/// publishes it depends on the model and the macOS version, so a reader that
/// knows one place parses every fixture and reads nothing on the real machine.
/// And the number is a raw gauge register, so a glitch arrives looking like a
/// temperature. A reading that is absent, or is not a temperature, has to come
/// out as nil, which `ChargePolicy` treats as neither hot nor cool.
final class BatteryTemperatureTests: XCTestCase {

    // ── One raw value ───────────────────────────────────────────────────────

    /// The registry's figure is centi-°C.
    func testTemperatureFromCentiDegrees() throws {
        let c = try XCTUnwrap(Battery.temperatureC(fromRaw: 3012))
        XCTAssertEqual(c, 30.12, accuracy: 0.001)
        // As IOKit hands it over, and the value this Mac read.
        let live = try XCTUnwrap(Battery.temperatureC(fromRaw: NSNumber(value: 3109)))
        XCTAssertEqual(live, 31.09, accuracy: 0.001)
    }

    func testMissingTemperatureIsNil() {
        XCTAssertNil(Battery.temperatureC(fromRaw: nil))
        XCTAssertNil(Battery.temperatureC(fromProperties: [:]))
        XCTAssertNil(Battery.temperatureC(fromProperties: ["BatteryData": ["DesignCapacity": 6249]]))
        // Every fixture written before the field existed describes a battery
        // without restating it, and has no reading.
        let s = Battery.State(percent: 52, isCharging: false, onAC: false, cycleCount: 82,
                              voltage_mV: 11610, amperage_mA: -1334,
                              remainingCapacity_mAh: 3075, timeRemaining_min: 187)
        XCTAssertNil(s.temperature_C)
    }

    /// Only a number is a reading. The booleans are here because a registry
    /// boolean bridges to a number, and `true` would read as 0.01 °C: a pack
    /// cold enough to end a heat pause.
    func testNonNumericTemperatureIsNil() {
        let notNumbers: [Any] = ["3012", Data([0x0b, 0xc4]), [3012], ["Temperature": 3012],
                                 true, false, NSNull()]
        for raw in notNumbers {
            XCTAssertNil(Battery.temperatureC(fromRaw: raw), "\(raw)")
        }
        XCTAssertNil(Battery.temperatureC(fromProperties: ["Temperature": "3012"]))
    }

    /// A glitched register must neither trip Heat Protection nor defeat it.
    /// 65535 is the SBS "unknown" that `Battery.state()` already filters out of
    /// `TimeRemaining`; as centi-°C it is 655.35 °C.
    func testImplausibleTemperatureIsNil() {
        let glitches: [Any] = [65535, 10001, -2001, 30_000, -27315,
                               Double.nan, Double.infinity, -Double.infinity]
        for raw in glitches {
            XCTAssertNil(Battery.temperatureC(fromRaw: raw), "\(raw)")
        }
        XCTAssertNil(Battery.temperatureC(fromProperties: ["Temperature": 65535]))
        XCTAssertNil(Battery.temperatureC(fromProperties: ["BatteryData": ["Temperature": 65535]]))
        // The ends of the range are readings.
        XCTAssertEqual(Battery.temperatureC(fromRaw: -2000), -20)
        XCTAssertEqual(Battery.temperatureC(fromRaw: 10000), 100)
    }

    // ── Where an entry keeps it ─────────────────────────────────────────────

    /// 3500 read as 35.00 °C with the SMC's own battery thermistors at 35.0,
    /// 35.0 and 34.4 °C the same moment. As 0.1 K it would have been 76.85 °C.
    func testTemperatureFromNestedBatteryData() throws {
        let props: [String: Any] = [
            "BatteryData": ["Temperature": 3500, "DesignCapacity": 6249],
            "Voltage": 11610,
        ]
        let c = try XCTUnwrap(Battery.temperatureC(fromProperties: props))
        XCTAssertEqual(c, 35.00, accuracy: 0.001)
    }

    /// Earlier macOS versions are documented to publish it at the top level,
    /// and that one is read first.
    func testTopLevelTemperatureWins() throws {
        let both: [String: Any] = ["Temperature": 3012, "BatteryData": ["Temperature": 2500]]
        let c = try XCTUnwrap(Battery.temperatureC(fromProperties: both))
        XCTAssertEqual(c, 30.12, accuracy: 0.001)
        // First, not only: a top-level value that is not a temperature does not
        // hide a nested one that is.
        let glitched: [String: Any] = ["Temperature": 65535, "BatteryData": ["Temperature": 2500]]
        XCTAssertEqual(Battery.temperatureC(fromProperties: glitched), 25)
    }

    // ── This Mac ────────────────────────────────────────────────────────────

    /// `Mac17,9` on macOS 27.0 (26A428), both entries read the same moment on
    /// 2026-11-11. The battery entry, which is the one `Battery.properties()`
    /// reads, has no temperature anywhere: its `BatteryData` is these eleven
    /// fields. The figure is in the `BatteryData` of its child entry,
    /// `AppleSmartBatteryPack`.
    ///
    /// `ioreg -rl` prints the two entries one under the other, each with a
    /// `BatteryData`, so the pack's reads as the battery's own. It is not, and
    /// a reader that stops at the battery entry has no temperature on this Mac.
    func testTheBatteryEntryOfMac17_9HasNoTemperatureAndItsPackEntryDoes() throws {
        XCTAssertNil(Battery.temperatureC(fromProperties: Self.mac17_9Battery))
        let c = try XCTUnwrap(Battery.temperatureC(fromProperties: Self.mac17_9Pack))
        XCTAssertEqual(c, 30.09, accuracy: 0.001)
    }

    static let mac17_9Battery: [String: Any] = [
        "BatteryData": ["FullChargeCapacity": 6148, "NominalChargeCapacity": 6300,
                        "FullyCharged": 0, "AvgTimeToEmpty": 187, "RemainingCapacity": 3075,
                        "AbsoluteCapacity": 0, "MaxCapacity": 100, "DesignCapacity": 6249,
                        "CurrentCapacity": 52, "BatteryPower": -15487,
                        "TrueRemainingCapacity": 0],
        "Voltage": 11610, "CurrentCapacity": 52, "MaxCapacity": 100, "CycleCount": 82,
        "InstantAmperage": -1334, "TimeRemaining": 187,
    ]

    static let mac17_9Pack: [String: Any] = [
        "BatteryData": ["Temperature": 3009, "VirtualTemperature": 3009, "Voltage": 11610,
                        "CycleCount": 82, "DesignCapacity": 6249, "StateOfCharge": 51],
    ]

    /// LIVE. The fixture above says where one Mac kept it on one day; this asks
    /// the machine the suite is running on. Whichever entry publishes a pack
    /// temperature, `Battery.state()` has to carry it.
    func testStateCarriesTheTemperatureThisMachinePublishes() throws {
        guard let state = Battery.state() else { throw XCTSkip("no battery on this machine") }
        let entries = ["AppleSmartBattery", "AppleSmartBatteryPack"]
        guard let published = entries.lazy.compactMap(Self.registryTemperature).first else {
            throw XCTSkip("neither battery entry publishes a Temperature here")
        }
        try XCTSkipUnless((-20.0...100.0).contains(published),
                          "the gauge is publishing \(published) °C right now")

        let read = try XCTUnwrap(state.temperature_C,
                                 "the registry publishes \(published) °C and Battery.state() read none")
        // Two reads a moment apart. The pack republishes about once a minute, in
        // steps of at most half a degree over four minutes of watching it warm
        // under a build, so one landing between them stays inside this.
        XCTAssertEqual(read, published, accuracy: 1.0)
    }

    /// One entry's own figure in °C, read without the code under test.
    private static func registryTemperature(_ serviceClass: String) -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching(serviceClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                == kIOReturnSuccess,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        let nested = (props["BatteryData"] as? [String: Any])?["Temperature"]
        return ((props["Temperature"] ?? nested) as? NSNumber).map { $0.doubleValue / 100 }
    }
}
