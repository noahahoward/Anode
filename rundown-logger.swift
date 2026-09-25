// Anode run-down logger — Phase 2 of the time-to-empty accuracy work.
//
//     swift rundown-logger.swift [output.csv]
//
// Samples AppleSmartBattery every 5 s and writes one CSV row per sample. No
// writes to anything the app owns, no root, no IOKit calls the app does not
// already make every tick.
//
// ## What this is for
// Nothing in this repo contains a real discharge curve. `HistoryStore.soc` is
// the integer `CurrentCapacity` — 1%-quantised AND ~2 points optimistic — and
// there is no voltage column at all. So the two largest suspected biases in
// time-to-empty have never been measured on this machine:
//
//   * V(SoC): the rails hold POWER, so as the pack sags the current rises and
//     the pack empties sooner than `charge / rate` predicts. Needs the voltage
//     against the charge, all the way down.
//   * the shutdown floor: does macOS stop at a non-zero mAh basis? The gauge is
//     no help — `TimeRemaining` is `RemainingCapacity/AvgCurrent` to within 1%,
//     so it reserves nothing and projects to mAh zero exactly like Anode does.
//
// One run yields both, plus the signed error curve that judges them.
//
// ## Why SIGNED error
// The scoring harness's only accuracy metric is MAE, which destroys the sign —
// and the entire question here is bias versus noise. Every row therefore
// carries the gauge's own quote and the raw inputs, so the error can be
// recomputed against the eventual death time in whatever form the analysis
// wants, rather than being baked in now.
//
// ## Robustness, because this run is expensive to repeat
// Flushed and fsync'd every row: the machine this runs on is expected to lose
// power at the end, and a buffered final minute is the most interesting minute.
// Appends rather than truncates, so a re-launch after a crash continues the
// same file. Records AC re-connection rather than exiting on it — a session
// that was plugged in at 12% is still a valid V(SoC) curve down to 12%, and
// the analysis needs to know where the pack stopped falling.

import Foundation
import IOKit

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~/Downloads/anode-rundown.csv").expandingTildeInPath
let interval: TimeInterval = 5

func batteryProps() -> [String: Any]? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                          IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var un: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &un, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = un?.takeRetainedValue() as? [String: Any] else { return nil }
    return d
}

/// `CLOCK_UPTIME_RAW` does not advance while asleep, so wall minus awake IS the
/// sleep. Carried per row so the analysis can drop any interval that straddled
/// one rather than fitting a voltage curve across hours nobody was watching.
func awakeSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

let columns = [
    "wall", "awake",
    "CurrentCapacity", "RemainingCapacity", "FullChargeCapacity", "DesignCapacity",
    "NominalChargeCapacity", "Voltage", "InstantAmperage", "Amperage", "BatteryPower",
    "TimeRemaining", "AvgTimeToEmpty", "CycleCount",
    "ExternalConnected", "IsCharging", "AtCriticalLevel", "FullyCharged",
    // The two hardware integrals the estimator actually runs on. Cumulative, so
    // a missed sample loses nothing — the unobserved ticks are still inside the
    // next difference.
    "AccumulatedBatteryDischarge", "BatteryDischargeAccumulatorCount",
    "AccumulatedSystemLoad", "SystemLoadAccumulatorCount",
]

let fm = FileManager.default
let isNew = !fm.fileExists(atPath: path) ||
    ((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) == 0
if isNew { fm.createFile(atPath: path, contents: nil) }
guard let fh = FileHandle(forWritingAtPath: path) else {
    FileHandle.standardError.write("cannot open \(path)\n".data(using: .utf8)!)
    exit(1)
}
fh.seekToEndOfFile()
if isNew { fh.write((columns.joined(separator: ",") + "\n").data(using: .utf8)!) }

func scalar(_ k: String, _ props: [String: Any], _ data: [String: Any],
            _ telemetry: [String: Any]) -> String {
    for src in [props, data, telemetry] {
        if let n = src[k] as? NSNumber { return "\(n)" }
        if let b = src[k] as? Bool { return b ? "1" : "0" }
    }
    return ""
}

FileHandle.standardError.write("logging to \(path) every \(Int(interval))s — ^C to stop\n"
    .data(using: .utf8)!)

var rows = 0
while true {
    if let props = batteryProps() {
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        var row = [String(format: "%.3f", Date().timeIntervalSince1970),
                   String(format: "%.3f", awakeSeconds())]
        row += columns.dropFirst(2).map { scalar($0, props, data, telemetry) }
        fh.write((row.joined(separator: ",") + "\n").data(using: .utf8)!)
        // The last minute is the point of the whole exercise, and this machine
        // is expected to lose power. Nothing stays in a buffer.
        fsync(fh.fileDescriptor)
        rows += 1
    }
    Thread.sleep(forTimeInterval: interval)
}
