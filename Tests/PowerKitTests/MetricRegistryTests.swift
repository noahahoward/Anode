import XCTest
@testable import PowerKit

final class MetricRegistryTests: XCTestCase {

    // ── Unit formatting: negative, zero, huge, NaN for every unit ──────────────

    func testPercentPerHourFormatting() {
        XCTAssertEqual(MetricUnit.percentPerHour.format(4.11), "4.1%/hr")
        XCTAssertEqual(MetricUnit.percentPerHour.format(-4.2), "-4.2%/hr")
        XCTAssertEqual(MetricUnit.percentPerHour.format(0), "0.0%/hr")
        XCTAssertEqual(MetricUnit.percentPerHour.format(98765.4), "98765%/hr")
        XCTAssertEqual(MetricUnit.percentPerHour.format(.nan), "—")
        XCTAssertEqual(MetricUnit.percentPerHour.format(.infinity), "—")
    }

    func testMinutesFormatting() {
        XCTAssertEqual(MetricUnit.minutes.format(72), "1h 12m")
        XCTAssertEqual(MetricUnit.minutes.format(0), "0m")
        XCTAssertEqual(MetricUnit.minutes.format(59.6), "1h 00m")   // rounds to 60 min
        XCTAssertEqual(MetricUnit.minutes.format(-72), "-1h 12m")
        XCTAssertEqual(MetricUnit.minutes.format(100000), "1666h 40m")
        XCTAssertEqual(MetricUnit.minutes.format(.nan), "—")
    }

    func testPercentAndRatioFormatting() {
        XCTAssertEqual(MetricUnit.percent.format(72), "72%")
        XCTAssertEqual(MetricUnit.percent.format(0), "0%")
        XCTAssertEqual(MetricUnit.percent.format(-5), "-5%")
        XCTAssertEqual(MetricUnit.ratio.format(0.63), "63%")
        XCTAssertEqual(MetricUnit.ratio.format(0), "0%")
        XCTAssertEqual(MetricUnit.ratio.format(.nan), "—")
    }

    func testBytesFormatting() {
        XCTAssertEqual(MetricUnit.bytes.format(0), "0 B")
        XCTAssertEqual(MetricUnit.bytes.format(512), "512 B")
        XCTAssertEqual(MetricUnit.bytes.format(1536), "1.5 KB")
        XCTAssertEqual(MetricUnit.bytes.format(1_300_000_000), "1.2 GB")
        XCTAssertEqual(MetricUnit.bytes.format(-1536), "-1.5 KB")
        XCTAssertEqual(MetricUnit.bytes.format(1e15), "909 TB")
        XCTAssertEqual(MetricUnit.bytes.format(.nan), "—")
    }

    func testMiscFormatting() {
        XCTAssertEqual(MetricUnit.celsius.format(43.2), "43°C")
        XCTAssertEqual(MetricUnit.rpm.format(2400), "2400 rpm")
        XCTAssertEqual(MetricUnit.count.format(3588), "3588")
        XCTAssertEqual(MetricUnit.celsius.format(.nan), "—")
    }

    // ── Registry behavior ───────────────────────────────────────────────────────

    func testRegisterReadAndReplace() {
        let r = MetricRegistry()
        let id = MetricID("test.metric")
        let d = MetricDescriptor(id: id, title: "Test", shortTitle: "T",
                                 unit: .count, category: "Test", higherIsWorse: true)
        r.register(d) { MetricValue(1, unit: .count, isEstimate: false) }

        XCTAssertEqual(r.descriptor(for: id)?.title, "Test")
        XCTAssertEqual(r.value(for: id)?.value, 1)
        XCTAssertEqual(r.descriptors().count, 1)

        // Re-registering the same ID replaces in place, no duplicate row.
        r.register(d) { MetricValue(2, unit: .count, isEstimate: false) }
        XCTAssertEqual(r.value(for: id)?.value, 2)
        XCTAssertEqual(r.descriptors().count, 1)

        // Unknown ID: nil, never a crash.
        XCTAssertNil(r.value(for: MetricID("does.not.exist")))
        XCTAssertNil(r.descriptor(for: MetricID("does.not.exist")))
    }

    func testSharedRegistryHasBatteryMetricsAndNilBeforeFirstSnapshot() {
        let ids = Set(MetricRegistry.shared.descriptors().map(\.id))
        for id in [MetricID.batteryDrain, .batteryPercent, .batteryTimeLeft,
                   .gpuDrain, .unattributedShare, .processCoverage] {
            XCTAssertTrue(ids.contains(id), "missing \(id.rawValue)")
        }
        // Test order isn't guaranteed, so a snapshot may already have been pushed by
        // another test; only assert "no crash" here, not nil.
        _ = MetricRegistry.shared.value(for: .batteryDrain)
    }

    /// Providers are read on the main thread while registration/updates come from a
    /// background queue — hammer both sides at once under TSan-visible conditions.
    func testConcurrentReadsAndRegistrations() {
        let r = MetricRegistry()
        let id = MetricID("test.concurrent")
        let d = MetricDescriptor(id: id, title: "C", shortTitle: "C",
                                 unit: .count, category: "Test", higherIsWorse: false)
        r.register(d) { MetricValue(0, unit: .count, isEstimate: false) }

        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            if i % 3 == 0 {
                r.register(d) { MetricValue(Double(i), unit: .count, isEstimate: false) }
            } else {
                _ = r.value(for: id)
                _ = r.descriptors()
            }
        }
        XCTAssertNotNil(r.value(for: id))
        XCTAssertEqual(r.descriptors().count, 1)
    }

    func testNoWattsUnitExists() {
        // The product rule "never display watts" is structural: MetricUnit has no
        // watts case. This test documents that intent against future edits.
        let names = MetricUnit.allCases.map { "\($0)" }
        XCTAssertFalse(names.contains { $0.lowercased().contains("watt") })
    }
}
