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

// ── Fan key probe ───────────────────────────────────────────────────────────
if args.contains("--fankeys") {
    guard let smc = SMC() else { print("SMC unavailable"); exit(1) }
    print("FNum = \(smc.read("FNum").map { String($0.value) } ?? "absent")")
    for i in 0..<4 {
        for suffix in ["Ac", "Mn", "Mx", "Tg", "Md", "Sf"] {
            let k = "F\(i)\(suffix)"
            if let r = smc.read(k) {
                print(String(format: "  %-5@ type=%-5@ %.2f", k as NSString,
                             r.type as NSString, r.value))
            }
        }
    }
    exit(0)
}

// ── CPU watch ───────────────────────────────────────────────────────────────
// Exact CPU time over a fixed window, from the process's own rusage counters.
// `ps %cpu` is a decaying average and cannot A/B a 0.5 point change.
if let i = args.firstIndex(of: "--cpuwatch") {
    let name = args.count > i + 1 ? args[i + 1] : "BetterStatsApp"
    let secs = args.count > i + 2 ? Double(args[i + 2]) ?? 30 : 30
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-f", name]
    let pipe = Pipe(); pg.standardOutput = pipe
    try? pg.run()
    let outData = pipe.fileHandleForReading.readDataToEndOfFile()
    pg.waitUntilExit()
    guard let pid = (String(data: outData, encoding: .utf8) ?? "")
        .split(separator: "\n").compactMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }).first
    else { print("no process matching \(name)"); exit(1) }

    // ri_user_time + ri_system_time are MACH ABSOLUTE TIME units, not nanoseconds.
    // On Apple Silicon the timebase is 125/3, i.e. ~41.67 ns per unit, so treating
    // them as nanoseconds under-reports CPU by 41.7x — measured: a process pegging
    // one core read as 2.4%.
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let nsPerUnit = Double(tb.numer) / Double(tb.denom)
    func cpuNanos(_ pid: pid_t) -> UInt64? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? ri.ri_user_time &+ ri.ri_system_time : nil
    }
    guard let a = cpuNanos(pid) else { print("cannot read rusage"); exit(1) }
    let t0 = Date()
    Thread.sleep(forTimeInterval: secs)
    guard let b = cpuNanos(pid) else { print("process gone"); exit(1) }
    let wall = Date().timeIntervalSince(t0)
    let cpuSec = Double(b &- a) * nsPerUnit / 1e9
    print(String(format: "%@ pid %d: %.3f CPU-seconds over %.1f s wall = %.3f%% of one core (timebase %u/%u)",
                 name, pid, cpuSec, wall, 100 * cpuSec / wall, tb.numer, tb.denom))
    exit(0)
}

// ── Disk write watch ────────────────────────────────────────────────────────
// macOS killed the app for dirtying 2.1 GB in 40 minutes. This measures the
// real rate for a named process so a fix can be verified rather than assumed.
if let i = args.firstIndex(of: "--diskwatch") {
    let name = args.count > i + 1 ? args[i + 1] : "BetterStatsApp"
    let secs = args.count > i + 2 ? Double(args[i + 2]) ?? 30 : 30
    // pgrep rather than the sampler: this only needs one pid and the sampler's
    // shape is not worth matching for a diagnostic.
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-f", name]
    let pipe = Pipe(); pg.standardOutput = pipe
    try? pg.run()
    let outData = pipe.fileHandleForReading.readDataToEndOfFile()
    pg.waitUntilExit()
    let found = String(data: outData, encoding: .utf8)?
        .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } ?? []
    guard let pid = found.first else { print("no process matching \(name)"); exit(1) }

    func written(_ pid: pid_t) -> UInt64? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return rc == 0 ? ri.ri_diskio_byteswritten : nil
    }
    guard let a = written(pid) else { print("cannot read rusage for \(pid)"); exit(1) }
    print("watching \(name) pid \(pid) for \(Int(secs))s…")
    Thread.sleep(forTimeInterval: secs)
    guard let b = written(pid) else { print("lost the process"); exit(1) }
    let kbs = Double(b &- a) / 1024 / secs
    print(String(format: "wrote %.1f MB in %.0fs = %.1f KB/s", Double(b &- a)/1048576, secs, kbs))
    print(String(format: "macOS sustained limit is 24.9 KB/s -> %@",
                 kbs > 24.9 ? "OVER by \(Int(kbs/24.9))x" : "within budget"))
    exit(0)
}

// ── Per-process network check ───────────────────────────────────────────────
if args.contains("--netproc") {
    guard NetworkAttribution.isAvailable else { print("nettop unavailable"); exit(1) }
    let na = NetworkAttribution(refreshInterval: 0)
    print("sampling (nettop blocks ~5 s per sample, twice for a rate)…")
    na.refreshIfNeeded()          // baseline
    Thread.sleep(forTimeInterval: 9)
    na.refreshIfNeeded()          // rate
    Thread.sleep(forTimeInterval: 9)
    let rows = na.latest
    guard !rows.isEmpty else { print("no processes moved traffic in that window"); exit(0) }
    print(String(format: "\n%-32@ %7@ %14@ %14@", "process" as NSString, "pid" as NSString,
                 "down" as NSString, "up" as NSString))
    for r in rows.prefix(20) {
        print(String(format: "%-32@ %7d %14@ %14@", r.name as NSString, r.pid,
                     MetricUnit.bytesPerSecond.format(r.bytesInPerSec) as NSString,
                     MetricUnit.bytesPerSecond.format(r.bytesOutPerSec) as NSString))
    }
    print(String(format: "\n%d processes with traffic", rows.count))
    exit(0)
}

// ── Attribution overflow diagnostic ─────────────────────────────────────────
// Is rusage-attributed CPU energy actually comparable to the PPMC rail? If
// attributed routinely exceeds it, the "system processes" bucket is empty by
// construction and the two are not measuring the same thing.
if let i = args.firstIndex(of: "--overflow") {
    let n = args.count > i + 1 ? Int(args[i + 1]) ?? 40 : 40
    guard let monitor = PowerMonitor(scale: scale) else { exit(1) }
    let dbgSMC = SMC()
    monitor.tick()
    var ratios: [Double] = []
    var hatches: [Double] = []
    var over = 0
    print("  attributed   cpuRail    pstr   ratio")
    for _ in 0..<n {
        Thread.sleep(forTimeInterval: 2)
        guard let s = monitor.tick(), let cpu = s.cpuRail_W else { continue }
        let ratio = cpu > 0 ? s.attributed_W / cpu : Double.nan
        if ratio.isFinite { ratios.append(ratio); if ratio > 1 { over += 1 } }
        let rawP = dbgSMC?.read("PSTR")?.value ?? 0
        let rawC = dbgSMC?.read("PPMC")?.value ?? 0
        let tot = max(s.smoothed_W, 0.001)
        let sys = s.systemProcesses_W ?? 0
        let plat = s.platform_W ?? 0
        print(String(format: "attr %6.3f  cpuRail %6.3f  smoothed %6.2f | rawPSTR %6.2f rawPPMC %6.2f share %.2f | apps %3.0f%% sys %3.0f%% hatch %3.0f%%",
                     s.attributed_W, cpu, s.smoothed_W, rawP, rawC,
                     rawP > 0 ? rawC / rawP : 0,
                     100 * s.attributed_W / tot, 100 * sys / tot, 100 * plat / tot))
        hatches.append(100 * plat / tot)
    }
    guard !ratios.isEmpty else { print("no samples"); exit(1) }
    let sorted = ratios.sorted()
    print(String(format: "\nn=%d  median ratio %.2f  min %.2f  max %.2f  overflowed %d/%d ticks",
                 ratios.count, sorted[sorted.count/2], sorted.first!, sorted.last!,
                 over, ratios.count))
    if !hatches.isEmpty {
        let h = hatches.sorted()
        let mean = hatches.reduce(0,+) / Double(hatches.count)
        let sd = (hatches.map { ($0 - mean) * ($0 - mean) }.reduce(0,+) / Double(hatches.count)).squareRoot()
        print(String(format: "hatch share: median %.0f%%  min %.0f%%  max %.0f%%  sd %.1f points  <-- the wobble",
                     h[h.count/2], h.first!, h.last!, sd))
    }
    exit(0)
}

// ── Live attribution check ──────────────────────────────────────────────────
// Ticks the real monitor and prints the named shares of the two anonymous
// buckets, so the end-to-end path can be verified without the GUI.
if args.contains("--sysattr") {
    guard let monitor = PowerMonitor(scale: scale) else { exit(1) }
    // The first tick returns nil (no prior sweep to diff) BEFORE reaching the
    // refresh call, so the rollup is only requested on the second tick and lands
    // asynchronously after it. Three ticks is the shortest honest sequence.
    monitor.tick()
    Thread.sleep(forTimeInterval: 1)
    monitor.tick()
    Thread.sleep(forTimeInterval: 3)
    guard let s = monitor.tick() else { print("no snapshot"); exit(1) }

    print(String(format: "total %.2f W · cpu rail %@ · gpu %@ · attributed %.2f W",
                 s.smoothed_W,
                 s.cpuRail_W.map { String(format: "%.2f W", $0) } ?? "—",
                 s.gpu_W.map { String(format: "%.2f W", $0) } ?? "—",
                 s.attributed_W))
    print(String(format: "rollup age: %@",
                 s.systemAttributionAge.map { String(format: "%.1fs", $0) } ?? "never"))

    print(String(format: "\nSYSTEM PROCESSES  bucket %@ (measured, CPU rail minus attributed)",
                 s.systemProcesses_W.map { String(format: "%.3f W", $0) } ?? "—"))
    for r in s.systemApps.prefix(12) {
        print(String(format: "  %-30@ %7.3f W  %6.2f %%/hr  (cpu %llu ms)",
                     r.name as NSString, r.watts, r.percentPerHour, r.cpu_ms))
    }
    let named = s.systemApps.reduce(0) { $0 + $1.watts }
    print(String(format: "  -> %d rows, %.3f W named of %.3f W measured (%.0f%%)",
                 s.systemApps.count, named, s.systemProcesses_W ?? 0,
                 (s.systemProcesses_W ?? 0) > 0 ? 100 * named / (s.systemProcesses_W ?? 1) : 0))

    print(String(format: "\nGPU  bucket %@ (measured rail, split by coalition GPU time)",
                 s.gpu_W.map { String(format: "%.3f W", $0) } ?? "—"))
    for r in s.gpuApps.prefix(8) {
        print(String(format: "  %-30@ %7.3f W  %6.2f %%/hr  (gpu %llu ms)",
                     r.name as NSString, r.watts, r.percentPerHour, r.gpu_ms))
    }
    exit(0)
}

// ── Coalition usage dump ────────────────────────────────────────────────────
// Apple's own per-app rollup, including the root coalitions proc_pid_rusage
// cannot see. --coalitions <minutes>
if let i = args.firstIndex(of: "--coalitions") {
    let mins = args.count > i + 1 ? Double(args[i + 1]) ?? 10 : 10
    guard SystemStats.isAvailable else { print("systemstats unavailable"); exit(1) }
    let since = Date().addingTimeInterval(-mins * 60)
    let rows = SystemStats.usage(since: since)
    if let st = SystemStats.lastRunStats {
        print(String(format: "%d lines, %d records, spawn %.2fs, parse %.3fs%@",
                     st.lines, st.records, st.spawn_s, st.parse_s,
                     st.timedOut ? " (TIMED OUT)" : ""))
    }
    print(String(format: "\n%-40@ %9@ %9@ %8@  %@",
                 "app" as NSString, "cpu ms" as NSString, "gpu ms" as NSString,
                 "share" as NSString, "kind" as NSString))
    for r in rows.prefix(30) {
        print(String(format: "%-40@ %9llu %9llu %7.2f%%  %@",
                     r.displayName as NSString, r.cpu_ms, r.gpu_ms,
                     r.energyShare * 100, r.isSystem ? "system" : "user"))
    }
    print(String(format: "\n%d coalitions total", rows.count))
    exit(0)
}

// ── Passive rail recorder ───────────────────────────────────────────────────
// --raillog <seconds> <interval>  → CSV on stdout.
if let i = args.firstIndex(of: "--raillog") {
    let secs = args.count > i + 1 ? Double(args[i + 1]) ?? 3600 : 3600
    let ivl  = args.count > i + 2 ? Double(args[i + 2]) ?? 5 : 5
    RailLog.run(seconds: secs, interval: ivl)
    exit(0)
}

// ── Display rail discovery ──────────────────────────────────────────────────
// Modulates screen brightness and reports which rails follow it. See
// DisplayExperiment for why brightness rather than a key-name guess.
if args.contains("--displayexp") {
    DisplayExperiment.run()
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
    // Constants are excluded. PZT0 reads 343.0000, PHPB 200.0000 and PHPM
    // 0.8900 in every sample across a 30x range of real system power — they are
    // limits or setpoints, not sensors. Summing them added 543 W of nonsense to
    // a figure whose whole purpose is to be quoted as "what the machine draws".
    //
    // They are identified by being constant, not by key, so a different Mac's
    // constants are excluded too without a hardcoded list.
    let constantKeys: Set<String> = ["PZT0", "PHPB", "PHPM"]
    let live = power.filter { $0.value > 0 && !constantKeys.contains($0.key) }
    let total = live.reduce(0) { $0 + $1.value }
    print(String(format: "\n  sum of positive P* sensors: %.2f W  (%d rails; %d known constants excluded)",
                 total, live.count, constantKeys.count))
    print("  NOTE: this sum double-counts — many of these rails are phase")
    print("  aggregates that each cover part of the same draw. PSTR is the total.")

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
