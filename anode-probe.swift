// Anode field probe. Run on the machine that misbehaves:
//     swift anode-probe.swift
// Prints exactly what the two suspect code paths read. No writes, no root.

import Foundation
import IOKit

// ── Machine ─────────────────────────────────────────────────────────────────
func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}
print("== machine ==")
print("model      : \(sysctlString("hw.model"))")
print("cpu        : \(sysctlString("machdep.cpu.brand_string"))")
print("os         : \(ProcessInfo.processInfo.operatingSystemVersionString)")

// ── Battery: exactly what Battery.state()/scale() read ──────────────────────
print("\n== battery (AppleSmartBattery) ==")
func batteryProps() -> [String: Any]? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                          IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var un: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &un, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = un?.takeRetainedValue() as? [String: Any] else { return nil }
    return d
}

if let props = batteryProps() {
    let data = props["BatteryData"] as? [String: Any] ?? [:]
    print("BatteryData present : \(props["BatteryData"] != nil)")
    print("BatteryData keys    : \(data.keys.sorted().joined(separator: ", "))")

    func num(_ k: String, _ src: [String: Any]) -> String {
        (src[k] as? NSNumber).map { "\($0)" } ?? "ABSENT"
    }
    // THE field Battery.State.remainingCapacity_mAh reads, with no fallback.
    print("\n-- the one the drain estimator depends on --")
    print("BatteryData.RemainingCapacity : \(num("RemainingCapacity", data))")
    print("top.RemainingCapacity         : \(num("RemainingCapacity", props))")
    print("top.AppleRawCurrentCapacity   : \(num("AppleRawCurrentCapacity", props))")
    print("BatteryData.AbsoluteCapacity  : \(num("AbsoluteCapacity", data))")
    print("BatteryData.TrueRemainingCapacity : \(num("TrueRemainingCapacity", data))")

    print("\n-- scale() --")
    for k in ["DesignCapacity", "FullChargeCapacity", "NominalChargeCapacity",
              "AppleRawMaxCapacity"] {
        print("  \(k.padding(toLength: 24, withPad: " ", startingAt: 0)) data=\(num(k, data))  top=\(num(k, props))")
    }
    print("\n-- state() --")
    for k in ["CurrentCapacity", "IsCharging", "ExternalConnected", "Voltage",
              "InstantAmperage", "Amperage", "TimeRemaining", "FullyCharged"] {
        let v = props[k]
        print("  \(k.padding(toLength: 24, withPad: " ", startingAt: 0)) \(v.map { "\($0)" } ?? "ABSENT")")
    }

    print("\n-- PowerTelemetryData (the discharge trend's source) --")
    if let t = props["PowerTelemetryData"] as? [String: Any] {
        print("  keys: \(t.keys.sorted().joined(separator: ", "))")
        for k in ["SystemPower", "SystemEnergyConsumed", "AdapterEnergyConsumed",
                  "BatteryPower", "AccumulatedSystemPower", "AccumulatedSystemEnergyConsumed"] {
            if let v = t[k] { print("  \(k) = \(v)") }
        }
    } else {
        print("  ABSENT")
    }
} else {
    print("no AppleSmartBattery service")
}

// ── SMC: exactly what FanPresence.detect() reads ────────────────────────────
print("\n== SMC / fans ==")

final class MiniSMC {
    private enum Off { static let key = 0, dataSize = 28, dataType = 32,
                              data8 = 42, data32 = 44, bytes = 48, total = 80 }
    private var conn: io_connect_t = 0
    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func setU32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v & 0xFF); b[o+1] = UInt8((v >> 8) & 0xFF)
        b[o+2] = UInt8((v >> 16) & 0xFF); b[o+3] = UInt8((v >> 24) & 0xFF)
    }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24
    }
    private static func code(_ s: String) -> UInt32 {
        var v: UInt32 = 0; for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }; return v
    }
    private static func str(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                 UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: b, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
    }
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: Off.total); var n = Off.total
        let rc = input.withUnsafeBytes { i in out.withUnsafeMutableBytes { o in
            IOConnectCallStructMethod(conn, 2, i.baseAddress!, Off.total, o.baseAddress!, &n) } }
        return rc == kIOReturnSuccess ? out : nil
    }
    /// Does the key EXIST, and what does the SMC say it is? (readKeyInfo only —
    /// this is the question the decoder cannot answer for types it skips.)
    ///
    /// MEASURED: a key that does not exist still returns kIOReturnSuccess, with
    /// dataSize 0 and an empty type. Size is the existence test, not the rc.
    func info(_ key: String) -> (size: Int, type: String)? {
        var i = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&i, Off.key, Self.code(key))
        i[Off.data8] = 9
        guard let o = call(i) else { return nil }
        let size = Int(Self.u32(o, Off.dataSize))
        guard size > 0 else { return nil }
        return (size, Self.str(Self.u32(o, Off.dataType)))
    }
    func keyCount() -> Int {
        guard let (b, _) = raw(Self.code("#KEY")), b.count >= 4 else { return 0 }
        return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }
    func key(at idx: Int) -> String? {
        var i = [UInt8](repeating: 0, count: Off.total)
        i[Off.data8] = 8
        Self.setU32(&i, Off.data32, UInt32(idx))
        guard let o = call(i) else { return nil }
        return Self.str(Self.u32(o, Off.key).bigEndian.byteSwapped)
    }
    private func raw(_ kc: UInt32) -> ([UInt8], String)? {
        var i = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&i, Off.key, kc); i[Off.data8] = 9
        guard let inf = call(i) else { return nil }
        let size = Int(Self.u32(inf, Off.dataSize)), type = Self.str(Self.u32(inf, Off.dataType))
        guard size > 0, size <= 32 else { return nil }
        var r = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&r, Off.key, kc); Self.setU32(&r, Off.dataSize, UInt32(size)); r[Off.data8] = 5
        guard let o = call(r) else { return nil }
        return (Array(o[Off.bytes..<(Off.bytes + size)]), type)
    }
    /// The app's decoder, verbatim in behaviour: nil for types it does not handle.
    func read(_ key: String) -> (type: String, value: Double)? {
        guard let (b, t) = raw(Self.code(key)) else { return nil }
        let v: Double
        switch t {
        case "flt":
            guard b.count >= 4 else { return nil }
            var u: UInt32 = 0; for (n, x) in b.prefix(4).enumerated() { u |= UInt32(x) << (8 * n) }
            v = Double(Float(bitPattern: u))
        case "ui8", "ui16", "ui32", "ui64":
            var u: UInt64 = 0; for x in b { u = (u << 8) | UInt64(x) }; v = Double(u)
        case "si8":  guard let x = b.first else { return nil }; v = Double(Int8(bitPattern: x))
        case "si16": guard b.count >= 2 else { return nil }
                     v = Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        case "sp78": guard b.count >= 2 else { return nil }
                     v = Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "fp88": guard b.count >= 2 else { return nil }
                     v = Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0
        default: return nil
        }
        return (t, v)
    }
}

if let smc = MiniSMC() {
    print("SMC opened  : yes")
    print("#KEY count  : \(smc.keyCount())")

    // What FanPresence.detect() sees.
    let fnumInfo = smc.info("FNum")
    let fnumRead = smc.read("FNum")
    print("FNum exists : \(fnumInfo.map { "yes (size=\($0.size) type=\($0.type))" } ?? "NO")")
    print("FNum decodes: \(fnumRead.map { "\($0.value) (\($0.type))" } ?? "NO — decoder skipped this type")")

    var respondingDecoded = 0, existingKeys = 0
    for i in 0..<10 {
        let k = "F\(i)Ac"
        let e = smc.info(k)
        let r = smc.read(k)
        if e != nil { existingKeys += 1 }
        if r != nil { respondingDecoded += 1 }
        if e != nil || r != nil {
            print("  \(k): exists=\(e.map { "size=\($0.size) type=\($0.type)" } ?? "no")  decoded=\(r.map { "\($0.value)" } ?? "no")")
        }
    }
    print("F<n>Ac keys existing : \(existingKeys)")
    print("F<n>Ac keys decoding : \(respondingDecoded)   <- respondingFans in FanPresence.decide")

    // Every F* key the SMC actually publishes. This is the ground truth for
    // "does this machine have fan hardware at all".
    let n = smc.keyCount()
    var fKeys: [String] = []
    if n > 0 {
        for i in 0..<n {
            guard let k = smc.key(at: i), k.hasPrefix("F") else { continue }
            fKeys.append(k + (smc.info(k).map { "(\($0.type))" } ?? ""))
        }
    }
    print("all F* keys (\(fKeys.count)): \(fKeys.isEmpty ? "NONE" : fKeys.joined(separator: " "))")

    // The whole-system power rail the drain estimator falls back on.
    print("PSTR        : \(smc.read("PSTR").map { "\($0.value) W (\($0.type))" } ?? "ABSENT")")

    // ── Verdict ─────────────────────────────────────────────────────────────
    print("\n== verdict ==")
    let fanState: String
    if let v = fnumRead?.value, v >= 0, v <= 10, v == v.rounded() {
        fanState = v > 0 ? "fans(\(Int(v)))" : (respondingDecoded > 0 ? "fans(\(respondingDecoded))" : "fanless")
    } else {
        fanState = respondingDecoded > 0 ? "fans(\(respondingDecoded))" : "unknown"
    }
    print("FanPresence.detect() would return : .\(fanState)")
    print("  -> Fans tab \(fanState == "fanless" ? "HIDDEN" : "SHOWN")")
    print("  hardware really has fans? \(fKeys.isEmpty ? "NO F* keys at all — fanless" : "\(fKeys.count) F* keys published")")

    if let props = batteryProps() {
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        let rc = (data["RemainingCapacity"] as? NSNumber)?.doubleValue ?? 0
        print("Battery.State.remainingCapacity_mAh = \(rc)")
        print("  -> DrainRateEstimator \(rc > 0 ? "records samples normally" : "DROPS EVERY SAMPLE (guard mAh > 0) -> estimate() == nil -> UI stuck on \"measuring…\"")")
    }
} else {
    print("SMC opened  : NO — IOServiceOpen(AppleSMC) failed")
}
