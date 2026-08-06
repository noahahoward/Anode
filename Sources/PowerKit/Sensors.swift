import Foundation

/// Temperatures, fans, and the classified sensor inventory, on top of `SMC`.
///
/// Why discovery instead of a key list: the SMC key set is model-specific and
/// Apple renames keys between chip generations (Intel `TC0P`/`sp78` vs Apple
/// Silicon `Tp00`/`flt`; this M5 Pro has no `Te*` efficiency-core keys at all,
/// which every published M1/M2 list says it should). So we enumerate all keys
/// once, classify by prefix + decoded type, and only *label* the families we
/// can actually vouch for. Anything else keeps its raw four-char key as its
/// name — an honest unknown beats a confident wrong label.
///
/// MEASURED on this machine (MacBook Pro, M5 Pro, macOS 27): 3,588 keys, 2,921
/// decode, 268 `T*`+`flt` temperature candidates, `FNum` = 2 real fans (both
/// parked at 0 rpm when cool — MacBook Pro fans stop entirely below the thermal
/// threshold; 0 rpm with min 2,317 is truth, not a read failure).
///
/// ESTIMATE-vs-MEASUREMENT boundary: every VALUE here is a measurement read
/// straight from the SMC. Every NAME is an estimate — community-reverse-
/// engineered, never documented by Apple. `cpuTemperature()` therefore averages
/// only the `Tp*`/`Te*` families (the two with solid community consensus) and
/// deliberately ignores plausible-but-unverified families like `Tm*`.
///
/// NO WRITES, EVER. Fan control would go through the same user client with a
/// write-bytes command against `F0Md`/`F0Tg` — and it is deliberately absent.
/// Forcing a fan target while the SoC is hot can cook the machine, and writes
/// require entitlements/root the unprivileged read connection does not have.
/// If control is ever built, it belongs in BetterStatsHelper behind an
/// explicit user gesture, never in this file.

public enum SensorKind {
    case temperature, fan, voltage, current, power, unknown
}

public struct SensorReading {
    public let key: String            // raw SMC key, e.g. "Tp00"
    public let name: String           // human label, or the raw key when unverified
    public let kind: SensorKind
    public let value: Double
    public let unit: String           // "°C", "rpm", "V", "A", "W"
}

public struct FanInfo {
    public let index: Int
    public let currentRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double?
    /// Fraction of the min..max range, for a gauge. A parked fan (0 rpm, below
    /// min) clamps to 0 rather than going negative.
    public var load: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(1, max(0, (currentRPM - minRPM) / (maxRPM - minRPM)))
    }
}

public enum Sensors {

    /// One full classified snapshot, including what was thrown away. The
    /// rejected list is part of the honesty contract: many SMC keys decode to
    /// plausible-looking garbage (this machine: `TTPD` = -3.07e8 "°C", nine
    /// `Tz1*` keys frozen at exactly 0), and the UI should be able to say how
    /// much was discarded rather than silently absorbing it.
    public struct Inventory {
        public let keysTotal: Int             // SMC #KEY on this machine
        public let keysDecoded: Int           // keys our decoder understands
        public let readings: [SensorReading]  // classified AND plausible
        public let fans: [FanInfo]
        public let rejected: [(key: String, value: Double)]  // classified but implausible
    }

    // ── Public API ──────────────────────────────────────────────────────────

    /// Every classified, plausible sensor: temperatures, fan speeds, voltages,
    /// currents, power rails. Keys that decode but match no known family are
    /// NOT included — ~2,600 opaque counters/flags would be noise, not depth;
    /// `SMC.scan()` remains the raw firehose for anyone who wants it.
    public static func all() -> [SensorReading] { store.snapshot().readings }

    public static func temperatures() -> [SensorReading] {
        store.snapshot().readings.filter { $0.kind == .temperature }
    }

    public static func fans() -> [FanInfo] { store.snapshot().fans }

    public static func hottest() -> SensorReading? {
        temperatures().max { $0.value < $1.value }
    }

    /// Average across CPU core sensors (`Tp*` performance + `Te*` efficiency
    /// families only) — the number worth putting in a menu bar widget. nil when
    /// no CPU-family key exists or every reading failed the sanity filter.
    public static func cpuTemperature() -> Double? {
        mean(prefixes: ["Tp", "Te"])
    }

    /// Average across the `Tg*` GPU cluster sensors.
    public static func gpuTemperature() -> Double? {
        mean(prefixes: ["Tg"])
    }

    /// Full snapshot with counts and rejects — what the CLI and any diagnostics
    /// view should print.
    public static func inventory() -> Inventory { store.snapshot() }

    private static func mean(prefixes: [String]) -> Double? {
        let vals = temperatures()
            .filter { r in prefixes.contains(where: { r.key.hasPrefix($0) }) }
            .map(\.value)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // ── Naming — labels only for families with real community consensus ─────
    //
    // Sources: exelban/Stats, iStat, smcFanControl key lists, cross-checked
    // against what this machine actually reports (e.g. TB0T reads 30.9 °C — a
    // battery temperature, not a CPU one). Prefix matching is CASE-SENSITIVE
    // on purpose: `Tp00` (perf core, 53 °C) and `TPD0` (unknown, 43 °C) are
    // different families, as are `Ts0P` (palm rest, 30 °C) and `TS0P` (40 °C).

    fileprivate static let exactNames: [String: String] = [
        "TB0T": "Battery 1", "TB1T": "Battery 2",
        "TB2T": "Battery 3", "TB3T": "Battery 4",
        "TaLP": "Airflow left", "TaRF": "Airflow right",
        "TW0P": "WiFi proximity",
        "TH0a": "NAND flash 1", "TH0b": "NAND flash 2", "TH0x": "NAND flash",
        "Ts0P": "Palm rest 1", "Ts1P": "Palm rest 2",
    ]

    /// Families whose members get an ordinal ("CPU performance sensor 3").
    /// Sensor count exceeds core count on Apple Silicon (21 Tp keys here, more
    /// thermal diodes than P-cores), so labels say "sensor", not "core N".
    fileprivate static let ordinalFamilies: [(prefix: String, label: String)] = [
        ("Tp", "CPU performance sensor"),
        ("Te", "CPU efficiency sensor"),
        ("Tg", "GPU sensor"),
    ]

    // ── Plausibility — the estimate boundary for VALUES ─────────────────────
    // A "temperature" of ≤5 or >150 °C is decode garbage, not a reading: a
    // powered-on component cannot sit below ambient, and Apple's own operating
    // floor is 10 °C. This machine proves the need — TTPD decodes to -3.07e8,
    // nine Tz1* keys are frozen at exactly 0, and TVMD at exactly 1.0. Config
    // keys inside the plausible band still slip through; a value filter can
    // catch an implausible lie, never a plausible one.

    fileprivate static func plausible(_ kind: SensorKind, _ v: Double) -> Bool {
        guard v.isFinite else { return false }
        switch kind {
        case .temperature: return v > 5 && v <= 150
        case .fan:         return v >= 0 && v <= 30_000
        case .voltage:     return v >= 0 && v <= 100
        case .current:     return abs(v) <= 100     // sign = direction, keep it
        case .power:       return abs(v) <= 1_000
        case .unknown:     return false
        }
    }

    // ── Discovery + cached re-reads ─────────────────────────────────────────
    //
    // Discovery (full 3,588-key enumeration, ~0.7 s measured) runs ONCE — the
    // key set is fixed per boot. Snapshots after that re-read only the few
    // hundred classified keys, cheap enough for a widget tick. All SMC traffic
    // is serialized behind one lock because the user client is not documented
    // thread-safe.

    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var smc: SMC?
        private var opened = false
        private var discovered: Discovery?

        private struct Discovery {
            var keysTotal = 0
            var keysDecoded = 0
            /// Names are fixed here, at discovery, so "CPU performance sensor 3"
            /// stays the same physical diode across snapshots even if some other
            /// reading transiently fails the sanity filter.
            var classified: [(key: String, name: String, kind: SensorKind)] = []
            var fanIndices: [Int] = []
        }

        func snapshot() -> Inventory {
            lock.lock(); defer { lock.unlock() }
            guard let smc = connection(), let d = discover(smc) else {
                // No AppleSMC user client (or zero keys) — degrade to empty,
                // never crash: the service is undocumented and can vanish.
                return Inventory(keysTotal: 0, keysDecoded: 0,
                                 readings: [], fans: [], rejected: [])
            }

            var readings: [SensorReading] = []
            var rejected: [(String, Double)] = []
            for (key, name, kind) in d.classified {
                guard let s = smc.read(key) else { continue }  // key can vanish
                guard Sensors.plausible(kind, s.value) else {
                    rejected.append((key, s.value)); continue
                }
                readings.append(SensorReading(key: key, name: name, kind: kind,
                                              value: s.value, unit: Self.unit(kind)))
            }

            let fans = d.fanIndices.compactMap { readFan(smc, index: $0) }
            // Fans appear in `all()` too, so a widget bound to "any metric"
            // can pick a fan without a second code path.
            readings.append(contentsOf: fans.map {
                SensorReading(key: "F\($0.index)Ac", name: "Fan \($0.index + 1)",
                              kind: .fan, value: $0.currentRPM, unit: "rpm")
            })

            return Inventory(keysTotal: d.keysTotal, keysDecoded: d.keysDecoded,
                             readings: readings, fans: fans, rejected: rejected)
        }

        private func connection() -> SMC? {
            if !opened { smc = SMC(); opened = true }  // nil is cached too — no retry storm
            return smc
        }

        private func discover(_ smc: SMC) -> Discovery? {
            if let d = discovered { return d }
            var d = Discovery()
            d.keysTotal = smc.keyCount()
            guard d.keysTotal > 0 else { return nil }

            // scan() yields only keys our decoder understands; classification
            // is prefix + type. Type matters: `VBUS` decodes as ui32 (a flag,
            // not volts) and Intel temps are sp78 where Apple Silicon uses flt.
            var byKind: [(key: String, kind: SensorKind)] = []
            for s in smc.scan() {
                d.keysDecoded += 1
                switch (s.key.first, s.type) {
                case ("T", "flt"), ("T", "sp78"): byKind.append((s.key, .temperature))
                case ("V", "flt"):                byKind.append((s.key, .voltage))
                case ("I", "flt"):                byKind.append((s.key, .current))
                case ("P", "flt"):                byKind.append((s.key, .power))
                default:                          break  // fans handled below
                }
            }

            // Ordinals follow key sort order within each family — the SMC's own
            // enumeration order is not contractual.
            var ordinals: [String: Int] = [:]
            for (key, kind) in byKind.sorted(by: { $0.key < $1.key }) {
                d.classified.append((key, Self.name(for: key, ordinals: &ordinals), kind))
            }

            // Fan discovery: FNum is authoritative when present. When absent
            // (some models), probe F0Ac.. directly — report only what answers.
            // On Intel, F?Ac is fpe2, which our decoder skips; fans() being
            // empty there is a known limitation, not a fanless machine.
            if let n = smc.read("FNum")?.value, n > 0, n <= 10 {
                d.fanIndices = (0..<Int(n)).filter { smc.read("F\($0)Ac") != nil }
            } else {
                d.fanIndices = (0..<10).filter { smc.read("F\($0)Ac") != nil }
            }

            discovered = d
            return d
        }

        private func readFan(_ smc: SMC, index i: Int) -> FanInfo? {
            guard let ac = smc.read("F\(i)Ac"),
                  Sensors.plausible(.fan, ac.value) else { return nil }
            // Min/max default to 0 when missing — load then reads 0 rather
            // than inventing a range.
            let mn = smc.read("F\(i)Mn")?.value ?? 0
            let mx = smc.read("F\(i)Mx")?.value ?? 0
            let tg = smc.read("F\(i)Tg")?.value
            return FanInfo(index: i, currentRPM: ac.value, minRPM: mn,
                           maxRPM: mx, targetRPM: tg)
        }

        private static func name(for key: String, ordinals: inout [String: Int]) -> String {
            if let n = Sensors.exactNames[key] { return n }
            for fam in Sensors.ordinalFamilies where key.hasPrefix(fam.prefix) {
                let n = (ordinals[fam.prefix] ?? 0) + 1
                ordinals[fam.prefix] = n
                return "\(fam.label) \(n)"
            }
            return key  // unverified family — the raw key IS the honest name
        }

        private static func unit(_ kind: SensorKind) -> String {
            switch kind {
            case .temperature: return "°C"
            case .fan:         return "rpm"
            case .voltage:     return "V"
            case .current:     return "A"
            case .power:       return "W"
            case .unknown:     return ""
            }
        }
    }
}
