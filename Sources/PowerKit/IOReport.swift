import Foundation

/// Live per-rail energy from the private IOReport framework.
///
/// MEASURED ON THIS HARDWARE (M5 Pro / Mac17,9 / macOS 27.0): of 11,541 channels,
/// exactly ONE energy-unit channel is live — `Energy Model / GPU Energy` in nJ.
/// All 308 per-core PMGR rails (PACC_*, MCPU*_*, CPU Energy, DRAM0, DISP0, ANE0 …)
/// report a unit label but delta to ZERO. They exist in the registry and are dead.
///
/// So this class does NOT hardcode a rail list. It subscribes to everything, keeps
/// whatever actually moves, and buckets by name. On an M1/M2/M3 or Intel machine
/// where more rails are live it will pick them up with no code change; here it
/// yields GPU and honestly reports the rest as unavailable.
///
/// Units are read PER CHANNEL via IOReportChannelGetUnitLabel — never assumed.
/// This die mixes mJ (308), uJ (5) and nJ (1) inside the single "Energy Model"
/// group, and `GPU0` is mJ while `GPU Energy` is nJ. A hardcoded divisor would be
/// wrong by 10^3–10^6 and would silently poison the ledger.
public final class IOReportSampler {

    public struct Rail {
        public let group: String
        public let subgroup: String?
        public let channel: String
        public let watts: Double
    }

    public struct Reading {
        public let rails: [Rail]
        public let interval: TimeInterval
        /// Sum of every live energy rail. On M5 this is effectively GPU alone.
        public var total_W: Double { rails.reduce(0) { $0 + $1.watts } }
        public func watts(_ channel: String) -> Double? {
            rails.first { $0.channel == channel }?.watts
        }
        public var gpu_W: Double? {
            watts("GPU Energy") ?? watts("GPU0") ?? watts("GPU")
        }
    }

    // ── dlopen'd symbols ────────────────────────────────────────────────────
    private typealias FnCopyAll = @convention(c)
        (UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias FnSubscribe = @convention(c)
        (UnsafeRawPointer?, CFMutableDictionary,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?)
        -> UnsafeMutableRawPointer?
    private typealias FnSamples = @convention(c)
        (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias FnDelta = @convention(c)
        (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias FnInt = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias FnStr = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private let copyAll: FnCopyAll
    private let subscribe: FnSubscribe
    private let samples: FnSamples
    private let delta: FnDelta
    private let intValue: FnInt
    private let chanName: FnStr
    private let chanGroup: FnStr
    private let chanSub: FnStr
    private let chanUnit: FnStr

    private var subscription: UnsafeMutableRawPointer
    private var subscribed: CFMutableDictionary
    private var previous: CFDictionary?
    private var previousAt: Date?

    /// nil if IOReport is unavailable or its ABI moved — callers degrade to a
    /// named "unavailable" bucket rather than crashing.
    public init?() {
        // NOTE: the file does NOT exist on disk (FileManager.fileExists is false);
        // it resolves only from the dyld shared cache. Probe with dlopen.
        // It is Apple-signed, so this needs no disable-library-validation entitlement.
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }

        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        // Every symbol resolved individually: a partial ABI is a degrade, not a crash.
        guard let a = sym("IOReportCopyAllChannels", FnCopyAll.self),
              let b = sym("IOReportCreateSubscription", FnSubscribe.self),
              let c = sym("IOReportCreateSamples", FnSamples.self),
              let d = sym("IOReportCreateSamplesDelta", FnDelta.self),
              let e = sym("IOReportSimpleGetIntegerValue", FnInt.self),
              let f = sym("IOReportChannelGetChannelName", FnStr.self),
              let g = sym("IOReportChannelGetGroup", FnStr.self),
              let i = sym("IOReportChannelGetSubGroup", FnStr.self),
              let j = sym("IOReportChannelGetUnitLabel", FnStr.self)
        else { return nil }

        copyAll = a; subscribe = b; samples = c; delta = d; intValue = e
        chanName = f; chanGroup = g; chanSub = i; chanUnit = j

        guard let all = copyAll(0, 0)?.takeRetainedValue() else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, all, &subbed, 0, nil),
              let sc = subbed?.takeRetainedValue() else { return nil }
        subscription = sub
        subscribed = sc
        previous = samples(sub, sc, nil)?.takeRetainedValue()
        previousAt = Date()
    }

    /// Energy unit label -> joules. Read per channel, never assumed.
    private static let multiplier: [String: Double] = [
        "J": 1, "mJ": 1e-3, "uJ": 1e-6, "µJ": 1e-6, "nJ": 1e-9, "pJ": 1e-12,
    ]

    /// nil on the first call — no interval to difference against yet.
    public func sample() -> Reading? {
        guard let prev = previous, let prevAt = previousAt,
              let now = samples(subscription, subscribed, nil)?.takeRetainedValue()
        else { return nil }

        let dt = Date().timeIntervalSince(prevAt)
        defer { previous = now; previousAt = Date() }
        guard dt > 0.05, let d = delta(prev, now, nil)?.takeRetainedValue() else { return nil }

        let key = "IOReportChannels" as CFString
        guard let arrRaw = CFDictionaryGetValue(d, unsafeBitCast(key, to: UnsafeRawPointer.self))
        else { return nil }
        let arr = unsafeBitCast(arrRaw, to: CFArray.self)

        var rails: [Rail] = []
        for idx in 0..<CFArrayGetCount(arr) {
            guard let raw = CFArrayGetValueAtIndex(arr, idx) else { continue }
            let ch = unsafeBitCast(raw, to: CFDictionary.self)

            guard let unit = chanUnit(ch)?.takeUnretainedValue() as String?,
                  let mult = Self.multiplier[unit.trimmingCharacters(in: .whitespaces)]
            else { continue }

            let raw_v = intValue(ch, 0)
            guard raw_v > 0 else { continue }  // dead rails and idle rails both drop out

            rails.append(Rail(
                group: (chanGroup(ch)?.takeUnretainedValue() as String?) ?? "?",
                subgroup: chanSub(ch)?.takeUnretainedValue() as String?,
                channel: (chanName(ch)?.takeUnretainedValue() as String?) ?? "?",
                watts: Double(raw_v) * mult / dt))
        }
        return Reading(rails: rails.sorted { $0.watts > $1.watts }, interval: dt)
    }
}
