import Foundation

/// Human names for SMC sensors — and, for every name, the evidence behind it.
///
/// Apple documents none of this. The SMC key set is model-specific, the community
/// tables that exist are partly guesswork, and a key that exists on two Macs can
/// mean two different things. So the rule here is the same one `SubsystemRails`
/// follows: a confident wrong label is worse than a raw key. "Exhaust 1" pointing
/// at the charger misleads in a way `TDER` never could, because the raw key
/// carries no claim at all.
///
/// Every name below therefore records WHY. Three kinds of evidence are accepted:
///
///   CONSENSUS   — independent community tables agree (exelban/Stats, credited in
///                 README; smcFanControl; iStat). Weakest on its own, because the
///                 tables copy each other.
///   BEHAVIOUR   — the sensor was watched against something known. All figures
///                 quoted here come from a 150-sample passive recording (4 s
///                 apart, ~10 min) of all 268 temperature keys plus the power
///                 rails, taken while the machine was in ordinary use. `r(P)` is
///                 correlation against instantaneous SMC `PSTR` (whole-system
///                 watts); `r(emaP)` is against an exponentially smoothed PSTR,
///                 which stands in for accumulated heat. NO LOAD WAS GENERATED —
///                 this is observation of what the user was already doing.
///   CROSS-CHECK — the value was compared against the same quantity reported by
///                 an independent, Apple-owned source. The strongest evidence
///                 available, and only one family here has it.
///
/// Anything that has none of the three keeps a hedged label and is marked
/// `.unidentified`, which is a promise to the UI that the label is a placeholder
/// and `SensorReading.key` is the sensor's only real identity.
///
/// A REJECTED INFERENCE, recorded so nobody repeats it: macOS publishes its own
/// human-readable sensor names through the HID vendor page (`PrimaryUsagePage`
/// 0xFF00, usage 5) — this machine exposes 79 of them, including "NAND CH0 temp",
/// "PMU tdie1..14" and "gas gauge battery", each tagged with a FourCC that looks
/// exactly like an SMC key. It is very tempting to map those onto SMC keys. It is
/// wrong. The HID FourCC `TG0B` is "gas gauge battery", while SMC `Tg*` is the
/// GPU cluster by every community table and by measured behaviour. The two
/// namespaces collide on the same FourCC with different meanings, so HID names
/// cannot be transferred to SMC keys. That collision is the negative control that
/// killed the idea.
public enum SensorNaming {

    // ── What a name claims ──────────────────────────────────────────────────

    /// Whether a name asserts anything about what the sensor physically measures.
    public enum Confidence: Sendable, Equatable {
        /// We can point at evidence for what this sensor is.
        case identified
        /// The label is a placeholder. `SensorReading.key` is the real identity,
        /// and a UI should show it rather than presenting the label as a fact.
        case unidentified
    }

    public struct Label: Sendable, Equatable {
        public let text: String
        public let confidence: Confidence
        public var isIdentified: Bool { confidence == .identified }
    }

    // ── Temperatures: exact keys ────────────────────────────────────────────

    /// Keys named individually, because the family they sit in is not uniform.
    ///
    /// `TB*T` — BATTERY. The only family here with a cross-check, and it is a
    /// clean one. IOKit publishes the pack's own temperature at
    /// `AppleSmartBatteryPack.BatteryData.Temperature` (centi-°C); measured
    /// simultaneously against the SMC, four times over ~90 s:
    ///     IOKit 27.09 °C   TB0T 27.10   TB1T 26.80   TB2T 27.10
    /// and on an earlier, warmer sample IOKit 28.19 against TB0T 27.90. TB0T and
    /// TB2T agree with Apple's own figure to 0.01 °C and track it as it moves;
    /// TB1T sits ~0.3 °C cooler, the spread of a second thermistor in the same
    /// pack. BEHAVIOUR corroborates: r(emaP) = +0.06 / -0.07 / +0.06, i.e. these
    /// three are thermally DECOUPLED from the SoC, which nothing on the die is
    /// (every on-die family measures r(emaP) ≥ 0.78). CONSENSUS agrees too.
    /// Named "sensor N" rather than "cell N" — three thermistors is not evidence
    /// of three cells.
    ///
    /// `Ts0P`/`Ts1P` — PALM REST. CONSENSUS (Intel-era lists) plus BEHAVIOUR:
    /// these are the coolest and least responsive temperatures on the machine
    /// (mean 26.9 / 25.6 °C, sd 0.32 / 0.34, r(emaP) 0.31 / 0.19) while their
    /// `Ts0*` neighbours — same two-letter prefix — average 36 °C with sd ≈ 2.4
    /// and r(emaP) ≈ 0.80. So the prefix is NOT one family, and these two are
    /// unambiguously exterior-surface sensors. That is the weakest retained label
    /// in this table: the measurement proves "outside surface, far from the die",
    /// it does not prove "palm rest" specifically.
    ///
    /// `TaLP`/`TaRF` — AIRFLOW. CONSENSUS: the only two `Ta*` keys any Apple
    /// Silicon table names. BEHAVIOUR is consistent rather than decisive — sd
    /// 1.34 / 1.23 and r(emaP) 0.40 / 0.33 put them between the die (sd ≈ 3) and
    /// the battery (r ≈ 0), which is where a sensor in the airflow path belongs.
    /// Note their `Ta0*` siblings behave like on-die sensors (sd ≈ 2.9,
    /// r(emaP) ≈ 0.81) and are deliberately NOT named airflow.
    ///
    /// `TW0P` — WI-FI. CONSENSUS only ("Airport" in Stats). BEHAVIOUR neutral
    /// (sd 1.58, r(emaP) 0.49). Retained because it was already shipping and
    /// nothing contradicts it.
    ///
    /// `TH0*` — NAND. CONSENSUS (Stats maps `TH0x` to NAND on Apple Silicon).
    /// BEHAVIOUR: r(emaP) ≈ 0.29, decoupled from the SoC like storage should be,
    /// and all three read within 0.07 °C of each other.
    static let exactTemperatures: [String: String] = [
        "TB0T": "Battery sensor 1", "TB1T": "Battery sensor 2",
        "TB2T": "Battery sensor 3", "TB3T": "Battery sensor 4",
        "TaLP": "Airflow left", "TaRF": "Airflow right",
        "TW0P": "Wi-Fi proximity",
        "TH0a": "NAND flash 1", "TH0b": "NAND flash 2", "TH0x": "NAND flash",
        "Ts0P": "Palm rest 1", "Ts1P": "Palm rest 2",
    ]

    // ── Temperatures: ordinal families ──────────────────────────────────────

    /// Families whose members share a purpose but not an identifiable position.
    ///
    /// The label says "sensor", never "core N", and that is deliberate. This
    /// machine exposes 23 `Tp*` keys; upstream's own M5 table covers 18 of them
    /// and splits those into "super core 1-6" (`Tp00`-`Tp0K`) and "performance
    /// core 1-12" (`Tp0O`-`Tp0y`). Three things stop that being usable here:
    ///
    ///   1. It is INCOMPLETE for this hardware. `Tp1E`, `Tp1I`, `Tp1Q`, `Tp1U`
    ///      and `Tp1g` are present on this Mac and appear in no published list.
    ///      A table that does not know about five of a machine's sensors is not
    ///      a table whose per-key assignments are verified for that machine.
    ///   2. Nothing MEASURED supports the claimed boundary. Across the recording
    ///      the two claimed groups are indistinguishable: `Tp00`-`Tp0K` sd
    ///      2.89-3.63, `Tp0O`-`Tp0y` sd 2.66-3.37, overlapping ranges, the same
    ///      r(emaP) to two decimals. A real P-core/E-core split under a mixed
    ///      workload would not hide that well.
    ///   3. A core ordinal is a much stronger claim than a family name. Getting
    ///      "GPU sensor 7" wrong costs nothing; "performance core 7" tells the
    ///      user which core to blame.
    ///
    /// `Tp` — CPU. CONSENSUS across every Apple Silicon generation (M1, M2, M4
    /// and M5 tables all put CPU cores under `Tp*`). BEHAVIOUR is the strong
    /// part: `Tp*` has the highest INSTANTANEOUS correlation with system power
    /// of any family (r(P) 0.57-0.71) and the largest dynamic range (10.2-17.0 °C
    /// swing over the recording). Fast and wide is what a core diode looks like;
    /// everything else on the die lags.
    ///
    /// Note the label changed from "CPU performance sensor" — that was an
    /// over-claim. On M1 the efficiency cores (`Tp09`, `Tp0T`) live INSIDE the
    /// `Tp*` family, so "performance" was asserting a core type the prefix does
    /// not carry. "CPU core sensor" claims only what the prefix supports.
    ///
    /// `Te` — CPU EFFICIENCY. CONSENSUS (M3/M4 tables). Kept for those machines;
    /// THIS machine has zero `Te*` keys, see `Sensors` for what that means.
    ///
    /// `Tg` — GPU. CONSENSUS across generations. BEHAVIOUR: 42 keys whose means
    /// all fall inside a 0.72 °C band (35.61-36.35) with near-identical sd
    /// (2.35-2.44) — a single large block with heavy lateral heat spreading. It
    /// has the LOWEST instantaneous power correlation of the on-die families
    /// (r(P) 0.44-0.51) but a high smoothed one (r(emaP) ≈ 0.79-0.83), the
    /// signature of a region that is mostly idle and being warmed by its
    /// neighbours — an idle GPU during ordinary desktop use.
    ///
    /// `Tm` — MEMORY. CONSENSUS on Apple Silicon (M1 `Tm02/06/08/09` = "Memory
    /// 1-4"; M4 `Tm0p/1p/2p` = "Memory proximity"). BEHAVIOUR is consistent —
    /// r(P) 0.44-0.67, between the cores and the chassis, as on-package DRAM
    /// should be — but not diagnostic. CAVEAT worth keeping: on Intel, `Tm0P` is
    /// the MAINBOARD, so this prefix has already changed meaning once across
    /// architectures. That is why the family is gated to `flt` keys below.
    static let ordinalFamilies: [(prefix: String, label: String)] = [
        ("Tp", "CPU core sensor"),
        ("Te", "CPU efficiency core sensor"),
        ("Tg", "GPU sensor"),
        ("Tm", "Memory sensor"),
    ]

    /// Apple Silicon reports temperatures as `flt`; Intel uses `sp78`. The
    /// families above were established on Apple Silicon only, and at least one
    /// of those prefixes means something else entirely on Intel (`Tm0P`,
    /// mainboard). Gating on the decoded type is a cheap way to make sure an
    /// Intel Mac cannot be handed an Apple Silicon name.
    static let appleSiliconTemperatureType = "flt"

    // ── Power rails ─────────────────────────────────────────────────────────

    /// Rails this project identified itself, by driving one subsystem at a time
    /// and confirming with a negative control. See `SubsystemRails` and
    /// `DisplayRail` for the full write-ups; the evidence is summarised here so
    /// the names and the reasons stay together.
    ///
    /// `PSTR` — whole-system watts. Used as the machine's total everywhere in
    /// this codebase; `PZC0+PZC1` and `PHPC+PHPS` each sum to it, which is what
    /// a system total should do.
    /// `PPMC` — CPU package. +13.3 W under an all-core load against +1.5 W under
    /// a pure Metal GPU load: a 9x discriminator WITH its negative control.
    ///
    /// These two are named on any Mac because this project already reads them
    /// unconditionally as those quantities.
    static let universalRails: [String: String] = [
        "PSTR": "System total power",
        "PPMC": "CPU package power",
    ]

    /// Rails whose identification came from experiments on ONE machine, and which
    /// are therefore named only on that machine.
    ///
    /// `PDBR` — display backlight. Tracked a brightness sweep from 0.204 W to
    /// 8.197 W, a 40x swing whose full scale matches the independently fitted
    /// panel span to within noise.
    /// `P3F2`/`PZD1` — memory. Found by a CPU-MATCHED contrast (ten threads of
    /// register-resident FP spin against ten threads streaming 249 GB/s, so the
    /// only difference is DRAM traffic): 21x and 112x discriminators.
    /// `PN00` — SSD. +4.5 W under real flash I/O, 0.51 W under 34 W of CPU and
    /// 249 GB/s of DRAM. Its negative control is the good part: a workload of the
    /// same shape served entirely from the buffer cache (1.03M IOPS/s, never
    /// reaching flash) did not move it at all.
    /// `PH0R`/`PHCR` — SSD controller. ~1000x discriminators with a visible NVMe
    /// idle-timer decay after each burst, but ~0.03 W at idle.
    ///
    /// Off this hardware these keys keep their raw names. `SubsystemRails` spells
    /// out why at length: `P3F2` existing on another Mac is not evidence it means
    /// memory there, and a misidentified rail passes every plausibility check
    /// while putting watts under a confidently wrong name.
    static let calibratedRails: [String: String] = [
        "PDBR": "Display backlight power",
        "P3F2": "Memory power 1",
        "PZD1": "Memory power 2",
        "PN00": "SSD power",
        "PH0R": "SSD controller power 1",
        "PHCR": "SSD controller power 2",
    ]

    // ── Naming ──────────────────────────────────────────────────────────────

    /// Counter bucket for hedged temperatures. Cannot collide with a family
    /// prefix because no SMC key contains `#`.
    private static let hedgedBucket = "#thermal"

    /// The name for one key.
    ///
    /// `ordinals` carries the per-family counters and is threaded through the
    /// whole discovery pass in sorted key order, so "GPU sensor 7" means the same
    /// physical diode for the life of the process. Callers must not reset it
    /// between keys — see `Sensors.Store.discover`, which fixes every name once
    /// precisely so a sensor is not renumbered when a neighbour transiently
    /// fails the plausibility filter.
    ///
    /// - Parameter type: the SMC's declared type for the key (`flt`, `sp78`, …).
    /// - Parameter calibratedRails: whether the rails identified on one machine
    ///   apply to the machine now running.
    static func label(for key: String,
                      kind: SensorKind,
                      type: String,
                      calibratedRails ratedRails: Bool,
                      ordinals: inout [String: Int]) -> Label {

        func identified(_ text: String) -> Label { Label(text: text, confidence: .identified) }

        // 1. Exact names win over families. `Ts0P` is a palm rest even though
        //    `Ts0*` siblings are on-die, and matching here means the family
        //    counter never advances for it.
        if kind == .temperature, let name = exactTemperatures[key] { return identified(name) }

        // 2. Rails.
        if kind == .power {
            if let name = universalRails[key] { return identified(name) }
            if ratedRails, let name = calibratedRails[key] { return identified(name) }
        }

        // 3. Ordinal families, Apple Silicon only.
        if kind == .temperature, type == appleSiliconTemperatureType {
            for family in ordinalFamilies where key.hasPrefix(family.prefix) {
                let n = (ordinals[family.prefix] ?? 0) + 1
                ordinals[family.prefix] = n
                return identified("\(family.label) \(n)")
            }
        }

        // 4. Nothing we can vouch for. A temperature still gets a readable
        //    placeholder — a list of "TDER / TD23 / TDVx" is hostile, and the
        //    key survives on `SensorReading.key` for anyone who needs it. Every
        //    other kind keeps the raw key, because an unidentified rail among
        //    hundreds is more findable as `PZC0` than as "Power sensor 41".
        if kind == .temperature {
            let n = (ordinals[hedgedBucket] ?? 0) + 1
            ordinals[hedgedBucket] = n
            return Label(text: "Thermal sensor \(n)", confidence: .unidentified)
        }
        return Label(text: key, confidence: .unidentified)
    }
}
