import AppKit
import Foundation

/// Apple's own per-coalition energy history, read from the on-disk systemstats
/// store via `systemstats --show-events`.
///
/// Why this exists: proc_pid_rusage covers only ~63% of pids on this machine —
/// everything root-owned or other-uid (WindowServer, bluetoothd, airportd,
/// locationd, mds_stores…) returns EPERM. WindowServer does ALL window
/// compositing and is routinely the single largest real consumer, so a product
/// that cannot see it is lying by omission. sysmond, running as root, has no
/// such blind spot, and it journals its per-coalition accounting to
/// /var/db/systemstats/*.stats — which are mode 644 root:wheel, i.e.
/// WORLD-READABLE. `systemstats --show-events` parses that corpus and runs fine
/// as an ordinary user. (Activity Monitor's private entitlements gate the LIVE
/// sysmond XPC stream, not this on-disk history.) Bonus: per-coalition GPU time,
/// and history that predates our own app's install.
///
/// Traps, all load-bearing:
///  - The `energy` field is Apple's cumulative UNITLESS Energy Impact score.
///    It is NOT joules and must NEVER be displayed as an absolute unit. Its only
///    legitimate use is apportionment: a coalition's share of the total score
///    delta, multiplied by a MEASURED total (SMC PSTR), yields real joules.
///  - Every counter is CUMULATIVE per coalition id (cid), so consecutive records
///    for the same cid must be differenced. A decrease means the counter reset
///    (reboot; cids restart small and counters restart at 0), so the prior value
///    is treated as 0 and the current value stands as the delta.
///  - `guessedBundleId` is the identity key. `bundleId`/`displayName`/`label`
///    are (null) for essentially everything; guessedBundleId is populated for
///    essentially everything. This is Apple's own app-rollup, handed to us free.
///  - The record format is undocumented and WILL change. Every field is located
///    by its own suffix/prefix keyword, never by position, and any line that
///    does not parse yields fewer rows, never a crash.
public struct CoalitionSample {
    public let timestamp: Date
    public let cid: Int
    public let cpu_ms: UInt64
    public let gpu_ms: UInt64
    /// Apple's cumulative unitless Energy Impact score. Apportionment weight
    /// ONLY — never display as an absolute quantity.
    public let energyScore: Double
    /// guessedBundleId (or the rare real bundleId), cleaned: "(null)" dropped,
    /// team-ID prefixes like "2BUA8C4S2C." stripped.
    public let bundleID: String?
    public let displayName: String?
    public let pkgIdleWkups: UInt64
    public let interruptWkups: UInt64
    public let diskReadBytes: UInt64
    /// immediate + deferred + metadata writes. Invalidated writes are excluded
    /// because they were cancelled before ever reaching the disk.
    public let diskWriteBytes: UInt64
}

/// Per-app usage over a window: consecutive records per cid differenced, then
/// rolled up by bundle id. `energyShare` is the apportionment weight — multiply
/// by a measured whole-system total to get real joules.
public struct CoalitionUsage {
    public let bundleID: String
    /// Human name: the app bundle's Finder name when one exists for this bundle
    /// id, otherwise the last reverse-DNS component ("com.apple.WindowServer"
    /// -> "WindowServer").
    public let displayName: String
    public let cpu_ms: UInt64
    public let gpu_ms: UInt64
    /// 0…1: this coalition's fraction of the total energy-score delta across
    /// the window. Weight, not a measurement of absolute energy.
    public let energyShare: Double
    public let isSystem: Bool
}

public enum SystemStats {

    // ── Availability ────────────────────────────────────────────────────────

    private static let binaryPath = "/usr/sbin/systemstats"
    private static let storePath = "/var/db/systemstats"

    /// True if the systemstats binary exists and the store has at least one
    /// readable .stats file. Checked fresh every time — a macOS update could
    /// remove either tomorrow, and this whole source must then vanish quietly.
    public static var isAvailable: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binaryPath) else { return false }
        guard let entries = try? fm.contentsOfDirectory(atPath: storePath) else { return false }
        return entries.contains {
            $0.hasSuffix(".stats") && fm.isReadableFile(atPath: storePath + "/" + $0)
        }
    }

    /// Diagnostics from the most recent events()/usage() call. The subprocess
    /// dominates wall time; parse_s is our own scanning cost only.
    public struct RunStats {
        public let lines: Int          // total lines emitted by systemstats
        public let records: Int        // CoalitionUsage records parsed
        public let spawn_s: Double     // subprocess wall time (spawn -> EOF)
        public let parse_s: Double     // our parsing time
        public let timedOut: Bool
    }
    public private(set) static var lastRunStats: RunStats?
    private static let statsLock = NSLock()

    // ── Public API ──────────────────────────────────────────────────────────

    /// Runs `systemstats --show-events` over [since, until] and returns raw
    /// parsed CoalitionUsage records in emission (chronological) order.
    /// Blocks up to `timeout` seconds — call it off the UI thread. On timeout
    /// the subprocess is killed and whatever parsed so far is returned: fewer
    /// rows, never a hang and never a crash.
    public static func events(since: Date, until: Date? = nil,
                              timeout: TimeInterval = 30) -> [CoalitionSample] {
        rawEvents(since: since, until: until, timeout: timeout).map { $0.sample }
    }

    /// Differences per-cid, rolls up per-app, sorted by energyShare descending.
    public static func usage(since: Date, until: Date? = nil,
                             timeout: TimeInterval = 30) -> [CoalitionUsage] {
        let raws = rawEvents(since: since, until: until, timeout: timeout)

        // Per-cid deltas. Records arrive chronologically, but sort defensively:
        // an out-of-order pair would masquerade as a counter reset and inflate
        // the delta.
        var byCid: [Int: [Raw]] = [:]
        for r in raws { byCid[r.sample.cid, default: []].append(r) }

        var byApp: [String: Acc] = [:]

        for (_, group) in byCid {
            // Sort only if actually disordered: Swift's sort is unstable, and
            // same-second records must keep stream order or the differencing
            // sees phantom decreases.
            var inOrder = true
            for i in 1..<group.count where group[i - 1].sample.timestamp > group[i].sample.timestamp {
                inOrder = false; break
            }
            let g = inOrder ? group : group.sorted { $0.sample.timestamp < $1.sample.timestamp }

            // A coalition's usage between `since` and its FIRST record inside
            // the window is invisible unless the coalition was BORN inside the
            // window. Birth time = record timestamp - cumulative runtime (the
            // HH:MM:SS field advances with wall clock; verified against cid 1).
            // Born inside -> its first record's cumulative values ARE the delta
            // from zero. Born before -> first record is baseline only and the
            // pre-record slice is undercounted, which is the honest direction:
            // we drop what we didn't observe rather than invent it. 5 s slack
            // covers the 1 s rounding on both fields.
            guard let first = g.first else { continue }
            // runtime_s == 0 means either a genuinely 0-second-old coalition
            // (whose cumulative counters are ~0 anyway) or a failed runtime
            // parse; both must NOT get the full-cumulative credit, because a
            // parse failure crediting full history would overcount massively.
            if first.runtime_s > 0,
               born(of: first) >= since.addingTimeInterval(-5) {
                credit(&byApp, appKey(first.sample.bundleID),
                       first.sample.cpu_ms, first.sample.gpu_ms,
                       max(0, first.sample.energyScore))
            }

            var prev = first
            for r in g.dropFirst() {
                // Each interval is credited to the LATER record's identity, not
                // the group's first: cid numbers restart after a reboot and DO
                // collide — measured 310 cids in one 10 h window whose
                // guessedBundleId changed across the 22:01 boot boundary.
                let key = appKey(r.sample.bundleID)

                // Rebirth: this record's coalition was born AFTER the previous
                // record was written, so it is a DIFFERENT incarnation of a
                // reused cid and its cumulative values count in full. Counter
                // direction cannot detect this case: measured live, cid 749 was
                // chronod at 40k score pre-reboot and a VSCode coalition at
                // 390k score post-reboot — an INCREASE across the boundary.
                // Only the runtime field exposes it.
                if r.runtime_s > 0,
                   born(of: r) > prev.sample.timestamp.addingTimeInterval(5) {
                    credit(&byApp, key, r.sample.cpu_ms, r.sample.gpu_ms,
                           max(0, r.sample.energyScore))
                } else {
                    credit(&byApp, key,
                           delta(prev.sample.cpu_ms, r.sample.cpu_ms),
                           delta(prev.sample.gpu_ms, r.sample.gpu_ms),
                           deltaScore(prev.sample.energyScore, r.sample.energyScore))
                }
                prev = r
            }
        }

        let totalEnergy = byApp.values.reduce(0) { $0 + $1.energy }
        return byApp.compactMap { key, acc -> CoalitionUsage? in
            // Zero across the board = coalition merely existed. Not a row.
            guard acc.cpu > 0 || acc.gpu > 0 || acc.energy > 0 else { return nil }
            return CoalitionUsage(
                bundleID: key,
                displayName: displayName(forBundleID: key),
                cpu_ms: acc.cpu,
                gpu_ms: acc.gpu,
                energyShare: totalEnergy > 0 ? acc.energy / totalEnergy : 0,
                isSystem: key == unknownKey || key.hasPrefix("com.apple."))
        }
        .sorted { $0.energyShare > $1.energyShare }
    }

    // ── Internals ───────────────────────────────────────────────────────────

    /// The events we hand out plus the one field the public struct doesn't
    /// carry: cumulative coalition runtime, needed for birth-time detection.
    private struct Raw {
        let sample: CoalitionSample
        let runtime_s: UInt64
    }

    private struct Acc { var cpu: UInt64 = 0; var gpu: UInt64 = 0; var energy: Double = 0 }

    private static func credit(_ byApp: inout [String: Acc], _ key: String,
                               _ cpu: UInt64, _ gpu: UInt64, _ energy: Double) {
        var acc = byApp[key] ?? Acc()
        acc.cpu += cpu
        acc.gpu += gpu
        acc.energy += energy
        byApp[key] = acc
    }

    /// The coalition incarnation's birth time. The HH:MM:SS runtime field
    /// advances 1:1 with wall clock (verified against cid 1 over 35 min), so
    /// timestamp minus runtime is when this incarnation started.
    private static func born(of r: Raw) -> Date {
        r.sample.timestamp.addingTimeInterval(-Double(r.runtime_s))
    }

    /// Coalitions sysmond couldn't identify still burned real energy; they get
    /// a named bucket instead of silently vanishing (philosophy: residuals are
    /// shown, never redistributed).
    private static let unknownKey = "unknown"

    private static func appKey(_ bundleID: String?) -> String {
        guard let id = bundleID, !id.isEmpty else { return unknownKey }
        return id
    }

    // Reset rule, shared shape for both counters and the float score: cumulative
    // values only grow within one boot. A decrease to NEAR ZERO means the
    // counter restarted (reboot — verified live: WindowServer's score fell
    // 7,843,261 -> 3,026 across the 22:01 boot), so the current cumulative
    // value is the whole delta. A SMALL decrease is float jitter or a torn
    // record; crediting the full cumulative value there would be a massive
    // misattribution, so it counts as 0 — the honest undercount.
    private static func delta(_ prev: UInt64, _ cur: UInt64) -> UInt64 {
        if cur >= prev { return cur - prev }
        return cur < prev / 2 ? cur : 0
    }

    private static func deltaScore(_ prev: Double, _ cur: Double) -> Double {
        if cur >= prev { return cur - prev }
        return cur < prev / 2 ? max(0, cur) : 0
    }

    // systemstats prints local time and parses -s/-e as local time.
    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func rawEvents(since: Date, until: Date?,
                                  timeout: TimeInterval) -> [Raw] {
        guard isAvailable else { return [] }

        var args = ["--show-events", "-s", format(since)]
        if let until { args += ["-e", format(until)] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        let spawnStart = DispatchTime.now()
        do { try proc.run() } catch { return [] }

        // Hard deadline. systemstats normally finishes a 13 h dump in under a
        // second, but it reads an undocumented store that could someday make it
        // hang, and this call may sit under a UI. Kill, keep what we got.
        var timedOut = false
        let killer = DispatchWorkItem { timedOut = true; proc.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: killer)

        // Drain the pipe INCREMENTALLY. Waiting for exit before reading would
        // deadlock once the dump exceeds the 64 KiB pipe buffer.
        var data = Data()
        let fh = pipe.fileHandleForReading
        while true {
            let chunk = fh.availableData
            if chunk.isEmpty { break }   // EOF (normal exit or our terminate)
            data.append(chunk)
        }
        proc.waitUntilExit()
        killer.cancel()
        let spawn_s = Double(DispatchTime.now().uptimeNanoseconds &- spawnStart.uptimeNanoseconds) / 1e9

        // Parse. Output is ASCII except possibly display names; lossy decode of
        // a torn multibyte sequence corrupts at most one line, which the parser
        // then drops. Exactly the intended failure mode.
        let parseStart = DispatchTime.now()
        var out: [Raw] = []
        out.reserveCapacity(4096)
        var lineCount = 0
        var tsCache: (str: Substring, date: Date)? = nil
        String(decoding: data, as: UTF8.self).forEachLine { line in
            lineCount += 1
            if let raw = parseLine(line, tsCache: &tsCache) { out.append(raw) }
        }
        let parse_s = Double(DispatchTime.now().uptimeNanoseconds &- parseStart.uptimeNanoseconds) / 1e9

        statsLock.lock()
        lastRunStats = RunStats(lines: lineCount, records: out.count,
                                spawn_s: spawn_s, parse_s: parse_s, timedOut: timedOut)
        statsLock.unlock()
        return out
    }

    // ── Line parser ─────────────────────────────────────────────────────────
    // One real line (tabs separate timestamp / type / payload):
    //   2026-08-05 19:00:02\tCoalitionUsage\t      P cid:1, 125043 msec (cpu),
    //   0 msec me, 2778 msec others, 61048 msec (gpu), 12:16:07, 1363528.82
    //   energy, 997.73Mi reads, 0.00B immediatewrites, 80.61Mi deferredwrites,
    //   6.52Gi metadatawrites, 0.00B invalidatedwrites, 1910769 pkgIdleWkups,
    //   79006945 interruptWkups, label:(null), bundleId:(null),
    //   displayName:(null), responsibleBundleId:(null),
    //   guessedBundleId:com.apple.system

    private static func parseLine(_ line: Substring,
                                  tsCache: inout (str: Substring, date: Date)?) -> Raw? {
        // Cheap structural check first: three tab-separated fields, exact type.
        guard let tab1 = line.firstIndex(of: "\t") else { return nil }
        let afterTab1 = line.index(after: tab1)
        guard let tab2 = line[afterTab1...].firstIndex(of: "\t"),
              line[afterTab1..<tab2] == "CoalitionUsage" else { return nil }

        let tsStr = line[..<tab1]
        guard let ts = timestamp(tsStr, cache: &tsCache) else { return nil }

        var cid: Int? = nil
        var cpu: UInt64 = 0, gpu: UInt64 = 0
        var energy: Double? = nil
        var pkgIdle: UInt64 = 0, intr: UInt64 = 0
        var reads: UInt64 = 0, writes: UInt64 = 0
        var runtime: UInt64 = 0
        var bundleID: String? = nil
        var guessedID: String? = nil
        var display: String? = nil

        // Every field self-identifies by keyword, so reordered or newly
        // inserted fields in a future macOS degrade to "that one field is
        // missing", not "every field after it is garbage".
        let payload = line[line.index(after: tab2)...]
        var start = payload.startIndex
        while start < payload.endIndex {
            let end = payload[start...].firstIndex(of: ",") ?? payload.endIndex
            var tok = payload[start..<end]
            while tok.first == " " { tok = tok.dropFirst() }

            if tok.hasPrefix("guessedBundleId:") {
                guessedID = cleanBundleID(tok.dropFirst("guessedBundleId:".count))
            } else if tok.hasPrefix("bundleId:") {
                bundleID = cleanBundleID(tok.dropFirst("bundleId:".count))
            } else if tok.hasPrefix("displayName:") {
                let v = tok.dropFirst("displayName:".count)
                if v != "(null)", !v.isEmpty { display = String(v) }
            } else if tok.hasPrefix("label:") || tok.hasPrefix("responsibleBundleId:") {
                // recognized, unused
            } else if tok.hasSuffix(" msec (cpu)") {
                cpu = leadingUInt(tok)
            } else if tok.hasSuffix(" msec (gpu)") {
                gpu = leadingUInt(tok)
            } else if tok.hasSuffix(" energy") {
                energy = leadingDouble(tok)
            } else if tok.hasSuffix(" reads") {
                reads = byteSize(tok)
            } else if tok.hasSuffix(" immediatewrites") || tok.hasSuffix(" deferredwrites")
                        || tok.hasSuffix(" metadatawrites") {
                writes &+= byteSize(tok)
            } else if tok.hasSuffix(" pkgIdleWkups") {
                pkgIdle = leadingUInt(tok)
            } else if tok.hasSuffix(" interruptWkups") {
                intr = leadingUInt(tok)
            } else if let r = tok.range(of: "cid:") {
                cid = Int(exactly: leadingUInt(tok[r.upperBound...]))
            } else if tok.contains(":"), tok.allSatisfy({ $0.isNumber || $0 == ":" }) {
                runtime = clockToSeconds(tok)
            }
            // else: unrecognized token (msec me / msec others / invalidated
            // writes / future fields) — deliberately skipped.

            start = end < payload.endIndex ? payload.index(after: end) : payload.endIndex
        }

        // cid and energy are the two fields the differencing and apportionment
        // cannot live without; a record missing either is dropped whole.
        guard let cid, let energy else { return nil }
        return Raw(sample: CoalitionSample(timestamp: ts, cid: cid,
                                           cpu_ms: cpu, gpu_ms: gpu,
                                           energyScore: energy,
                                           bundleID: bundleID ?? guessedID,
                                           displayName: display,
                                           pkgIdleWkups: pkgIdle,
                                           interruptWkups: intr,
                                           diskReadBytes: reads,
                                           diskWriteBytes: writes),
                   runtime_s: runtime)
    }

    /// "yyyy-MM-dd HH:mm:ss", local time, manual digit scan. Batches share the
    /// same second, so a one-deep cache eliminates most Calendar work.
    private static let calendar = Calendar(identifier: .gregorian)
    private static func timestamp(_ s: Substring,
                                  cache: inout (str: Substring, date: Date)?) -> Date? {
        if let c = cache, c.str == s { return c.date }
        let u = s.utf8
        guard u.count == 19 else { return nil }
        var nums = [0, 0, 0, 0, 0, 0]
        var idx = 0
        for b in u {
            if b >= 0x30 && b <= 0x39 {
                nums[idx] = nums[idx] * 10 + Int(b - 0x30)
            } else if idx < 5 {
                idx += 1
            } else {
                return nil
            }
        }
        var comps = DateComponents()
        comps.year = nums[0]; comps.month = nums[1]; comps.day = nums[2]
        comps.hour = nums[3]; comps.minute = nums[4]; comps.second = nums[5]
        guard let d = calendar.date(from: comps) else { return nil }
        cache = (s, d)
        return d
    }

    /// Digits at the front of a token ("125043 msec (cpu)" -> 125043).
    private static func leadingUInt(_ s: Substring) -> UInt64 {
        var v: UInt64 = 0
        for b in s.utf8 {
            guard b >= 0x30 && b <= 0x39 else { break }
            let (m, o1) = v.multipliedReportingOverflow(by: 10)
            guard !o1 else { return v }
            v = m &+ UInt64(b - 0x30)
        }
        return v
    }

    /// Float at the front of a token ("1363528.82 energy" -> 1363528.82).
    private static func leadingDouble(_ s: Substring) -> Double {
        var end = s.startIndex
        while end < s.endIndex, s[end].isNumber || s[end] == "." || s[end] == "-" {
            end = s.index(after: end)
        }
        return Double(s[..<end]) ?? 0
    }

    /// "997.73Mi reads" -> bytes. Suffixes are binary (Ki = 1024).
    private static func byteSize(_ s: Substring) -> UInt64 {
        var end = s.startIndex
        while end < s.endIndex, s[end].isNumber || s[end] == "." {
            end = s.index(after: end)
        }
        let value = Double(s[..<end]) ?? 0
        var suffix = s[end...]
        if let sp = suffix.firstIndex(of: " ") { suffix = suffix[..<sp] }
        let mult: Double
        switch suffix {
        case "B":  mult = 1
        case "Ki": mult = 1024
        case "Mi": mult = 1048576
        case "Gi": mult = 1073741824
        case "Ti": mult = 1099511627776
        case "Pi": mult = 1125899906842624
        default:   mult = 1   // unknown suffix: keep the mantissa, undercount
        }
        let bytes = value * mult
        return bytes.isFinite && bytes >= 0 ? UInt64(bytes) : 0
    }

    /// "12:16:07" -> seconds; tolerates a leading days group ("1:02:03:04")
    /// in case runtimes past 24 h ever switch format.
    private static func clockToSeconds(_ s: Substring) -> UInt64 {
        let parts = s.split(separator: ":").compactMap { UInt64($0) }
        guard !parts.isEmpty, parts.count <= 4 else { return 0 }
        let weights: [UInt64] = [1, 60, 3600, 86400]
        var total: UInt64 = 0
        for (i, p) in parts.reversed().enumerated() { total &+= p &* weights[i] }
        return total
    }

    /// "(null)" -> nil; strips team-ID prefixes ("2BUA8C4S2C.com.1password…")
    /// so the id both groups sanely and resolves via NSWorkspace.
    private static func cleanBundleID(_ raw: Substring) -> String? {
        var s = raw
        while s.last == " " { s = s.dropLast() }
        guard !s.isEmpty, s != "(null)" else { return nil }
        if let dot = s.firstIndex(of: "."), s.distance(from: s.startIndex, to: dot) == 10,
           s[..<dot].allSatisfy({ ($0.isUppercase && $0.isLetter) || $0.isNumber }),
           s[s.index(after: dot)...].contains(".") {
            s = s[s.index(after: dot)...]
        }
        return String(s)
    }

    // ── Display-name resolution ─────────────────────────────────────────────

    private static var nameCache: [String: String] = [:]
    private static let nameLock = NSLock()

    private static func displayName(forBundleID id: String) -> String {
        nameLock.lock()
        if let hit = nameCache[id] { nameLock.unlock(); return hit }
        nameLock.unlock()

        let name = resolveName(id)
        nameLock.lock(); nameCache[id] = name; nameLock.unlock()
        return name
    }

    private static func resolveName(_ id: String) -> String {
        if id == unknownKey { return "Unknown coalitions" }
        if id == "com.apple.system" { return "System" }   // cid 1: kernel + core daemons

        // Same naming philosophy as AppResolver: the Finder name of the bundle,
        // because Info.plist names are wrong for exactly the apps people use
        // most (VS Code -> "Code", Brave -> "Brave").
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let display = FileManager.default.displayName(atPath: url.path)
            let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
            if !name.isEmpty { return name }
        }

        // Daemons have no app bundle; the last reverse-DNS component is the
        // best available label (com.apple.WindowServer -> WindowServer).
        if let last = id.split(separator: ".").last, !last.isEmpty {
            return String(last)
        }
        return id
    }
}

// Foundation's enumerateLines splits on more separators than \n and goes
// through NSString; a plain \n walk is both faster and exactly what this
// line-oriented format needs.
private extension String {
    func forEachLine(_ body: (Substring) -> Void) {
        var start = startIndex
        while start < endIndex {
            let end = self[start...].firstIndex(of: "\n") ?? endIndex
            if start < end { body(self[start..<end]) }
            start = end < endIndex ? index(after: end) : endIndex
        }
    }
}
