import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The storage family: swap, SSD wear, lifetime traffic, and the write RATE.
///
/// Three claims are pinned here and each one has already been got wrong once in
/// review:
///
///   1. The IDs are the persistence format. A widget stores the raw string, so a
///      rename silently unbinds every widget and panel row a user arranged.
///   2. `bindable` is a judgement about the MENU BAR, not about usefulness. A
///      value pinned at 0 for the life of the drive is degenerate in all four
///      widget styles at once, which is the same finding that withdrew
///      `system.disk.bytesPerSec` — see `DiskActivityTests`.
///   3. `.bytesPerDay` is DECIMAL, unlike `.bytes`, because its only source is
///      DATA_UNITS_WRITTEN × 512,000 and the storage pane prints that same
///      counter decimally. Binary here would put the widget 1024⁴/1000⁴ = 9.95 %
///      away from the pane row a reader divides it into.
final class MetricRegistryStorageTests: XCTestCase {

    // ── Fixtures ────────────────────────────────────────────────────────────

    /// The pinned `NVMeHealth.Sample` contract, with everything the storage
    /// metrics do not read left at a benign value. Written in DECLARATION ORDER
    /// — this is the internal memberwise init, so a field reordered upstream is
    /// a compile error here rather than a silently transposed value.
    private func sample(writtenUnits: UInt64 = 0, readUnits: UInt64 = 0,
                        percentageUsed: UInt8 = 0, spare: UInt8 = 100,
                        threshold: UInt8 = 10, mediaErrors: UInt64 = 0,
                        criticalWarning: UInt8 = 0) -> NVMeHealth.Sample {
        NVMeHealth.Sample(criticalWarning: criticalWarning,
                          temperatureK: 313,
                          availableSpare: spare,
                          availableSpareThreshold: threshold,
                          percentageUsed: percentageUsed,
                          dataUnitsRead: readUnits,
                          dataUnitsWritten: writtenUnits,
                          hostReadCommands: 0,
                          hostWriteCommands: 0,
                          controllerBusyTimeMinutes: 0,
                          powerCycles: 0,
                          powerOnHours: 0,
                          unsafeShutdowns: 0,
                          mediaErrors: mediaErrors,
                          errorLogEntries: 0)
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "anode.tests.storage.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func anchor(_ defaults: UserDefaults? = nil) -> SSDWriteAnchor {
        SSDWriteAnchor(defaults: defaults ?? scratchDefaults())
    }

    /// A registry carrying ONLY the storage family, with every input injected.
    /// Nothing here touches IOKit, `UserDefaults.standard`, or this machine's
    /// actual drive — the same reason `DiskActivityTests` builds its own
    /// registry rather than reading `.shared`.
    private func registry(health: NVMeHealth.Sample? = nil,
                          swap: SwapUsage.Sample? = nil,
                          anchor: SSDWriteAnchor? = nil) -> MetricRegistry {
        let r = MetricRegistry()
        r.registerStorageMetrics(anchor: anchor ?? self.anchor(),
                                 readHealth: { health },
                                 readSwap: { swap })
        return r
    }

    private static let day: TimeInterval = 24 * 3600
    /// A whole number of 512,000-byte NVMe data units close to 30 × 50 GB:
    /// 2,929,688 units = 1,500,000,256,000 B, which is 50.000009 GB/day over
    /// thirty days and prints as "50GB/d". The counter only moves in whole data
    /// units, so a fixture that is exact in bytes is not reachable.
    private static let unitsFor30DaysAt50GB: UInt64 = 2_929_688
    /// 14,277,344 units = 7,310,000,128,000 B — this drive's measured lifetime
    /// written, to the hundredth of a TB the pane prints.
    private static let unitsForLifetime: UInt64 = 14_277_344

    // ── The IDs are the persistence format ──────────────────────────────────

    /// A shipped ID may never be renamed: widget configs and the panel order are
    /// stored as these exact strings, so a rename unbinds every widget bound to
    /// it and silently drops the row from every saved panel arrangement. Retire
    /// an ID, never rewrite one.
    func testTheStorageIDsAreFrozen() {
        XCTAssertEqual(MetricID.swapUsed.rawValue, "storage.swap.used")
        XCTAssertEqual(MetricID.writePerDay.rawValue, "storage.write.perDay")
        XCTAssertEqual(MetricID.ssdHealth.rawValue, "storage.ssd.health")
        XCTAssertEqual(MetricID.ssdLifeUsed.rawValue, "storage.ssd.lifeUsed")
        XCTAssertEqual(MetricID.ssdWritten.rawValue, "storage.ssd.written")
        XCTAssertEqual(MetricID.ssdRead.rawValue, "storage.ssd.read")
        XCTAssertEqual(MetricID.ssdSpare.rawValue, "storage.ssd.spare")
    }

    func testRegistrationCoversExactlyTheseSevenAndNothingElse() {
        let r = registry()
        XCTAssertEqual(Set(r.allDescriptors().map(\.id.rawValue)),
                       ["storage.swap.used", "storage.write.perDay",
                        "storage.ssd.health", "storage.ssd.lifeUsed",
                        "storage.ssd.written", "storage.ssd.read",
                        "storage.ssd.spare"])
    }

    /// POWER-ON HOURS IS NOT A METRIC, and this is the guard on that decision.
    ///
    /// `powerOnHours` is controller ACTIVE-STATE residency, measured at 4.6 % of
    /// calendar time on this machine. Any consumer that divides a lifetime total
    /// by it — the obvious thing to do with a field called "hours" — is wrong by
    /// ~22x. Registering it makes that division available to every future
    /// surface in the app with no way to stop it. It belongs in the storage pane
    /// as a row LABELLED for what it is, and nowhere else.
    func testPowerOnHoursIsNotRegisteredAsAMetric() {
        let raw = registry().allDescriptors().map { $0.id.rawValue.lowercased() }
        XCTAssertFalse(raw.contains(where: { $0.contains("poweron") || $0.contains("hours") }),
                       "power-on hours is 4.6 % of calendar time; a metric invites "
                       + "a division that is wrong by ~22x")
    }

    // ── bindable: the menu-bar judgement ────────────────────────────────────

    /// Swap was the user's one explicit menu-bar request, and it genuinely moves
    /// within a session. The rate and the health dot are the other two readings
    /// that change on a timescale a menu bar can show.
    func testOnlySwapRateAndHealthAreOfferedAsWidgets() {
        let r = registry()
        // Swap is a sysctl every Mac answers; the drive rows need a SMART drive,
        // which a VM or an Intel Mac does not have.
        let drive: Set<MetricID> = NVMeHealth.read() != nil ? [.writePerDay, .ssdHealth] : []
        XCTAssertEqual(Set(r.descriptors().map(\.id)), drive.union([.swapUsed]))
    }

    /// The four lifetime readings stay OUT of the picker and IN the registry:
    /// `value(for:)` still serves them, exactly as it serves the withdrawn
    /// `system.disk.bytesPerSec`, so the storage pane and the CLI are unaffected.
    func testTheLifetimeReadingsAreReadableButNotBindable() {
        let r = registry(health: sample(writtenUnits: 100, readUnits: 200,
                                        percentageUsed: 0, spare: 100))
        for id in [MetricID.ssdLifeUsed, .ssdWritten, .ssdRead, .ssdSpare] {
            XCTAssertFalse(r.descriptors().contains { $0.id == id },
                           "\(id.rawValue) must not be offered in the menu bar")
            XCTAssertTrue(r.allDescriptors().contains { $0.id == id },
                          "\(id.rawValue) must still be registered")
            XCTAssertNotNil(r.value(for: id), "\(id.rawValue) must still be readable")
        }
    }

    /// The reason, stated as a test so it cannot be reversed by someone who only
    /// sees an unused metric. `PERCENTAGE_USED` reads 0 and will keep reading 0
    /// for years: text renders a constant "0%", bar renders empty, dot renders
    /// green, sparkline renders flat. All four widget styles are degenerate at
    /// once — the same finding that withdrew the combined disk row.
    func testLifeUsedIsDegenerateInEveryWidgetStyle() {
        let r = registry(health: sample(percentageUsed: 0))
        let d = try! XCTUnwrap(r.descriptor(for: .ssdLifeUsed))
        let v = try! XCTUnwrap(r.value(for: .ssdLifeUsed))

        XCTAssertFalse(d.bindable)
        XCTAssertEqual(v.text, "0%")                                   // text
        XCTAssertEqual(WidgetRenderer.normalizedFraction(d.unit, v.value), 0)  // bar
        XCTAssertEqual(WidgetRenderer.severityColor(d, v), .systemGreen)       // dot
        XCTAssertEqual(v.value, 0)                                     // sparkline
    }

    /// The lifetime totals print DECIMAL, through the same `MetricUnit.siBytes`
    /// the storage pane row uses.
    ///
    /// `MetricUnit.bytes` renders this drive's 7.31 TB as "6.6 TB" (7.31e12 ÷
    /// 1024⁴ = 6.648). One quantity, the same glyphs, 10 % apart between the pane
    /// and the `anode --metrics` dump — a difference small enough to be mistaken
    /// for a real change in what the machine has written. The value stays raw
    /// bytes; only the text is spelled.
    func testTheLifetimeTotalsAreSpelledDecimally() {
        let r = registry(health: sample(writtenUnits: Self.unitsForLifetime))
        let v = try! XCTUnwrap(r.value(for: .ssdWritten))
        XCTAssertEqual(v.text, "7.31 TB")
        XCTAssertEqual(v.text, MetricUnit.siBytes(7_310_000_128_000))
        XCTAssertEqual(v.value, 7_310_000_128_000)
        XCTAssertNotEqual(v.text, MetricUnit.bytes.format(7_310_000_128_000),
                          "binary would render the same counter as 6.6 TB")
    }

    // ── Units ───────────────────────────────────────────────────────────────

    /// Storage metrics are TOTALS and a rate-per-DAY. None of them is
    /// throughput. `.bytesPerSecond` here would be claiming an instantaneous
    /// figure that the NVMe log page cannot produce — it publishes monotonic
    /// lifetime counters, not a rate — and it would put a second, worse answer
    /// beside the real `system.disk.write` widget.
    func testNoStorageMetricIsThroughput() {
        for d in registry().allDescriptors() {
            XCTAssertNotEqual(d.unit, .bytesPerSecond,
                              "\(d.id.rawValue): storage is totals and per-day, never throughput")
        }
    }

    func testTheUnitOfEachStorageMetric() {
        let r = registry()
        func unit(_ id: MetricID) -> MetricUnit? { r.descriptor(for: id)?.unit }
        XCTAssertEqual(unit(.swapUsed), .bytes)
        XCTAssertEqual(unit(.writePerDay), .bytesPerDay)
        XCTAssertEqual(unit(.ssdHealth), .ratio)
        XCTAssertEqual(unit(.ssdLifeUsed), .percent)
        XCTAssertEqual(unit(.ssdWritten), .bytes)
        XCTAssertEqual(unit(.ssdRead), .bytes)
        XCTAssertEqual(unit(.ssdSpare), .percent)
    }

    // ── .bytesPerDay formatting ─────────────────────────────────────────────

    /// Menu-bar tight, and DECIMAL.
    ///
    /// The divisor is 1000, NOT `.bytes`' 1024, and the rule behind that is that
    /// the basis follows the SOURCE. The only thing that ever feeds this unit is
    /// `NVMeHealth.Sample.bytesWritten` — DATA_UNITS_WRITTEN × 512,000, decimal
    /// by the NVMe spec — and the storage pane prints that same counter through
    /// `MetricUnit.siBytes`, captioned "TB above are decimal". A binary rate
    /// under a decimal total is 1024⁴/1000⁴ = 9.95 % of contradiction between two
    /// figures a reader divides into each other. `.bytes` stays binary because
    /// its sources (memory, caches, volume capacities) are what macOS itself
    /// shows in 1024s.
    func testBytesPerDayFormatting() {
        let u = MetricUnit.bytesPerDay
        XCTAssertEqual(u.format(0), "0B/d")
        XCTAssertEqual(u.format(340e6), "340MB/d")
        XCTAssertEqual(u.format(50e9), "50GB/d")
        XCTAssertEqual(u.format(1.2e12), "1.2TB/d")
        // Non-finite is "—" for every unit: upstream is undocumented and a menu
        // bar reading "nanGB/d" is the startup breakage this app exists to avoid.
        XCTAssertEqual(u.format(.nan), "—")
        XCTAssertEqual(u.format(.infinity), "—")
    }

    /// One decimal below 10, none above — the `.percentPerHour` idiom, not the
    /// `.bytesPerSecond` one. A 30-day mean is not precise to 0.1 GB when it is
    /// 50 GB, and "50.0GB/d" spends two characters of scarce menu-bar width
    /// asserting a precision the measurement does not have.
    func testBytesPerDayDropsTheDecimalAboveTen() {
        XCTAssertEqual(MetricUnit.bytesPerDay.format(9.5e9), "9.5GB/d")
        XCTAssertEqual(MetricUnit.bytesPerDay.format(12e9), "12GB/d")
    }

    /// The sign is KEPT, unlike `.bytesPerSecond`, which formats `abs`.
    ///
    /// The anchor can never publish a negative rate — it re-anchors instead —
    /// so a negative here means a caller bypassed the anchor, and printing it
    /// as a positive would hide that bug behind a plausible number.
    func testBytesPerDayKeepsTheSignSoABadCallerIsVisible() {
        XCTAssertEqual(MetricUnit.bytesPerDay.format(-50e9), "-50GB/d")
    }

    // ── .bytesPerDay severity: deliberately none ────────────────────────────

    /// NO BOUND, and the reasoning, because a write rate LOOKS like it has one.
    ///
    /// A full scale is a claim about every machine and every user. The only
    /// measurement behind one would be a single machine's habit: 52.2 GB/day over
    /// this drive's lifetime and 47.2 GB/day over a fresh 22 h window, agreeing to
    /// 9 %. Two views of ONE machine is n = 1. A bar scaled to it would colour a
    /// developer's laptop yellow and a video editor's red while having measured
    /// nothing about either.
    ///
    /// AND NO SCALE MAY BE DERIVED FROM DRIVE ENDURANCE. The 612 TB figure
    /// originally proposed for exactly that is not uncertain, it is FALSIFIED:
    /// `percentageUsed` still reads 0 at 7.31 TB written, which puts the
    /// manufacturer's own basis above 731 TB. What is left is a LOWER bound, and a
    /// lower bound is not a scale — it can say the rate is safer than assumed, and
    /// never how much of anything it is using.
    ///
    /// What is withdrawn is the SCALE, not the reading: text, textWithLabel and
    /// sparkline all still say something, and only the dot and the bar go neutral,
    /// exactly as they already do for the shipped `system.disk.read` and `.write`
    /// widgets. The thing a coloured write rate would have stood in for already
    /// exists, measured: `storage.ssd.lifeUsed` is the wear the drive itself
    /// reports, and `storage.ssd.health` is the dot that colours — on alarms that
    /// have happened, not on a projection.
    func testBytesPerDayHasNoSeverityScale() {
        for v in [0, 1e9, 5e10, 1e13, -1e9, Double.nan] {
            XCTAssertNil(WidgetRenderer.normalizedFraction(.bytesPerDay, v),
                         "a write rate has no defensible bound: see the doc comment")
        }
        let r = registry()
        let d = try! XCTUnwrap(r.descriptor(for: .writePerDay))
        XCTAssertEqual(WidgetRenderer.severityColor(d, MetricValue(5e10, unit: .bytesPerDay,
                                                                   isEstimate: false)),
                       .secondaryLabelColor, "neutral, not a colour we cannot justify")
    }

    /// The unit is CaseIterable and several tests iterate it; the product rule
    /// it carries is that watts are never user-visible, and a new case must not
    /// smuggle one in.
    func testTheNewUnitIsNotAWattInDisguise() {
        XCTAssertTrue(MetricUnit.allCases.contains(.bytesPerDay))
        XCTAssertFalse("\(MetricUnit.bytesPerDay)".lowercased().contains("watt"))
    }

    // ── Swap ────────────────────────────────────────────────────────────────

    func testSwapUsedIsTheUsedBytesAndSitsWithMemory() {
        let r = registry(swap: SwapUsage.Sample(totalBytes: 1024 * 1024 * 1024,
                                                usedBytes: 262_144, isEncrypted: true))
        let v = try! XCTUnwrap(r.value(for: .swapUsed))
        XCTAssertEqual(v.value, 262_144)
        XCTAssertEqual(v.text, "256 KB")   // `.bytes` drops the decimal at 100
        XCTAssertFalse(v.isEstimate, "a sysctl counter is not a model")
        XCTAssertEqual(r.descriptor(for: .swapUsed)?.category, "Memory")
    }

    /// A machine that has never swapped reports zero used, and zero IS the
    /// measurement — it must render as "0 B", not as "—". "—" is reserved for a
    /// reading we could not take, which is what a failed sysctl gives.
    func testZeroSwapIsAMeasurementAndAFailedReadIsNot() {
        let never = registry(swap: SwapUsage.Sample(totalBytes: 0, usedBytes: 0,
                                                    isEncrypted: false))
        XCTAssertEqual(never.value(for: .swapUsed)?.text, "0 B")
        XCTAssertNil(registry(swap: nil).value(for: .swapUsed))
    }

    // ── Drive health: measured alarms only ──────────────────────────────────

    /// 1.0 with the text "OK" — no alarm is a fact about the drive, not a
    /// missing reading, so it renders as a green dot rather than a grey one.
    func testAHealthyDriveIsOneAndReadsOK() {
        let r = registry(health: sample(percentageUsed: 0, spare: 100, threshold: 10))
        let d = try! XCTUnwrap(r.descriptor(for: .ssdHealth))
        let v = try! XCTUnwrap(r.value(for: .ssdHealth))
        XCTAssertEqual(v.value, 1)
        XCTAssertEqual(v.text, "OK")
        XCTAssertFalse(v.isEstimate, "no projection enters this metric")
        XCTAssertEqual(WidgetRenderer.severityColor(d, v), .systemGreen)
    }

    /// Ordinary wear is not an alarm. The counter only climbs, so a yellow dot
    /// at 1 % stayed yellow for the life of the machine on a drive the drive
    /// itself rates as barely used.
    func testOrdinaryWearReadsOKAndLateWearDoesNot() {
        let d = MetricDescriptor(id: .ssdHealth, title: "Drive health",
                                 shortTitle: "SSD", unit: .ratio,
                                 category: "Storage", higherIsWorse: false)
        let early = try! XCTUnwrap(registry(health: sample(percentageUsed: 5)).value(for: .ssdHealth))
        XCTAssertEqual(early.text, "OK")
        XCTAssertEqual(WidgetRenderer.severityColor(d, early), .systemGreen)

        let late = try! XCTUnwrap(registry(health: sample(percentageUsed: 85)).value(for: .ssdHealth))
        XCTAssertEqual(late.text, "WEAR 85%")
        XCTAssertEqual(WidgetRenderer.severityColor(d, late), .systemYellow)

        let spent = try! XCTUnwrap(registry(health: sample(percentageUsed: 100)).value(for: .ssdHealth))
        XCTAssertEqual(spent.text, "WORN 100%")
        XCTAssertEqual(WidgetRenderer.severityColor(d, spent), .systemRed)

        // A real fault still wins over quiet wear.
        let fault = try! XCTUnwrap(registry(health: sample(percentageUsed: 5, mediaErrors: 2))
            .value(for: .ssdHealth))
        XCTAssertEqual(fault.text, "2 ERRORS")
    }

    /// THE POLARITY, pinned against the renderer that would invert it.
    ///
    /// The first draft made 0.0 healthy with `higherIsWorse: true`, which reads
    /// fine as "zero alarms" until something formats the VALUE:
    /// `MetricUnit.ratio.format(0.0)` is "0%", and "Drive health  0%" under a
    /// confident-looking title is the exact opposite of the truth.
    ///
    /// "`text` is always overridden" is not a defence. That is a property of the
    /// two providers, not of the descriptor, and the next consumer — a graph
    /// axis, a tooltip, a CSV export — will format `value` through `unit` the way
    /// every other metric in this registry is formatted. This test asserts the
    /// number survives that treatment.
    func testAHealthyDriveSurvivesBeingFormattedByItsOwnUnit() {
        let r = registry(health: sample())
        let d = try! XCTUnwrap(r.descriptor(for: .ssdHealth))
        let v = try! XCTUnwrap(r.value(for: .ssdHealth))
        XCTAssertFalse(d.higherIsWorse, "higher health must be better")
        XCTAssertEqual(d.unit.format(v.value), "100%",
                       "a consumer that ignores `text` must not read a healthy "
                       + "drive as 0 %")
        XCTAssertEqual(d.unit.format(MetricRegistry.alarmHealth(.mediaErrors(12))), "0%")
    }

    /// The escalation is on MEASURED transitions and nothing else. Media errors,
    /// a spare below the drive's own threshold and a critical-warning bit are
    /// all things that have happened; wear leaving 0 is a real transition but
    /// not yet a fault, so it stops at yellow.
    ///
    /// These colours are UNCHANGED by the 0-healthy → 1-healthy flip:
    /// `severityColor` computes `badness = higherIsWorse ? f : 1 - f`, so each
    /// alarm's badness is the same number it was under the old polarity.
    func testTheSeverityLadderMapsOntoTheThreeDotColours() {
        let d = MetricDescriptor(id: .ssdHealth, title: "Drive health",
                                 shortTitle: "SSD", unit: .ratio,
                                 category: "Storage", higherIsWorse: false)
        func colour(_ alarm: NVMeHealth.Alarm) -> NSColor {
            WidgetRenderer.severityColor(
                d, MetricValue(value: MetricRegistry.alarmHealth(alarm),
                               text: MetricRegistry.alarmText(alarm), isEstimate: false))
        }
        XCTAssertEqual(colour(.wearStarted(1)), .systemYellow)
        XCTAssertEqual(colour(.mediaErrors(12)), .systemRed)
        XCTAssertEqual(colour(.spareBelowThreshold(8, threshold: 10)), .systemRed)
        XCTAssertEqual(colour(.criticalWarning(0x04)), .systemRed)
    }

    /// The text is a free string on `MetricValue`, not `MetricUnit.ratio`'s
    /// formatting of the value: a dot's tooltip and the panel row have to say
    /// WHICH alarm, and "60%" says nothing at all.
    func testTheTextNamesTheAlarm() {
        XCTAssertEqual(MetricRegistry.alarmText(.spareBelowThreshold(98, threshold: 10)),
                       "SPARE 98%")
        XCTAssertEqual(MetricRegistry.alarmText(.mediaErrors(12)), "12 ERRORS")
        XCTAssertEqual(MetricRegistry.alarmText(.wearStarted(1)), "WEAR 1%")
        XCTAssertEqual(MetricRegistry.alarmText(.criticalWarning(0x04)), "WARN 0x04")
    }

    /// No SMART user client — an Intel Mac, a VM, an external bridge — is an
    /// ABSENT measurement. Every storage metric answers nil, and none of them
    /// invents a zero that would read as a healthy drive.
    func testNoDriveMeansNilAndNeverAReassuringZero() {
        let r = registry(health: nil)
        for id in [MetricID.ssdHealth, .ssdLifeUsed, .ssdWritten, .ssdRead,
                   .ssdSpare, .writePerDay] {
            XCTAssertNil(r.value(for: id), "\(id.rawValue) invented a reading")
        }
    }

    // ── The anchor ──────────────────────────────────────────────────────────

    /// NOTHING is published before 30 days.
    ///
    /// Short windows run high and converge slowly: measured on this machine, the
    /// this-boot rate stood at 2.14x the lifetime rate after 29.8 h of uptime
    /// and was still 1.64x it at 51.7 h. And the events that dominate a month of
    /// writes arrive on a week/month cadence — one OS update accounted for 23 %
    /// of a whole boot's writes. A figure quoted at day 3 is a figure about
    /// whatever happened in those three days.
    func testNoRateIsPublishedBeforeThirtyDays() {
        let a = anchor()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        a.observe(bytesWritten: 0, now: t0)

        XCTAssertNil(a.rate(bytesWritten: 5_000_000_000, now: t0))
        XCTAssertNil(a.rate(bytesWritten: 5_000_000_000,
                            now: t0 + 29.99 * Self.day))
        XCTAssertNotNil(a.rate(bytesWritten: 5_000_000_000, now: t0 + 30 * Self.day),
                        "the gate is >= 30 days, not > 30 days")
    }

    func testNoAnchorMeansNoRate() {
        XCTAssertNil(anchor().rate(bytesWritten: 5_000_000_000))
    }

    func testTheRateIsTheDeltaOverTheElapsedDays() {
        let a = anchor()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        a.observe(bytesWritten: 1_000_000, now: t0)
        let delta = 30.0 * 50e9                              // 30 days at 50 GB/day
        let r = try! XCTUnwrap(a.rate(bytesWritten: 1_000_000 + UInt64(delta),
                                      now: t0 + 30 * Self.day))
        XCTAssertEqual(r, 50e9, accuracy: 1)
        XCTAssertEqual(MetricUnit.bytesPerDay.format(r), "50GB/d")
    }

    /// A drive that wrote nothing in thirty days genuinely wrote nothing.
    /// Zero is the measurement; nil would say we never looked.
    func testAnIdleDriveReportsZeroNotNil() {
        let a = anchor()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        a.observe(bytesWritten: 4_000_000_000, now: t0)
        XCTAssertEqual(a.rate(bytesWritten: 4_000_000_000, now: t0 + 31 * Self.day), 0)
    }

    // ── The counter going backwards ─────────────────────────────────────────

    /// A LIFETIME counter that fell is not this drive.
    ///
    /// The counter is monotonic for a given controller, so a smaller reading
    /// means the hardware underneath changed — a replaced SSD, a logic-board
    /// swap, or this preferences file restored onto a different machine. The
    /// stored anchor describes a drive that is no longer here, and the delta
    /// against it is meaningless and NEGATIVE.
    ///
    /// Reads never publish it: `rate` returns nil rather than a negative rate.
    func testAFallenCounterPublishesNoRateRatherThanANegativeOne() {
        let a = anchor()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        a.observe(bytesWritten: 8_000_000_000_000, now: t0)
        XCTAssertNil(a.rate(bytesWritten: 12_000_000_000, now: t0 + 60 * Self.day),
                     "a replaced drive must not read as a negative write rate")
    }

    /// And the next launch re-anchors on the new device, restarting the 30-day
    /// window rather than inheriting a basis from hardware that is gone.
    func testTheNextLaunchReAnchorsOnTheNewDevice() {
        let d = scratchDefaults()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        anchor(d).observe(bytesWritten: 8_000_000_000_000, now: t0)

        let later = t0 + 60 * Self.day
        let fresh = anchor(d)                       // a new launch, same defaults
        fresh.observe(bytesWritten: 12_000_000_000, now: later)
        XCTAssertEqual(fresh.anchor()?.bytesWritten, 12_000_000_000)
        XCTAssertEqual(fresh.anchor()?.startedAt, later)
        // The window restarts: nothing is published until it is 30 days old again.
        XCTAssertNil(fresh.rate(bytesWritten: 60_000_000_000, now: later + 5 * Self.day))
        XCTAssertNotNil(fresh.rate(bytesWritten: 60_000_000_000, now: later + 30 * Self.day))
    }

    /// A launch on a drive that has only grown must NOT reset the window — that
    /// would make the 30-day gate unreachable for anyone who quits the app.
    func testAnOrdinaryLaunchLeavesTheAnchorAlone() {
        let d = scratchDefaults()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        anchor(d).observe(bytesWritten: 1_000_000, now: t0)

        let fresh = anchor(d)
        fresh.observe(bytesWritten: 900_000_000_000, now: t0 + 40 * Self.day)
        XCTAssertEqual(fresh.anchor()?.startedAt, t0)
        XCTAssertNotNil(fresh.rate(bytesWritten: 900_000_000_000, now: t0 + 40 * Self.day))
    }

    /// A clock that moved BACKWARDS must not cost 30 days of window.
    ///
    /// A boot before NTP settles reads minutes or hours in the past, and
    /// re-anchoring on that would restart the gate for a skew that corrects
    /// itself in seconds. The rate is simply withheld while `now` is behind the
    /// anchor (a negative span cannot clear a 30-day gate), and only a clock a
    /// FULL GATE in the past — a wrong year, not a skew — is treated as
    /// evidence that the stored date is unusable.
    func testASmallBackwardsClockWithholdsTheRateWithoutDestroyingTheAnchor() {
        let d = scratchDefaults()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        anchor(d).observe(bytesWritten: 1_000_000, now: t0)

        let skewed = anchor(d)
        skewed.observe(bytesWritten: 2_000_000, now: t0 - 3600)     // an hour behind
        XCTAssertEqual(skewed.anchor()?.startedAt, t0, "an hour of skew reset the window")
        XCTAssertNil(skewed.rate(bytesWritten: 2_000_000, now: t0 - 3600))

        let wrongYear = anchor(d)
        wrongYear.observe(bytesWritten: 2_000_000, now: t0 - 400 * Self.day)
        XCTAssertEqual(wrongYear.anchor()?.startedAt, t0 - 400 * Self.day,
                       "a date a full gate in the future is unusable, not a skew")
    }

    /// The anchor survives the process, because a 30-day window that resets on
    /// every launch is a window that never closes. Same persistence shape as
    /// `ChargeLimitLearner`: one plist value in UserDefaults, not the SQLite
    /// history store — this is a setting-sized fact, not a time series.
    func testTheAnchorSurvivesRelaunch() {
        let d = scratchDefaults()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        anchor(d).observe(bytesWritten: 7_310_000_000_000, now: t0)

        let reloaded = anchor(d).anchor()
        XCTAssertEqual(reloaded?.bytesWritten, 7_310_000_000_000)
        XCTAssertEqual(reloaded?.startedAt, t0)
    }

    /// Both halves of the anchor are written under ONE key, so a crash between
    /// two `set` calls cannot leave a byte count paired with someone else's
    /// date. A half-written anchor is no anchor.
    func testAHalfWrittenAnchorIsNoAnchor() {
        let d = scratchDefaults()
        d.set(["bytes": 12_345], forKey: SSDWriteAnchor.storeKey)
        XCTAssertNil(anchor(d).anchor())
        XCTAssertNil(anchor(d).rate(bytesWritten: 99_999_999_999))
    }

    // ── The metric on top of the anchor ─────────────────────────────────────

    func testTheWriteRateMetricIsSilentUntilTheAnchorIsThirtyDaysOld() {
        let s = sample(writtenUnits: Self.unitsFor30DaysAt50GB)

        // Separate anchors, because an established anchor is deliberately not
        // movable by a later `observe` — see `testAnOrdinaryLaunchLeavesTheAnchorAlone`.
        let young = anchor()
        young.observe(bytesWritten: 0, now: Date().addingTimeInterval(-5 * Self.day))
        XCTAssertNil(registry(health: s, anchor: young).value(for: .writePerDay),
                     "five days of history must not be quoted as a per-day rate")

        let old = anchor()
        old.observe(bytesWritten: 0, now: Date().addingTimeInterval(-30 * Self.day))
        let v = try! XCTUnwrap(registry(health: s, anchor: old).value(for: .writePerDay))
        XCTAssertEqual(v.text, "50GB/d")
        // A difference of two measured counters over a measured interval. It is
        // not extrapolated past the window it was measured over, so it carries
        // no "*" — unlike time-to-empty, which is.
        XCTAssertFalse(v.isEstimate)
    }
}
