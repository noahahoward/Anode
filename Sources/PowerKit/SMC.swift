import Foundation
import IOKit

/// Apple System Management Controller reader.
///
/// Why this exists: IOReport's `Energy Model` group is almost entirely DEAD on M5
/// (1 live channel of 314 — GPU only), so display, DRAM, ANE and radio power have
/// no IOReport path on this hardware. The SMC exposes real power sensors in WATTS
/// and needs no root — Stats reads them unprivileged, which is where its menu bar
/// "Sensor 6W" figure comes from.
///
/// IMPLEMENTATION NOTE — the struct is built as an explicit 80-byte buffer rather
/// than a Swift struct. Swift does not guarantee C-compatible layout for nested
/// structs: the obvious translation of `SMCKeyData_t` lays out as 76 bytes here,
/// and IOConnectCallStructMethod rejects it with kIOReturnBadArgument (0xe00002c2).
/// Explicit offsets are both correct and self-documenting.
///
/// The layout is the long-standing community-reverse-engineered one. It is not API
/// and can change; every read is failure-tolerant.
public final class SMC {

    // ── Wire format: 80 bytes, explicit offsets ─────────────────────────────
    private enum Off {
        static let key         = 0    // UInt32, FourCC in native order
        static let versMajor   = 4
        static let pLimitVer   = 12
        static let dataSize    = 28   // keyInfo.dataSize   UInt32
        static let dataType    = 32   // keyInfo.dataType   UInt32
        static let dataAttrs   = 36   // UInt8
        static let result      = 40
        static let status      = 41
        static let data8       = 42
        static let data32      = 44   // UInt32
        static let bytes       = 48   // 32 bytes
        static let total       = 80
    }

    private enum Cmd: UInt8 { case readBytes = 5, writeBytes = 6, readKeyInfo = 9, readIndex = 8 }

    private var conn: io_connect_t = 0
    public private(set) var lastError: kern_return_t = 0

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        // Unprivileged: opening the SMC user client for READS needs no root.
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // ── Buffer helpers (arm64 is little-endian; these are native-order fields) ──
    private static func setU32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off]     = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
        b[off + 2] = UInt8((v >> 16) & 0xFF)
        b[off + 3] = UInt8((v >> 24) & 0xFF)
    }
    private static func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8
            | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: Off.total)
        var outSize = Off.total
        let rc = input.withUnsafeBytes { inPtr -> kern_return_t in
            out.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, 2,
                                          inPtr.baseAddress!, Off.total,
                                          outPtr.baseAddress!, &outSize)
            }
        }
        lastError = rc
        return rc == kIOReturnSuccess ? out : nil
    }

    private static func code(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for ch in s.utf8.prefix(4) { v = (v << 8) | UInt32(ch) }
        return v
    }

    private static func string(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                 UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: b, encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
    }

    public struct Sensor {
        public let key: String
        public let type: String
        public let value: Double
    }

    public func keyCount() -> Int {
        guard let (bytes, _) = readRaw(Self.code("#KEY")), bytes.count >= 4 else { return 0 }
        return Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                   | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    public func key(at index: Int) -> String? {
        var i = [UInt8](repeating: 0, count: Off.total)
        i[Off.data8] = Cmd.readIndex.rawValue
        Self.setU32(&i, Off.data32, UInt32(index))
        guard let o = call(i) else { return nil }
        return Self.string(Self.u32(o, Off.key).bigEndian.byteSwapped)
    }

    private func readRaw(_ keyCode: UInt32) -> ([UInt8], String)? {
        var i = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&i, Off.key, keyCode)
        i[Off.data8] = Cmd.readKeyInfo.rawValue
        guard let info = call(i) else { return nil }

        let size = Int(Self.u32(info, Off.dataSize))
        let type = Self.string(Self.u32(info, Off.dataType))
        guard size > 0, size <= 32 else { return nil }

        var r = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&r, Off.key, keyCode)
        Self.setU32(&r, Off.dataSize, UInt32(size))
        r[Off.data8] = Cmd.readBytes.rawValue
        guard let out = call(r) else { return nil }

        return (Array(out[Off.bytes..<(Off.bytes + size)]), type)
    }

    /// Does this key EXIST, whatever its type?
    ///
    /// A strictly smaller question than `read`, which answers "is there a value I
    /// can decode". The decoder below handles nine numeric types and returns nil for
    /// everything else, so on Intel — where `F<n>Ac` is `fpe2` — a machine with two
    /// fans reads as having none. Key info carries the SMC's own declared size and
    /// type and needs no decoder at all, which makes this the honest test for
    /// "is this hardware present".
    ///
    /// MEASURED on `Mac17,9`: a key that does not exist still returns
    /// `kIOReturnSuccess`, with `dataSize` 0 and an empty type — `F0Ac`/`F1Ac` come
    /// back size 4 type `flt` while `F2Ac`..`F9Ac` come back size 0. **The size is
    /// the existence test; the return code is not.**
    public func exists(_ key: String) -> Bool {
        var i = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&i, Off.key, Self.code(key))
        i[Off.data8] = Cmd.readKeyInfo.rawValue
        guard let o = call(i) else { return false }
        return Self.u32(o, Off.dataSize) > 0
    }

    /// Decodes the SMC numeric types we care about. `flt` is the one that matters on
    /// Apple Silicon — power sensors report IEEE-754 watts directly.
    public func read(_ key: String) -> Sensor? {
        guard let (bytes, type) = readRaw(Self.code(key)) else { return nil }

        let value: Double
        switch type {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            var v: UInt32 = 0
            for (n, b) in bytes.prefix(4).enumerated() { v |= UInt32(b) << (8 * n) }
            value = Double(Float(bitPattern: v))
        case "ui8", "ui16", "ui32", "ui64":
            var v: UInt64 = 0
            for b in bytes { v = (v << 8) | UInt64(b) }   // big-endian
            value = Double(v)
        case "si8":
            guard let b = bytes.first else { return nil }
            value = Double(Int8(bitPattern: b))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "sp78":            // signed fixed point, 7 integer bits / 8 fractional
            guard bytes.count >= 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256.0
        default:
            return nil
        }
        return Sensor(key: key, type: type, value: value)
    }

    /// Every key the SMC exposes, decoded. The key set is model-specific, so rails
    /// are discovered rather than hardcoded.
    // ── Writes ──────────────────────────────────────────────────────────────

    /// Write a float key. The ONLY write in this file, and it needs root.
    ///
    /// Kept deliberately narrow: it takes a key and a Double, refuses anything
    /// whose declared type is not a 4-byte float, and does no policy of its own.
    /// Deciding WHETHER a value is safe belongs to FanPolicy, and deciding
    /// whether the user asked for it belongs above that again. This function's
    /// only job is to be a correct write.
    ///
    /// Returns false rather than throwing on permission failure, because running
    /// unprivileged is the normal case for the main app — only the helper ever
    /// expects this to succeed.
    @discardableResult
    public func writeFloat(_ key: String, _ value: Double) -> Bool {
        guard value.isFinite else { return false }

        // Read the key's metadata first. Writing a 4-byte float into a key the
        // SMC thinks is 2-byte, or that does not exist, is how you corrupt
        // adjacent state rather than get a clean error.
        var info = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&info, Off.key, Self.code(key))
        info[Off.data8] = Cmd.readKeyInfo.rawValue
        guard let meta = call(info) else { return false }
        let size = Self.u32(meta, Off.dataSize)
        let type = Self.string(Self.u32(meta, Off.dataType))
        guard size == 4, type == "flt" else { return false }

        var buf = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&buf, Off.key, Self.code(key))
        Self.setU32(&buf, Off.dataSize, 4)
        Self.setU32(&buf, Off.dataType, Self.code("flt"))
        buf[Off.data8] = Cmd.writeBytes.rawValue
        let f = Float(value)
        withUnsafeBytes(of: f.bitPattern.littleEndian) { raw in
            for i in 0..<4 { buf[Off.bytes + i] = raw[i] }
        }
        return call(buf) != nil
    }

    /// Write a one-byte key, with the same discipline as `writeFloat`: verify the
    /// SMC's own declared type and size first, refuse anything else, and do no
    /// policy.
    ///
    /// This exists for the fan MODE key, `F<n>md`, which is `ui8` where every
    /// other fan key is `flt`. Writing a target while the mode says automatic is
    /// ignored by the firmware, so without this fan control silently does
    /// nothing — see `FanHardware.readMode`.
    ///
    /// Separate from `writeFloat` rather than a widened version of it, because
    /// the size/type guard is the entire safety of both: a function that accepts
    /// "4-byte float or 1-byte int" has to pick the encoding at runtime, and
    /// picking wrong is how you write a float's bit pattern into a byte and take
    /// three neighbouring keys with it.
    @discardableResult
    public func writeUInt8(_ key: String, _ value: UInt8) -> Bool {
        var info = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&info, Off.key, Self.code(key))
        info[Off.data8] = Cmd.readKeyInfo.rawValue
        guard let meta = call(info) else { return false }
        let size = Self.u32(meta, Off.dataSize)
        let type = Self.string(Self.u32(meta, Off.dataType))
        guard size == 1, type == "ui8" else { return false }

        var buf = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&buf, Off.key, Self.code(key))
        Self.setU32(&buf, Off.dataSize, 1)
        Self.setU32(&buf, Off.dataType, Self.code("ui8"))
        buf[Off.data8] = Cmd.writeBytes.rawValue
        buf[Off.bytes] = value
        return call(buf) != nil
    }

    public func scan() -> [Sensor] {
        var out: [Sensor] = []
        for idx in 0..<keyCount() {
            guard let k = key(at: idx), !k.isEmpty else { continue }
            if let s = read(k) { out.append(s) }
        }
        return out
    }

    public func diagnose() -> String {
        var i = [UInt8](repeating: 0, count: Off.total)
        Self.setU32(&i, Off.key, Self.code("#KEY"))
        i[Off.data8] = Cmd.readKeyInfo.rawValue
        let o = call(i)
        return String(format: "buffer=%d bytes  conn=%u  #KEY ok=%@ rc=0x%08x",
                      Off.total, conn, o != nil ? "yes" : "no",
                      UInt32(bitPattern: lastError))
    }
}
