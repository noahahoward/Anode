import Foundation
import PowerKit

// Plain-text milestone 0: prove the measurement pipeline end to end.
// Every number printed here is measured or derived from a measured quantity.
// Nothing is normalized to a total, and nothing is invented.

let args = CommandLine.arguments
let window = args.firstIndex(of: "-w").flatMap { i -> Double? in
    i + 1 < args.count ? Double(args[i + 1]) : nil
} ?? 5.0
let topN = args.firstIndex(of: "-n").flatMap { i -> Int? in
    i + 1 < args.count ? Int(args[i + 1]) : nil
} ?? 15

func rule(_ s: String = "") {
    if s.isEmpty { print(String(repeating: "─", count: 78)) }
    else { print("\n\(s)\n" + String(repeating: "─", count: 78)) }
}

// ── Battery scale ───────────────────────────────────────────────────────────
guard let scale = Battery.scale(), let state = Battery.state() else {
    FileHandle.standardError.write(Data("no AppleSmartBattery found (desktop Mac?)\n".utf8))
    exit(1)
}

// ── Metric registry dump ────────────────────────────────────────────────────
if args.contains("--metrics") {
    guard let monitor = PowerMonitor(scale: scale) else { exit(1) }
    let sys = SystemMetrics()
    monitor.tick(); _ = sys.sample()          // prime: both need an interval
    Thread.sleep(forTimeInterval: 2.0)
    if let snap = monitor.tick() { MetricRegistry.shared.update(with: snap) }
    MetricRegistry.shared.update(system: sys.sample())

    rule("REGISTERED METRICS")
    var cat = ""
    for d in MetricRegistry.shared.descriptors() {
        if d.category != cat { cat = d.category; print("\n  [\(cat)]") }
        let v = MetricRegistry.shared.value(for: d.id)
        let shown = v.map { $0.text + ($0.isEstimate ? " *" : "") } ?? "— (no data)"
        let lbl = v?.label ?? d.shortTitle
        print(String(format: "    %-26@ %-14@ %@", d.id.rawValue as NSString,
                     lbl as NSString, shown as NSString))
    }
    print("")
    exit(0)
}

// ── Fast rail dump ──────────────────────────────────────────────────────────
// --smc runs a 60-95 s gauge validation, so it cannot be used to sample rails
// around a timed load; each "snapshot" spans minutes. This is the quick one.
if args.contains("--rails") {
    guard let smc = SMC() else { print("SMC unavailable"); exit(1) }
    for s in smc.scan()
        where s.key.hasPrefix("P") && s.type == "flt" && s.value.isFinite && abs(s.value) > 0.005 {
        print(String(format: "%@ %.4f", s.key, s.value))
    }
    exit(0)
}

// ── SMC discovery ───────────────────────────────────────────────────────────
if args.contains("--smc") {
    guard let smc = SMC() else {
        print("SMC: could not open AppleSMC user client"); exit(1)
    }
    print(smc.diagnose())
    let n = smc.keyCount()
    print("SMC keys: \(n)")
    let all = smc.scan()
    let power = all.filter { $0.key.hasPrefix("P") && $0.type == "flt" }
    print("\nPOWER SENSORS (P* / flt)  — \(power.count) of \(all.count) decoded")
    for s in power.sorted(by: { $0.value > $1.value }) where s.value.isFinite {
        print(String(format: "  %-6@ %10.3f W", s.key as NSString, s.value))
    }
    let total = power.filter { $0.value > 0 }.reduce(0) { $0 + $1.value }
    print(String(format: "\n  sum of positive P* sensors: %.2f W", total))

    // Validate PSTR against the battery gas gauge over one publish window. PSTR is
    // fast but undocumented; the gauge is slow but authoritative. If their means
    // agree, PSTR can safely replace the gauge as the live anchor.
    print("\n  validating PSTR against the 60 s gas gauge…")
    var samples: [Double] = []
    let start = PowerTelemetry.sample()
    var elapsed = 0.0
    while elapsed < 95 {
        if let v = smc.read("PSTR")?.value, v.isFinite, v > 0 { samples.append(v) }
        Thread.sleep(forTimeInterval: 1.0); elapsed += 1.0
        if let a = start, let b = PowerTelemetry.sample(),
           let w = SystemPowerWindow.between(a, b), elapsed > 60 {
            let mean = samples.reduce(0,+) / Double(samples.count)
            print(String(format: "  PSTR mean over %.0fs : %.3f W  (n=%d, min %.2f, max %.2f)",
                         elapsed, mean, samples.count, samples.min() ?? 0, samples.max() ?? 0))
            print(String(format: "  gas gauge mean       : %.3f W  (%llu ticks)", w.power_mW/1000, w.ticks))
            print(String(format: "  ratio PSTR/gauge     : %.3f", mean / (w.power_mW/1000)))
            break
        }
    }
    exit(0)
}

// ── Watch mode ──────────────────────────────────────────────────────────────
if args.contains("--watch") || args.contains("-f") {
    guard let monitor = PowerMonitor(scale: scale) else { exit(1) }
    monitor.tick()  // prime
    func p(_ s: String, _ w: Int) -> String {
        s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
    }
    func rp(_ s: String, _ w: Int) -> String {
        s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s
    }
    // --log: one line per tick, no screen clear. Used to verify stability of the
    // displayed figure against the raw gauge over time.
    let logMode = args.contains("--log")
    if logMode {
        print("  tick   raw_fast    gauge   smoothed    jump   gpu_W  calib")
    }
    var tick = 0
    while true {
        Thread.sleep(forTimeInterval: window)
        guard let s = monitor.tick() else { continue }
        if logMode {
            tick += 1
            let g = s.measured_W.map { String(format: "%7.3f", $0) } ?? "      —"
            let gpu = s.gpu_W.map { String(format: "%6.2f", $0) } ?? "     —"
            print(String(format: "  %4d  %8.3f  %@  %9.3f  %@  %@  %@",
                         tick, s.fast_W, g, s.smoothed_W,
                         s.didJump ? "JUMP" : "    ", gpu,
                         s.isCalibrated ? "yes" : "no"))
            continue
        }
        print("\u{001B}[H\u{001B}[2J", terminator: "")  // home + clear
        let st = s.state
        let charge = st.map { "\($0.percent)%\($0.onAC ? " AC" : " batt")" } ?? "—"
        print("BetterStats — battery \(charge)   window \(String(format: "%.1f", s.interval))s   "
              + String(format: "%d readable of %d, %d denied, %d active",
                       s.readable, s.attempted, s.denied, s.active))
        print(String(repeating: "─", count: 68))
        print("  " + p("PROCESS", 30) + rp("%/hr", 9) + rp("JOULES", 10) + rp("PID", 8))
        for d in s.drains.prefix(topN) {
            let pct = d.percentPerHour < 0.01 ? "<0.01" : String(format: "%.2f", d.percentPerHour)
            print("  " + p(d.name, 30) + rp(pct, 9)
                  + rp(String(format: "%.2f", d.joules), 10) + rp("\(d.pid)", 8))
        }
        print(String(repeating: "─", count: 68))
        print(String(format: "  attributed    %6.2f %%/hr  (%.3f W)", s.attributed_pctHr, s.attributed_W))
        if let mp = s.measured_pctHr, let mW = s.measured_W, let rp2 = s.residual_pctHr,
           let share = s.residualShare {
            let age = s.measuredAge.map { String(format: "  %.0fs old", $0) } ?? ""
            print(String(format: "  measured      %6.2f %%/hr  (%.3f W)%@", mp, mW, age))
            print(String(format: "  unattributed  %6.2f %%/hr  (%.0f%%)", rp2, share * 100))
            if let hr = s.projectedRuntime_hr() {
                print(String(format: "  projected     %dh %02dm at this draw", Int(hr), Int(hr * 60) % 60))
            }
        } else {
            print("  measured      waiting for 60 s telemetry batch…")
        }
        print("\n  ctrl-C to quit")
    }
}

rule("BATTERY SCALE  — the real \"100%\"")
print(String(format: "  full charge      %.0f mAh   (design %.0f mAh, health %.1f%%)",
             scale.fullChargeCapacity_mAh, scale.designCapacity_mAh, scale.health * 100))
print(String(format: "  energy at full   %.1f Wh  = %.0f J", scale.energyFull_Wh, scale.energyFull_J))
print(String(format: "  1%% of battery    %.0f J", scale.joulesPerPercent))
print(String(format: "  1 W sustained    %.2f %%/hr", 3600.0 / scale.joulesPerPercent))
print("  V_nom            \(scale.nominalVoltage_V) V  [SEED — not yet self-calibrated]")

rule("BATTERY STATE")
let src = state.onAC ? "AC" : "battery"
print("  charge           \(state.percent)%  (\(src)\(state.isCharging ? ", charging" : ""))")
print(String(format: "  voltage          %.3f V", Double(state.voltage_mV) / 1000))
print("  cycles           \(state.cycleCount)")
if let t = state.timeRemaining_min {
    print("  time remaining   \(t / 60)h \(t % 60)m")
} else {
    print("  time remaining   unknown (SBS sentinel 65535 — expected on AC)")
}

// ── Whole-system power ──────────────────────────────────────────────────────
let power0 = PowerTelemetry.sample()
if let p = power0 {
    rule("WHOLE-SYSTEM POWER  — the conservation anchor")
    print(String(format: "  scalar snapshot  %.0f mW", p.systemLoad_mW))
    print(String(format: "  lifetime avg     %.0f mW   [NOT current draw — cumulative ratio]",
                 Double(p.accumulatedSystemLoad) / Double(p.accumulatorCount)))
    print("  publish cadence  ~60 s in 60-tick batches; a measured window needs a new batch")
}

// ── Per-process energy ──────────────────────────────────────────────────────
rule("SAMPLING  \(window)s …")
let a = ProcessSampler.sweep()
Thread.sleep(forTimeInterval: window)
let b = ProcessSampler.sweep()

let drains = DrainCalculator.between(a, b, scale: scale)
let attributedW = drains.reduce(0) { $0 + $1.watts }

func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
}
func rpad(_ s: String, _ w: Int) -> String {
    s.count >= w ? String(s.prefix(w)) : String(repeating: " ", count: w - s.count) + s
}

let apps = DrainCalculator.group(drains, scale: scale)

rule("PER-APP DRAIN  — processes rolled up to owning app, top \(topN)")
print("  " + pad("APP", 32) + rpad("%/hr", 9) + rpad("JOULES", 10) + rpad("PROCS", 7) + "  KIND")
for a in apps.prefix(topN) {
    let pct = a.percentPerHour < 0.01 ? "<0.01" : String(format: "%.2f", a.percentPerHour)
    print("  " + pad(a.name, 32)
        + rpad(pct, 9)
        + rpad(String(format: "%.2f", a.joules), 10)
        + rpad(a.processCount > 1 ? "\(a.processCount)" : "—", 7)
        + "  " + (a.isApp ? "app" : "daemon"))
}

// ── The ledger ──────────────────────────────────────────────────────────────
rule("LEDGER  — rows sum to the MEASURED total, never normalized to 100%")
print(String(format: "  attributed (own uid)   %7.3f W   %6.2f %%/hr",
             attributedW, 3600.0 * attributedW / scale.joulesPerPercent))

var window2 = power0.flatMap { p0 -> SystemPowerWindow? in
    PowerTelemetry.sample().flatMap { SystemPowerWindow.between(p0, $0) }
}
if let w = window2 {
    let measuredW = w.power_mW / 1000
    let residual = measuredW - attributedW
    print(String(format: "  measured system total  %7.3f W   %6.2f %%/hr",
                 measuredW, 3600.0 * measuredW / scale.joulesPerPercent))
    print(String(format: "  UNATTRIBUTED residual  %7.3f W   %6.2f %%/hr   (%.0f%% of total)",
                 residual, 3600.0 * residual / scale.joulesPerPercent,
                 measuredW > 0 ? residual / measuredW * 100 : 0))
    print("     display backlight, radios, SSD, DRAM, kernel, root-owned processes")
} else {
    print("  measured system total  —  no new 60 s batch published during this run")
    print("     rerun with  -w 70  to cross a publish boundary")
}

print(String(format: "\n  coverage  %d of %d processes readable (%.0f%%), %d denied EPERM",
             a.processes.count, a.attempted, a.coverage * 100, a.denied))
print("     denied = root-owned (WindowServer, bluetoothd, …) — needs the helper,")
print("     or CoalitionUsage for the retrospective view")
print("")
