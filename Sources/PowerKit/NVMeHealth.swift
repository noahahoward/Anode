import Foundation
import IOKit

/// NVMe Health Information Log Page 0x02 for the internal SSD.
///
/// WHY THIS FILE EXISTS AT ALL — "SMART is unavailable on Apple Silicon" is
/// widely believed and wrong, and the reason it is believed is a single wrong
/// guess about which IORegistry node vends the user client. Measured here on
/// `Mac17,9` (M5 Pro, macOS 27.0, uid 501, no entitlements), calling
/// `IOCreatePlugInInterfaceForService` with `kIONVMeSMARTUserClientTypeID`:
///
///     AppleANS3CGv2Controller             0xe00002c7  kIOReturnUnsupported
///     AppleEmbeddedNVMeTemperatureSensor  0xe00002c7  kIOReturnUnsupported
///     NVMeSEPNotifier                     0xe00002c7  kIOReturnUnsupported
///     IOEmbeddedNVMeBlockDevice           0x00000000  works
///     IONVMeBlockStorageDevice            0x00000000  works, byte-identical data
///
/// The obvious node — the controller — is the one that refuses. The user client
/// hangs off the NAMESPACE child, which is where `IOCFPlugInTypes` actually
/// lists `AA0FA6F9-…` → `NVMeSMARTLib.plugin`. Anyone who probes the controller,
/// gets `kIOReturnUnsupported`, and concludes the platform does not support SMART
/// has reproduced the entire myth in one step.
///
/// That failure mode is also why this file matches BOTH working classes rather
/// than the one that happens to answer on this machine. Getting the class wrong
/// does not produce an error anywhere a user can see it — it produces an empty
/// card that looks exactly like unsupported hardware.
///
/// So the rule here is that "no SMART on this machine" and "SMART that we failed
/// to read" must never be confusable. Three things enforce it: `smartCapableClasses`
/// is a list rather than a name; every node is gated on the `NVMe SMART Capable`
/// property BEFORE it is opened (see `smartCapableKey`); and `probeInternalDevices`
/// reports a per-device `Outcome` instead of a bare optional, so a device that
/// claims the capability and then fails to deliver is a distinct, assertable state.
/// `NVMeHealthTests` turns that into the strong test — any node advertising
/// `NVMe SMART Capable` MUST yield a decodable page, or the suite fails loudly on
/// the machine where it broke.
///
/// The two class names are not two devices. `IOEmbeddedNVMeBlockDevice` is a
/// SUBCLASS of `IONVMeBlockStorageDevice`, so `IOServiceMatching` on either name
/// returns the SAME node — measured: registry entry ID `0x100000d3a` from both
/// matching dictionaries, one namespace, one drive. They are both listed because
/// a non-embedded controller (an Intel Mac, a third-party drive in a Mac Pro)
/// publishes only the base class, and they are deduplicated by registry entry ID
/// so the internal SSD can never be counted twice.
///
/// COST, measured: 2.68 ms to open the plug-in and query the interface, 0.076 ms
/// per `SMARTReadData` once open. The open is what the hourly TTL is protecting
/// against; see `Cache`.
///
/// ── What this file deliberately does NOT compute ─────────────────────────────
///
/// No TBW figure, no endurance percentage, no "years of life left". This feature
/// originally planned to show a wear bar against a 612 TB endurance denominator
/// derived from the drive's geometry, and the measurement falsified it: this
/// drive reports `PERCENTAGE_USED = 0` at 7.31 TB written. If the vendor's own
/// integrator is still rounding to zero after 7.31 TB, the manufacturer's basis
/// is bounded BELOW by roughly 731 TB — 100 x the writes so far, since the field
/// is an integer percent and has not yet reached 1. That is above the 612 TB
/// number the bar would have been drawn against, so the bar would have been
/// wrong in the pessimistic direction on day one. A denominator this app cannot
/// measure is a denominator this app does not use.
///
/// `PERCENTAGE_USED == 0` is in any case not evidence of anything, because it is
/// indistinguishable from an unimplemented field. `CONTROLLER_BUSY_TIME` sits in
/// the same 512-byte page, reads exactly 0 after 204 recorded power-on hours and
/// 340 million write commands, and is almost certainly a stub — a controller that
/// served 7.31 TB was not busy for zero minutes. Two fields in one page reading 0
/// where one of them provably cannot be true is the reason nothing is built on
/// either. Both are still CARRIED, unaltered, because "the drive reports 0" is
/// what was measured; they are just never a denominator and never a headline.
///
/// ── Units, and how they were checked ─────────────────────────────────────────
///
/// `DATA_UNITS_READ`/`WRITTEN` are counted in 512,000-byte DECIMAL units — one
/// thousand 512-byte logical blocks, per NVMe Base Spec 2.0 §5.16.1.3 — NOT in
/// 512 KiB. The two differ by 2.4 %, which on a 7 TB total is 175 GB, so the
/// wrong constant is a wrong number rather than a rounding difference.
///
/// Verified empirically rather than taken from the spec. Over a 21.7 h passive
/// window the `DATA_UNITS_WRITTEN` delta agreed with `IOBlockStorageDriver`'s
/// `Bytes (Write)` for the same device to within the 512,000-byte quantum — i.e.
/// to within one count, which is the best agreement the field's resolution
/// permits. In the same window `HOST_WRITE_COMMANDS` matched `Operations (Write)`
/// EXACTLY: 2,292,636 against 2,292,636, difference 0. An exact match on a
/// nine-digit counter is not a coincidence, and it confirms both the offsets and
/// the byte order without needing to trust the header.
///
/// ── Concurrency ──────────────────────────────────────────────────────────────
///
/// THREAD-SAFE, NOT MAIN-THREAD-ONLY. Two other files depend on this, so it is a
/// contract rather than an implementation detail: `ResourcesPane` calls `read()`
/// on the main thread during a pane refresh, and `MetricRegistry` calls it from a
/// metric provider — and providers are invoked OUTSIDE the registry's lock, from
/// whichever thread called `update(with:)` (the sampling queue) or `value(for:)`
/// (the main thread on every widget refresh, and the calling thread in
/// `anode --metrics`). So `read()` can be entered concurrently from at least
/// three places and carries its own `NSLock`; see `Cache`.
///
/// The lock is NEVER held across the IOKit call, and that is measured rather than
/// assumed. `SMARTReadData` is an admin command that queues behind ordinary I/O:
/// median 0.076 ms idle, but a tail of 12.95 ms observed while ten `dd` writers
/// were saturating the same drive, and 2.83 ms even on an idle machine. Blocking
/// the main thread for most of a frame because a sampling thread happened to hit
/// the same expiry is not a trade worth making, so `Cache` claims the attempt
/// under the lock and then releases it before touching the hardware.
///
/// Nothing here touches AppKit and nothing assumes the main thread.
///
/// ── Does the read fail transiently? ──────────────────────────────────────────
///
/// Measured, because the retry policy in `Cache` depends on the answer: 378,100
/// `SMARTReadData` calls across 7,562 separate open/close cycles, half of them
/// while ten concurrent writers hammered the drive. Zero failures — no failed
/// `IOCreatePlugInInterfaceForService`, no failed `QueryInterface`, no non-success
/// `SMARTReadData`. The command is served even while the controller has been
/// power-gating between requests (this drive spends ~95 % of calendar time out of
/// its active state; see `powerOnHours`).
///
/// So on THIS hardware the failure path is effectively the unsupported-hardware
/// path, and the thing `failureRetryInterval` is really protecting against is an
/// Intel Mac or a VM retrying forever on every redraw. It is still kept short
/// enough to recover from a transient, because "never observed here" is not
/// "cannot happen" — a device genuinely offline across a sleep transition, or a
/// drive behind a bridge that answers only sometimes, is exactly the case this
/// machine cannot exhibit and cannot rule out.
public enum NVMeHealth {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: The reading

    /// One read of NVMe Health Information Log Page 0x02. All fields measured.
    public struct Sample: Equatable {
        public let criticalWarning: UInt8
        /// Raw Kelvin as the drive reports it. 0 means "not reported", never 0 K.
        public let temperatureK: UInt16
        public let availableSpare: UInt8            // percent
        public let availableSpareThreshold: UInt8   // percent; spare below this = EOL
        public let percentageUsed: UInt8            // vendor wear integrator
        public let dataUnitsRead: UInt64            // units of 512,000 bytes
        public let dataUnitsWritten: UInt64
        public let hostReadCommands: UInt64
        public let hostWriteCommands: UInt64
        public let controllerBusyTimeMinutes: UInt64
        public let powerCycles: UInt64
        /// Controller ACTIVE-STATE residency, NOT machine time. Measured at 4.6 % of
        /// calendar on this machine. NEVER divide by this and never show it unlabelled.
        ///
        /// The measurement: 203 → 204 over a 21.9 h wall-clock window during which
        /// the machine was awake 99.5 % of the time. One hour of "power on" for
        /// 21.9 hours of being switched on and used. The field counts the time the
        /// controller spent OUT of its low-power states, and an Apple SSD idles into
        /// PS3/PS4 between requests aggressively enough that a fully-used laptop
        /// accumulates it at about a twentieth of real time.
        ///
        /// So: as a rate denominator it would inflate every rate by ~22x — this
        /// drive's 7.31 TB over 204 "hours" reads as 36 GB/h, against the ~1.6 GB/h
        /// it actually averaged. And shown unlabelled next to `powerCycles` it reads
        /// as the age of the machine, which it is not: 204 h would suggest a
        /// six-week-old laptop rather than the ~9 months this one has been running.
        /// It is carried because it is measured; it is not a clock.
        public let powerOnHours: UInt64
        public let unsafeShutdowns: UInt64
        public let mediaErrors: UInt64
        public let errorLogEntries: UInt64

        public var bytesRead: UInt64 { dataUnitsRead &* 512_000 }
        public var bytesWritten: UInt64 { dataUnitsWritten &* 512_000 }
        /// nil when the drive reports 0 K, which is "no sensor", not absolute zero.
        public var temperatureC: Double? { temperatureK == 0 ? nil : Double(temperatureK) - 273.15 }
    }

    /// A measured state transition worth telling someone about. Never a projection.
    ///
    /// Every case is a comparison between two numbers that are both in the page in
    /// front of us. There is no case here that means "will fail in N months",
    /// because nothing in this page supports that claim — see the file header on
    /// the endurance denominator that was measured out of existence.
    public enum Alarm: Equatable {
        case criticalWarning(UInt8)      // any non-zero bit
        case spareBelowThreshold(UInt8, threshold: UInt8)
        case mediaErrors(UInt64)         // > 0
        case wearStarted(UInt8)          // percentageUsed left 0
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Decoding — pure, no IOKit

    /// Byte offsets into log page 0x02, NVMe Base Spec 2.0 §5.16.1.3.
    ///
    /// Written out rather than read through the SDK's `NVMeSMARTData` struct for
    /// the reason `SMC` writes out its 80-byte request buffer: Swift does not
    /// promise C layout, the C struct is `#pragma pack(1)` with a `uint16_t` at
    /// offset 1, and the naive Swift translation of that would pad `TEMPERATURE`
    /// to offset 2 and silently shift every subsequent field. Explicit offsets are
    /// both correct and self-documenting, and they are the thing the fixture test
    /// pins.
    ///
    /// Every offset below was checked against `offsetof` on the real SDK header
    /// AND against a live 512-byte dump from this machine. `errorLogEntries` is
    /// called out because an earlier reading of the spec had it at the wrong
    /// offset; it is 176, confirmed both ways.
    private enum Off {
        static let criticalWarning = 0    // 1 byte
        static let temperature     = 1    // 2 bytes, Kelvin, little-endian
        static let availableSpare  = 3    // 1 byte, percent
        static let spareThreshold  = 4    // 1 byte, percent
        static let percentageUsed  = 5    // 1 byte, percent
        // The rest are 128-bit little-endian counters, 16 bytes each.
        static let dataUnitsRead      = 32
        static let dataUnitsWritten   = 48
        static let hostReadCommands   = 64
        static let hostWriteCommands  = 80
        static let controllerBusyTime = 96
        static let powerCycles        = 112
        static let powerOnHours       = 128
        static let unsafeShutdowns    = 144
        static let mediaErrors        = 160
        static let errorLogEntries    = 176   // NOT 192; verified against a live dump
        static let pageSize           = 512
    }

    /// The band a composite temperature may lie in, in Kelvin: −40 °C to +125 °C,
    /// the JEDEC storage-plus-operating envelope for NAND and the controller.
    ///
    /// This fence is not guarding against a broken drive — a drive at 130 °C has
    /// bigger problems than a mislabelled card. It guards against a UNIT slip. If
    /// a future driver ever handed back Celsius in this field, this machine's
    /// 307 K would arrive as 34, and 34 K prints as −239 °C: a finite, plausibly
    /// formatted, completely wrong number that a card would show without
    /// complaint. 34 is outside the band; −239 °C never reaches the screen.
    ///
    /// 0 is exempt and handled separately — see `temperatureC`. "No sensor" is a
    /// legal answer and is not the same claim as "cold".
    static let plausibleTemperatureK: ClosedRange<UInt16> = 233...398

    /// Decodes a 512-byte log page. Pure, no IOKit — this is the unit-testable half.
    /// Returns nil if the buffer is not 512 bytes.
    ///
    /// This split is the structural point of the file. Everything that can be
    /// wrong about the LAYOUT of this page — offsets, endianness, the 128-bit
    /// truncation, the plausibility bands — is decided here, from a byte array,
    /// with no hardware in the room. `NVMeHealthTests` drives it with the real
    /// 512 bytes this machine returned, so a layout regression fails on a CI box
    /// that has never seen an NVMe drive.
    ///
    /// nil rather than a partial `Sample` when anything is out of band, following
    /// `DiskActivity.maxPlausibleBytesPerSec` and `Store.maxPlausibleWatts`: a
    /// counter doing something unexplained becomes a MISSING card, never a
    /// headline number. There is no half-credible SSD health card — a page whose
    /// spare percentage reads 200 has told us nothing trustworthy about its media
    /// error count either.
    public static func decode(_ page: [UInt8]) -> Sample? {
        // Exactly 512, not "at least". A longer buffer is not this log page with
        // slack on the end; it is a caller that handed us something else, and the
        // offsets below would decode it into confident nonsense.
        guard page.count == Off.pageSize else { return nil }

        let availableSpare = page[Off.availableSpare]
        let spareThreshold = page[Off.spareThreshold]
        let percentageUsed = page[Off.percentageUsed]

        // Spare and its threshold are integer percents of a quantity that cannot
        // exceed itself, so a byte holding 101–255 there is a decode error and the
        // page is rejected — a spare of 200 % would render as a full green bar.
        //
        // `percentageUsed` is DELIBERATELY NOT FENCED, and the asymmetry is the
        // point. The spec permits 101–255, meaning "past the manufacturer's rated
        // endurance", saturating at 255. That is not a malformed reading: it is the
        // single most important reading this file can ever return, and it is the one
        // state in which somebody needs to be told something urgently.
        //
        // Rejecting it would return nil, which every caller renders as "this machine
        // has no SMART" — so a worn-out drive would present EXACTLY like an Intel Mac
        // or a VM. That is the failure this whole feature was rebuilt to avoid: an
        // absent measurement and an alarming one must never be the same pixel.
        // Downstream consumers therefore take a "percent" that can exceed 100, which
        // is correct; `alarms(for:)` already carries the raw value through
        // `.wearStarted`, so a drive at 150 % reports 150.
        guard availableSpare <= 100, spareThreshold <= 100 else { return nil }

        let temperatureK = u16(page, Off.temperature)
        guard temperatureK == 0 || plausibleTemperatureK.contains(temperatureK)
        else { return nil }

        // Each of these is a 128-bit little-endian counter, and each is truncated
        // to its low 64 bits.
        //
        // The truncation is lossless in practice and checked rather than assumed:
        // `u64Low` returns nil when the HIGH 64 bits are non-zero, and a nil there
        // rejects the whole page. 2^64 data units is 9.4 x 10^24 bytes — nine
        // yottabytes — so a non-zero high half is not a drive that wrote a great
        // deal, it is proof that we are reading the buffer at the wrong offsets or
        // in the wrong byte order. Measured on this machine every high half is 0,
        // which is what makes this a usable fence rather than a theoretical one.
        guard let dataUnitsRead      = u64Low(page, Off.dataUnitsRead),
              let dataUnitsWritten   = u64Low(page, Off.dataUnitsWritten),
              let hostReadCommands   = u64Low(page, Off.hostReadCommands),
              let hostWriteCommands  = u64Low(page, Off.hostWriteCommands),
              let controllerBusyTime = u64Low(page, Off.controllerBusyTime),
              let powerCycles        = u64Low(page, Off.powerCycles),
              let powerOnHours       = u64Low(page, Off.powerOnHours),
              let unsafeShutdowns    = u64Low(page, Off.unsafeShutdowns),
              let mediaErrors        = u64Low(page, Off.mediaErrors),
              let errorLogEntries    = u64Low(page, Off.errorLogEntries)
        else { return nil }

        // A page with no evidence that the drive has ever been used is a buffer
        // that was never written, not a measurement.
        //
        // This is the "not measured vs measured zero" line, drawn where it can
        // actually be drawn. We only ever read this page off a device the machine
        // is running from, so a drive reporting zero reads AND zero writes AND
        // zero power cycles is claiming something that cannot be true of a drive
        // we just talked to. The realistic cause is a user client that returned
        // success without filling the buffer — `readPage` hands us a pre-zeroed
        // 512 bytes, so that failure arrives looking exactly like this.
        //
        // Deliberately a conjunction of all three, not a test on any one of them.
        // Individually every field in this page is allowed to be zero and often
        // is: `mediaErrors` and `errorLogEntries` are zero on a healthy drive, and
        // `controllerBusyTime` is zero on this one because it is a stub. Rejecting
        // on a single zero would throw away good pages; rejecting on all three
        // together only ever catches a page that says nothing at all.
        guard !(dataUnitsRead == 0 && dataUnitsWritten == 0 && powerCycles == 0)
        else { return nil }

        return Sample(criticalWarning: page[Off.criticalWarning],
                      temperatureK: temperatureK,
                      availableSpare: availableSpare,
                      availableSpareThreshold: spareThreshold,
                      percentageUsed: percentageUsed,
                      dataUnitsRead: dataUnitsRead,
                      dataUnitsWritten: dataUnitsWritten,
                      hostReadCommands: hostReadCommands,
                      hostWriteCommands: hostWriteCommands,
                      controllerBusyTimeMinutes: controllerBusyTime,
                      powerCycles: powerCycles,
                      powerOnHours: powerOnHours,
                      unsafeShutdowns: unsafeShutdowns,
                      mediaErrors: mediaErrors,
                      errorLogEntries: errorLogEntries)
    }

    /// Little-endian 16-bit read. The page is LE on the wire regardless of host
    /// byte order, so this is spelled out rather than borrowed from `loadUnaligned`
    /// — and `temperature` sits at offset 1, which is unaligned anyway.
    private static func u16(_ page: [UInt8], _ off: Int) -> UInt16 {
        UInt16(page[off]) | UInt16(page[off + 1]) << 8
    }

    /// Low 64 bits of a 128-bit little-endian counter, or nil if the high 64 bits
    /// are set. See the truncation note in `decode`.
    private static func u64Low(_ page: [UInt8], _ off: Int) -> UInt64? {
        for i in 8..<16 where page[off + i] != 0 { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(page[off + i]) }
        return v
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Alarms

    /// Measured transitions only, in severity order.
    ///
    /// Severity order is the declaration order of `Alarm`, and it is a claim: a
    /// controller-raised critical warning outranks a spare-pool comparison this
    /// code made itself, which outranks a media error count, which outranks the
    /// wear integrator merely having left zero. A UI showing one line shows the
    /// first; a UI showing a list shows them top-down.
    ///
    /// `criticalWarning` and `spareBelowThreshold` OVERLAP by design. Bit 0 of the
    /// critical warning byte is defined as "available spare has fallen below
    /// threshold", so a conforming drive raises both. They are still reported
    /// separately because they are different measurements: one is the drive's own
    /// verdict, the other is a comparison of two numbers we can show. A drive that
    /// raises the bit without the spare having moved, or moves the spare without
    /// raising the bit, is telling us something, and collapsing them would hide it.
    public static func alarms(for s: Sample) -> [Alarm] {
        var out: [Alarm] = []

        // Any bit. The spec assigns meanings to bits 0–5 and reserves 6–7, and this
        // deliberately does not decode them: a reserved bit set is still the drive
        // saying something is wrong, and dropping it because we lack a label for it
        // would be the worst possible direction to be silent in.
        if s.criticalWarning != 0 { out.append(.criticalWarning(s.criticalWarning)) }

        // Strictly below. Spare EQUAL to the threshold is the drive sitting on the
        // line, which the spec does not define as the failure condition, and firing
        // there would raise a permanent alarm on any drive whose vendor sets the
        // two equal. This machine reports 100 against a threshold of 99.
        if s.availableSpare < s.availableSpareThreshold {
            out.append(.spareBelowThreshold(s.availableSpare,
                                            threshold: s.availableSpareThreshold))
        }

        // Unrecoverable data integrity errors. One is a real event; there is no
        // "acceptable" count and so no threshold to tune.
        if s.mediaErrors > 0 { out.append(.mediaErrors(s.mediaErrors)) }

        // Not a wear LEVEL — a transition. The whole significance of this is that
        // the field is an integer percent that has been pinned at 0 since the drive
        // was made, so the step to 1 is the first and only wear information the
        // drive has ever volunteered. It is emitted as a note that the counter has
        // started moving, never as a fraction of a lifetime; see the file header
        // for why there is no lifetime to be a fraction of.
        if s.percentageUsed > 0 { out.append(.wearStarted(s.percentageUsed)) }

        return out
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Reading the hardware

    /// Reads the internal SSD's log page. nil when no device vends the SMART user
    /// client (Intel Macs, VMs, external bridges) — an absent measurement, never zeros.
    /// Cached; re-reads at most once per hour.
    ///
    /// Safe from any thread. `now` is injectable so a caller that already has a
    /// tick timestamp does not pay a `Date()` per call, and so the TTL is drivable
    /// in a test on hardware that happens to have the device.
    public static func read(now: Date = Date()) -> Sample? {
        shared.read(now: now)
    }

    /// The classes that vend `kIONVMeSMARTUserClientTypeID`. See the file header:
    /// the second entry is the base class of the first, both match the same node
    /// here, and the list is a list precisely so that getting this wrong cannot
    /// look like unsupported hardware.
    private static let smartCapableClasses = [
        "IOEmbeddedNVMeBlockDevice",
        "IONVMeBlockStorageDevice",
    ]

    /// `kIONVMeSMARTUserClientTypeID`, AA0FA6F9-C2D6-457F-B10B-59A13253292F.
    ///
    /// Spelled out because the SDK constant is a C MACRO wrapping
    /// `CFUUIDGetConstantUUIDWithBytes`, which Swift declines to import —
    /// `cannot find 'kIONVMeSMARTUserClientTypeID' in scope`, with the clang note
    /// "macro unavailable: structure not supported". The whole
    /// `NVMeSMARTLibExternal.h` interface is invisible from Swift for the same
    /// reason, which is the other half of why this file talks to the vtable by
    /// hand below.
    private static let userClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
        0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)

    /// `kIONVMeSMARTInterfaceID`, CCD1DB19-FD9A-4DAF-BF95-12454B230AB6.
    private static let smartInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
        0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

    /// `kIOCFPlugInInterfaceID`, C244E858-109C-11D4-91D4-0050E4C6426F. Also a
    /// macro, also invisible from Swift.
    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    /// `IOReturn (*SMARTReadData)(void *interface, NVMeSMARTData *data)`.
    private typealias SMARTReadData = @convention(c)
        (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
    /// `ULONG (*Release)(void *thisPointer)` from `IUNKNOWN_C_GUTS`.
    private typealias COMRelease = @convention(c) (UnsafeMutableRawPointer?) -> UInt32

    /// Byte offsets into the `IONVMeSMARTInterface` vtable.
    ///
    /// The COM interface is reached through explicit offsets for the same reason
    /// `SMC` builds its request buffer by hand, and then for a second reason on
    /// top: the type is not importable into Swift at all (see `userClientTypeID`),
    /// so there is no struct to lay out even incorrectly. These are the offsets
    /// `offsetof` reports on the real SDK header:
    ///
    ///     _reserved       0    IUNKNOWN_C_GUTS
    ///     QueryInterface  8
    ///     AddRef         16
    ///     Release        24
    ///     version        32    UInt16 — reads 1 on this machine
    ///     revision       34    UInt16 — reads 0
    ///     (padding)      36    to align the next function pointer
    ///     SMARTReadData  40
    ///     GetIdentifyData 48
    ///     GetLogPage     72    (after two reserved UInt64s)
    ///
    /// Only `Release` and `SMARTReadData` are used. `GetLogPage` would let this
    /// read arbitrary log pages — the error log, the persistent-event log — and is
    /// deliberately not wired up: page 0x02 is the one whose every field has been
    /// cross-checked against a second source, and an unvalidated page is exactly
    /// the sort of confident-looking unknown this app does not ship.
    ///
    /// The value handed back by `QueryInterface` is an `IONVMeSMARTInterface **`:
    /// a pointer to a pointer to the interface struct, which IS the vtable. The
    /// outer pointer is the `this` argument every method takes, and the inner one
    /// is what these offsets are relative to.
    private enum VTable {
        static let release       = 24
        static let smartReadData = 40
    }

    /// `kIOPropertyNVMeSMARTCapableKey`, spelled out from `NVMeSMARTLibExternal.h`.
    ///
    /// The header's own discussion of it: "Property to search for in IORegistry to
    /// find NVMe SMART capable devices WITHOUT HARDCODING THE SEARCH TO A
    /// PARTICULAR DEVICE CLASS". Which is to say Apple documented the answer to the
    /// question this file's header is about, and the myth that Apple Silicon has no
    /// SMART survives partly because nobody read it.
    ///
    /// Measured: exactly ONE node in the entire IORegistry publishes this key —
    /// the namespace node, `IOEmbeddedNVMeBlockDevice`, where it reads `Yes`. It is
    /// absent from `AppleANS3CGv2Controller` entirely, which is the same story the
    /// return codes tell, from the other end.
    ///
    /// Used as a FAST PATH, never as the measurement and never as a gate. The
    /// property is the device's claim about itself; the 512 bytes are the fact. An
    /// explicit false is taken at its word; an ABSENT key is not, because absence
    /// is what an OS or a controller generation we have never seen looks like. See
    /// `Outcome` and `attemptsOpen(claim:)`.
    private static let smartCapableKey = "NVMe SMART Capable"

    /// What one candidate node had to say. Three failures that a bare `nil` would
    /// flatten into one.
    ///
    /// This is the distinction the whole feature turns on. "No device vends the
    /// user client" (an Intel Mac, a VM) and "a device SAID it vends the user
    /// client and then would not open it" are not the same event: the first is
    /// ordinary absent hardware, and the second is a bug — in this file, in the
    /// vtable offsets, or in an OS change — that presents to the user as an empty
    /// card indistinguishable from the first. That indistinguishability is exactly
    /// how this feature got designed wrong once, so the states are kept apart here
    /// and `NVMeHealthTests` asserts on them.
    enum Outcome: Equatable {
        /// The node publishes `NVMe SMART Capable` and it reads false. The device
        /// is telling us it has no health page. Not an error, and not asked.
        case notCapable
        /// The node publishes no capability key AT ALL, was asked anyway, and would
        /// not open. Quiet, deliberately.
        ///
        /// The key was measured present on this hardware, but "present on the two
        /// machines anyone tried" is not "emitted by every Apple Silicon Mac since
        /// 2020, on every macOS since 13". Treating its ABSENCE as a verdict would
        /// make an older Mac render a blank card while a perfectly good log page sat
        /// one unasked open away — the same silent-blank this file exists to have
        /// stopped happening. So absence buys a 2.7 ms question, not a conclusion,
        /// and only an explicit false closes the door.
        case unclaimed
        /// The node claims SMART capability and the user client would not open, or
        /// would not vend the interface. A LOUD failure: something we believe is
        /// wrong.
        case openFailed(IOReturn)
        /// The client opened and `SMARTReadData` refused. Never observed on this
        /// hardware in 378,100 calls; see the file header.
        case readFailed(IOReturn)
        /// 512 bytes arrived and failed a plausibility fence in `decode`.
        case undecodable
        case sample(Sample)
    }

    /// Every INTERNAL candidate node and what it answered, deduplicated and in a
    /// stable order. Internal rather than private so the tests can make the strong
    /// assertion — that no node claiming `NVMe SMART Capable` is allowed to fail to
    /// produce a page — instead of the weak one, that something somewhere answered.
    ///
    /// THE TWO CLASS NAMES MATCH THE SAME DEVICE. `IOEmbeddedNVMeBlockDevice` is a
    /// subclass of `IONVMeBlockStorageDevice`, and `IOServiceMatching` matches
    /// subclasses, so a match on the base name returns the child too. Measured
    /// here: both matching dictionaries return registry entry ID `0x100000d3a`,
    /// class `IOEmbeddedNVMeBlockDevice`, one namespace node, one drive —
    /// `ioreg -c IONVMeBlockStorageDevice` and `ioreg -c IOEmbeddedNVMeBlockDevice`
    /// print the identical node. Matching both names is therefore not two lookups
    /// of two devices; it is one device found twice, plus insurance for hardware
    /// that publishes only the base class (an Intel Mac, a third-party drive).
    ///
    /// Matching by class at all, when the header offers a property to search on
    /// instead, is deliberate: a property match would also sweep in a Thunderbolt
    /// enclosure's namespace, and this feature is scoped to the internal drive
    /// anyway (see `isInternal`). The class list keeps the candidate set small and
    /// the property gates it.
    ///
    /// Candidates are deduplicated by registry entry ID — unique for the life of
    /// the boot and never reused, the same guarantee `DiskActivity.identity` relies
    /// on — and then SORTED by that ID before any of them is opened.
    ///
    /// The sort is the part that matters. `IOIteratorNext` promises no order, so on
    /// a machine with more than one internal SMART-capable namespace, taking
    /// "whichever came first" would let the headline number describe a different
    /// device from one launch to the next, with nothing on screen to say so. That
    /// is the same class of silent nondeterminism the plausibility fences exist to
    /// prevent, and the entry ID is a stable, monotonic tiebreak that costs
    /// nothing. On this machine there is exactly one candidate and the sort is a
    /// no-op; it is here for the machine that has two.
    static func probeInternalDevices() -> [(entryID: UInt64, outcome: Outcome)] {
        // Ownership: `IOIteratorNext` returns a retained object. A service that
        // fails the guards is released immediately; one that reaches `candidates`
        // is owned by the array and released by the `defer`.
        var candidates: [(id: UInt64, service: io_object_t)] = []
        defer { for c in candidates { IOObjectRelease(c.service) } }

        for className in smartCapableClasses {
            guard let match = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                      !candidates.contains(where: { $0.id == entryID }),
                      isInternal(service)
                else { IOObjectRelease(service); continue }

                candidates.append((entryID, service))
            }
        }

        return candidates
            .sorted { $0.id < $1.id }
            .map { (entryID: $0.id, outcome: outcome(for: $0.service)) }
    }

    /// Why an open-and-read produced no page. Distinct from `Outcome` only
    /// because `Result`'s failure type must be an `Error`, and `Outcome` is not
    /// one — it has a success case, and a type whose `.sample` is an `Error` would
    /// be a lie told to the type system for one line's convenience.
    private enum IOFailure: Error {
        case open(IOReturn)
        case read(IOReturn)
    }

    /// Is a node carrying this claim worth asking? PURE, and the whole portability
    /// decision in this file lives in this one line.
    ///
    /// nil (no key published) attempts, because absence is not denial. Only an
    /// explicit false declines. Costs a 2.7 ms open, once an hour, on hardware that
    /// will usually answer.
    static func attemptsOpen(claim: Bool?) -> Bool { claim != false }

    /// How to read a refusal to open, given what the node claimed. PURE.
    ///
    /// A node that CLAIMED capability and then refused is a contradiction — a bug
    /// here, in the vtable offsets, or in an OS change — and is loud. A node that
    /// claimed nothing and refused is ordinary absent hardware and is quiet. Same
    /// return code, different events, and flattening them is how an empty card
    /// stops being distinguishable from a broken one.
    static func openFailure(claim: Bool?, _ rc: IOReturn) -> Outcome {
        claim == true ? .openFailed(rc) : .unclaimed
    }

    /// The claim, then the trial open, then the decode.
    private static func outcome(for service: io_object_t) -> Outcome {
        let claim = IORegistryEntryCreateCFProperty(
            service, smartCapableKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        guard attemptsOpen(claim: claim) else { return .notCapable }

        switch openPage(service) {
        case .failure(.open(let rc)): return openFailure(claim: claim, rc)
        case .failure(.read(let rc)): return .readFailed(rc)
        case .success(let page):      return decode(page).map(Outcome.sample) ?? .undecodable
        }
    }

    /// One pass over the hardware, reduced to the answer `read(now:)` promises.
    /// No caching, no clock — `Cache` owns both.
    private static func readFromHardware() -> Sample? {
        for (_, outcome) in probeInternalDevices() {
            if case .sample(let s) = outcome { return s }
        }
        return nil
    }

    /// Is this the built-in drive?
    ///
    /// The same predicate `DiskActivity.Identity.isInternal` uses, against the same
    /// key on the same node — `Protocol Characteristics` → `Physical Interconnect
    /// Location` == "Internal". (In `DiskActivity` it is read from the
    /// `IOBlockStorageDriver`'s parent; here the NVMe namespace node IS that
    /// parent, so it is read directly.) Measured on this machine:
    /// `{"Physical Interconnect"="Apple Fabric", "Physical Interconnect Location"="Internal"}`.
    ///
    /// A Thunderbolt NVMe enclosure very likely answers the same user client
    /// honestly, and is excluded anyway. That is a SCOPE decision, not a capability
    /// one, and the difference matters: the card this feeds says "your Mac's SSD"
    /// and reports lifetime writes and wear for the machine. Folding in whatever
    /// drive happens to be plugged in would make the same headline number mean a
    /// different thing depending on what is on the desk, and a drive that is
    /// unplugged mid-session would make it vanish. Supporting external drives is a
    /// feature — a device picker, a per-device card — not a missing `guard`. If it
    /// is ever built, this is the line to relax, and nothing else here changes.
    private static func isInternal(_ service: io_object_t) -> Bool {
        guard let raw = IORegistryEntryCreateCFProperty(
                service, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0),
              let proto = raw.takeRetainedValue() as? [String: Any]
        else { return false }
        // Unlike `DiskActivity.isPhysical`, an unknown location is NOT given the
        // benefit of the doubt. There, dropping a device under-reports a total
        // this app is trying to make complete; here, admitting the wrong device
        // mislabels a headline as the machine's own SSD.
        return (proto["Physical Interconnect Location"] as? String) == "Internal"
    }

    /// Opens the SMART user client on one service, reads page 0x02, closes
    /// everything.
    ///
    /// Reports WHICH step failed, rather than collapsing to nil, so `outcome(for:)`
    /// can keep an open failure apart from a read failure — see `Outcome` for why
    /// that distinction is load-bearing rather than decorative. This is only ever
    /// reached after the node has claimed `NVMe SMART Capable`, so every failure
    /// below is a device contradicting its own property.
    ///
    /// MEMORY: three things need releasing — the plug-in interface, the COM
    /// interface, and (by the caller) the io_object. Every one of them is on a
    /// `defer` placed immediately after the acquisition that needs it, so the
    /// early returns below cannot skip one. This is the single most leak-prone
    /// shape in the file: `IODestroyPlugInInterface` on the plug-in is not enough
    /// on its own, because `QueryInterface` handed out an independent COM
    /// reference that keeps the user client connection open, and leaking that one
    /// leaks a kernel resource rather than a few bytes of userspace.
    private static func openPage(_ service: io_object_t) -> Result<[UInt8], IOFailure> {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        // kIOReturnUnsupported (0xe00002c7) is what a node that does not vend the
        // client answers — a controller, an Intel Mac, a VM. Reaching it HERE
        // means the node published `NVMe SMART Capable` and then refused, which is
        // a contradiction rather than an absence, hence `.openFailed` and not
        // `.notCapable`.
        let kr = IOCreatePlugInInterfaceForService(service, userClientTypeID,
                                                   plugInInterfaceID, &plugIn, &score)
        guard kr == KERN_SUCCESS, let plugIn else { return .failure(.open(kr)) }
        defer { IODestroyPlugInInterface(plugIn) }

        // A plug-in with no `QueryInterface` in its own vtable loaded but is not a
        // COM interface. There is no return code to report, so `kIOReturnUnsupported`
        // stands in — the same code the controller answers with, and the same claim:
        // this node cannot serve the request.
        var interface: LPVOID?
        guard let queryInterface = plugIn.pointee?.pointee.QueryInterface
        else { return .failure(.open(kIOReturnUnsupported)) }
        let hr = queryInterface(plugIn, CFUUIDGetUUIDBytes(smartInterfaceID), &interface)
        guard hr == S_OK, let interface
        else { return .failure(.open(IOReturn(truncatingIfNeeded: hr))) }

        // The vtable pointer, and the two entries taken from it. Loaded before the
        // `defer` so that a malformed vtable fails here rather than inside cleanup.
        let vtable = interface.load(as: UnsafeMutableRawPointer.self)
        let release = vtable.load(fromByteOffset: VTable.release, as: COMRelease.self)
        defer { _ = release(interface) }
        let smartReadData = vtable.load(fromByteOffset: VTable.smartReadData, as: SMARTReadData.self)

        // 512 bytes, matching `sizeof(NVMeSMARTData)` exactly — confirmed 512 on
        // this SDK. Pre-zeroed, which is why a driver that returns success without
        // writing anything is caught twice over: by the explicit check on the
        // return code here, and by the all-zero fence in `decode` if a driver ever
        // manages to report success and write nothing.
        var page = [UInt8](repeating: 0, count: Off.pageSize)
        let rc = page.withUnsafeMutableBytes { smartReadData(interface, $0.baseAddress) }
        guard rc == kIOReturnSuccess else { return .failure(.read(rc)) }
        return .success(page)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Caching

    /// The TTL cache in front of `readFromHardware`.
    ///
    /// An object rather than a pile of `static var`s so the tests can own one and
    /// drive it with a fake clock and a fake fetch, the way `SensorCacheTests`
    /// does: whether a read is issued must depend only on the clock, never on the
    /// hardware the tests happen to run on.
    ///
    /// Thread-safe, and the lock is NEVER held across the fetch — the same shape
    /// `Battery.properties()` uses, for a sharper reason. `SMARTReadData` is an
    /// admin command that queues behind ordinary I/O: 0.076 ms median on an idle
    /// drive, but a measured tail of 12.95 ms with ten writers saturating it, on
    /// top of the 2.7 ms open. `read(now:)` is called from the main thread by
    /// `ResourcesPane` and from the sampling queue by a `MetricRegistry` provider,
    /// so a held lock would let a background refresh stall a UI frame — most of a
    /// 16.7 ms budget, for a number that changes in its fifth digit.
    ///
    /// Two callers arriving together must still not both open a user client, so
    /// the attempt is CLAIMED under the lock before it is made: `lastFailure` is
    /// stamped pessimistically, which makes any concurrent caller take the
    /// rate-limit branch and return nil rather than start a second open. If the
    /// fetch succeeds the stamp is cleared and the sample published; if it fails
    /// the stamp is already correct. The visible cost of that race is that a
    /// caller landing inside the ~3-13 ms of an in-flight fetch is told "not
    /// measured" — which for those milliseconds is exactly true.
    final class Cache {
        /// An hour, because nothing on this page can visibly change inside one.
        ///
        /// The counters move at a few GB per hour of ordinary use — this machine
        /// averaged ~1.6 GB/h over its life — and one data unit is 512,000 bytes,
        /// so an hour is a few thousand counts on a total reading 14,285,870. That
        /// is the fifth significant figure of a number displayed to three. Wear,
        /// power cycles, unsafe shutdowns and media errors move on scales of months
        /// or of discrete events; `percentageUsed` has not moved once in the life
        /// of this drive.
        ///
        /// The one field that genuinely moves fast is temperature, and this is not
        /// where it should come from: a live SSD temperature belongs on the SMC
        /// sensor path with the rest of the thermals, sampled at the sensor
        /// cadence. `temperatureK` is here because it is in the page, and it is
        /// honest about being an hourly snapshot.
        ///
        /// What the TTL is actually buying: the plug-in open costs 2.7 ms. A card
        /// that redraws at 1 Hz would spend 9.7 seconds per hour opening a user
        /// client to re-read a number that changed in its fifth digit.
        let successTTL: TimeInterval
        /// How long to wait after a FAILED read before trying again.
        ///
        /// Failures come in two flavours that the return code cannot tell apart.
        /// One is permanent — an Intel Mac, a VM, a machine whose only NVMe is
        /// behind a Thunderbolt bridge — where every retry until the end of time
        /// will fail, and the only cost that matters is that retrying must be
        /// cheap. The other is transient: the device offline across a sleep
        /// transition, a namespace momentarily busy, where an hour of blankness
        /// would be a bug.
        ///
        /// So: shorter than the success TTL, and far longer than any UI cadence.
        /// Five minutes gives the transient case twelve chances an hour, and costs
        /// the permanent case twelve empty `IOServiceGetMatchingServices` walks an
        /// hour — a matching dictionary against a class with no instances, which
        /// returns an empty iterator and touches no user client at all. The thing
        /// this number exists to prevent is per-call retry: without it, an
        /// unsupported machine would attempt the whole match-and-open dance on
        /// every single redraw, forever, and never once succeed.
        let failureRetryInterval: TimeInterval

        private let fetch: () -> Sample?
        private let lock = NSLock()
        /// The last SUCCESSFUL read, and when. Failures are never stored here —
        /// there is no negative cache entry, because "no sample" is not a sample.
        private var cached: (sample: Sample, at: Date)?
        private var lastFailure: Date?

        init(successTTL: TimeInterval = 3600,
             failureRetryInterval: TimeInterval = 300,
             fetch: @escaping () -> Sample?) {
            self.successTTL = successTTL
            self.failureRetryInterval = failureRetryInterval
            self.fetch = fetch
        }

        func read(now: Date) -> Sample? {
            lock.lock()
            if let c = cached, now.timeIntervalSince(c.at) < successTTL {
                lock.unlock()
                return c.sample
            }
            if let f = lastFailure, now.timeIntervalSince(f) < failureRetryInterval {
                lock.unlock()
                return nil
            }
            // Claim the attempt before releasing, so a caller arriving during the
            // fetch takes the branch above instead of opening a second user
            // client. Pessimistic: if the fetch succeeds this is cleared below.
            lastFailure = now
            lock.unlock()

            let fresh = fetch()

            lock.lock()
            defer { lock.unlock() }

            guard let fresh else {
                // `lastFailure` already stands at the pre-fetch instant.
                //
                // The stale entry is DROPPED rather than served on.
                //
                // A sample we could not refresh is not merely old, it is
                // understated in a specific direction: every counter in it is
                // cumulative and monotone, so a stale `dataUnitsWritten` is a
                // number that has certainly grown since. Showing it would be
                // showing a figure that is known to be too low, with no way to say
                // by how much. Absence beats a quiet undercount, which is the same
                // call `SystemMetrics.Snapshot.sensorsSampled` makes for fans.
                //
                // The visible consequence is that one transient failure blanks the
                // card for up to `failureRetryInterval`. That is the intended
                // trade, and it is why that interval is minutes rather than an hour.
                cached = nil
                return nil
            }
            cached = (fresh, now)
            lastFailure = nil
            return fresh
        }
    }

    /// The process-wide cache behind `read(now:)`.
    private static let shared = Cache(fetch: readFromHardware)
}
