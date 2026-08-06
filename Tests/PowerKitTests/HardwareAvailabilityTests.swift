import XCTest
@testable import PowerKit

/// Tests that touch real hardware. Every data source here is undocumented and can
/// vanish (different model, VM, CI, locked-down config), so absence is a SKIP,
/// never a failure — the suite must pass anywhere. What IS asserted, when the
/// hardware answers, are the invariants whose violation means a shipped bug.
final class HardwareAvailabilityTests: XCTestCase {

    // ── SMC ─────────────────────────────────────────────────────────────────

    /// The 80-byte trap. A naturally-laid-out Swift struct comes out 76 bytes and
    /// IOConnectCallStructMethod rejects it with kIOReturnBadArgument (0xe00002c2)
    /// — silently, as a nil read. diagnose() prints the wire size actually used,
    /// which is the one observable for this regression.
    func testSMCRequestBufferIsExactly80Bytes() throws {
        guard let smc = SMC() else { throw XCTSkip("AppleSMC not reachable here") }
        let diag = smc.diagnose()
        XCTAssertTrue(diag.hasPrefix("buffer=80 bytes"), "wire size regressed: \(diag)")
    }

    /// #KEY is decoded by two independent paths (keyCount's manual big-endian read
    /// and read()'s ui32 decoder). They must agree — a disagreement means one
    /// decoder's endianness slipped.
    func testSMCKeyCountAndDecoderAgree() throws {
        guard let smc = SMC() else { throw XCTSkip("AppleSMC not reachable here") }
        let n = smc.keyCount()
        // Opened-but-unreadable (e.g. sandboxed) is a degrade, not a maths failure.
        guard n > 0 else { throw XCTSkip("SMC opened but #KEY unreadable: \(smc.diagnose())") }

        // Measured on this machine: 3588 keys. Any real SMC has hundreds.
        XCTAssertGreaterThan(n, 100)
        if let sensor = smc.read("#KEY") {
            XCTAssertEqual(Int(sensor.value), n, "ui32 decoder disagrees with keyCount")
        }
        XCTAssertNotNil(smc.key(at: 0), "index enumeration must work when #KEY does")
    }

    /// PSTR = whole-system watts, the live anchor for the displayed figure. When
    /// present it must be a plausible laptop power draw — flt type, finite, positive.
    func testSMCWholeSystemPowerIsPlausibleWhenPresent() throws {
        guard let smc = SMC() else { throw XCTSkip("AppleSMC not reachable here") }
        guard let pstr = smc.read("PSTR") else { throw XCTSkip("PSTR absent on this model") }
        XCTAssertEqual(pstr.type, "flt", "power sensors are IEEE-754 watts on Apple Silicon")
        XCTAssertTrue(pstr.value.isFinite)
        XCTAssertGreaterThan(pstr.value, 0, "a running machine draws SOMETHING")
        XCTAssertLessThan(pstr.value, 500, "a laptop, not a space heater")
    }

    // ── IOReport ────────────────────────────────────────────────────────────

    /// IOReport resolves only from the dyld shared cache and its ABI is private —
    /// init?() returning nil is the designed degrade. When it works, rails must be
    /// finite and non-negative (a negative rail would silently drain the ledger).
    func testIOReportDegradesWithoutCrashing() throws {
        guard let sampler = IOReportSampler() else {
            throw XCTSkip("libIOReport unavailable — degrade path exercised")
        }
        // sample() needs dt > 0.05 s against the init-time snapshot.
        Thread.sleep(forTimeInterval: 0.15)
        guard let reading = sampler.sample() else {
            return  // nil (no delta yet / ABI hiccup) is a legal degrade, not a failure
        }
        XCTAssertGreaterThan(reading.interval, 0)
        for rail in reading.rails {
            XCTAssertTrue(rail.watts.isFinite, "\(rail.channel) is not finite")
            XCTAssertGreaterThanOrEqual(rail.watts, 0, "\(rail.channel) is negative")
        }
        if let gpu = reading.gpu_W {
            XCTAssertTrue(gpu.isFinite)
            XCTAssertGreaterThanOrEqual(gpu, 0)
        }
        XCTAssertEqual(reading.total_W,
                       reading.rails.reduce(0) { $0 + $1.watts },
                       accuracy: 1e-9)
    }

    // ── Battery ─────────────────────────────────────────────────────────────

    /// The Apple Silicon percent-vs-mAh trap, live. If the parser ever regresses to
    /// the top-level (percent) capacities, full-charge comes out ≈100 "mAh" and the
    /// whole %/hr ledger is off ~60×. Real packs are thousands of mAh.
    func testBatteryScaleParsesRealMAhNotPercent() throws {
        guard let scale = Battery.scale() else { throw XCTSkip("no battery on this machine") }
        XCTAssertGreaterThan(scale.fullChargeCapacity_mAh, 1000,
                             "≈100 means the PERCENT field was parsed as mAh")
        XCTAssertGreaterThan(scale.designCapacity_mAh, 1000)
        XCTAssertEqual(scale.nominalVoltage_V, BatteryScale.seedNominalVoltage_V,
                       "uncalibrated scale must carry the seed voltage")
        XCTAssertFalse(scale.isCalibrated)
        XCTAssertGreaterThan(scale.joulesPerPercent, 0)
        XCTAssertTrue((0.3...1.3).contains(scale.health),
                      "implausible health \(scale.health) — capacity fields crossed?")
    }

    /// The SBS 65535 sentinel must have been filtered to nil, never surfaced as
    /// "1092 hours remaining". No assumption about AC vs battery — both are legal.
    func testBatteryStateFiltersTheSBSSentinel() throws {
        guard let state = Battery.state() else { throw XCTSkip("no battery on this machine") }
        XCTAssertTrue((0...100).contains(state.percent))
        XCTAssertGreaterThanOrEqual(state.cycleCount, 0)
        if let t = state.timeRemaining_min {
            XCTAssertNotEqual(t, 65535, "SBS sentinel leaked through")
            XCTAssertGreaterThan(t, 0)
        }
    }
}
