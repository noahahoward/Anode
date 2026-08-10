import XCTest
import IOKit
@testable import PowerKit

/// Naming is the one part of the sensor stack that can be confidently wrong.
///
/// A value that decodes to nonsense gets caught — `TTPD` reads -3.07e8 "°C" and
/// nine `Tz1*` keys sit frozen at 0, and the plausibility filter throws all of
/// them out. A NAME has no such backstop. "Exhaust 1" attached to the charger
/// rail is finite, plausible, and wrong forever, and the user has no way to tell.
///
/// So these tests pin the two halves of the contract: the families we claim to
/// know keep the names the evidence supports, and everything else is visibly
/// marked as a placeholder instead of borrowing a name from a neighbour.
final class SensorNamingTests: XCTestCase {

    /// Runs one key through the namer with a fresh counter set.
    private func label(_ key: String,
                       kind: SensorKind = .temperature,
                       type: String = "flt",
                       rails: Bool = true) -> SensorNaming.Label {
        var ordinals: [String: Int] = [:]
        return SensorNaming.label(for: key, kind: kind, type: type,
                                  calibratedRails: rails, ordinals: &ordinals)
    }

    /// Runs a whole discovery pass, sharing one counter set the way `Sensors`
    /// does — which is what makes the ordinals mean anything.
    private func labels(_ keys: [String],
                        kind: SensorKind = .temperature,
                        type: String = "flt",
                        rails: Bool = true) -> [String] {
        var ordinals: [String: Int] = [:]
        return keys.map {
            SensorNaming.label(for: $0, kind: kind, type: type,
                               calibratedRails: rails, ordinals: &ordinals).text
        }
    }

    // ── Names we can defend ─────────────────────────────────────────────────

    func testExactlyNamedKeysGetTheirNames() {
        XCTAssertEqual(label("TB0T").text, "Battery sensor 1")
        XCTAssertEqual(label("TB2T").text, "Battery sensor 3")
        XCTAssertEqual(label("Ts0P").text, "Palm rest 1")
        XCTAssertEqual(label("Ts1P").text, "Palm rest 2")
        XCTAssertEqual(label("TaLP").text, "Airflow left")
        XCTAssertEqual(label("TaRF").text, "Airflow right")
        XCTAssertEqual(label("TH0x").text, "NAND flash")
        XCTAssertEqual(label("TW0P").text, "Wi-Fi proximity")
        for key in ["TB0T", "Ts0P", "TaLP", "TH0x", "TW0P"] {
            XCTAssertEqual(label(key).confidence, .identified, "\(key) should be a claim we stand behind")
        }
    }

    func testFamiliesAreNumberedInTheOrderTheyAreDiscovered() {
        XCTAssertEqual(labels(["Tp00", "Tp04", "Tp08"]),
                       ["CPU core sensor 1", "CPU core sensor 2", "CPU core sensor 3"])
        XCTAssertEqual(labels(["Tg08", "Tg0C"]), ["GPU sensor 1", "GPU sensor 2"])
        XCTAssertEqual(labels(["Tm00", "Tm04"]), ["Memory sensor 1", "Memory sensor 2"])
    }

    /// Each family counts independently, and interleaving must not disturb that.
    func testFamilyCountersAreIndependent() {
        XCTAssertEqual(labels(["Tg08", "Tp00", "Tg0C", "Tp04"]),
                       ["GPU sensor 1", "CPU core sensor 1", "GPU sensor 2", "CPU core sensor 2"])
    }

    /// `Tp*` is not labelled "performance", because on M1 the efficiency cores
    /// sit inside the same family — the prefix does not carry a core type, and
    /// claiming one tells the user which core to blame on no evidence.
    func testTheCPUFamilyDoesNotClaimACoreType() {
        let name = label("Tp00").text
        XCTAssertFalse(name.lowercased().contains("performance"),
                       "the Tp prefix does not distinguish P-cores from E-cores")
        XCTAssertFalse(name.lowercased().contains("core 1"),
                       "a sensor ordinal is not a core ordinal")
        XCTAssertTrue(name.hasPrefix("CPU core sensor"))
    }

    // ── Honest unknowns ─────────────────────────────────────────────────────

    /// The keys the user complained about. They get a readable placeholder, and
    /// the placeholder is FLAGGED so the UI can show the raw key beside it.
    func testAnUnidentifiedTemperatureIsHedgedAndFlagged() {
        for key in ["TDER", "TD23", "TDVx", "TVD0", "TPD0", "TRDX", "TUD0"] {
            let l = label(key)
            XCTAssertEqual(l.confidence, .unidentified, "\(key) is not a family we can vouch for")
            XCTAssertTrue(l.text.hasPrefix("Thermal sensor "), "got \(l.text) for \(key)")
        }
    }

    /// The heart of it: an unknown key must not inherit a name from a family it
    /// merely resembles. Matching is case-sensitive because `Tp00` (a CPU diode)
    /// and `TPD0` (unidentified, and a different temperature) differ only in case.
    func testAnUnknownKeyNeverBorrowsAFamilyName() {
        for key in ["TPD0", "TGxx", "TMVR", "TEST"] {
            let l = label(key)
            XCTAssertEqual(l.confidence, .unidentified)
            XCTAssertFalse(l.text.contains("CPU"), "\(key) was handed a CPU name")
            XCTAssertFalse(l.text.contains("GPU"), "\(key) was handed a GPU name")
            XCTAssertFalse(l.text.contains("Memory"), "\(key) was handed a memory name")
        }
    }

    /// An exact name must not spend a family ordinal, or `Ts0P` (palm rest)
    /// would silently shift the numbering of a family it does not belong to.
    func testAnExactNameDoesNotConsumeAFamilyOrdinal() {
        XCTAssertEqual(labels(["Tg08", "TB0T", "Tg0C"]),
                       ["GPU sensor 1", "Battery sensor 1", "GPU sensor 2"])
    }

    /// The Apple Silicon families were established on `flt` keys. On Intel the
    /// same prefix can mean something else entirely — `Tm0P` is the MAINBOARD
    /// there, not memory — so an `sp78` key must never be given one of these
    /// names.
    func testIntelKeysAreNotGivenAppleSiliconFamilyNames() {
        for key in ["Tm0P", "Tp0P", "Tg0P"] {
            let l = label(key, type: "sp78")
            XCTAssertEqual(l.confidence, .unidentified, "\(key) on Intel is not the AS family")
            XCTAssertFalse(l.text.contains("Memory"), "\(key)/sp78 got the Apple Silicon memory name")
            XCTAssertFalse(l.text.contains("CPU"), "\(key)/sp78 got the Apple Silicon CPU name")
        }
        // The same key on Apple Silicon still resolves normally.
        XCTAssertEqual(label("Tm00", type: "flt").text, "Memory sensor 1")
    }

    // ── Rails ───────────────────────────────────────────────────────────────

    /// `PSTR` and `PPMC` are read as those quantities everywhere in this
    /// codebase, so they are named everywhere.
    func testUniversalRailsAreNamedOnAnyMachine() {
        XCTAssertEqual(label("PSTR", kind: .power, rails: false).text, "System total power")
        XCTAssertEqual(label("PPMC", kind: .power, rails: false).text, "CPU package power")
    }

    /// The rest were identified by load experiments on ONE Mac. A key that
    /// exists on another machine is not evidence it means the same thing there,
    /// and a misidentified rail passes every plausibility check while putting
    /// watts under a confidently wrong name.
    func testCalibratedRailsAreNamedOnlyOnTheMachineTheyWereMeasuredOn() {
        for key in ["PDBR", "P3F2", "PZD1", "PN00"] {
            XCTAssertEqual(label(key, kind: .power, rails: true).confidence, .identified)

            let off = label(key, kind: .power, rails: false)
            XCTAssertEqual(off.confidence, .unidentified, "\(key) must not be named off its machine")
            XCTAssertEqual(off.text, key, "an unidentified rail keeps its raw key")
        }
    }

    /// An unidentified rail keeps its key rather than becoming "Power sensor 41":
    /// among hundreds of opaque rails the key is the more findable identity.
    func testUnidentifiedNonTemperaturesKeepTheRawKey() {
        XCTAssertEqual(label("PZC0", kind: .power).text, "PZC0")
        XCTAssertEqual(label("VD0R", kind: .voltage).text, "VD0R")
        XCTAssertEqual(label("ID0R", kind: .current).text, "ID0R")
    }

    // ── Stable ordinals ─────────────────────────────────────────────────────

    /// Why `Sensors` fixes every name once, at discovery.
    ///
    /// Naming is positional: the Nth member of a family seen gets N. So if names
    /// were recomputed from each snapshot's SURVIVING keys, one sensor dropping
    /// out for one tick — a transient read failure, or a value that briefly
    /// fails the plausibility filter — would renumber every sensor behind it,
    /// and a graph the user was watching would silently change which diode it
    /// was plotting. This pins the hazard that the discovery-time cache exists
    /// to prevent.
    func testRecomputingNamesFromASnapshotWouldRenumberTheSurvivors() {
        let discovered = ["Tg08", "Tg0C", "Tg0O"]
        XCTAssertEqual(labels(discovered),
                       ["GPU sensor 1", "GPU sensor 2", "GPU sensor 3"])

        // Tg0C fails the sanity filter for one tick.
        XCTAssertEqual(labels(["Tg08", "Tg0O"]), ["GPU sensor 1", "GPU sensor 2"],
                       "Tg0O is the same diode but would be renumbered 3 -> 2")
    }

    /// The observable fingerprint of naming-at-discovery.
    ///
    /// Ordinals are handed out over EVERY classified key, including the ones
    /// that fail the plausibility filter on every single sweep — this machine
    /// has nine `Tz1*` frozen at exactly 0, `TTPD` at -3.07e8 and `TVMD` at 1.0.
    /// Those keys are numbered and then never shown, so the numbers that ARE
    /// visible have gaps in them, and the highest one exceeds how many are on
    /// screen. If the numbering ever came out contiguous it would mean names
    /// were being computed from the survivors of one sweep — which is precisely
    /// the arrangement that renumbers a user's graph when an unrelated sensor
    /// blinks.
    func testHedgedNumbersAreAssignedAtDiscoveryNotPerSnapshot() throws {
        let inv = Sensors.inventory()
        try XCTSkipIf(inv.keysTotal == 0, "no AppleSMC user client here")

        let hedged = inv.temperatures.filter { $0.confidence == .unidentified }
        try XCTSkipIf(hedged.isEmpty, "every temperature on this machine is identified")
        try XCTSkipIf(inv.rejected.filter { $0.key.hasPrefix("T") }.isEmpty,
                      "nothing failed the plausibility filter on this sweep")

        let prefix = "Thermal sensor "
        let numbers = hedged.compactMap { Int($0.name.dropFirst(prefix.count)) }
        XCTAssertEqual(numbers.count, hedged.count, "a hedged name carried no number")
        XCTAssertGreaterThan(numbers.max() ?? 0, numbers.count,
                             "hedged numbering is contiguous — names look recomputed per sweep, "
                             + "not fixed at discovery")
    }

    /// And the guarantee itself, on real hardware: the same key keeps the same
    /// name across snapshots.
    func testNamesAreStableAcrossSnapshotsOnThisMachine() throws {
        let first = Sensors.inventory()
        try XCTSkipIf(first.keysTotal == 0, "no AppleSMC user client here")

        let second = Sensors.inventory()
        var namesByKey: [String: String] = [:]
        for r in first.readings { namesByKey[r.key] = r.name }
        for r in second.readings {
            if let was = namesByKey[r.key] {
                XCTAssertEqual(was, r.name, "\(r.key) was renamed between two snapshots")
            }
        }
        XCTAssertFalse(second.readings.isEmpty)
    }

    /// Every name is either something we can defend or visibly a placeholder —
    /// there is no third state where a guess is presented as a fact.
    func testEveryReadingDeclaresWhetherItsNameIsAClaim() throws {
        let inv = Sensors.inventory()
        try XCTSkipIf(inv.keysTotal == 0, "no AppleSMC user client here")

        for r in inv.readings {
            XCTAssertFalse(r.name.isEmpty, "\(r.key) has no name at all")
            if r.confidence == .unidentified, r.kind == .temperature {
                XCTAssertTrue(r.name.hasPrefix("Thermal sensor "),
                              "\(r.key) is unidentified but reads as \(r.name)")
            }
        }
        XCTAssertTrue(inv.readings.contains { $0.confidence == .identified },
                      "nothing at all was identified on a machine with a live SMC")
        // ~150 of this machine's 268 temperature keys belong to no family we can
        // vouch for. If none of them come back flagged, the confidence is not
        // reaching the reading and the UI has no way to tell a name from a guess.
        XCTAssertTrue(inv.readings.contains { $0.confidence == .unidentified },
                      "no reading was flagged unidentified — is confidence plumbed through?")
    }

    // ── The one family with an independent cross-check ──────────────────────

    /// `TB*T` is the only family here whose name can be checked against a
    /// source that is not the SMC. IOKit publishes the pack's own temperature at
    /// `AppleSmartBatteryPack.BatteryData.Temperature`, in centi-°C, from the
    /// gas gauge rather than from a thermistor read. Measured while writing
    /// this: IOKit 27.09 °C against TB0T 27.10 and TB2T 27.10.
    ///
    /// The tolerance is wide enough for two thermistors in one pack to disagree
    /// and far too narrow to survive the label landing on a different subsystem
    /// — the next-coolest thing on this machine is the palm rest at 26.9 °C and
    /// the die sits 9 °C above the pack, so a misapplied "Battery" would show.
    func testTheBatterySensorsAgreeWithApplesOwnBatteryTemperature() throws {
        let inv = Sensors.inventory()
        try XCTSkipIf(inv.keysTotal == 0, "no AppleSMC user client here")

        let battery = inv.temperatures.filter { $0.name.hasPrefix("Battery sensor") }
        try XCTSkipIf(battery.isEmpty, "no TB*T keys on this machine")

        let pack = try XCTUnwrap(Self.batteryPackTemperature(),
                                 "AppleSmartBatteryPack publishes no Temperature here")
        for r in battery {
            XCTAssertEqual(r.value, pack, accuracy: 3.0,
                           "\(r.key) is named \(r.name) but reads \(r.value) against a pack at \(pack)")
        }
    }

    /// Apple's own figure for the pack, in °C, or nil where it is not published.
    private static func batteryPackTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBatteryPack"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                == kIOReturnSuccess,
              let props = unmanaged?.takeRetainedValue() as? [String: Any],
              let data = props["BatteryData"] as? [String: Any],
              let centiC = data["Temperature"] as? Int else { return nil }
        return Double(centiC) / 100.0
    }
}
