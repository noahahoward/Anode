import XCTest
@testable import PowerKit

/// The SSD health page is 512 bytes of undocumented-by-Apple binary whose every
/// field is at a hardcoded offset, and the failure mode when an offset is wrong is
/// not a crash — it is a plausible-looking wrong number. Byte 176 is the reason
/// this file exists in the shape it does: `NUM_ERROR_INFO_LOG_ENTRIES` was read at
/// the wrong offset during review, and because the whole tail of the page is zeros
/// on a healthy drive, the wrong offset produced the RIGHT answer (0) on this
/// machine and would only ever have been caught on a drive that had logged an
/// error.
///
/// So the fixture below is not a hand-written example. It is the literal 512 bytes
/// `SMARTReadData` returned on this machine — `Mac17,9`, M5 Pro, macOS 27.0,
/// APPLE SSD AP1024Z, firmware 241.0.12, read through
/// `IOEmbeddedNVMeBlockDevice` — captured with the same plug-in dance
/// `NVMeHealth.openPage` performs, and byte-identical to what
/// `IONVMeBlockStorageDevice` returned in the same second. `decode` is pure, so
/// every offset, every endianness assumption and every plausibility fence is
/// pinned here on a machine that need not have an NVMe drive at all.
///
/// The other half of this file is about what must NEVER appear: no lifespan, no
/// TBW denominator, no rate derived from `powerOnHours`. See
/// `testSampleExposesNothingDerivedFromAnUnmeasuredDenominator`.
final class NVMeHealthTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: The captured page

    /// The real 512 bytes, 16 per line, offsets in the trailing comment. Kept as
    /// hex rather than as a `[UInt8]` literal so it can be diffed against a fresh
    /// `xxd` of the device without reformatting either side.
    private static let capturedHex = [
        "00330164630000000000000000000000",  //   0  warning, 307 K, 100/99, used 0
        "00000000000000000000000000000000",  //  16  reserved
        "5917a301000000000000000000000000",  //  32  data units read      27,465,561
        "2efcd900000000000000000000000000",  //  48  data units written   14,285,870
        "0b1cfb17000000000000000000000000",  //  64  host read commands  402,332,683
        "9e965014000000000000000000000000",  //  80  host write commands 340,825,758
        "00000000000000000000000000000000",  //  96  controller busy time  0 (a stub)
        "a4000000000000000000000000000000",  // 112  power cycles        164
        "cc000000000000000000000000000000",  // 128  power on hours      204
        "0b000000000000000000000000000000",  // 144  unsafe shutdowns     11
        "00000000000000000000000000000000",  // 160  media errors          0
        "00000000000000000000000000000000",  // 176  error log entries     0
        "00000000000000000000000000000000",  // 192  reserved
        "00000000000000000000000000000000",  // 208
        "00000000000000000000000000000000",  // 224
        "00000000000000000000000000000000",  // 240
        "00000000000000000000000000000000",  // 256
        "00000000000000000000000000000000",  // 272
        "00000000000000000000000000000000",  // 288
        "00000000000000000000000000000000",  // 304
        "00000000000000000000000000000000",  // 320
        "00000000000000000000000000000000",  // 336
        "00000000000000000000000000000000",  // 352
        "00000000000000000000000000000000",  // 368
        "00000000000000000000000000000000",  // 384
        "00000000000000000000000000000000",  // 400
        "00000000000000000000000000000000",  // 416
        "00000000000000000000000000000000",  // 432
        "00000000000000000000000000000000",  // 448
        "00000000000000000000000000000000",  // 464
        "00000000000000000000000000000000",  // 480
        "00000000000000000000000000000000",  // 496
    ].joined()

    private static let captured: [UInt8] = {
        var out: [UInt8] = []
        var i = capturedHex.startIndex
        while i < capturedHex.endIndex {
            let j = capturedHex.index(i, offsetBy: 2)
            out.append(UInt8(capturedHex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }()

    private var page: [UInt8] { Self.captured }

    /// The captured page with one byte changed. Used by every fence test, so that
    /// a rejection is provably caused by the byte named in the test and not by
    /// some other thing being wrong with a hand-built buffer.
    private func page(_ offset: Int, _ value: UInt8) -> [UInt8] {
        var p = Self.captured
        p[offset] = value
        return p
    }

    /// The captured page with the temperature replaced.
    ///
    /// A separate helper from `page(_:_:)` because temperature is the one field
    /// here that spans two bytes, and writing only byte 1 leaves byte 2 holding the
    /// captured 0x01 — so "set the temperature to 0" silently produces 256 K. That
    /// mistake was made while writing this file, and it is the same little-endian
    /// trap the decoder itself has to get right.
    private func page(kelvin: UInt16) -> [UInt8] {
        var p = Self.captured
        p[1] = UInt8(kelvin & 0xFF)
        p[2] = UInt8(kelvin >> 8)
        return p
    }

    private func decoded(file: StaticString = #filePath, line: UInt = #line) throws
        -> NVMeHealth.Sample {
        try XCTUnwrap(NVMeHealth.decode(page), file: file, line: line)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Byte-exact decode

    /// The load-bearing test. Every field, against the values the drive reported
    /// at capture time, cross-checked against the C `NVMeSMARTData` struct fields
    /// on the same read. If an offset moves, this fails.
    func testCapturedPageDecodesFieldForField() throws {
        XCTAssertEqual(Self.captured.count, 512, "the fixture IS the log page size")
        let s = try decoded()

        XCTAssertEqual(s.criticalWarning, 0)
        XCTAssertEqual(s.temperatureK, 307)
        XCTAssertEqual(s.availableSpare, 100)
        XCTAssertEqual(s.availableSpareThreshold, 99)
        XCTAssertEqual(s.percentageUsed, 0)
        XCTAssertEqual(s.dataUnitsRead, 27_465_561)
        XCTAssertEqual(s.dataUnitsWritten, 14_285_870)
        XCTAssertEqual(s.hostReadCommands, 402_332_683)
        XCTAssertEqual(s.hostWriteCommands, 340_825_758)
        XCTAssertEqual(s.controllerBusyTimeMinutes, 0)
        XCTAssertEqual(s.powerCycles, 164)
        XCTAssertEqual(s.powerOnHours, 204)
        XCTAssertEqual(s.unsafeShutdowns, 11)
        XCTAssertEqual(s.mediaErrors, 0)
        XCTAssertEqual(s.errorLogEntries, 0)
    }

    /// Byte 176, specifically, because this is the offset that was wrong once and
    /// whose wrongness was invisible: the whole tail of a healthy page is zeros, so
    /// reading `errorLogEntries` from 192 or 160 also yields 0 here. Only a page
    /// with a distinguishing value at 176 can tell them apart, so this test makes
    /// one.
    func testErrorLogEntriesIsAtByte176AndNowhereElse() throws {
        var p = Self.captured
        p[176] = 7                              // error log entries
        p[160] = 3                              // media errors, the field before
        p[192] = 9                              // reserved, the field after
        let s = try XCTUnwrap(NVMeHealth.decode(p))
        XCTAssertEqual(s.errorLogEntries, 7, "error log entries live at byte 176")
        XCTAssertEqual(s.mediaErrors, 3, "media errors live at byte 160")
    }

    /// The 512,000-byte DECIMAL unit, not 512 KiB. The two differ by 2.4 %, which
    /// on this drive's real total is 175 GB — a wrong headline, not a rounding
    /// difference. Verified against `IOBlockStorageDriver`'s `Bytes (Write)` over a
    /// 21.7 h passive window, where the deltas agreed to within one 512,000-byte
    /// count.
    func testDataUnitsAreDecimal512kNotBinary() throws {
        let s = try decoded()
        XCTAssertEqual(s.bytesWritten, 14_285_870 * 512_000)
        XCTAssertEqual(s.bytesRead, 27_465_561 * 512_000)
        XCTAssertEqual(s.bytesWritten, 7_314_365_440_000, "7.31 TB, the figure on the card")
        XCTAssertNotEqual(s.bytesWritten, 14_285_870 * 524_288, "524,288 is the KiB mistake")
    }

    /// Kelvin on the wire, Celsius at the edge, and the conversion is the only
    /// arithmetic applied to it.
    func testTemperatureIsRawKelvinConvertedOnlyAtTheAccessor() throws {
        let s = try decoded()
        XCTAssertEqual(s.temperatureK, 307, "the field is not pre-converted")
        XCTAssertEqual(try XCTUnwrap(s.temperatureC), 33.85, accuracy: 0.001)
    }

    /// 0 K is "this drive reports no composite temperature", which is a different
    /// claim from "the drive is at absolute zero" and a very different one from
    /// "−273 °C". It must arrive as nil, not as a number.
    func testZeroKelvinIsNoSensorAndNotACelsiusValue() throws {
        let s = try XCTUnwrap(NVMeHealth.decode(page(kelvin: 0)))
        XCTAssertEqual(s.temperatureK, 0)
        XCTAssertNil(s.temperatureC, "0 K is an absent reading, never −273.15 °C")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Buffers that are not this page

    /// Exactly 512. A short buffer is the obvious case; the oversized one is the
    /// one worth pinning, because a 4 KB buffer decodes perfectly happily at these
    /// offsets and would silently accept an identify-controller page — a different
    /// 4,096-byte structure reachable through the SAME interface — as if it were
    /// health data.
    func testOnlyA512ByteBufferDecodes() {
        for count in [0, 1, 191, 511, 513, 1024, 4096] {
            XCTAssertNil(NVMeHealth.decode([UInt8](repeating: 0x41, count: count)),
                         "\(count) bytes is not log page 0x02")
        }
        XCTAssertNotNil(NVMeHealth.decode(page), "…and 512 bytes is")
    }

    /// A 512-byte buffer that was never written looks exactly like a successful
    /// read of a drive that has done nothing. It is not one: this page is only ever
    /// read off a device the machine is running from, so zero reads AND zero writes
    /// AND zero power cycles cannot all be true at once.
    func testAnAllZeroPageIsAnUnwrittenBufferNotAnIdleDrive() {
        XCTAssertNil(NVMeHealth.decode([UInt8](repeating: 0, count: 512)))
    }

    /// …but the fence is a conjunction, and must not reject a real page that
    /// happens to have one of those counters at zero. A freshly imaged drive with a
    /// single power cycle and nothing written yet is a legitimate page.
    func testASingleZeroCounterDoesNotRejectARealPage() {
        var p = [UInt8](repeating: 0, count: 512)
        p[1] = 0x33; p[2] = 0x01        // 307 K
        p[3] = 100; p[4] = 99           // spare / threshold
        p[112] = 1                      // one power cycle: the drive has been used
        XCTAssertNotNil(NVMeHealth.decode(p),
                        "zero bytes written is a real state on a new drive")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Plausibility fences

    /// A percent that will not fit in a percent. These are bytes, so 101–255 is
    /// representable and has to be rejected rather than assumed away — a spare of
    /// 200 % would render as a full green bar.
    ///
    /// Spare and its threshold ONLY. `percentageUsed` is excluded on purpose; see
    /// the test below, which pins the opposite behaviour.
    func testSparePercentFieldsAboveOneHundredRejectThePage() {
        for offset in [3, 4] {             // spare, threshold
            XCTAssertNotNil(NVMeHealth.decode(page(offset, 100)), "100 is legal")
            XCTAssertNil(NVMeHealth.decode(page(offset, 101)), "byte \(offset) = 101")
            XCTAssertNil(NVMeHealth.decode(page(offset, 255)), "byte \(offset) = 255")
        }
    }

    /// A drive past its rated endurance must SURVIVE decoding, not be rejected.
    ///
    /// The spec permits `percentageUsed` 101–255 ("past rated endurance", saturating
    /// at 255). Fencing it to 100 returns nil, and every caller renders nil as "this
    /// machine has no SMART" — so the most worn-out drive in the world would present
    /// identically to an Intel Mac. An absent measurement and an alarming one must
    /// never be the same pixel. This pins the asymmetry against a future tidy-up
    /// that "consistently" fences all three percent fields.
    func testPastRatedEnduranceSurvivesAndIsReportedVerbatim() throws {
        for used in [UInt8(101), 150, 255] {
            let s = try XCTUnwrap(NVMeHealth.decode(page(5, used)),
                                  "percentageUsed \(used) must decode, not vanish")
            XCTAssertEqual(s.percentageUsed, used, "reported verbatim, never clamped")
            XCTAssertTrue(NVMeHealth.alarms(for: s).contains(.wearStarted(used)),
                          "a drive past rated endurance must raise wearStarted")
        }
    }

    /// The unit-slip fence. This machine reports 307 K; a driver that ever handed
    /// back Celsius in the same field would report 34, and 34 K is −239.15 °C — a
    /// finite, well-formed, catastrophically wrong number that a card would render
    /// without complaint. The band is 233…398 K, −40 °C to +125 °C.
    func testATemperatureOutsideTheSaneBandRejectsThePage() {
        XCTAssertNil(NVMeHealth.decode(page(kelvin: 34)), "Celsius in the Kelvin slot")
        XCTAssertNil(NVMeHealth.decode(page(kelvin: 232)), "−41 °C: below the band")
        XCTAssertNotNil(NVMeHealth.decode(page(kelvin: 233)), "−40 °C: the low edge is legal")
        XCTAssertNotNil(NVMeHealth.decode(page(kelvin: 398)), "+125 °C: the high edge is legal")
        XCTAssertNil(NVMeHealth.decode(page(kelvin: 399)), "+126 °C: above the band")

        // 398 is 0x018E, so the high edge also pins the little-endian order: read
        // big-endian it would be 0x8E01 = 36,353 and would fail the band.
        XCTAssertEqual(try XCTUnwrap(NVMeHealth.decode(page(kelvin: 398))).temperatureK, 398)
    }

    /// Every counter in this page is 128 bits wide and is truncated to its low 64.
    /// The truncation is checked, not assumed: 2^64 data units is nine yottabytes,
    /// so a set high half is proof the buffer is being read at the wrong offsets or
    /// in the wrong byte order — not a drive that wrote a great deal. Measured on
    /// this machine, all ten high halves are zero.
    func testASetHighHalfOnAny128BitCounterRejectsThePage() {
        let counters = [32, 48, 64, 80, 96, 112, 128, 144, 160, 176]
        for base in counters {
            for byte in 8..<16 {
                XCTAssertNil(NVMeHealth.decode(page(base + byte, 1)),
                             "high half of the counter at \(base), byte \(base + byte)")
            }
        }
    }

    /// The whole page is rejected, not the offending field. A page whose spare
    /// percentage reads 200 has told us nothing trustworthy about its media error
    /// count either, and this codebase's rule — `DiskActivity.maxPlausibleBytesPerSec`,
    /// `Store.maxPlausibleWatts` — is that an unexplained counter becomes a missing
    /// card rather than a headline number.
    func testAFenceRejectsTheWholeSampleAndNotJustOneField() {
        XCTAssertNil(NVMeHealth.decode(page(3, 200)),
                     "no partially-credible SSD health card exists")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Alarms

    /// The drive in front of us. Healthy means SILENT — no "everything is fine"
    /// alarm, no informational row.
    func testAHealthyDriveRaisesNothing() throws {
        XCTAssertEqual(NVMeHealth.alarms(for: try decoded()), [])
    }

    /// Any bit, including the two the spec reserves. A reserved bit set is still
    /// the drive saying something is wrong, and staying quiet because we lack a
    /// label for it is the worst possible direction to be silent in.
    func testCriticalWarningFiresOnAnyBitIncludingReservedOnes() throws {
        for bit in 0..<8 {
            let raw = UInt8(1 << bit)
            let s = try XCTUnwrap(NVMeHealth.decode(page(0, raw)))
            XCTAssertEqual(NVMeHealth.alarms(for: s).first, .criticalWarning(raw),
                           "bit \(bit)")
        }
    }

    /// STRICTLY below. Sitting exactly on the threshold is not the spec's failure
    /// condition, and firing there would raise a permanent alarm on any drive whose
    /// vendor sets spare and threshold equal.
    func testSpareAlarmNeedsSpareStrictlyBelowTheThreshold() throws {
        // spare 99, threshold 99: on the line, silent.
        let onTheLine = try XCTUnwrap(NVMeHealth.decode(page(3, 99)))
        XCTAssertEqual(NVMeHealth.alarms(for: onTheLine), [])

        // spare 98, threshold 99: below it.
        let below = try XCTUnwrap(NVMeHealth.decode(page(3, 98)))
        XCTAssertEqual(NVMeHealth.alarms(for: below),
                       [.spareBelowThreshold(98, threshold: 99)])
    }

    /// One unrecoverable error is an event. There is no acceptable count and so no
    /// threshold to tune.
    func testASingleMediaErrorFires() throws {
        let s = try XCTUnwrap(NVMeHealth.decode(page(160, 1)))
        XCTAssertEqual(NVMeHealth.alarms(for: s), [.mediaErrors(1)])
    }

    /// A transition, not a level. `percentageUsed` has been pinned at 0 for the
    /// life of this drive, so the step to 1 is the first wear information it has
    /// ever volunteered — and it is reported as "the counter started moving", never
    /// as a fraction of a lifetime, because there is no measured lifetime for it to
    /// be a fraction of.
    func testWearStartedFiresOnlyWhenPercentageUsedLeavesZero() throws {
        let untouched = try XCTUnwrap(NVMeHealth.decode(page(5, 0)))
        XCTAssertEqual(NVMeHealth.alarms(for: untouched), [], "0 % is not an event")

        let moved = try XCTUnwrap(NVMeHealth.decode(page(5, 1)))
        XCTAssertEqual(NVMeHealth.alarms(for: moved), [.wearStarted(1)])
    }

    /// Severity order is a claim, and it is the order of `Alarm`'s cases: the
    /// drive's own verdict outranks a comparison this code made, which outranks a
    /// media error count, which outranks the wear integrator merely having moved.
    /// A UI showing one line shows the first of these.
    func testAlarmsComeBackInSeverityOrder() throws {
        var p = Self.captured
        p[0] = 0x01      // critical warning: spare below threshold
        p[3] = 90        // available spare 90, against a threshold of 99
        p[5] = 4         // percentage used has left 0
        p[160] = 2       // two media errors
        let s = try XCTUnwrap(NVMeHealth.decode(p))

        XCTAssertEqual(NVMeHealth.alarms(for: s), [
            .criticalWarning(0x01),
            .spareBelowThreshold(90, threshold: 99),
            .mediaErrors(2),
            .wearStarted(4),
        ])
    }

    /// The critical-warning bit and the spare comparison OVERLAP by design — bit 0
    /// is defined as "spare below threshold", so a conforming drive raises both.
    /// They stay separate because they are different measurements, and a drive that
    /// raises one without the other is telling us something that collapsing them
    /// would hide.
    func testTheSpareBitAndTheSpareComparisonAreReportedSeparately() throws {
        // The bit set, but the spare has NOT moved: the drive disagrees with the
        // numbers it published, which is exactly what must stay visible.
        let s = try XCTUnwrap(NVMeHealth.decode(page(0, 0x01)))
        XCTAssertEqual(NVMeHealth.alarms(for: s), [.criticalWarning(0x01)])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: What must never appear

    /// `Sample` carries exactly the measured fields and nothing derived from a
    /// denominator this app cannot measure.
    ///
    /// The two forbidden shapes, both of which this feature nearly shipped:
    ///
    /// (a) an endurance figure. `percentageUsed` reads 0 at 7.31 TB written, which
    ///     bounds the manufacturer's own basis above ~731 TB and falsifies the
    ///     612 TB geometry-derived denominator a wear bar was going to use.
    ///
    /// (b) anything per-hour. `powerOnHours` is controller ACTIVE-STATE residency,
    ///     measured at 4.6 % of calendar time here (203 → 204 across 21.9 h wall
    ///     while 99.5 % awake), so a rate built on it reads ~22x low.
    ///
    /// Reflection rather than a manual review because the failure is additive: the
    /// dangerous change is someone appending `var terabytesWritten`, and a list
    /// that must be updated to add a field is the thing that makes them stop.
    func testSampleExposesNothingDerivedFromAnUnmeasuredDenominator() throws {
        let fields = Mirror(reflecting: try decoded()).children.compactMap(\.label)
        XCTAssertEqual(Set(fields), [
            "criticalWarning", "temperatureK",
            "availableSpare", "availableSpareThreshold", "percentageUsed",
            "dataUnitsRead", "dataUnitsWritten",
            "hostReadCommands", "hostWriteCommands",
            "controllerBusyTimeMinutes", "powerCycles", "powerOnHours",
            "unsafeShutdowns", "mediaErrors", "errorLogEntries",
        ], "a stored property was added — if it is a lifespan or a per-hour rate, "
         + "the measurement says it cannot be computed from this page")

        // And the arithmetic that would be wrong, spelled out so the number is on
        // the record: this drive's real average is ~1.6 GB/h.
        let s = try decoded()
        let perPowerOnHour = Double(s.bytesWritten) / Double(s.powerOnHours)
        XCTAssertGreaterThan(perPowerOnHour, 30e9,
                             "36 GB/h — what dividing by powerOnHours would claim")
    }

    /// `controllerBusyTimeMinutes` reads 0 after 340 million write commands, which
    /// a controller cannot honestly have done in zero minutes. It is carried
    /// unaltered because 0 is what was measured, and it must not be interpreted —
    /// but its being a stub must also not cost us the rest of the page.
    func testAStubbedFieldIsCarriedWithoutPoisoningThePage() throws {
        let s = try decoded()
        XCTAssertEqual(s.controllerBusyTimeMinutes, 0)
        XCTAssertEqual(s.hostWriteCommands, 340_825_758,
                       "…which is why 0 busy minutes cannot be true")
        XCTAssertEqual(s.percentageUsed, 0,
                       "the other field in this page indistinguishable from a stub")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: The cache

    /// A read that counts how many times the hardware was asked, and a clock the
    /// test moves by hand — the `SensorCacheTests` rule: whether a read is issued
    /// must depend only on the clock, never on the hardware the tests run on.
    private final class FakeDrive {
        private(set) var reads = 0
        var answer: NVMeHealth.Sample?
        init(_ answer: NVMeHealth.Sample?) { self.answer = answer }
        func read() -> NVMeHealth.Sample? { reads += 1; return answer }
    }

    private func makeCache(_ answer: NVMeHealth.Sample?)
        -> (NVMeHealth.Cache, FakeDrive) {
        let drive = FakeDrive(answer)
        return (NVMeHealth.Cache(fetch: { drive.read() }), drive)
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testConstructingTheCacheTouchesNoHardware() throws {
        let (_, drive) = makeCache(try decoded())
        XCTAssertEqual(drive.reads, 0)
    }

    /// The point of the hourly TTL: the plug-in open costs 2.7 ms, and a card
    /// redrawing at 1 Hz would otherwise spend 9.7 s an hour opening a user client
    /// to re-read a counter that moved in its fifth significant figure.
    func testASecondReadInsideTheHourIssuesNoIOKit() throws {
        let sample = try decoded()
        let (cache, drive) = makeCache(sample)
        XCTAssertEqual(cache.read(now: t0), sample)
        XCTAssertEqual(cache.read(now: t0 + 3599), sample)
        XCTAssertEqual(drive.reads, 1)
    }

    func testTheHourExpiresAndTheDriveIsReadAgain() throws {
        let (cache, drive) = makeCache(try decoded())
        _ = cache.read(now: t0)
        _ = cache.read(now: t0 + 3600)
        XCTAssertEqual(drive.reads, 2)
    }

    /// A machine with no NVMe SMART client — Intel, a VM, an external-only bridge
    /// — must not attempt the match-and-open dance on every call, forever, and
    /// never once succeed.
    func testAFailureIsRetriedButNotOnEveryCall() {
        let (cache, drive) = makeCache(nil)
        XCTAssertNil(cache.read(now: t0))
        XCTAssertNil(cache.read(now: t0 + 1))
        XCTAssertNil(cache.read(now: t0 + 299))
        XCTAssertEqual(drive.reads, 1, "one attempt inside the retry window")

        XCTAssertNil(cache.read(now: t0 + 300))
        XCTAssertEqual(drive.reads, 2, "…and one more once it has passed")
    }

    /// Retrying sooner than the success TTL is the whole reason there are two
    /// intervals: a device that went offline across a sleep transition recovers in
    /// minutes rather than in an hour.
    func testFailuresAreRetriedSoonerThanSuccessesAreRefreshed() {
        let (cache, _) = makeCache(nil)
        XCTAssertLessThan(cache.failureRetryInterval, cache.successTTL)
    }

    /// A sample we could not refresh is not merely old, it is understated: every
    /// counter in it is cumulative and monotone, so a stale `dataUnitsWritten` is
    /// known to be too low with no way to say by how much. Absence beats a quiet
    /// undercount — the same call `SystemMetrics.Snapshot.sensorsSampled` makes.
    func testAStaleSampleIsNotServedAfterAFailedRefresh() throws {
        let sample = try decoded()
        let (cache, drive) = makeCache(sample)
        XCTAssertEqual(cache.read(now: t0), sample)

        drive.answer = nil
        XCTAssertNil(cache.read(now: t0 + 3600), "the refresh failed")
        XCTAssertNil(cache.read(now: t0 + 3601), "and the old number does not come back")
    }

    /// …and a recovery is a recovery: once the drive answers again the cache holds
    /// the new sample for a full hour, with no residue from the failure.
    func testARecoveredDriveResumesTheHourlyCadence() throws {
        let sample = try decoded()
        let (cache, drive) = makeCache(nil)
        XCTAssertNil(cache.read(now: t0))

        drive.answer = sample
        XCTAssertEqual(cache.read(now: t0 + 300), sample)
        XCTAssertEqual(cache.read(now: t0 + 300 + 3599), sample)
        XCTAssertEqual(drive.reads, 2, "the success restarted the hourly TTL")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Live hardware

    /// THE STRONG ONE. A device that advertises `NVMe SMART Capable` and then
    /// fails to produce a decodable page is a LOUD failure, not a skip.
    ///
    /// This is the test that would have caught the original mistake. "Assert that
    /// something answered" cannot distinguish a wrong class name from an Intel Mac
    /// — both find nothing, both pass, and the bug ships as an empty card. The
    /// property makes the stronger claim available: the drive itself says whether
    /// it has a health page, so anything that says yes is obliged to deliver one,
    /// and `NVMeHealth.Outcome` keeps "said no" apart from "said yes and failed".
    ///
    /// Measured: exactly one node in the whole IORegistry publishes the key, and
    /// `NVMeSMARTLibExternal.h` names it as the intended class-agnostic way to find
    /// these devices. A machine with none of them skips; a machine with one that
    /// misbehaves fails.
    func testEveryDeviceClaimingSMARTCapabilityDeliversAPage() throws {
        let probed = NVMeHealth.probeInternalDevices()
        let claimed = probed.filter { $0.outcome != .notCapable }
        guard !claimed.isEmpty else {
            throw XCTSkip("no internal device advertises \"NVMe SMART Capable\" here")
        }
        for (entryID, outcome) in claimed {
            guard case .sample = outcome else {
                return XCTFail("""
                    device 0x\(String(entryID, radix: 16)) advertises \
                    "NVMe SMART Capable" but answered \(outcome). That is a broken \
                    read, NOT unsupported hardware, and it must never reach a user \
                    as an empty card.
                    """)
            }
        }
    }

    /// The same node must be chosen every time. `IOIteratorNext` promises no order
    /// and both class names match the same device, so without the entry-ID dedupe
    /// and sort the card could silently describe a different drive run to run.
    func testTheDeviceChosenIsStableAcrossCalls() throws {
        let first = NVMeHealth.probeInternalDevices().map(\.entryID)
        guard !first.isEmpty else { throw XCTSkip("no internal NVMe namespace here") }
        XCTAssertEqual(first, first.sorted(), "candidates come back in entry-ID order")
        XCTAssertEqual(Set(first).count, first.count,
                       "the two class names match one device, deduped by entry ID")
        XCTAssertEqual(NVMeHealth.probeInternalDevices().map(\.entryID), first)
    }

    /// Every probe opens a user client and closes it again, and a missed release
    /// there leaks a KERNEL resource rather than a few bytes of userspace — an
    /// io_object, a CFPlugIn, and the COM reference `QueryInterface` hands out,
    /// which is the one an `IODestroyPlugInInterface` alone would strand. Each of
    /// those shows up as a mach port name in this task, so the port table is the
    /// observable.
    ///
    /// Measured while writing this: 1,000 probes, delta 0 ports. The threshold is
    /// loose because XCTest itself moves the count around; a real leak here would
    /// be 1,000-odd, not 20.
    func testTheProbeReleasesEveryKernelObjectItOpens() throws {
        guard !NVMeHealth.probeInternalDevices().isEmpty else {
            throw XCTSkip("no internal NVMe namespace here")
        }
        func portCount() -> Int {
            var names: mach_port_name_array_t?
            var nameCount: mach_msg_type_number_t = 0
            var types: mach_port_type_array_t?
            var typeCount: mach_msg_type_number_t = 0
            guard mach_port_names(mach_task_self_, &names, &nameCount,
                                  &types, &typeCount) == KERN_SUCCESS else { return -1 }
            if let names {
                vm_deallocate(mach_task_self_,
                              vm_address_t(UInt(bitPattern: names)),
                              vm_size_t(Int(nameCount) * MemoryLayout<mach_port_name_t>.size))
            }
            if let types {
                vm_deallocate(mach_task_self_,
                              vm_address_t(UInt(bitPattern: types)),
                              vm_size_t(Int(typeCount) * MemoryLayout<mach_port_type_t>.size))
            }
            return Int(nameCount)
        }

        for _ in 0..<50 { _ = NVMeHealth.probeInternalDevices() }   // let it settle
        let before = portCount()
        for _ in 0..<1000 { _ = NVMeHealth.probeInternalDevices() }
        XCTAssertLessThan(portCount() - before, 20,
                          "a user client, plug-in or io_object is being leaked per probe")
    }

    /// Absence is a SKIP, never a failure — this suite must pass on an Intel Mac,
    /// in a VM and on CI, exactly as `HardwareAvailabilityTests` requires.
    ///
    /// What IS asserted when the drive answers: the invariants whose violation
    /// means the plug-in dance is reading the wrong thing.
    func testTheLiveDriveAnswersWithAPlausiblePageWhenPresent() throws {
        guard let s = NVMeHealth.read() else {
            throw XCTSkip("no NVMe SMART user client on this machine")
        }
        XCTAssertLessThanOrEqual(s.availableSpare, 100)
        // No upper bound asserted on percentageUsed: 101-255 is legal and means
        // "past rated endurance". See testPastRatedEnduranceSurvivesAndIsReportedVerbatim.
        XCTAssertLessThanOrEqual(s.availableSpareThreshold, 100)
        if let c = s.temperatureC {
            XCTAssertGreaterThan(c, -40)
            XCTAssertLessThan(c, 125)
        }
        // A drive the machine booted from has been switched on and has read
        // something. Zeros here would mean the buffer came back unwritten.
        XCTAssertGreaterThan(s.powerCycles, 0)
        XCTAssertGreaterThan(s.dataUnitsRead, 0)

        // The second call must not touch IOKit again — the TTL is process-wide.
        XCTAssertEqual(NVMeHealth.read(), s)
    }
}
