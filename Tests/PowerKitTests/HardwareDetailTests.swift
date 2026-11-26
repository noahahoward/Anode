import XCTest
@testable import PowerKit

/// What the hover tip and the pinned panel say, driven from readings.
final class HardwareDetailTests: XCTestCase {

    private func component(_ id: String,
                           _ kind: HardwareComponentKind,
                           confidence: Confidence = .verified,
                           flags: [String] = [],
                           text: [String] = []) -> HardwareComponent {
        HardwareComponent(id: id, kind: kind, confidence: confidence, flags: flags, text: text)
    }

    private func detail(_ c: HardwareComponent,
                        _ r: HardwareReadings,
                        history: HardwareHistory = HardwareHistory(),
                        role: String? = nil) -> HardwareDetail? {
        HardwareDetail.make(component: c, readings: r, history: history, role: role)
    }

    private func value(_ d: HardwareDetail, _ label: String) -> String? {
        d.rows.first(where: { $0.label == label })?.value
    }

    private func provenance(_ d: HardwareDetail, _ label: String) -> Provenance? {
        d.rows.first(where: { $0.label == label })?.provenance
    }

    private func laptop(fans: [FanInfo] = [], onAC: Bool = true) -> HardwareReadings {
        HardwareFixtures.make(
            system: HardwareFixtures.system(fans: fans, memory: HardwareFixtures.memory()),
            power: HardwareFixtures.power(state: HardwareFixtures.battery(charging: onAC, onAC: onAC)),
            swapBytes: 0, brightness: 0.62)
    }

    // MARK: Fan

    func testAFanAtZeroSaysParkedAndIsMarkedReal() throws {
        let r = laptop(fans: [HardwareFixtures.fan(0, rpm: 0)])
        let d = try XCTUnwrap(detail(component("fan0", .fan(index: 0)), r))
        XCTAssertEqual(d.title, "Fan 1")
        XCTAssertEqual(value(d, "Speed"), "0 rpm · parked")
        XCTAssertEqual(provenance(d, "Speed"), .real)
        XCTAssertEqual(value(d, "Range"), "2,317 – 7,826 rpm")
        XCTAssertEqual(value(d, "Mode"), "Automatic")
        XCTAssertEqual(value(d, "Control"), "Needs helper")
        XCTAssertEqual(d.confidenceNote, "Layout verified from teardowns")
        XCTAssertEqual(d.series?.channel, .fanRPM(index: 0))
    }

    func testASpinningFanShowsItsSpeedAndManualMode() throws {
        var r = laptop(fans: [HardwareFixtures.fan(1, rpm: 4380)])
        r.fans[0].isManual = true
        r.helperInstalled = true
        let d = try XCTUnwrap(detail(component("fan1", .fan(index: 1), confidence: .inferred), r))
        XCTAssertEqual(d.title, "Fan 2")
        XCTAssertEqual(value(d, "Speed"), "4,380 rpm")
        XCTAssertEqual(value(d, "Mode"), "Manual")
        XCTAssertEqual(value(d, "Control"), "Helper installed")
        XCTAssertEqual(d.confidenceNote, "Position approximate · inferred")
    }

    func testAFanThatWasNotMeasuredIsADashNotZero() throws {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2400)],
                                            sensorsSampled: false))
        let d = try XCTUnwrap(detail(component("fan0", .fan(index: 0)), r))
        XCTAssertEqual(value(d, "Speed"), "—")
        XCTAssertNil(provenance(d, "Speed"))
        XCTAssertEqual(value(d, "Range"), "—")
    }

    func testAFanTheSweepDidNotListHasNoCard() {
        let r = laptop(fans: [HardwareFixtures.fan(0, rpm: 2400)])
        XCTAssertNil(detail(component("fan1", .fan(index: 1)), r), "a measured Mac with one fan has no fan 2")
        XCTAssertNotNil(detail(component("fan0", .fan(index: 0)), r))
        // Not swept at all is "not measured", which still has a card of dashes.
        let unswept = HardwareFixtures.make(system: HardwareFixtures.system(sensorsSampled: false))
        XCTAssertNotNil(detail(component("fan1", .fan(index: 1)), unswept))
    }

    func testTheZeroRpmNoteIsOnlyForAFanThatWasRead() throws {
        let read = try XCTUnwrap(detail(component("fan0", .fan(index: 0)), laptop(fans: [HardwareFixtures.fan(0, rpm: 0)])))
        XCTAssertTrue(read.note?.contains("0 rpm is a real reading") == true)
        let unswept = HardwareFixtures.make(system: HardwareFixtures.system(sensorsSampled: false))
        let dash = try XCTUnwrap(detail(component("fan0", .fan(index: 0)), unswept))
        XCTAssertFalse(dash.note?.contains("0 rpm") == true, "no reading, so nothing about a reading of 0")
        XCTAssertTrue(dash.note?.contains("Blade motion") == true)
    }

    // MARK: Heat pipe

    func testThePipeShowsTemperaturesAndSaysWhichHalfIsInferred() throws {
        let r = laptop()
        var rr = r
        rr.cpuSensorCount = 23
        rr.gpuSensorCount = 42
        let d = try XCTUnwrap(detail(component("pipe", .heatPipe, flags: ["dieSideInferred"]), rr))
        XCTAssertEqual(d.title, "Heat pipe")
        XCTAssertEqual(d.confidenceNote, "Pipe verified · which half is CPU or GPU is inferred")
        XCTAssertEqual(value(d, "CPU"), "41.4 °C")
        XCTAssertEqual(provenance(d, "CPU"), .real)
        XCTAssertEqual(value(d, "CPU sensors"), "mean of 23 die sensors")
        XCTAssertEqual(value(d, "GPU sensors"), "mean of 42 sensors")
        XCTAssertEqual(d.series?.channel, .cpuTemp)
    }

    func testTheFanlessSpreaderHasItsOwnTitleAndNote() throws {
        let d = try XCTUnwrap(detail(component("pipe", .heatPipe, flags: ["spreader"]), laptop()))
        XCTAssertEqual(d.title, "Passive spreader")
        XCTAssertEqual(d.note, "No fan: heat leaves through a metal plate and the case.")
    }

    func testUnsampledTemperaturesAreDashes() throws {
        let r = HardwareFixtures.make(system: HardwareFixtures.system(sensorsSampled: false))
        let d = try XCTUnwrap(detail(component("pipe", .heatPipe), r))
        XCTAssertEqual(value(d, "CPU"), "—")
        XCTAssertNil(provenance(d, "CPU"))
        XCTAssertEqual(value(d, "CPU sensors"), "—")
    }

    // MARK: Memory, storage, Wi-Fi

    func testMemoryUsesTheKernelsPressureLevel() throws {
        let d = try XCTUnwrap(detail(component("mem", .memory), laptop()))
        XCTAssertEqual(value(d, "In use"), "20.0 of 24 GB")
        XCTAssertEqual(value(d, "Pressure"), "Normal")
        XCTAssertEqual(value(d, "Swap"), "0.0 GB")
        XCTAssertEqual(d.series?.channel, .memoryUsed)

        var r = laptop()
        r.memory?.pressure = 4
        XCTAssertEqual(value(try XCTUnwrap(detail(component("mem", .memory), r)), "Pressure"), "Critical")
        r.memory?.pressure = nil
        let dash = try XCTUnwrap(detail(component("mem", .memory), r))
        XCTAssertEqual(value(dash, "Pressure"), "—")
        XCTAssertNil(provenance(dash, "Pressure"))
    }

    func testMemoryWithNoTotalNeverSaysOfZeroGB() throws {
        var r = laptop()
        r.memory?.total = 0
        let d = try XCTUnwrap(detail(component("mem", .memory), r))
        let inUse = try XCTUnwrap(value(d, "In use"))
        XCTAssertTrue(inUse.hasSuffix(" of —"), inUse)
        XCTAssertFalse(inUse.contains("0 GB"))
    }

    func testNumbersUseThousandsSeparatorsAtEveryNumberOfDecimals() {
        // Twice, so the shared formatters give the same answer the second time.
        for _ in 0..<2 {
            XCTAssertEqual(HardwareDetail.fmt(1234.567, 0), "1,235")
            XCTAssertEqual(HardwareDetail.fmt(1234.567, 1), "1,234.6")
            XCTAssertEqual(HardwareDetail.fmt(1234.567, 2), "1,234.57")
            XCTAssertEqual(HardwareDetail.fmt(1234.5678, 3), "1,234.568")
        }
    }

    func testStorageShowsFreeSpaceAndHealthAndDashesWhatIsMissing() throws {
        var r = laptop()
        r.storage = StorageReading(freeBytes: 129_000_000_000, totalBytes: 994_000_000_000,
                                   readBPS: 63_100, writeBPS: 19_700, smartTempC: 33.9,
                                   wearPercent: 1, spare: 100, bytesWritten: nil)
        let d = try XCTUnwrap(detail(component("ssd", .storage), r))
        XCTAssertEqual(value(d, "Free"), "129 of 994 GB")
        XCTAssertEqual(value(d, "Read / write"), "63.1 KB/s · 19.7 KB/s")
        XCTAssertEqual(value(d, "Wear used"), "1 %")
        XCTAssertEqual(value(d, "Written"), "—")
        XCTAssertNil(provenance(d, "Written"))
        XCTAssertEqual(d.series?.channel, .storageRead)
        XCTAssertEqual(d.series?.isRate, true)
    }

    func testWifiShowsRatesAndSaysSignalIsNotExposed() throws {
        var r = laptop()
        r.network = (down: 38.4e6, up: 2.1e6)
        r.networkInterface = "en0"
        let d = try XCTUnwrap(detail(component("wifi", .wifi, confidence: .inferred), r))
        XCTAssertEqual(value(d, "Download"), "38.4 MB/s")
        XCTAssertEqual(value(d, "Upload"), "2.1 MB/s")
        XCTAssertEqual(value(d, "Interface"), "en0")
        XCTAssertEqual(value(d, "Signal strength"), "not exposed")
        XCTAssertNil(provenance(d, "Signal strength"))
        let note = d.note ?? ""
        XCTAssertTrue(note.contains("total over its network links"), note)
        XCTAssertFalse(note.contains("per interface"), "the figure is the Mac's total, not one interface's")
    }

    // MARK: Display, adapter, power supply

    func testDisplayPowerIsTaggedByHowItWasObtained() throws {
        let measured = try XCTUnwrap(detail(component("display", .display), laptop()))
        XCTAssertEqual(value(measured, "Power"), "2.60 W")
        XCTAssertEqual(provenance(measured, "Power"), .real)
        XCTAssertEqual(value(measured, "Brightness"), "62 %")
        XCTAssertEqual(value(measured, "Temperature"), "not exposed")
        XCTAssertTrue(measured.note?.contains("PDBR") == true)

        var r = laptop()
        r.display?.watts.provenance = .estimate
        let modelled = try XCTUnwrap(detail(component("display", .display), r))
        XCTAssertEqual(provenance(modelled, "Power"), .estimate)
        XCTAssertTrue(modelled.note?.contains("estimated from brightness") == true)
    }

    func testTheDisplayGraphIsMarkedAsEstimatedWhenItsWattsAre() throws {
        let measured = try XCTUnwrap(detail(component("display", .display), laptop()))
        XCTAssertEqual(measured.series?.provenance, .real)
        var r = laptop()
        r.display?.watts.provenance = .estimate
        let modelled = try XCTUnwrap(detail(component("display", .display), r))
        XCTAssertEqual(modelled.series?.provenance, .estimate)
        let fan = try XCTUnwrap(detail(component("fan0", .fan(index: 0)), laptop(fans: [HardwareFixtures.fan(0, rpm: 100)])))
        XCTAssertEqual(fan.series?.provenance, .real)
    }

    func testAMacWithNoDisplayReadingShowsDashes() throws {
        let r = HardwareFixtures.make(system: HardwareFixtures.system())
        let d = try XCTUnwrap(detail(component("display", .display, text: ["2408 × 1506", "Liquid Retina"]), r))
        XCTAssertEqual(value(d, "Power"), "—")
        XCTAssertEqual(value(d, "Brightness"), "—")
        XCTAssertEqual(value(d, "Resolution"), "2408 × 1506")
        XCTAssertEqual(value(d, "Panel"), "Liquid Retina")
    }

    func testTheAdapterDrawIsAnEstimateAndTheTitleFollowsThePort() throws {
        let magsafe = try XCTUnwrap(detail(component("power-in", .powerIn), laptop()))
        XCTAssertEqual(magsafe.title, "MagSafe 3 · power in")
        XCTAssertEqual(value(magsafe, "Adapter rating"), "68 W")
        XCTAssertEqual(value(magsafe, "Drawing from adapter"), "≈ 62.0 W")
        XCTAssertEqual(provenance(magsafe, "Drawing from adapter"), .estimate)
        XCTAssertEqual(value(magsafe, "State"), "charging")

        let usbc = try XCTUnwrap(detail(component("power-in", .powerIn, flags: ["usbcPower"]), laptop()))
        XCTAssertEqual(usbc.title, "USB-C power in")

        let unplugged = try XCTUnwrap(detail(component("power-in", .powerIn),
                                             laptop(onAC: false)))
        XCTAssertEqual(value(unplugged, "Drawing from adapter"), "—")
        XCTAssertEqual(value(unplugged, "State"), "not connected")
    }

    func testThePowerSupplyShowsTheWholeMacDraw() throws {
        let d = try XCTUnwrap(detail(component("psu", .psu), laptop()))
        XCTAssertEqual(d.title, "Power supply")
        XCTAssertEqual(value(d, "Whole-Mac draw"), "41.5 W")
        XCTAssertEqual(value(d, "Source"), "Wall power")
    }

    func testNoSystemDrawReadingIsADashWithNoTag() throws {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(),
            power: HardwareFixtures.power(state: HardwareFixtures.battery(),
                                          measured_W: nil, smcTotal_W: nil))
        let psu = try XCTUnwrap(detail(component("psu", .psu), r))
        XCTAssertEqual(value(psu, "Whole-Mac draw"), "—")
        XCTAssertNil(provenance(psu, "Whole-Mac draw"))
        let draw = try XCTUnwrap(detail(component("battery", .battery), r, role: "draw"))
        XCTAssertEqual(value(draw, "Whole Mac"), "—")
        XCTAssertNil(provenance(draw, "Whole Mac"))
    }

    // MARK: Battery

    func testBatteryChargeSaysItIsAPackReading() throws {
        let d = try XCTUnwrap(detail(component("battery", .battery), laptop(), role: "charge"))
        XCTAssertEqual(d.title, "Charge")
        XCTAssertEqual(value(d, "Charge"), "64 %")
        XCTAssertEqual(provenance(d, "Charge"), .real)
        XCTAssertEqual(value(d, "Cycles"), "95", "the rated cycles are not known, so none are invented")
        XCTAssertTrue(d.note?.contains("pack readings") == true)

        // No role reads as charge.
        let none = try XCTUnwrap(detail(component("battery", .battery), laptop(), role: nil))
        XCTAssertEqual(none.title, "Charge")
    }

    func testEachBatteryRoleHasItsOwnRows() throws {
        let r = laptop()
        let c = component("battery", .battery)

        let temp = try XCTUnwrap(detail(c, r, role: "temp"))
        XCTAssertEqual(temp.title, "Battery temperature")
        XCTAssertEqual(value(temp, "Pack"), "36.8 °C")

        let state = try XCTUnwrap(detail(c, r, role: "state"))
        XCTAssertEqual(state.title, "State and rate")
        XCTAssertEqual(value(state, "State"), "Charging")
        XCTAssertEqual(value(state, "Current"), "+6.1 A")
        XCTAssertEqual(value(state, "Time"), "≈ 0:52 to full")
        XCTAssertEqual(provenance(state, "Time"), .estimate)

        let graph = try XCTUnwrap(detail(c, r, role: "graph"))
        XCTAssertEqual(graph.title, "Charge, last 24 hours")
        XCTAssertEqual(value(graph, "Source"), "Anode history")

        let draw = try XCTUnwrap(detail(c, r, role: "draw"))
        XCTAssertEqual(draw.title, "System draw")
        XCTAssertEqual(value(draw, "Whole Mac"), "41.5 W")

        let health = try XCTUnwrap(detail(c, r, role: "health"))
        XCTAssertEqual(health.title, "Health")
        XCTAssertNotNil(value(health, "Capacity vs new"))
        XCTAssertNotEqual(value(health, "Capacity vs new"), "—")
    }

    func testNoBatteryReadingMeansNoBatteryCard() {
        let desktop = HardwareFixtures.make(system: HardwareFixtures.system())
        XCTAssertNil(desktop.battery)
        for role in [nil, "charge", "temp", "state", "graph", "draw", "health"] as [String?] {
            XCTAssertNil(detail(component("battery", .battery), desktop, role: role), "role \(role ?? "none")")
        }
    }

    func testBatteryRatedCyclesAppearOnlyWhenKnown() throws {
        var r = laptop()
        r.battery?.designCycles = 1000
        let d = try XCTUnwrap(detail(component("battery", .battery), r, role: "charge"))
        XCTAssertEqual(value(d, "Cycles"), "95 of 1000")
    }

    func testAMissingTimeIsADashWithNoTag() throws {
        var r = laptop()
        r.battery?.timeRemainingMin = .estimate(nil)
        let d = try XCTUnwrap(detail(component("battery", .battery), r, role: "state"))
        XCTAssertEqual(value(d, "Time"), "—")
        XCTAssertNil(provenance(d, "Time"))
    }

    // MARK: Parts with nothing to say

    func testPartsWithNoReadingReturnNil() {
        let r = laptop()
        let silent: [HardwareComponentKind] = [.board, .soc, .antenna, .speaker, .trackpad, .note]
        for kind in silent {
            XCTAssertNil(detail(component("x", kind), r), "\(kind) has nothing to show")
        }
    }

    // MARK: The series carries history values

    func testTheSeriesCarriesTheBufferedValuesOldestFirst() throws {
        let h = HardwareHistory()
        for t in [40.0, 41, 42] {
            h.append(HardwareFixtures.make(system: HardwareFixtures.system(cpuT: t)))
        }
        let d = try XCTUnwrap(detail(component("pipe", .heatPipe), laptop(), history: h))
        XCTAssertEqual(d.series?.values, [40, 41, 42])
        XCTAssertEqual(d.series?.unit, " °C")
    }
}
