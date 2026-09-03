import Foundation
import IOKit

// Identity and memory-pressure facts for `anode --ssd`.
//
// The health page itself is PowerKit's (`NVMeHealth`). This file holds the two
// things that page does NOT carry and that the section still needs in order to
// be readable: which drive it is, and what the memory system is costing it.
// Both are diagnostics — neither has a menu bar or window surface, which is why
// they live in the CLI target rather than in PowerKit.

/// Who the drive is, read from IORegistry.
///
/// Every field is optional because every field is a READ. A machine that does
/// not publish one gets no row, not a placeholder — the same rule the health
/// page itself follows when no SMART user client exists.
struct SSDIdentity {
    var model: String?
    var firmware: String?
    /// NAND package vendor, e.g. "Hynix". Space-padded in the registry.
    var nandVendor: String?
    /// e.g. "tlc_3d_v9_4p_1024". Also space-padded.
    var nandMarketingName: String?
    /// Bits per cell: 1 SLC, 2 MLC, 3 TLC, 4 QLC.
    var cellType: Int?
    /// The LBA capacity the drive actually EXPOSES — IOMedia "Size" on the whole
    /// disk, which is what `diskutil info` reports as Size. This is the correct
    /// denominator for over-provisioning.
    var exposedCapacityBytes: UInt64?
    /// The controller's own `capacity` key, kept deliberately separate. It reads
    /// 1,024,000,000,000 on a drive that exposes 1,000,555,581,440 — a 2.3 %
    /// difference that puts over-provisioning at 19.5 % instead of 22.3 %. That
    /// error was made and caught here; see ARCHITECTURE.md, "SSD health".
    var controllerCapacityKey: UInt64?

    /// "Hynix 3D TLC" — three read fields joined. Nothing is inferred, and a
    /// missing field just drops out of the string.
    var nandDescription: String? {
        var parts: [String] = []
        if let v = nandVendor?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
            parts.append(v)
        }
        if nandMarketingName?.lowercased().contains("3d") == true { parts.append("3D") }
        if let c = cellType, let cell = [1: "SLC", 2: "MLC", 3: "TLC", 4: "QLC"][c] {
            parts.append(cell)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func read() -> SSDIdentity {
        var out = SSDIdentity()
        // Match IOBlockStorageDevice, not the concrete driver class.
        // AppleANS3CGv2Controller is this machine's silicon and naming it would
        // make the section blank on every other Mac. Matching the superclass
        // also means IOEmbeddedNVMeBlockDevice and IONVMeBlockStorageDevice are
        // both covered without naming either — and, as NVMeHealth records, those
        // two names are ONE device anyway, since the first is a subclass of the
        // second. Nothing here needs deduplicating only because the first
        // matching node with an NVMe parent wins and the loop returns.
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDevice"),
                                           &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }

        while case let dev = IOIteratorNext(it), dev != 0 {
            defer { IOObjectRelease(dev) }
            // The built-in SD card reader is an IOBlockStorageDevice too
            // (AppleSDXCBlockStorageDevice). The discriminator is the parent:
            // only an NVMe controller publishes "Controller Characteristics".
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(dev, kIOServicePlane, &parent)
                    == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            guard let cc = prop(parent, "Controller Characteristics") as? [String: Any]
            else { continue }

            let dc = prop(dev, "Device Characteristics") as? [String: Any] ?? [:]
            out.model = (dc["Product Name"] as? String)
                ?? (cc["Model Number"] as? String)
                ?? (prop(parent, "Model Number") as? String)
            out.firmware = (dc["Product Revision Level"] as? String)
                ?? (cc["firmware-version"] as? String)
            out.nandVendor = cc["vendor-name"] as? String
            out.nandMarketingName = cc["nand-marketing-name"] as? String
            out.cellType = (cc["cell-type"] as? NSNumber)?.intValue
                ?? (cc["default-bits-per-cell"] as? NSNumber)?.intValue
            out.controllerCapacityKey = (cc["capacity"] as? NSNumber)?.uint64Value
            out.exposedCapacityBytes = exposedCapacity(of: dev)
            return out
        }
        return out
    }

    /// The whole-disk IOMedia is the block device's DIRECT child. Searching
    /// recursively for "Size" would find whichever partition the iterator
    /// reached first; asking the direct child for `Whole == true` names exactly
    /// the node meant, on any partition layout.
    private static func exposedCapacity(of dev: io_object_t) -> UInt64? {
        var kids: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(dev, kIOServicePlane, &kids)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(kids) }
        while case let media = IOIteratorNext(kids), media != 0 {
            defer { IOObjectRelease(media) }
            guard prop(media, "Whole") as? Bool == true,
                  let size = prop(media, "Size") as? NSNumber else { continue }
            return size.uint64Value
        }
        return nil
    }

    private static func prop(_ obj: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(obj, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}

/// What the memory system costs the drive.
///
/// The swap-shaped question — "how much is swapped out?" — has a boring answer
/// on a healthy Mac, and a display built around it is a column of zeros that
/// looks like a broken instrument. Measured on this machine the compressor has
/// moved about 97,000x the bytes swap has. Both are read here in one
/// `host_statistics64` call; the caller prints the compressor first.
struct SwapFacts {
    let pageSize: UInt64
    let compressions: UInt64
    let decompressions: UInt64
    let swapins: UInt64
    let swapouts: UInt64
    /// Pages the compressor holds, AFTER compression.
    let compressorPages: UInt64
    /// The anonymous pages those represent, BEFORE compression.
    let uncompressedPagesHeld: UInt64
    /// Compressor-stored pages that really are sitting in swap right now.
    let pagesInSwap: UInt64
    /// `vm.swapusage`'s total field. Printed as a pre-formatted string on
    /// purpose: it is a RESERVATION, and rendering it through the same byte
    /// formatter as everything else would make it look like an allocation.
    let swapusageTotal: String?
    /// Files in /private/var/vm named `swapfile*`. On this machine there are
    /// none — the directory holds only a sleepimage.
    let swapFiles: [String]
    let sleepImageBytes: UInt64?
    let hibernateMode: Int?

    var compressedBytes: UInt64 { compressions &* pageSize }
    var decompressedBytes: UInt64 { decompressions &* pageSize }
    var poolBytes: UInt64 { compressorPages &* pageSize }
    var heldAnonBytes: UInt64 { uncompressedPagesHeld &* pageSize }
    var swappedOutBytes: UInt64 { swapouts &* pageSize }

    /// Live, and never cached as a constant: it is a property of what is in
    /// memory right now, not of the compressor.
    var compressionRatio: Double? {
        poolBytes == 0 ? nil : Double(heldAnonBytes) / Double(poolBytes)
    }
    /// nil when swap has moved nothing at all, which is the common case and is
    /// the point — a ratio against zero would be the confident wrong number.
    var compressorToSwapRatio: Double? {
        swappedOutBytes == 0 ? nil : Double(compressedBytes) / Double(swappedOutBytes)
    }

    static func read() -> SwapFacts? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        var st = vm_statistics64_data_t()
        let rc = withUnsafeMutablePointer(to: &st) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }

        // /private/var/vm is world-listable, so this needs no privilege. A
        // swapfile is named "swapfile0", "swapfile1", …; anything else in there
        // (the sleepimage) is not swap and must not be counted as if it were.
        let vm = "/private/var/vm"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: vm)) ?? []
        func bytes(_ name: String) -> UInt64? {
            // `try?` on a throwing call that returns a non-optional already yields
            // an Optional, so the subscript needs the value unwrapped first rather
            // than a second `?` — which the compiler rejects as having no effect.
            guard let attrs = try? FileManager.default
                    .attributesOfItem(atPath: vm + "/" + name) else { return nil }
            return (attrs[.size] as? NSNumber)?.uint64Value
        }

        return SwapFacts(
            pageSize: UInt64(vm_kernel_page_size),
            compressions: st.compressions,
            decompressions: st.decompressions,
            swapins: st.swapins,
            swapouts: st.swapouts,
            compressorPages: UInt64(st.compressor_page_count),
            uncompressedPagesHeld: st.total_uncompressed_pages_in_compressor,
            pagesInSwap: st.swapped_count,
            swapusageTotal: swapusageTotalField(),
            swapFiles: entries.filter { $0.hasPrefix("swapfile") }.sorted(),
            sleepImageBytes: entries.contains("sleepimage") ? bytes("sleepimage") : nil,
            hibernateMode: hibernateMode())
    }

    /// `vm.swapusage` is an `xsw_usage` struct. Only its total is quoted, and
    /// only ever as the reservation it is, so it is formatted here in the same
    /// MiB shape `sysctl` itself prints — which is the form somebody comparing
    /// this output against a terminal will be holding.
    private static func swapusageTotalField() -> String? {
        var u = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &u, &len, nil, 0) == 0 else { return nil }
        return String(format: "%.2fM", Double(u.xsu_total) / 1_048_576)
    }

    /// Explains the sleepimage rather than being load-bearing, so a failure to
    /// read it drops the clause instead of failing the section.
    private static func hibernateMode() -> Int? {
        let pm = Process()
        pm.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pm.arguments = ["-g"]
        let pipe = Pipe(); pm.standardOutput = pipe; pm.standardError = Pipe()
        guard (try? pm.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        pm.waitUntilExit()
        return out.split(separator: "\n")
            .first { $0.contains("hibernatemode") }
            .flatMap { Int($0.split(separator: " ").last ?? "") }
    }
}
