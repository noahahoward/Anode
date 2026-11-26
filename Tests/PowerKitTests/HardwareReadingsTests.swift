import XCTest
@testable import PowerKit

/// Builders for the hardware view's input snapshots, shared by the readings and
/// the detail tests. Nothing here reads the machine.
enum HardwareFixtures {

    static func fan(_ index: Int, rpm: Double = 0, target: Double? = nil) -> FanInfo {
        FanInfo(index: index, currentRPM: rpm, minRPM: 2317, maxRPM: 7826, targetRPM: target)
    }

    static func memory(pressure: Int32? = 1) -> MemoryUsage.Sample {
        let gib: UInt64 = 1_073_741_824
        return MemoryUsage.Sample(total: 24 * gib, used: 20 * gib, wired: 4 * gib,
                                  compressed: 8 * gib, app: 8 * gib, free: 2 * gib,
                                  pressureLevel: pressure)
    }

    static func system(fans: [FanInfo] = [],
                       cpuT: Double? = 41.4,
                       gpuT: Double? = 40.2,
                       memory: MemoryUsage.Sample? = nil,
                       network: NetworkThroughput.Sample? = nil,
                       disk: DiskActivity.Sample? = nil,
                       sensorsSampled: Bool = true) -> SystemMetrics.Snapshot {
        SystemMetrics.Snapshot(cpu: nil, memory: memory, gpu: nil, network: network,
                               disk: disk, cpuTemperature: cpuT, gpuTemperature: gpuT,
                               fans: fans, sensorsSampled: sensorsSampled)
    }

    static func battery(percent: Int = 64,
                        charging: Bool = true,
                        onAC: Bool = true,
                        amperage_mA: Int = 6100,
                        timeRemaining_min: Int? = 52,
                        adapterInput_mW: Double? = 62_000,
                        adapterWatts: Double? = 68) -> Battery.State {
        var s = Battery.State(percent: percent, isCharging: charging, onAC: onAC,
                              cycleCount: 95, voltage_mV: 12_000,
                              amperage_mA: amperage_mA, remainingCapacity_mAh: 4_000,
                              timeRemaining_min: timeRemaining_min)
        s.adapterInput_mW = adapterInput_mW
        s.adapterWatts = adapterWatts
        s.adapterPresent = onAC
        s.temperature_C = 36.8
        return s
    }

    static func power(state: Battery.State?,
                      measured_W: Double? = 38.4,
                      smcTotal_W: Double? = 41.5,
                      display_W: Double? = 2.6,
                      displayIsMeasured: Bool = true) -> PowerMonitor.Snapshot {
        PowerMonitor.Snapshot(
            drains: [], apps: [], systemApps: [], gpuApps: [],
            systemAttributionAge: nil, isFullSample: true,
            attributed_W: 0.3, rails: [], gpu_W: nil, fast_W: 0.3,
            measured_W: measured_W, measuredAge: nil,
            smoothed_W: 3.9745, isCalibrated: true,
            smcTotal_W: smcTotal_W, smcGain: 1, cpuRail_W: 1,
            display_W: display_W, memory_W: nil, storage_W: nil, usb_W: nil,
            usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
            displayIsMeasured: displayIsMeasured, baseline_W: nil, didJump: false,
            residual_W: 3, rawResidual_W: 3,
            scale: makeMachineScale(), state: state,
            coverage: 0.63, denied: 300, readable: 600, attempted: 900, interval: 2)
    }

    static func nvme() -> NVMeHealth.Sample {
        NVMeHealth.Sample(criticalWarning: 0, temperatureK: 307,
                          availableSpare: 100, availableSpareThreshold: 10,
                          percentageUsed: 1,
                          dataUnitsRead: 0, dataUnitsWritten: 37_400_000,
                          hostReadCommands: 0, hostWriteCommands: 0,
                          controllerBusyTimeMinutes: 0, powerCycles: 0,
                          powerOnHours: 0, unsafeShutdowns: 0, mediaErrors: 0,
                          errorLogEntries: 0)
    }

    static func make(system: SystemMetrics.Snapshot,
                     power: PowerMonitor.Snapshot? = nil,
                     swapBytes: UInt64? = nil,
                     brightness: Double? = nil,
                     nvme: NVMeHealth.Sample? = nil,
                     helperInstalled: Bool = false,
                     manualTargets: [Int: Double] = [:]) -> HardwareReadings {
        HardwareReadings.make(system: system, power: power, swapBytes: swapBytes,
                              brightness: brightness, nvme: nvme,
                              helperInstalled: helperInstalled,
                              manualTargets: manualTargets)
    }
}

/// The reading binding and the in-memory history.
final class HardwareReadingsTests: XCTestCase {

    // MARK: Provenance

    func testTemperaturesAreRealAndTheAdapterAndTimeAreEstimates() throws {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 4380)]),
            power: HardwareFixtures.power(state: HardwareFixtures.battery()))
        XCTAssertEqual(r.cpuTemp, Tagged(value: 41.4, provenance: .real))
        XCTAssertEqual(r.gpuTemp, Tagged(value: 40.2, provenance: .real))
        let battery = try XCTUnwrap(r.battery)
        XCTAssertEqual(battery.timeRemainingMin, Tagged(value: 52, provenance: .estimate))
        XCTAssertEqual(battery.systemDrawW, Tagged(value: 41.5, provenance: .real))
        let adapter = try XCTUnwrap(r.adapter)
        XCTAssertEqual(adapter.drawnW.provenance, .estimate)
        XCTAssertEqual(try XCTUnwrap(adapter.drawnW.value), 62.0, accuracy: 0.001)
        XCTAssertEqual(adapter.ratedW, 68)
    }

    func testDisplayWattsAreRealOnlyWhenTheRailIsMeasured() throws {
        let state = HardwareFixtures.battery()
        let measured = HardwareFixtures.make(
            system: HardwareFixtures.system(),
            power: HardwareFixtures.power(state: state, display_W: 2.6, displayIsMeasured: true),
            brightness: 0.62)
        XCTAssertEqual(try XCTUnwrap(measured.display).watts.provenance, .real)
        XCTAssertEqual(try XCTUnwrap(measured.display).brightness, 0.62)

        let modelled = HardwareFixtures.make(
            system: HardwareFixtures.system(),
            power: HardwareFixtures.power(state: state, display_W: 1.1, displayIsMeasured: false),
            brightness: 0.62)
        XCTAssertEqual(try XCTUnwrap(modelled.display).watts.provenance, .estimate)
    }

    func testAnUnplugBlanksTheAdapterRatherThanShowingZeroDraw() throws {
        let unplugged = HardwareFixtures.battery(charging: false, onAC: false,
                                                 adapterInput_mW: 0, adapterWatts: nil)
        let r = HardwareFixtures.make(system: HardwareFixtures.system(),
                                      power: HardwareFixtures.power(state: unplugged))
        XCTAssertNil(r.adapter)
        XCTAssertEqual(r.battery?.state, .discharging)

        // On the cable but the draw has not been published yet: no number, not 0.
        let waiting = HardwareFixtures.battery(adapterInput_mW: 0)
        let r2 = HardwareFixtures.make(system: HardwareFixtures.system(),
                                       power: HardwareFixtures.power(state: waiting))
        XCTAssertNil(try XCTUnwrap(r2.adapter).drawnW.value)
    }

    func testSystemDrawIsThePSTRReadingWhenItIsAvailable() {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(),
            power: HardwareFixtures.power(state: HardwareFixtures.battery(),
                                          measured_W: 38.4, smcTotal_W: 41.5))
        XCTAssertEqual(r.systemW, Tagged(value: 41.5, provenance: .real))
        XCTAssertEqual(r.battery?.systemDrawW, Tagged(value: 41.5, provenance: .real))
    }

    func testSystemDrawFallsBackToTheGaugeWhenPSTRIsMissing() {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(),
            power: HardwareFixtures.power(state: HardwareFixtures.battery(),
                                          measured_W: 38.4, smcTotal_W: nil))
        XCTAssertEqual(r.systemW, Tagged(value: 38.4, provenance: .real))
    }

    func testSystemDrawFallsBackToTheGaugeWhenPSTRIsNotANumber() {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(),
            power: HardwareFixtures.power(state: HardwareFixtures.battery(),
                                          measured_W: 38.4, smcTotal_W: Double.nan))
        XCTAssertEqual(r.systemW, Tagged(value: 38.4, provenance: .real))
    }

    func testSystemDrawIsNilWhenNeitherReadingExists() {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(),
            power: HardwareFixtures.power(state: HardwareFixtures.battery(),
                                          measured_W: nil, smcTotal_W: nil))
        XCTAssertNil(r.systemW.value)
        XCTAssertNil(r.battery?.systemDrawW.value)
    }

    func testNoPowerSnapshotMeansNoBatteryAdapterOrDisplay() {
        let r = HardwareFixtures.make(system: HardwareFixtures.system())
        XCTAssertNil(r.battery)
        XCTAssertNil(r.adapter)
        XCTAssertNil(r.display)
        XCTAssertNil(r.systemW.value)
    }

    // MARK: Sensors not sampled, and a fanless Mac

    func testUnsampledSensorsMeanUnmeasuredFansAndNoTemperatures() {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2400)],
                                            cpuT: 55, gpuT: 50, sensorsSampled: false))
        XCTAssertFalse(r.fansMeasured)
        XCTAssertTrue(r.fans.isEmpty)
        XCTAssertNil(r.cpuTemp.value)
        XCTAssertNil(r.gpuTemp.value)
    }

    func testAFanlessMacWithNoBrightnessHasNoFansAndNoDisplayAndDoesNotCrash() {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [], cpuT: 38, gpuT: 37),
            power: HardwareFixtures.power(state: HardwareFixtures.battery(),
                                          display_W: nil, displayIsMeasured: false),
            brightness: nil)
        XCTAssertTrue(r.fansMeasured, "measured, and there are none")
        XCTAssertTrue(r.fans.isEmpty)
        XCTAssertNil(r.display)
        XCTAssertNil(r.memory)
        XCTAssertNil(r.network)
        XCTAssertNil(r.storage)
    }

    func testManualTargetsMarkAFanManualAndOverrideItsTarget() throws {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 3000, target: 2500),
                                                   HardwareFixtures.fan(1, rpm: 3000, target: 2500)]),
            helperInstalled: true,
            manualTargets: [1: 5000])
        XCTAssertEqual(r.fans.count, 2)
        XCTAssertFalse(r.fans[0].isManual)
        XCTAssertEqual(r.fans[0].targetRPM, 2500)
        XCTAssertTrue(r.fans[1].isManual)
        XCTAssertEqual(r.fans[1].targetRPM, 5000)
        XCTAssertTrue(r.helperInstalled)
    }

    // MARK: Memory, storage, network

    func testMemoryStorageAndNetworkAreBoundFromTheirSamples() throws {
        let net = NetworkThroughput.Sample(bytesInPerSec: 3500, bytesOutPerSec: 2700,
                                           interfaces: [NetworkThroughput.Interface(name: "en0", inPerSec: 3500, outPerSec: 2700)],
                                           measured: ["en0"], interval: 2)
        let disk = DiskActivity.Sample(bytesReadPerSec: 63_100, bytesWrittenPerSec: 19_700,
                                       devices: [], interval: 2)
        let r = HardwareReadings.make(
            system: HardwareFixtures.system(memory: HardwareFixtures.memory(pressure: 2),
                                            network: net, disk: disk),
            power: nil, swapBytes: 9_126_805_504, brightness: nil,
            nvme: HardwareFixtures.nvme(), helperInstalled: false, manualTargets: [:],
            volume: (freeBytes: 129_000_000_000, totalBytes: 994_000_000_000))

        let m = try XCTUnwrap(r.memory)
        XCTAssertEqual(m.pressure, 2)
        XCTAssertEqual(m.swapBytes, Tagged(value: 9_126_805_504, provenance: .real))

        XCTAssertEqual(try XCTUnwrap(r.network).down, 3500)
        XCTAssertEqual(try XCTUnwrap(r.network).up, 2700)
        XCTAssertEqual(r.networkInterface, "en0")

        let s = try XCTUnwrap(r.storage)
        XCTAssertEqual(s.freeBytes, 129_000_000_000)
        XCTAssertEqual(s.totalBytes, 994_000_000_000)
        XCTAssertEqual(s.readBPS, 63_100)
        XCTAssertEqual(s.writeBPS, 19_700)
        XCTAssertEqual(s.wearPercent, 1)
        XCTAssertEqual(s.spare, 100)
        XCTAssertEqual(s.bytesWritten, UInt64(37_400_000) * 512_000)
        XCTAssertEqual(try XCTUnwrap(s.smartTempC), 33.85, accuracy: 0.01)
    }

    func testAMissingPressureReadingStaysMissing() throws {
        let r = HardwareFixtures.make(
            system: HardwareFixtures.system(memory: HardwareFixtures.memory(pressure: nil)))
        XCTAssertNil(try XCTUnwrap(r.memory).pressure)
    }

    // MARK: History

    func testHistoryStartsEmpty() {
        let h = HardwareHistory()
        XCTAssertEqual(h.count, 0)
        XCTAssertTrue(h.series(.cpuTemp).isEmpty)
        XCTAssertTrue(h.series(.fanRPM(index: 0)).isEmpty)
    }

    func testHistoryDropsTheOldestPastCapacity() {
        let h = HardwareHistory(capacity: 3)
        for t in [10.0, 20, 30, 40, 50] {
            h.append(HardwareFixtures.make(system: HardwareFixtures.system(cpuT: t)))
        }
        XCTAssertEqual(h.series(.cpuTemp), [30, 40, 50])
    }

    func testHistoryKeepsAGapForAMissingReadingAndSeparatesFans() {
        let h = HardwareHistory(capacity: 5)
        h.append(HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2400),
                                                   HardwareFixtures.fan(1, rpm: 2500)])))
        h.append(HardwareFixtures.make(
            system: HardwareFixtures.system(fans: [HardwareFixtures.fan(0, rpm: 2600)],
                                            cpuT: nil, sensorsSampled: false)))
        XCTAssertEqual(h.series(.cpuTemp), [41.4, nil])
        XCTAssertEqual(h.series(.fanRPM(index: 0)), [2400, nil])
        XCTAssertEqual(h.series(.fanRPM(index: 1)), [2500, nil])
        XCTAssertEqual(h.series(.netDown), [nil, nil])
    }

    func testHistoryRecordsMemoryInUseInBytes() {
        let h = HardwareHistory()
        h.append(HardwareFixtures.make(
            system: HardwareFixtures.system(memory: HardwareFixtures.memory())))
        let gib = 1_073_741_824.0
        XCTAssertEqual(h.series(.memoryUsed), [(8 + 4 + 8) * gib])
    }
}
