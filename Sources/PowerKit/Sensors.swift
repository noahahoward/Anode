import Foundation

/// Temperatures, fans, and the classified sensor inventory, on top of `SMC`.
///
/// Why discovery instead of a key list: the SMC key set is model-specific and
/// Apple renames keys between chip generations (Intel `TC0P`/`sp78` vs Apple
/// Silicon `Tp00`/`flt`). So we enumerate all keys once, classify by prefix +
/// decoded type, and only *label* the families we can actually vouch for.
/// Anything else gets a hedged placeholder marked `.unidentified` — an honest
/// unknown beats a confident wrong label. `SensorNaming` holds the tables and
/// the evidence for every entry.
///
/// THE MISSING `Te*`: this machine has ZERO efficiency-core keys under that
/// prefix, and that turns out not to be a gap. `Te*` appears only in the M3 and
/// M4 community tables; on M1, M2 and M5 the efficiency cores live INSIDE the
/// `Tp*` family (M1 maps `Tp09`/`Tp0T` to E-cores and the rest to P-cores). So
/// the prefix is generation-specific, and its absence here means the E-core
/// diodes are among the 23 `Tp*` keys rather than missing. That is also why the
/// `Tp*` label no longer says "performance" — see `SensorNaming`.
///
/// MEASURED on this machine (MacBook Pro, M5 Pro, macOS 27): 3,588 keys, 2,921
/// decode, 268 `T*`+`flt` temperature candidates, `FNum` = 2 real fans (both
/// parked at 0 rpm when cool — MacBook Pro fans stop entirely below the thermal
/// threshold; 0 rpm with min 2,317 is truth, not a read failure).
///
/// ESTIMATE-vs-MEASUREMENT boundary: every VALUE here is a measurement read
/// straight from the SMC. Every NAME is an estimate — community-reverse-
/// engineered, never documented by Apple, and each one carries a `confidence`
/// saying whether it is a claim at all. `cpuTemperature()` averages only the
/// `Tp*`/`Te*` families: `Tm*` is named ("Memory sensor N") but naming it does
/// not make it CPU, and a memory diode folded into a CPU mean would move the
/// number the menu bar shows.
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

    /// Whether `name` claims to know what this sensor measures.
    ///
    /// `.unidentified` means the label is a placeholder ("Thermal sensor 12") and
    /// `key` is the sensor's only real identity. A UI showing these should say so
    /// — render the key alongside, or group them apart from the named ones —
    /// rather than presenting a placeholder as a fact. See `SensorNaming` for
    /// what evidence a name needs before it counts as identified.
    public let confidence: SensorNaming.Confidence

    public init(key: String, name: String, kind: SensorKind, value: Double,
                unit: String, confidence: SensorNaming.Confidence = .identified) {
        self.key = key
        self.name = name
        self.kind = kind
        self.value = value
        self.unit = unit
        self.confidence = confidence
    }

    public var isIdentified: Bool { confidence == .identified }

    /// The ONLY label safe to print without also printing `key`.
    ///
    /// `name` alone is a trap for the 140 hedged temperatures on this machine:
    /// "Thermal sensor 37" looks exactly like "GPU sensor 37" on screen while
    /// carrying none of the evidence, and the ordinal is an artefact of key sort
    /// order rather than anything physical. For those, the key IS the identity —
    /// `TVDc` is a fact, "Thermal sensor 37" is a bucket number — so it is
    /// appended rather than left for the caller to remember.
    ///
    /// Identified readings return `name` unchanged: `TB0T` is already "Battery
    /// sensor 1" on the strength of a cross-check against IOKit, and repeating
    /// the key would just be noise.
    ///
    /// Non-temperature unidentified keys already have the key AS their name (see
    /// `SensorNaming.label`), so they are returned as-is rather than as "PZC0
    /// (PZC0)".
    public var qualifiedName: String {
        guard !isIdentified, name != key else { return name }
        return "\(name) (\(key))"
    }

    /// Sorts the way a person reads: "Thermal sensor 2" before "Thermal sensor 10".
    ///
    /// Lexicographic order puts 10 before 2, which scatters a family across the
    /// list and makes a run of consecutive sensors look like unrelated entries.
    public static func precedesByName(_ a: SensorReading, _ b: SensorReading) -> Bool {
        switch NaturalOrder.compare(a.name, b.name) {
        case .orderedAscending:  return true
        case .orderedDescending: return false
        // Two readings can share a display name only when both are raw keys that
        // differ in case (`Ts0P` vs `TS0P`), so the key breaks the tie and the
        // order stays total.
        case .orderedSame:       return a.key < b.key
        }
    }
}

public extension Array where Element == SensorReading {
    /// Natural order by display name — see `SensorReading.precedesByName`.
    func sortedByName() -> [SensorReading] { sorted(by: SensorReading.precedesByName) }
}

/// Digit runs compared as numbers, everything else as text.
///
/// Split out from `SensorReading` because it is not about sensors: any list this
/// app numbers ("Fan 2", "CPU core sensor 10") has the same problem, and the rule
/// is easier to test as a total order on plain strings.
public enum NaturalOrder {

    public static func precedes(_ a: String, _ b: String) -> Bool {
        compare(a, b) == .orderedAscending
    }

    /// A TOTAL order: equal-comparing chunks fall through to a plain string
    /// compare at the end, so `sorted(by:)` cannot see two different strings as
    /// interchangeable and reorder them differently between runs.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex {
            if a[i].isNumber, b[j].isNumber {
                let (na, ia) = digits(a, from: i)
                let (nb, jb) = digits(b, from: j)
                // Compared by length first, then lexicographically, with leading
                // zeros stripped — so this is exact for numbers of any size
                // rather than overflowing on a key that happens to be 30 digits.
                if na.count != nb.count { return na.count < nb.count ? .orderedAscending : .orderedDescending }
                if na != nb { return na < nb ? .orderedAscending : .orderedDescending }
                i = ia; j = jb
                continue
            }
            let ca = String(a[i]).lowercased(), cb = String(b[j]).lowercased()
            if ca != cb { return ca < cb ? .orderedAscending : .orderedDescending }
            i = a.index(after: i); j = b.index(after: j)
        }
        if i < a.endIndex { return .orderedDescending }   // a is longer
        if j < b.endIndex { return .orderedAscending }
        // Same shape, same digits, same letters ignoring case: "Tp0A" vs "Tp0a".
        // Only now does case decide, so the order is stable and total.
        if a == b { return .orderedSame }
        return a < b ? .orderedAscending : .orderedDescending
    }

    /// The digit run starting at `i`, leading zeros removed, and the index after it.
    private static func digits(_ s: String, from i: String.Index) -> (String, String.Index) {
        var k = i
        while k < s.endIndex, s[k].isNumber { k = s.index(after: k) }
        var run = Substring(s[i..<k])
        while run.count > 1, run.first == "0" { run = run.dropFirst() }
        return (String(run), k)
    }
}

public extension Array where Element == FanInfo {
    /// What this machine's fans are doing, as one number.
    ///
    /// THE AVERAGE, and it is an average everywhere: the window's fan card sets
    /// it in the headline, the bar captions it, the graph plots it, and the menu
    /// bar widget reports it. That widget used to report the FASTEST fan instead —
    /// a fair argument on its own, since the fastest is the one you can hear, and
    /// it lost to the app agreeing with itself. On a machine whose fans sit at
    /// 2318 and 2500 rpm it simply read as the second fan.
    ///
    /// Written once because it was written seven times, which is how the widget
    /// managed to disagree with everything around it in the first place. Zero for
    /// no fans; callers that need to tell "no fans" from "fans at rest" check the
    /// array itself, since those are different claims.
    var averageRPM: Double {
        isEmpty ? 0 : reduce(0) { $0 + $1.currentRPM } / Double(count)
    }

    /// The same, as a fraction of top speed. See `FanInfo.load`.
    var averageLoad: Double {
        isEmpty ? 0 : reduce(0) { $0 + $1.load } / Double(count)
    }
}

public struct FanInfo {
    public let index: Int
    public let currentRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let targetRPM: Double?
    /// Fraction of the fan's TOP SPEED, for a gauge.
    ///
    /// It was a fraction of the min..max RANGE, and that is a different question
    /// with a much worse answer. Measured on this machine: the fans idle at 2318
    /// and 2500 rpm against a minimum of 2317 and a maximum of 7826 — so
    /// range-relative load was 0.02% and 3.3% while both fans were plainly
    /// spinning, and the graph drew a flat line on the floor. Reported as "the
    /// green staying at the bottom, even though the fans are spinning".
    ///
    /// The minimum is not zero, so "how far into its adjustable range" is not the
    /// question anyone is asking of a fan graph. "How fast, out of as fast as it
    /// goes" is, and it answers correctly at both ends: a fan parked at 0 rpm
    /// reads 0, and a fan flat out reads 100.
    ///
    /// One definition, so the pane's gauges, the Resources rows, the bottom bar
    /// and the graph cannot disagree about what "% fan speed" means.
    public var load: Double {
        guard maxRPM > 0 else { return 0 }
        return min(1, max(0, currentRPM / maxRPM))
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

        public var temperatures: [SensorReading] { readings.filter { $0.kind == .temperature } }

        /// Average across CPU core sensors (`Tp*` performance + `Te*` efficiency
        /// families only). nil when no CPU-family key exists or every reading
        /// failed the sanity filter.
        public var cpuTemperature: Double? { mean(prefixes: ["Tp", "Te"]) }

        /// Average across the `Tg*` GPU cluster sensors.
        public var gpuTemperature: Double? { mean(prefixes: ["Tg"]) }

        /// The highest temperature on the machine, whatever it turns out to be.
        ///
        /// MEASURED here, and it is why `qualifiedName` exists: on this Mac the
        /// hottest sensor is `TVDc`/`TCMb` at ~47-63 °C, and BOTH are
        /// `.unidentified`. A caption reading "hottest 63°C (Thermal sensor 37)"
        /// is therefore a placeholder ordinal presented as if it named a part —
        /// the user cannot tell it apart from "hottest 63°C (GPU sensor 37)",
        /// which would be a real claim. Anything printing this MUST print
        /// `qualifiedName`, not `name`, and should check `isIdentified` before
        /// implying the reading points at a component.
        public var hottest: SensorReading? { temperatures.max { $0.value < $1.value } }

        /// The hottest temperature we can actually name.
        ///
        /// Deliberately separate from `hottest` rather than a filter applied to
        /// it: these are different questions ("what is the peak on this machine"
        /// vs "what is the hottest thing we can attribute"), they have different
        /// answers here, and collapsing them would hide the peak whenever it
        /// lands on an unnamed sensor — which on this machine is always.
        public var hottestIdentified: SensorReading? {
            temperatures.filter(\.isIdentified).max { $0.value < $1.value }
        }

        /// The two halves of the naming contract, for a UI that groups them.
        public var identified: [SensorReading] { readings.filter(\.isIdentified) }
        public var unidentified: [SensorReading] { readings.filter { !$0.isIdentified } }

        private func mean(prefixes: [String]) -> Double? {
            let vals = temperatures
                .filter { r in prefixes.contains(where: { r.key.hasPrefix($0) }) }
                .map(\.value)
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count)
        }
    }

    // ── Public API ──────────────────────────────────────────────────────────

    /// Every classified, plausible sensor: temperatures, fan speeds, voltages,
    /// currents, power rails. Keys that decode but match no known family are
    /// NOT included — ~2,600 opaque counters/flags would be noise, not depth;
    /// `SMC.scan()` remains the raw firehose for anyone who wants it.
    public static func all() -> [SensorReading] { store.snapshot().readings }

    public static func temperatures() -> [SensorReading] { store.snapshot().temperatures }

    public static func fans() -> [FanInfo] { store.snapshot().fans }

    public static func hottest() -> SensorReading? { store.snapshot().hottest }

    /// The number worth putting in a menu bar widget.
    ///
    /// EACH of these convenience accessors performs a FULL SMC SWEEP — there is
    /// no cache under `snapshot()`, it re-reads every classified key and every
    /// fan on every call. Measured on this machine: 88 ms wall / 9.1 ms CPU per
    /// sweep, ~540 IOKit round trips.
    ///
    /// So asking for three of these is three sweeps: 264 ms / 28 ms CPU, which
    /// is what `SystemMetrics` was doing every 5 s whenever a sensor widget was
    /// bound — 0.56% of one core to read the same keys three times. Anything
    /// wanting more than one figure must take `inventory()` ONCE and read the
    /// properties off it; these exist for the single-value case only.
    public static func cpuTemperature() -> Double? { store.snapshot().cpuTemperature }

    /// Average across the `Tg*` GPU cluster sensors. Same sweep cost as above.
    public static func gpuTemperature() -> Double? { store.snapshot().gpuTemperature }

    /// Full snapshot with counts and rejects — what the CLI and any diagnostics
    /// view should print, and what any caller needing two or more figures should
    /// use so it pays for one sweep instead of several.
    public static func inventory() -> Inventory { store.snapshot() }

    // ── Naming ──────────────────────────────────────────────────────────────
    //
    // The tables, and the evidence for every entry in them, live in
    // `SensorNaming`. Matching is CASE-SENSITIVE on purpose: `Tp00` (a CPU core
    // diode) and `TPD0` (unidentified) are different families, as are `Ts0P`
    // (palm rest, 26.9 °C) and `TS0P` (33.6 °C).

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
            /// Names are fixed here, at discovery, so "GPU sensor 3" stays the
            /// same physical diode across snapshots even if some other reading
            /// transiently fails the sanity filter.
            var classified: [(key: String, name: String, kind: SensorKind,
                              confidence: SensorNaming.Confidence)] = []
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
            for (key, name, kind, confidence) in d.classified {
                guard let s = smc.read(key) else { continue }  // key can vanish
                guard Sensors.plausible(kind, s.value) else {
                    rejected.append((key, s.value)); continue
                }
                readings.append(SensorReading(key: key, name: name, kind: kind,
                                              value: s.value, unit: Self.unit(kind),
                                              confidence: confidence))
            }

            let fans = d.fanIndices.compactMap { readFan(smc, index: $0) }
            // Fans appear in `all()` too, so a widget bound to "any metric"
            // can pick a fan without a second code path.
            //
            // Numbered, not named, and that is a finding rather than a shrug.
            // "Intake 1"/"Exhaust 1" in other monitors are not thermistor labels
            // — they are the fan's OWN name, a string the firmware publishes at
            // `F<n>ID` (type `{fds`). This machine does not publish it: `F0ID`,
            // `F1ID` and `F2ID` all return size 0 with no type, i.e. the keys do
            // not exist. So there is no intake/exhaust vocabulary to read here,
            // and inventing one would be asserting airflow direction from
            // nothing. Even upstream falls back to "Left fan"/"Right fan" when
            // `F<n>ID` is missing, which is itself a guess about which side fan
            // 0 sits on. If a future model does publish `F<n>ID`, reading it is
            // the right fix — that name comes from the hardware.

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
            // The decoded TYPE is carried through to naming, not just used to
            // classify: `flt` vs `sp78` is how Apple Silicon and Intel are told
            // apart, and some prefixes mean different things on each.
            var byKind: [(key: String, kind: SensorKind, type: String)] = []
            for s in smc.scan() {
                d.keysDecoded += 1
                switch (s.key.first, s.type) {
                case ("T", "flt"), ("T", "sp78"): byKind.append((s.key, .temperature, s.type))
                case ("V", "flt"):                byKind.append((s.key, .voltage, s.type))
                case ("I", "flt"):                byKind.append((s.key, .current, s.type))
                case ("P", "flt"):                byKind.append((s.key, .power, s.type))
                default:                          break  // fans handled below
                }
            }

            // Ordinals follow key sort order within each family — the SMC's own
            // enumeration order is not contractual. One `ordinals` dictionary is
            // threaded through the whole pass so numbering is assigned exactly
            // once, here.
            let rails = SubsystemRails.isCalibratedHardware
            var ordinals: [String: Int] = [:]
            for (key, kind, type) in byKind.sorted(by: { $0.key < $1.key }) {
                let label = SensorNaming.label(for: key, kind: kind, type: type,
                                               calibratedRails: rails, ordinals: &ordinals)
                d.classified.append((key, label.text, kind, label.confidence))
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
