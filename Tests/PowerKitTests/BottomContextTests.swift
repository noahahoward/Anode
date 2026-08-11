import XCTest
@testable import BetterStatsApp
@testable import PowerKit

/// The bottom of the window follows the SORT.
///
/// Sorting the process table by CPU is a statement that CPU is the question, and
/// answering it with a battery breakdown is three panels describing something the
/// user has just said they are not looking at.
final class BottomContextTests: XCTestCase {

    func testTheSortColumnPicksTheSubject() {
        XCTAssertEqual(BottomContext.forSortKey("cpu"), .cpu)
        XCTAssertEqual(BottomContext.forSortKey("gpuPct"), .gpu)
        XCTAssertEqual(BottomContext.forSortKey("gputime"), .gpu)
        XCTAssertEqual(BottomContext.forSortKey("memPct"), .memory)
        XCTAssertEqual(BottomContext.forSortKey("mem"), .memory)
    }

    /// The battery columns stay on battery, including the one that names the GPU.
    /// "GPU %/hr" is a battery cost: sorting by it asks what is draining the
    /// battery, not what is loading the GPU.
    func testTheDrainColumnsStayOnBattery() {
        for key in ["pctHr", "window", "cost", "gpuPctHr"] {
            XCTAssertEqual(BottomContext.forSortKey(key), .battery, key)
        }
    }

    /// Columns that name no subsystem leave the question open rather than
    /// answering it with a guess.
    func testColumnsThatNameNoSubjectFallBackToBattery() {
        for key in ["name", "procs", "somethingAddedLater"] {
            XCTAssertEqual(BottomContext.forSortKey(key), .battery, key)
        }
    }

    /// Both disk columns land on one subject, whose graph draws both lines.
    /// Sorting by writes says disk is the question, not that reads stopped
    /// mattering — and the two come off the same counter pair on the same tick.
    func testBothDiskColumnsShareOneSubject() {
        XCTAssertEqual(BottomContext.forSortKey("diskRead"), .disk)
        XCTAssertEqual(BottomContext.forSortKey("diskWrite"), .disk)
    }

    /// Every column the table actually has resolves to something. A column added
    /// later without a mapping gets battery, which is a defensible default and not
    /// a crash.
    func testEveryRealColumnResolves() {
        for column in ProcessColumns.all(powerWindowHours: 10) {
            _ = BottomContext.forSortKey(column.id)
        }
    }

    // ── The bar's slices ────────────────────────────────────────────────────

    /// Apps, system processes, and the measured remainder that belongs to
    /// neither — the battery bar's shape, because it is the honest one for any
    /// quantity measured whole and attributed in part.
    func testTheRemainderIsWhatTheTotalDoesNotExplain() {
        let s = UtilizationSlices(total: 40, apps: 25, systemProcesses: 10)
        XCTAssertEqual(s.unattributed, 5, accuracy: 0.001)
        XCTAssertEqual(s.used, 40, accuracy: 0.001)
    }

    /// The per-process figures and the whole-device figure are sampled a moment
    /// apart, so they disagree in both directions. A negative remainder is that
    /// disagreement, not a discovery, and drawing it would put a slice on the bar
    /// for something that does not exist.
    func testAnOverAttributedSampleShowsNoNegativeSlice() {
        let s = UtilizationSlices(total: 30, apps: 25, systemProcesses: 10)
        XCTAssertEqual(s.unattributed, 0)
        XCTAssertEqual(s.used, 35, accuracy: 0.001,
                       "the named parts are still shown at what they measured")
    }

    /// Idle never enters: the bar is the used portion, and a bar that is 85 %
    /// "nothing is happening" says less than the same bar without it.
    func testIdleIsNeverASlice() {
        let s = UtilizationSlices(total: 12, apps: 8, systemProcesses: 3)
        XCTAssertEqual(s.used, 12, accuracy: 0.001,
                       "the bar covers the used portion, not the device")
    }

    /// Only the subjects that are actually persisted offer long ranges. A 7D
    /// button that draws an empty plot is a worse answer than no button.
    func testEverySubjectOffersOnlyRangesItCanAnswer() {
        for c in BottomContext.allCases {
            XCTAssertFalse(c.ranges.isEmpty, "\(c) draws a graph but offers no range")
        }
    }

    /// A subject with no history must never be asked the store for it.
    ///
    /// Clicking beside the range pill lands on the graph, which zooms it — and a
    /// zoomed graph is a historical one, so it went to the store. The store has
    /// never held a temperature, so the query returned nothing and the caller fell
    /// through to the generic utilisation path: a temperature graph titled
    /// "% TEMPERATURE" on a 0-100 axis over "no history yet".
    ///
    /// `isSessionOnly` is what the history path checks, and it must agree with the
    /// range list: a subject offering only the live hour is exactly a subject with
    /// nothing stored.
    func testTheSubjectsWithNoStoredHistoryAreTheOnesOfferingOnlyTheLiveHour() {
        for c in BottomContext.allCases {
            XCTAssertEqual(c.isSessionOnly, c.ranges == [3600],
                           "\(c) disagrees with itself about whether it has history")
        }
        XCTAssertTrue(BottomContext.sensors.isSessionOnly)
        XCTAssertTrue(BottomContext.fans.isSessionOnly)
        XCTAssertFalse(BottomContext.network.isSessionOnly,
                       "network IS stored — net_in_bps and net_out_bps")
    }

    /// The RIGHT axis prints the unit it is actually counted in.
    ///
    /// It printed "%" unconditionally, because it had exactly one caller: battery
    /// charge. The fan graph puts a temperature there and inherited ticks reading
    /// "0%, 25%, 50%, 100%" beside a line in degrees — and a 51 °C reading sitting
    /// on the 50% gridline looks plausible, which is the worst kind of wrong.
    func testTheRightAxisPrintsTheUnitItCounts() {
        let g = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        XCTAssertEqual(g.rightAxisUnit, "%", "battery charge is the default and is a percent")
        g.rightAxisUnit = "°C"
        XCTAssertEqual(g.rightAxisUnit, "°C")
    }

    /// And a temperature never gets a percent axis, whichever path drew it.
    func testATemperatureIsNeverLabelledAsAPercentage() {
        for c in [BottomContext.sensors, .fans] {
            XCTAssertNotEqual(c.unit, "%", "\(c) is not a fraction of anything")
            XCTAssertFalse(c.isPercentage)
        }
        XCTAssertEqual(BottomContext.sensors.unit, "°C")
    }

    /// The session-only subjects offer the hour and nothing beyond it.
    ///
    /// Temperatures and fan speeds are never written to the store: the SMC sweep
    /// is gated on a tab that reads it being open, so there is no week of them to
    /// draw. This is the case the per-subject range list exists for — every other
    /// subject is persisted, so until these arrived the list could have been one
    /// constant and nobody would have noticed.
    func testTheSessionOnlySubjectsOfferTheHourAlone() {
        for c in [BottomContext.sensors, .fans] {
            XCTAssertEqual(c.ranges, [3600], "\(c) promises history it never stored")
        }
    }

    /// The tab wins over the sort everywhere except Processes, where there is no
    /// tab-level subject to win with.
    ///
    /// Sorting by CPU and then opening Fans used to leave a CPU graph under a fan
    /// pane — the same defect as the Resources rail changing its highlight and
    /// leaving the readings behind, one level up.
    func testTheTabPicksTheSubjectAndTheSortOnlyDecidesOnProcesses() {
        func subject(_ lens: SidebarView.Lens, _ key: String = "cpu",
                     _ resource: Resource = .cpu) -> BottomContext {
            BottomContext.forLens(lens, sortKey: key, resource: resource)
        }
        XCTAssertEqual(subject(.fans), .fans)
        XCTAssertEqual(subject(.network), .network)
        XCTAssertEqual(subject(.sensors, "memPct"), .sensors)
        // Processes has no subject of its own, so the sort keeps deciding.
        XCTAssertEqual(subject(.processes, "cpu"), .cpu)
        XCTAssertEqual(subject(.processes, "diskRead"), .disk)
        XCTAssertEqual(subject(.processes, "pctHr"), .battery)
    }

    /// Six cards behind one tab, and the bottom follows the card. A rail whose
    /// selection the bottom ignored would answer Memory with a CPU card.
    func testTheResourcesRailSelectionPicksTheSubject() {
        for (resource, expected): (Resource, BottomContext) in [
            (.cpu, .cpu), (.memory, .memory), (.gpu, .gpu),
            (.network, .network), (.disk, .disk), (.sensors, .sensors),
        ] {
            XCTAssertEqual(
                BottomContext.forLens(.resources, sortKey: "pctHr", resource: resource),
                expected, "\(resource)")
        }
    }

    /// EVERY resource the rail can select resolves to a subject. A card that can
    /// be clicked and leaves the bottom describing something else is worse than a
    /// card that cannot be clicked.
    func testEveryRailCardHasASubject() {
        let subjects = Resource.allCases.map { BottomContext.forResource($0) }
        XCTAssertEqual(Set(subjects).count, Resource.allCases.count,
                       "two rail cards share one subject, so one of them lies")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// What the graph does when the subject changes.
final class BottomGraphContextTests: XCTestCase {

    /// A utilisation is a percentage of a fixed whole, so its axis is pinned. An
    /// autoscaled one makes 4 % and 40 % look identical, and the height is the
    /// entire reading.
    ///
    /// Disk is the exception and has to be: bytes per second has no ceiling to
    /// divide by, so it autoscales. `isPercentage` is the flag both the live and
    /// the historical path read, so it is what this asserts against rather than
    /// re-listing the cases — a subject added later gets caught by the unit check
    /// below instead of silently pinning its axis at 100.
    func testAUtilisationGraphPinsItsAxisAndABatteryGraphDoesNot() {
        for c in BottomContext.allCases where c.isPercentage && c != .battery {
            XCTAssertEqual(c.unit, "%", "\(c) claims to be a percentage")
        }
        XCTAssertEqual(BottomContext.battery.unit, "%/hr")
        XCTAssertFalse(BottomContext.disk.isPercentage,
                       "a byte rate has no ceiling to be a percentage of")
        XCTAssertEqual(BottomContext.disk.unit, "B/s")
    }

    /// The subjects that offer a week are exactly the ones the store persists.
    /// A range button that draws an empty plot is a worse answer than no button.
    func testTheLongRangesMatchWhatIsActuallyStored() {
        // cpu_pct, mem_pct and gpu_pct are columns on the interval table, written
        // every tick beside the power figures.
        for c in [BottomContext.cpu, .gpu, .memory, .battery] {
            XCTAssertTrue(c.ranges.contains(7 * 24 * 3600),
                          "\(c) is persisted but does not offer a week")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The bar and the card, for a subject that is not the battery.
final class BottomPanelTests: XCTestCase {

    private func sys(cpu: CPUUsage.Sample? = nil,
                     memory: MemoryUsage.Sample? = nil,
                     disk: DiskActivity.Sample? = nil,
                     network: NetworkThroughput.Sample? = nil,
                     fans: [FanInfo] = []) -> SystemMetrics.Snapshot {
        SystemMetrics.Snapshot(cpu: cpu, memory: memory, gpu: nil, network: network,
                               disk: disk, cpuTemperature: nil, gpuTemperature: nil,
                               fans: fans)
    }

    /// Memory is cut by KIND, not into apps and daemons — the kernel reports it
    /// that way and it is the more useful cut: wired cannot be paged out, and
    /// compressed is pressure that has already happened.
    func testTheMemoryBarIsCutByKindAndHasNothingUnattributed() {
        let bar = LedgerBarView.UtilizationBar.memory(app: 30, wired: 12, compressed: 5)
        XCTAssertEqual(bar.parts.map(\.title), ["app", "wired", "compressed"])
        XCTAssertEqual(bar.used, 47, accuracy: 0.001)
        XCTAssertFalse(bar.parts.contains { $0.hatched },
                       "memory has no unattributed part to hatch")
    }

    /// CPU and GPU keep the battery bar's shape, including the hatched remainder:
    /// something measured whole, attributed in part, with the rest shown rather
    /// than folded into a neighbour.
    func testAnAttributedBarAlwaysMarksItsRemainder() {
        let bar = LedgerBarView.UtilizationBar.attributed(
            "CPU", UtilizationSlices(total: 40, apps: 25, systemProcesses: 10))
        XCTAssertEqual(bar.parts.map(\.title), ["apps", "system processes", "unattributed"])
        XCTAssertTrue(bar.parts.last?.hatched ?? false,
                      "the part that could not be named is not marked as such")
        XCTAssertEqual(bar.used, 40, accuracy: 0.001)
    }

    /// The GPU bar says its split is slower than its total. Per-app GPU is a
    /// coalition rollup at ~30-60 s while the device figure is read every tick,
    /// so the parts step while the whole moves — which looks like a stall.
    func testTheGPUBarDisclosesItsSlowerAttribution() {
        let bar = LedgerBarView.UtilizationBar.attributed(
            "GPU", UtilizationSlices(total: 20, apps: 12, systemProcesses: 3),
            note: "per-app GPU updates every ~30-60 s")
        XCTAssertNotNil(bar.attributionNote)
        // And the CPU bar does not, because its parts and its whole are both read
        // every tick.
        XCTAssertNil(LedgerBarView.UtilizationBar.attributed(
            "CPU", UtilizationSlices(total: 20, apps: 12, systemProcesses: 3)).attributionNote)
    }

    /// The card states the same number its headline does, and names its facts.
    func testTheCPUCardShowsTheChipAndTheSplit() throws {
        let s = sys(cpu: CPUUsage.Sample(total: 16.4, user: 12.4, system: 4.1,
                                         idle: 83.6, interval: 2))
        let m = try XCTUnwrap(GlanceCardView.model(for: .cpu, system: s,
                                                   facts: MachineInfo.facts, census: nil))
        XCTAssertEqual(m.headline, "16.4%")
        // No pill: the headline is already the percentage, and printing it again
        // rounded differently is what "10.7%" over "11% · CPU · measured" was.
        XCTAssertNil(m.pill)
        // Paired into three rows to fit the card's height, so this asserts the
        // FACTS survived rather than the labels — user and system share a row now,
        // and cores carries threads. Truncating instead of pairing is what this
        // guards against: every number that was here is still here.
        let text = m.rows.map { "\($0.label) \($0.value) \($0.trailing ?? "")" }.joined(separator: "|")
        XCTAssertTrue(m.rows.contains { $0.label == "Chip" })
        XCTAssertTrue(text.contains("12.4%"), "user time was dropped, not paired")
        XCTAssertTrue(text.contains("4.1%"), "system time was dropped, not paired")
    }

    /// Disk keeps the attributed shape but counts in bytes per second, and it has
    /// to: there is no ceiling to divide by, so nothing here is a percentage.
    func testTheDiskBarCountsInBytesRatherThanPercent() {
        let bar = LedgerBarView.UtilizationBar.attributed(
            "Disk", UtilizationSlices(total: 4_194_304, apps: 1_048_576,
                                      systemProcesses: 524_288),
            scale: .bytesPerSecond)
        XCTAssertEqual(bar.parts.map(\.title), ["apps", "system processes", "unattributed"])
        XCTAssertEqual(bar.scale, .bytesPerSecond)
        // Through the app's own byte formatter, so the bar and the Disk columns
        // cannot disagree about what a megabyte is — this app counts in 1024s, and
        // a hand-rolled divisor here is how "977KB/s" and "1.0MB/s" end up side by
        // side on one screen.
        XCTAssertEqual(bar.scale(1_048_576), "1.0MB/s")
        XCTAssertEqual(bar.scale(1_048_576),
                       MetricUnit.bytesPerSecond.format(1_048_576))
    }

    /// The axis plots MiB/s and says "MB/s", which is only honest because the rest
    /// of the app means 1024² by "MB" too. A 1000-based axis beside a 1024-based
    /// column is a 5 % disagreement nobody would ever track down.
    func testTheDiskAxisAgreesWithTheAppsByteUnits() {
        XCTAssertEqual(AppDelegate.mib(1_048_576), 1, accuracy: 1e-9)
        XCTAssertEqual(AppDelegate.rateAxisLabel, "MB/s")
        XCTAssertTrue(MetricUnit.bytesPerSecond.format(1_048_576).hasSuffix("MB/s"))
    }

    /// Two lines, and the same two whether they came from the live buffer or the
    /// store. The live charge line stayed the wrong colour for a whole release
    /// because the 1H view and the longer views built their series separately.
    func testTheDiskGraphDrawsReadAndWriteInDistinctInks() {
        let series = AppDelegate.diskSeries(
            read: [.init(time: Date(), value: 1)],
            write: [.init(time: Date(), value: 2)])
        XCTAssertEqual(series.map { $0.name }, ["read", "write"])
        XCTAssertNotEqual(series[0].color, series[1].color)
        XCTAssertFalse(series.contains { $0.filled == true },
                       "two filled areas overlap into a third apparent value")
    }

    /// Disk states a rate, so it has no percentage to put in the pill — and the
    /// pill used to be an `Int` with the "%" written into the view, which assumed
    /// every subject was one.
    func testTheDiskCardStatesARateAndClaimsNoPercentage() throws {
        let s = sys(disk: DiskActivity.Sample(bytesReadPerSec: 3_145_728,
                                              bytesWrittenPerSec: 1_048_576,
                                              devices: [], interval: 2))
        let m = try XCTUnwrap(GlanceCardView.model(for: .disk, system: s,
                                                   facts: MachineInfo.facts, census: nil))
        XCTAssertEqual(m.headline, MetricUnit.bytesPerSecond.format(4_194_304))
        XCTAssertNil(m.pill, "there is no honest disk-busy percentage to show")
        // Read and write share one row: they are the graph's own two lines, and
        // the headline is their sum. Both figures still appear.
        let text = m.rows.map { "\($0.value) \($0.trailing ?? "")" }.joined(separator: "|")
        XCTAssertTrue(text.contains(MetricUnit.bytesPerSecond.format(3_145_728)))
        XCTAssertTrue(text.contains(MetricUnit.bytesPerSecond.format(1_048_576)))
    }

    /// A utilisation bar can never claim more than the whole device.
    ///
    /// It did. Reported as "the little bar graph was saying the cpu was 105% in
    /// use"; the screenshot showed 129.0%, with apps at 74.3 and system processes
    /// at 54.6 while the machine was at 17.3%.
    ///
    /// The cause is two conventions meeting: `AppDrain.cpuPercent` is percent of
    /// ONE core — Activity Monitor's convention, where a busy four-thread process
    /// reads 400% — and `CPUUsage.total` is 0-100 across ALL cores. Summing the
    /// first and handing it to a slice measured against the second overstates by
    /// the core count, which on that machine was 15.
    ///
    /// The slices type cannot catch this on its own, since 129 is a perfectly
    /// valid percent-of-one-core. What it CAN enforce is that the named parts
    /// never exceed the measured whole, which is the property that failed.
    func testTheNamedPartsNeverExceedTheMeasuredWhole() {
        // The real numbers off the screenshot, before the divisor.
        let wrong = UtilizationSlices(total: 17.3, apps: 74.3, systemProcesses: 54.6)
        XCTAssertEqual(wrong.unattributed, 0, accuracy: 0.001,
                       "a remainder cannot be negative")
        // After dividing by the 15 cores those figures were measured against.
        let right = UtilizationSlices(total: 17.3, apps: 74.3 / 15, systemProcesses: 54.6 / 15)
        XCTAssertLessThanOrEqual(right.apps + right.systemProcesses, right.used + 0.001)
        XCTAssertEqual(right.used, 17.3, accuracy: 0.001,
                       "the parts must add up to what was measured, not past it")
        XCTAssertGreaterThan(right.unattributed, 0,
                             "575 of 926 processes are readable, so some of it is unnamed")
    }

    /// Idle is drawn, so the bar is the whole device rather than the used sliver.
    ///
    /// The reverse of the original call ("the cpu/gpu bar should only show the
    /// used portion"), and the reason for the reversal is that the split alone
    /// says nothing about how hard the machine is working: "17% used, and of that
    /// mostly apps" is one glance instead of two.
    func testTheCPUBarShowsIdleAndStillCaptionsTheUsedPart() {
        let bar = LedgerBarView.UtilizationBar.attributed(
            "CPU", UtilizationSlices(total: 17.3, apps: 5, systemProcesses: 3.6),
            idle: 82.7)
        XCTAssertEqual(bar.parts.map(\.title),
                       ["apps", "system processes", "unattributed", "idle"])
        XCTAssertEqual(bar.used, 100, accuracy: 0.001, "the bar is now the whole device")
        // Idle is the best-known part here, not the least-known: hatching means
        // "measured and could not be named", which is the opposite of idle.
        XCTAssertFalse(bar.parts.last?.hatched ?? true)
        // And a rate has no idle to show.
        XCTAssertEqual(LedgerBarView.UtilizationBar.attributed(
            "Disk", UtilizationSlices(total: 100, apps: 40, systemProcesses: 10),
            scale: .bytesPerSecond).parts.count, 3)
    }

    /// A point can say what the hover should read, and it survives the sanitise
    /// the view does before drawing.
    ///
    /// The fan line has to be a PERCENTAGE — two fans with different top speeds
    /// have no shared rpm scale — but nobody reads a fan in percent. The readout
    /// says both, and the rpm is recorded at the same instant as the percentage it
    /// annotates, which is the whole reason it rides on the point rather than in a
    /// parallel array: the view filters and re-sorts before drawing.
    func testAPointCarriesItsOwnReadoutThroughSanitising() {
        let g = HistoryGraphView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let t = Date()
        g.series = [.init(name: "fan speed", color: .green, points: [
            // Out of order and with a non-finite neighbour, which is exactly what
            // the sanitise pass exists to fix.
            .init(time: t.addingTimeInterval(2), value: 48, detail: "48% · 3760 rpm"),
            .init(time: t, value: 31, detail: "31% · 2430 rpm"),
            .init(time: t.addingTimeInterval(1), value: .nan, detail: "dropped"),
        ])]
        let kept = g.sanitizedPoints(inSeries: 0)
        XCTAssertEqual(kept.map(\.detail), ["31% · 2430 rpm", "48% · 3760 rpm"],
                       "the readout did not stay with the point it describes")
    }

    /// A right-hand axis is added only where a second quantity EXPLAINS the
    /// first, never to fill an axis.
    ///
    /// Load against the heat it produced is the pairing worth having, both ways
    /// round: a CPU graph answers "did that spike cost anything", and a
    /// temperature graph answers "what is the machine doing about it". Memory
    /// against nothing and disk bytes against nothing are not pairings, and an
    /// invented second line is worse than an empty axis.
    func testOnlyTheResourcesWithAnHonestSecondQuantityGetARightAxis() {
        let paired: [Resource: String] = [.cpu: "°C", .gpu: "°C", .sensors: "%"]
        for resource in Resource.allCases {
            let track = ResourceTrack(resource, title: "x")
            // The pane names them at construction; this mirrors that mapping so a
            // resource added later has to make the same decision deliberately.
            switch resource {
            case .cpu, .gpu, .sensors:
                XCTAssertNotNil(paired[resource], "\(resource) should be paired")
            case .memory, .network, .disk:
                XCTAssertNil(paired[resource], "\(resource) has no honest second axis")
            }
            XCTAssertTrue(track.companion.isEmpty, "a track starts with no second line")
        }
    }

    /// Sensor groups are built from evidence the naming layer already has, and
    /// invent nothing.
    ///
    /// In particular `Tp*` is CPU as one family and is NOT split into efficiency
    /// and performance cores: the published tables miss five of this machine's
    /// keys and nothing measured supports the boundary. See
    /// `SensorNaming.ordinalFamilies`.
    func testSensorGroupsMatchTheFamiliesTheNamingLayerEstablished() {
        XCTAssertEqual(SensorNaming.group(forKey: "Tp01"), .cpu)
        XCTAssertEqual(SensorNaming.group(forKey: "Te05"), .cpu)
        XCTAssertEqual(SensorNaming.group(forKey: "Tg0f"), .gpu)
        XCTAssertEqual(SensorNaming.group(forKey: "Tm02"), .memory)
        XCTAssertEqual(SensorNaming.group(forKey: "TB0T"), .battery)
        XCTAssertEqual(SensorNaming.group(forKey: "TH0a"), .storage)
        XCTAssertEqual(SensorNaming.group(forKey: "TW0P"), .wireless)
        XCTAssertEqual(SensorNaming.group(forKey: "Ts0P"), .enclosure)
        XCTAssertEqual(SensorNaming.group(forKey: "TaLP"), .enclosure)
        // The 140 hedged keys stay together rather than being given homes.
        XCTAssertEqual(SensorNaming.group(forKey: "Tq3z"), .unidentified)
        XCTAssertEqual(SensorNaming.group(forKey: "XXXX"), .unidentified)
    }

    /// A key that this file NAMES is filed under a heading that matches its name.
    /// A sensor called "Battery sensor 1" sitting under Storage would be one
    /// mapping drifting from the other.
    func testAGroupNeverContradictsTheNameOfTheSameKey() {
        for (key, name) in SensorNaming.exactTemperatures {
            let group = SensorNaming.group(forKey: key)
            switch group {
            case .battery: XCTAssertTrue(name.hasPrefix("Battery"), key)
            case .storage: XCTAssertTrue(name.hasPrefix("NAND"), key)
            case .wireless: XCTAssertTrue(name.hasPrefix("Wi-Fi"), key)
            case .enclosure:
                XCTAssertTrue(name.hasPrefix("Airflow") || name.hasPrefix("Palm"), key)
            default:
                XCTFail("\(key) (\(name)) landed in \(group)")
            }
        }
    }

    /// The menu bar widget reports the SAME fan number the window does.
    ///
    /// It reported the fastest fan while every surface in the window reported the
    /// average. On this machine the fans sit at 2318 and 2500 rpm, so the widget
    /// read as though it were simply the second fan — which is how it was
    /// reported. The rationale for the maximum was real (the fastest is the one
    /// you can hear) and it lost to the app agreeing with itself.
    func testTheFanWidgetAgreesWithTheFanCard() {
        let fans = [FanInfo(index: 0, currentRPM: 2318, minRPM: 2317,
                            maxRPM: 7826, targetRPM: nil),
                    FanInfo(index: 1, currentRPM: 2500, minRPM: 2317,
                            maxRPM: 7826, targetRPM: nil)]
        XCTAssertEqual(fans.averageRPM, 2409, accuracy: 0.001)
        XCTAssertNotEqual(fans.averageRPM, fans.map(\.currentRPM).max(),
                          "this fixture cannot tell the average from the maximum")

        // And the card's headline is built from the same property, so the two
        // cannot drift apart again.
        let card = GlanceCardView.model(for: .fans, system: sys(fans: fans),
                                        facts: MachineInfo.facts, census: nil)
        XCTAssertEqual(card?.headline, "2409 rpm")
    }

    /// No fans is zero, and it is the CALLER's job to tell that from fans at rest.
    func testAnEmptyFanListAveragesToZeroRatherThanCrashing() {
        XCTAssertEqual([FanInfo]().averageRPM, 0)
        XCTAssertEqual([FanInfo]().averageLoad, 0)
        // The card declines entirely, which is the distinction the average cannot
        // carry on its own: a fanless Mac is not a Mac whose fans are stopped.
        XCTAssertNil(GlanceCardView.model(for: .fans, system: sys(fans: []),
                                          facts: MachineInfo.facts, census: nil))
    }

    /// A SPINNING FAN NEVER READS ZERO.
    ///
    /// Fan speed was a fraction of the min..max range, and the minimum is not
    /// zero. Measured on this machine: the two fans idle at 2318 and 2500 rpm
    /// against a minimum of 2317 and a maximum of 7826, so range-relative load
    /// was 0.02% and 3.3% while both were plainly spinning — a flat green line on
    /// the floor of the fan graph.
    ///
    /// Fraction of TOP SPEED answers the question actually being asked and is
    /// right at both ends: parked reads 0, flat out reads 100.
    func testAFanAtItsMinimumIsNotReportedAsStopped() {
        let idling = FanInfo(index: 0, currentRPM: 2318, minRPM: 2317,
                             maxRPM: 7826, targetRPM: 2317)
        XCTAssertEqual(idling.load, 2318.0 / 7826.0, accuracy: 0.001)
        XCTAssertGreaterThan(idling.load, 0.25,
                             "a fan doing 2318 of 7826 rpm is not at the bottom of the graph")

        // Both ends still behave. A parked fan is genuinely zero...
        XCTAssertEqual(FanInfo(index: 0, currentRPM: 0, minRPM: 2317,
                               maxRPM: 7826, targetRPM: nil).load, 0)
        // ...and flat out is one, not more.
        XCTAssertEqual(FanInfo(index: 0, currentRPM: 7826, minRPM: 2317,
                               maxRPM: 7826, targetRPM: nil).load, 1)
        XCTAssertEqual(FanInfo(index: 0, currentRPM: 9000, minRPM: 2317,
                               maxRPM: 7826, targetRPM: nil).load, 1)
    }

    /// Fans get a GAUGE, not a split. Two fans do not divide one quantity between
    /// them — each sits somewhere in its own min..max — so the bar shows how far
    /// in they are and what is left, which is what the graph above plots and what
    /// the pane's own dials show.
    func testTheFanBarIsAGaugeRatherThanASplit() {
        let bar = LedgerBarView.UtilizationBar.gauge("Fan speed", percent: 42)
        XCTAssertEqual(bar.used, 100, accuracy: 0.001, "a gauge is always of its whole")
        XCTAssertEqual(bar.parts.map(\.title), ["now", "headroom"])
        XCTAssertEqual(bar.parts[0].value, 42, accuracy: 0.001)
        XCTAssertEqual(bar.parts[1].value, 58, accuracy: 0.001)
        XCTAssertFalse(bar.parts.contains { $0.hatched },
                       "headroom is known, not unattributed")
    }

    /// And it cannot run off either end. A fan parked below its own minimum
    /// reports a negative position, and a bar with a negative slice draws
    /// backwards over its neighbour.
    func testTheGaugeClampsToItsOwnEnds() {
        XCTAssertEqual(LedgerBarView.UtilizationBar.gauge("x", percent: -10).parts[0].value, 0)
        XCTAssertEqual(LedgerBarView.UtilizationBar.gauge("x", percent: 140).parts[0].value, 100)
        XCTAssertEqual(LedgerBarView.UtilizationBar.gauge("x", percent: 140).parts[1].value, 0)
    }

    /// The network card names the link, and states the rate the pane above states.
    func testTheNetworkCardNamesTheLinkAndItsRates() throws {
        let s = sys(network: NetworkThroughput.Sample(
            bytesInPerSec: 2_097_152, bytesOutPerSec: 1_048_576,
            interfaces: [], measured: [], interval: 2))
        let m = try XCTUnwrap(GlanceCardView.model(for: .network, system: s,
                                                   facts: MachineInfo.facts, census: nil))
        XCTAssertEqual(m.headline, MetricUnit.bytesPerSecond.format(3_145_728))
        XCTAssertNil(m.pill, "a throughput has no percentage to pair with")
        // Down and up share a row so the link facts have somewhere to go — those
        // are the part of this card the graph beside it cannot say.
        let text = m.rows.map { "\($0.value) \($0.trailing ?? "")" }.joined(separator: "|")
        XCTAssertTrue(text.contains(MetricUnit.bytesPerSecond.format(2_097_152)))
        XCTAssertTrue(text.contains(MetricUnit.bytesPerSecond.format(1_048_576)))
    }

    /// The fan card states each fan's own range beside its speed: 2200 rpm means
    /// nothing without knowing whether that is idle or flat out, and two fans in
    /// one machine often do not share a range.
    func testTheFanCardGivesEachFanItsOwnRange() throws {
        let s = sys(fans: [FanInfo(index: 0, currentRPM: 2200, minRPM: 1200,
                                   maxRPM: 4600, targetRPM: nil)])
        let m = try XCTUnwrap(GlanceCardView.model(for: .fans, system: s,
                                                   facts: MachineInfo.facts, census: nil))
        XCTAssertEqual(m.headline, "2200 rpm")
        // Of TOP SPEED: 2200/4600 = 47.8%. Not of the min..max range, which would
        // be 29% here and 0% on the real machine — see below.
        XCTAssertEqual(m.pill, "48%")
        XCTAssertEqual(m.rows.first?.label, "Fan 1")
        XCTAssertEqual(m.rows.first?.trailing, "1200–4600",
                       "a speed with no range attached says nothing")
    }

    /// Every subject readable at once, so the whole-card tests below check the
    /// real cards rather than a hand-built model that drifts from them.
    private var fullSample: SystemMetrics.Snapshot {
        sys(cpu: CPUUsage.Sample(total: 16.4, user: 12.4, system: 4.1,
                                 idle: 83.6, interval: 2),
            memory: MemoryUsage.Sample(total: 34_359_738_368, used: 20_000_000_000,
                                       wired: 5_000_000_000, compressed: 3_000_000_000,
                                       app: 12_000_000_000, free: 14_359_738_368),
            disk: DiskActivity.Sample(bytesReadPerSec: 3_145_728,
                                      bytesWrittenPerSec: 1_048_576,
                                      devices: [], interval: 2),
            network: NetworkThroughput.Sample(bytesInPerSec: 14_500,
                                              bytesOutPerSec: 340_000,
                                              interfaces: [], measured: [], interval: 2),
            fans: [FanInfo(index: 0, currentRPM: 2200, minRPM: 1200,
                           maxRPM: 4600, targetRPM: nil),
                   FanInfo(index: 1, currentRPM: 2100, minRPM: 1200,
                           maxRPM: 4600, targetRPM: nil)])
    }

    /// NO CARD RESTATES ITS OWN HEADLINE IN THE PILL.
    ///
    /// The pill exists for the battery, whose headline is a DURATION — "73% · on
    /// battery" beside "9h 41m" says something the headline cannot. Handing a
    /// percentage subject its own percentage printed "10.7%" over "11% · CPU ·
    /// measured": one number, rounded twice, two lines apart.
    ///
    /// The rule is checkable, so it is checked rather than remembered: a headline
    /// that is a percentage gets no percentage pill. Fans keep theirs, because 29%
    /// of a fan's range and 2200 rpm are two facts.
    func testNoCardRestatesItsOwnHeadlineInThePill() {
        for context in BottomContext.allCases {
            guard let m = GlanceCardView.model(for: context, system: fullSample,
                                               facts: MachineInfo.facts,
                                               census: MachineInfo.census()) else { continue }
            guard m.headline.hasSuffix("%"), let pill = m.pill else { continue }
            XCTAssertFalse(pill.hasSuffix("%"),
                           "\(context) prints \(m.headline) and \(pill) two lines apart")
        }
    }

    /// NO CARD OVERFLOWS THE HEIGHT IT IS GIVEN.
    ///
    /// The card is top-pinned with `bottom <= bottom`, so content taller than the
    /// card is COMPRESSED rather than clipped — and an NSTextField with less
    /// height than it needs centres its text and loses the top and bottom of every
    /// glyph. That ate the headline on the Network card ("cutting off that text
    /// with the c card"), and the same mechanism had already eaten the estimate
    /// headline once with "measuring…". Both looked like font bugs.
    ///
    /// Measured rather than reasoned: this renders each subject's REAL card at the
    /// real 236x128 and asks what height it wanted. Counting rows by hand in the
    /// factory above is what let five of them through in the first place.
    func testNoCardOverflowsTheHeightItIsGiven() {
        let s = fullSample
        let size = NSSize(width: 236, height: 128)
        for context in BottomContext.allCases {
            guard let m = GlanceCardView.model(for: context, system: s,
                                               facts: MachineInfo.facts,
                                               census: MachineInfo.census()) else { continue }
            let card = GlanceCardView(frame: NSRect(origin: .zero, size: size))
            card.model = m
            card.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(
                card.fittingSize.height, size.height,
                "\(context) wants \(card.fittingSize.height) pt in \(size.height) — its "
                + "headline will be compressed and clipped")
        }
    }

    /// And the cap the card enforces matches what actually fits, so a subject that
    /// hands over more rows loses the extra rather than the headline.
    func testTheRowBudgetIsWhatTheCardCanActuallyHold() {
        let budget = GlanceCardView.maxRows(forHeight: 128)
        let card = GlanceCardView(frame: NSRect(x: 0, y: 0, width: 236, height: 128))
        card.model = GlanceCardView.Model(
            source: .ac, headline: "347KB/s", pill: nil, sourceLabel: "Network · measured",
            // Twice the budget, which is what a careless factory would hand it.
            rows: (0..<(budget * 2)).map { ("Label\($0)", "1234", nil) })
        card.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(card.fittingSize.height, 128,
                                 "the cap does not actually keep the card inside its height")
        XCTAssertGreaterThanOrEqual(budget, 3, "a card this size held three rows when measured")
    }

    /// And a subject with no reading yet returns nil so the caller can fall back
    /// to the battery, rather than inventing a card of zeroes.
    func testASubjectWithNoReadingYieldsNoCard() {
        XCTAssertNil(GlanceCardView.model(for: .cpu, system: sys(),
                                          facts: MachineInfo.facts, census: nil))
        XCTAssertNil(GlanceCardView.model(for: .memory, system: sys(),
                                          facts: MachineInfo.facts, census: nil))
        XCTAssertNil(GlanceCardView.model(for: .battery, system: sys(),
                                          facts: MachineInfo.facts, census: nil),
                     "battery is the fallback, not something this builds")
    }
}

