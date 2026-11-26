import AppKit
import PowerKit

// ── Hardware View: memory, storage, Wi-Fi, power in and the battery cells ───
//
// Transcribed from the approved mockup (docs/superpowers/hardware-view-assets/mockup-source.html): `DRAW.pmem`, `DRAW.pssd`,
// `DRAW.pwifi`, `DRAW.padapter` (the photograph's plates), `DRAW.memory`, `DRAW.ssd`, `DRAW.wifi`, `DRAW.adapter` (the drawn
// layouts), `DRAW.battery` with its `ROLE.*` readings, `PRESSURE`, `rate()` and `spark()`.
//
// Everything is drawn in layout units (`HardwareCanvasView.draw` has already moved and scaled the context). Nothing here owns a
// timer, a thread or an observer. A missing reading shows "—", never a zero; a value Anode estimated carries a "≈" before its
// number. A part with no reading at all is drawn as its outline only (memory, storage) or as a plate with "—" (Wi-Fi, power in);
// a Mac with no battery reading draws no battery.

/// The colours that belong to this file alone (the shared ones are in `HardwareStyle`).
private enum ReadoutStyle {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

    // Memory composition bar (the mockup's segs) and the kernel's pressure colours (--pg, --py, --pr).
    static let memoryApp = rgb(0x4C8DFF)
    static let memoryWired = rgb(0x8A7CF0)
    static let memoryCompressed = rgb(0xE0A24C)
    static let memoryFree = rgb(0x3B4656)
    static let pressureNormal = rgb(0x30D158)
    static let pressureWarning = rgb(0xFFD60A)
    static let pressureCritical = rgb(0xFF453A)
    static let dieFill = rgb(0x0D1218)

    // Storage
    static let nandFill = rgb(0x10161D)
    static let nandStroke = rgb(0x3A4757)
    static let photoNandLabel = rgb(0x6FB7C6)

    // Wi-Fi
    static let wifiFill = rgb(0x12202A)
    static let wifiLabel = rgb(0xCFE6EF)

    // Power in
    static let portFill = rgb(0x06080B)
    static let portStroke = rgb(0x3A4757)

    // Battery cells
    static let cellFill = rgb(0x10151B)
    static let cellStroke = rgb(0x26303C)

    // Shared
    static let track = white(0.08)
    static let gridLine = white(0.07)
    static let separator = white(0.07)
}

/// One styled piece of a line of text; a line is several of them side by side on one baseline (the mockup's `<tspan>`s).
private struct ReadoutRun {
    let text: String
    let font: NSFont
    let color: NSColor
}

extension HardwareCanvasView {

    // MARK: - Pure text and number helpers

    private static let wholeFormatter = makeReadoutFormatter(digits: 0)
    private static let tenthsFormatter = makeReadoutFormatter(digits: 1)
    private static let hundredthsFormatter = makeReadoutFormatter(digits: 2)

    /// A number the way the mockup's `fmt()` writes it: en_US (so the text does not depend on the Mac's locale), thousands
    /// separators, a fixed number of decimals (0, 1 or 2). "—" for a number that is not finite.
    static func readoutNumber(_ n: Double, digits: Int = 1) -> String {
        guard n.isFinite else { return "—" }
        let formatter: NumberFormatter
        switch digits {
        case 0: formatter = wholeFormatter
        case 2: formatter = hundredthsFormatter
        default: formatter = tenthsFormatter
        }
        return formatter.string(from: NSNumber(value: n)) ?? String(format: "%.\(digits)f", n)
    }

    /// The mockup's `rate()`: bytes per second as KB/s, MB/s or GB/s (decimal units, as network speeds are quoted); "—" for none.
    static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytes = bytesPerSecond, bytes.isFinite else { return "—" }
        let v = max(bytes, 0)
        if v >= 1e9 { return readoutNumber(v / 1e9, digits: 2) + " GB/s" }
        if v >= 1e6 { return readoutNumber(v / 1e6, digits: 1) + " MB/s" }
        return readoutNumber(v / 1e3, digits: 1) + " KB/s"
    }

    /// The "≈ " a number carries when Anode worked it out rather than read it. An example value is a stand-in and the live view
    /// never produces one, so it is written plainly.
    static func estimatePrefix(_ provenance: Provenance) -> String {
        provenance == .estimate ? "≈ " : ""
    }

    // Memory

    private static let gibibyte = 1_073_741_824.0

    /// Memory is counted in the units macOS uses for it: a "24 GB" Mac is 24 GiB.
    static func memoryGigabytes(_ bytes: UInt64) -> Double { Double(bytes) / gibibyte }

    /// A memory size for a total ("24"): whole when it is whole, one decimal otherwise.
    static func memoryTotalText(_ bytes: UInt64) -> String {
        let g = memoryGigabytes(bytes)
        return abs(g - g.rounded()) < 0.05 ? readoutNumber(g, digits: 0) : readoutNumber(g, digits: 1)
    }

    /// The total with its unit ("24 GB"), or "—" when the Mac reported no total: never "0 GB".
    static func memoryTotalLabel(_ bytes: UInt64) -> String {
        bytes == 0 ? "—" : memoryTotalText(bytes) + " GB"
    }

    /// Memory in use: app + wired + compressed, in bytes.
    static func memoryUsedBytes(_ m: MemoryReading) -> UInt64 { m.app &+ m.wired &+ m.compressed }

    /// "21.8": memory in use, in GB with one decimal.
    static func memoryUsedText(_ m: MemoryReading) -> String {
        readoutNumber(memoryGigabytes(memoryUsedBytes(m)), digits: 1)
    }

    /// The kernel's word for its pressure level (1 normal, 2 warning, 4 critical); "—" when it did not answer.
    static func memoryPressureName(_ level: Int32?) -> String {
        switch level {
        case 1?: return "Normal"
        case 2?: return "Warning"
        case 4?: return "Critical"
        default: return "—"
        }
    }

    /// Green, yellow or red for the kernel's level; neutral grey when it did not answer.
    static func memoryPressureColor(_ level: Int32?) -> NSColor {
        switch level {
        case 1?: return ReadoutStyle.pressureNormal
        case 2?: return ReadoutStyle.pressureWarning
        case 4?: return ReadoutStyle.pressureCritical
        default: return HardwareStyle.faint
        }
    }

    /// The composition bar's four segments in drawing order: App, Wired, Compressed, Free.
    static func memorySegments(_ m: MemoryReading) -> [(name: String, bytes: UInt64, color: NSColor)] {
        [("App", m.app, ReadoutStyle.memoryApp),
         ("Wired", m.wired, ReadoutStyle.memoryWired),
         ("Compressed", m.compressed, ReadoutStyle.memoryCompressed),
         ("Free", m.free, ReadoutStyle.memoryFree)]
    }

    /// "Swap 8.5 GB", "Swap ≈ 8.5 GB" for an estimate, "Swap —" when it is not known.
    static func swapText(_ swap: Tagged<UInt64>) -> String {
        guard let bytes = swap.value else { return "Swap —" }
        return "Swap " + estimatePrefix(swap.provenance) + readoutNumber(memoryGigabytes(bytes), digits: 1) + " GB"
    }

    // Storage

    /// A disk size in the decimal gigabytes a drive is sold in ("994"); "—" for none.
    static func storageGigabytesText(_ bytes: UInt64?) -> String {
        guard let bytes = bytes else { return "—" }
        return readoutNumber(Double(bytes) / 1e9, digits: 0)
    }

    /// How much of the volume is used, 0...1; nil when free or total space is not known (or the total is nothing).
    static func storageUsedFraction(_ s: StorageReading) -> Double? {
        guard let free = s.freeBytes, let total = s.totalBytes, total > 0 else { return nil }
        return max(0, min(1, 1 - Double(free) / Double(total)))
    }

    // Power in

    /// The power-in plate's reading: the number ("≈ 4.4 W", or "—") and the words after it ("in · not charging"; empty when
    /// there is no adapter reading at all).
    static func powerInReadout(_ adapter: AdapterReading?) -> (value: String, note: String) {
        guard let a = adapter else { return ("—", "") }
        let note = "in · " + (a.isCharging ? "charging" : "not charging")
        guard let watts = a.drawnW.value, watts.isFinite else { return ("—", note) }
        return (estimatePrefix(a.drawnW.provenance) + readoutNumber(watts, digits: 1) + " W", note)
    }

    // Battery

    /// What the pack is doing, in a word short enough for the narrowest state cell (the photograph's, about 160 pt of text room at
    /// 19 pt). The line under it carries the current and the time, so a plugged-in pack that is not charging says only "Plugged in".
    static func batteryStateText(_ state: BatteryChargeState) -> String {
        switch state {
        case .charging: return "Charging"
        case .full: return "Full · holding"
        case .pluggedNotCharging: return "Plugged in"
        case .discharging: return "Discharging"
        }
    }

    /// Text that has to fit a width: the start size if it does, else smaller in 1 pt steps down to 14 pt, else cut with "…" at that
    /// smallest size. The system font at `weight`, measured the way it is drawn.
    static func fittedText(_ text: String, width: CGFloat, startSize: CGFloat, weight: NSFont.Weight,
                           minimumSize: CGFloat = 14) -> (text: String, size: CGFloat) {
        func measure(_ t: String, _ size: CGFloat) -> CGFloat {
            NSAttributedString(string: t, attributes: [.font: Palette.Font.sans(size, weight)]).size().width
        }
        var size = startSize
        while size > minimumSize, measure(text, size) > width { size -= 1 }
        size = max(size, min(minimumSize, startSize))
        if measure(text, size) <= width { return (text, size) }
        var cut = text
        while !cut.isEmpty, measure(cut + "…", size) > width { cut.removeLast() }
        return (cut + "…", size)
    }

    /// The pack current: "+6.1 A", "-250 mA", "0 mA".
    static func batteryCurrentText(_ amps: Double) -> String {
        guard amps.isFinite else { return "—" }
        let milliamps = (amps * 1000).rounded()
        if milliamps == 0 { return "0 mA" }
        let sign = milliamps > 0 ? "+" : "-"
        if abs(amps) >= 1 { return sign + readoutNumber(abs(amps), digits: 1) + " A" }
        return sign + readoutNumber(abs(milliamps), digits: 0) + " mA"
    }

    /// Minutes as hours and minutes ("0:52").
    static func batteryClockText(_ minutes: Int) -> String {
        String(format: "%ld:%02ld", minutes / 60, minutes % 60)
    }

    /// macOS's time estimate: "≈ 0:52 to full" while charging, "≈ 3:20 left" otherwise, "time left —" when it has none.
    static func batteryTimeText(_ b: BatteryReading) -> String {
        guard let minutes = b.timeRemainingMin.value, minutes >= 0 else {
            return b.isCharging ? "time to full —" : "time left —"
        }
        return estimatePrefix(b.timeRemainingMin.provenance) + batteryClockText(minutes) + (b.isCharging ? " to full" : " left")
    }

    /// "95 / 1000 cycles", or stacked under the health on a narrow cell "95 of 1000 cycles". A pack whose rated cycles are
    /// not known says "—" there.
    static func batteryCyclesText(_ b: BatteryReading, stacked: Bool) -> String {
        let design = b.designCycles.map { "\($0)" } ?? "—"
        return "\(b.cycles) " + (stacked ? "of" : "/") + " \(design) cycles"
    }

    // MARK: - Drawing helpers

    private static func numberFont(_ size: CGFloat) -> NSFont { Palette.Font.mono(size, .semibold) }
    private static func sansFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { Palette.Font.sans(size, weight) }

    private static func run(_ text: String, _ font: NSFont, _ color: NSColor) -> ReadoutRun {
        ReadoutRun(text: text, font: font, color: color)
    }

    private static func cgRect(_ r: HWRect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
    }

    /// The mockup's `.lbl`: a small uppercase kerned name (kern is .14em).
    private static func drawLabel(_ text: String, x: CGFloat, baseline: CGFloat, size: CGFloat = 10.5,
                                  color: NSColor = HardwareStyle.dim, align: NSTextAlignment = .left) {
        drawText(text, x: x, baseline: baseline, font: HardwareStyle.label(size), color: color, align: align, kern: size * 0.14)
    }

    /// Several styled pieces on one baseline, side by side (left, right or centre aligned as a whole).
    private static func drawRuns(_ runs: [ReadoutRun], x: CGFloat, baseline: CGFloat, align: NSTextAlignment = .left) {
        let strings = runs.map { r in
            NSAttributedString(string: r.text, attributes: [.font: r.font, .foregroundColor: r.color])
        }
        let widths = strings.map { $0.size().width }
        let total = widths.reduce(0, +)
        var left: CGFloat
        switch align {
        case .center: left = x - total / 2
        case .right: left = x - total
        default: left = x
        }
        for (i, s) in strings.enumerated() {
            s.draw(at: NSPoint(x: left, y: baseline - runs[i].font.ascender))
            left += widths[i]
        }
    }

    private static func fillRoundedRect(in ctx: CGContext, rect: CGRect, radius: CGFloat, color: NSColor) {
        ctx.saveGState()
        ctx.addPath(roundedPath(rect, radius: radius))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func strokeRoundedRect(in ctx: CGContext, rect: CGRect, radius: CGFloat, color: NSColor,
                                          width: CGFloat = 1, dash: [CGFloat]? = nil) {
        ctx.saveGState()
        ctx.addPath(roundedPath(rect, radius: radius))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        if let dash = dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func strokeLine(in ctx: CGContext, from a: CGPoint, to b: CGPoint, color: NSColor,
                                   width: CGFloat = 1, dash: [CGFloat]? = nil) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        if let dash = dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A thin horizontal meter: a faint track and a coloured fill `fraction` of the way along (nothing when there is no value).
    private static func drawMeter(in ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                                  fraction: Double?, color: NSColor) {
        fillRoundedRect(in: ctx, rect: CGRect(x: x, y: y, width: width, height: height), radius: height / 2,
                        color: ReadoutStyle.track)
        guard let f = fraction, f.isFinite else { return }
        let filled = width * CGFloat(max(0, min(1, f)))
        guard filled > 0 else { return }
        fillRoundedRect(in: ctx, rect: CGRect(x: x, y: y, width: filled, height: height), radius: height / 2, color: color)
    }

    // MARK: - Memory

    /// Memory: on the photograph two dashed module outlines with a plate on each (the composition bar, and the pressure and
    /// swap); on a drawn layout the package's die outlines, the composition bar and the readout. The outlines take the
    /// pressure colour. With no memory reading only the outlines are drawn.
    func drawMemory(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        let memory = readings?.memory
        let pc = Self.memoryPressureColor(memory?.pressure)

        if let left = c.parts.first(where: { $0.name == "moduleL" }),
           let right = c.parts.first(where: { $0.name == "moduleR" }) {
            drawPhotoMemory(in: ctx, left: Self.cgRect(left.rect), right: Self.cgRect(right.rect), memory: memory, pressure: pc)
            return
        }

        let dies = c.parts.filter { $0.name.hasPrefix("die") }.map { Self.cgRect($0.rect) }
        for die in dies {
            Self.fillRoundedRect(in: ctx, rect: die, radius: 8, color: ReadoutStyle.dieFill)
            Self.strokeRoundedRect(in: ctx, rect: die, radius: 8, color: pc.withAlphaComponent(0.6), width: 1.5)
        }
        guard let m = memory else { return }

        if let bar = c.parts.first(where: { $0.name == "bar" }) {
            let b = Self.cgRect(bar.rect)
            Self.drawCompositionBar(in: ctx, x: b.minX, y: b.minY, width: b.width, height: b.height,
                                    radius: 3, gap: 1.5, alpha: 0.92, memory: m)
        }

        let used = Self.memoryUsedText(m)
        let total = Self.memoryTotalLabel(m.total)
        let level = m.pressure
        let name = Self.memoryPressureName(level)
        guard let pkg = c.rect.map({ Self.cgRect($0) }) else { return }

        if c.flags.contains("compact") {
            let stack = c.flags.contains("stack")
            let tx = pkg.minX + 14
            Self.drawLabel("MEMORY" + (stack ? " · STACKED ON SOC" : ""),
                           x: tx, baseline: stack ? pkg.minY + 16 : pkg.minY - 26)
            Self.drawRuns([Self.run(used, Self.numberFont(22), HardwareStyle.ink),
                           Self.run(" of \(total)", Self.sansFont(13), HardwareStyle.dim)],
                          x: tx, baseline: stack ? pkg.minY + 38 : pkg.minY - 4)
            let dotY = stack ? pkg.minY + 30 : pkg.minY - 10
            ctx.saveGState()
            ctx.setFillColor(pc.cgColor)
            ctx.fillEllipse(in: CGRect(x: pkg.maxX - 86 - 5.5, y: dotY - 5.5, width: 11, height: 11))
            ctx.restoreGState()
            Self.drawText(name, x: pkg.maxX - 76, baseline: stack ? pkg.minY + 35 : pkg.minY - 5,
                          font: Self.sansFont(13, .semibold), color: HardwareStyle.ink)
        } else if dies.count >= 1 {
            let a = dies[0]
            Self.drawLabel("MEMORY", x: a.minX + 14, baseline: a.minY + 18)
            Self.drawRuns([Self.run(used, Self.numberFont(24), HardwareStyle.ink),
                           Self.run(" / \(total)", Self.sansFont(12.5), HardwareStyle.dim)],
                          x: a.minX + 14, baseline: a.minY + 44)
            Self.drawText("unified · on package", x: a.minX + 14, baseline: a.minY + 100,
                          font: Self.sansFont(11), color: HardwareStyle.faint)
            if dies.count >= 2 {
                let b = dies[1]
                Self.drawLabel("PRESSURE", x: b.minX + 14, baseline: b.minY + 18)
                ctx.saveGState()
                ctx.setFillColor(pc.cgColor)
                ctx.fillEllipse(in: CGRect(x: b.minX + 22 - 6, y: b.minY + 37 - 6, width: 12, height: 12))
                ctx.setFillColor(pc.withAlphaComponent(0.2).cgColor)
                ctx.fillEllipse(in: CGRect(x: b.minX + 22 - 11, y: b.minY + 37 - 11, width: 22, height: 22))
                ctx.restoreGState()
                Self.drawText(name, x: b.minX + 36, baseline: b.minY + 43,
                              font: Self.sansFont(16, .semibold), color: HardwareStyle.ink)
                Self.drawText(Self.swapText(m.swapBytes), x: b.minX + 14, baseline: b.minY + 100,
                              font: Self.sansFont(13), color: HardwareStyle.dim)
            }
        }
    }

    /// The photograph's memory: a module each side of the SoC, dashed in the pressure colour, and (with a reading) a plate
    /// low on each module.
    private func drawPhotoMemory(in ctx: CGContext, left: CGRect, right: CGRect, memory: MemoryReading?, pressure pc: NSColor) {
        for module in [left, right] {
            Self.strokeRoundedRect(in: ctx, rect: module, radius: 6, color: pc.withAlphaComponent(0.55), dash: [5, 4])
        }
        guard let m = memory else { return }
        func plateRect(_ module: CGRect) -> CGRect {
            CGRect(x: module.minX + 3, y: module.minY + module.height * 0.36,
                   width: module.width - 6, height: module.height * 0.62)
        }

        let l = plateRect(left)
        Self.plate(in: ctx, rect: l, radius: 8, alpha: 0.84)
        Self.drawLabel("MEMORY", x: l.minX + 9, baseline: l.minY + 15, size: 8.5)
        Self.drawText(Self.memoryUsedText(m), x: l.minX + 9, baseline: l.minY + 40,
                      font: Self.numberFont(22), color: HardwareStyle.ink)
        Self.drawText("of \(Self.memoryTotalLabel(m.total))", x: l.minX + 9, baseline: l.minY + 55,
                      font: Self.sansFont(11), color: HardwareStyle.dim)
        Self.drawCompositionBar(in: ctx, x: l.minX + 9, y: l.maxY - 13, width: l.width - 18, height: 6,
                                radius: 2, gap: 1.2, alpha: 1, memory: m)

        let r = plateRect(right)
        Self.plate(in: ctx, rect: r, radius: 8, alpha: 0.84)
        Self.drawLabel("PRESSURE", x: r.minX + 9, baseline: r.minY + 15, size: 8.5)
        ctx.saveGState()
        ctx.setFillColor(pc.cgColor)
        ctx.fillEllipse(in: CGRect(x: r.minX + 16 - 5, y: r.minY + 35 - 5, width: 10, height: 10))
        ctx.restoreGState()
        Self.drawText(Self.memoryPressureName(m.pressure), x: r.minX + 27, baseline: r.minY + 40,
                      font: Self.sansFont(14, .semibold), color: HardwareStyle.ink)
        Self.drawText(Self.swapText(m.swapBytes), x: r.minX + 9, baseline: r.minY + 57,
                      font: Self.sansFont(11.5), color: HardwareStyle.dim)
    }

    /// The App / Wired / Compressed / Free bar: each segment as wide as its share of the total memory, with a small gap
    /// after it. A segment of nothing is not drawn.
    private static func drawCompositionBar(in ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                                           radius: CGFloat, gap: CGFloat, alpha: CGFloat, memory m: MemoryReading) {
        guard m.total > 0, width > 0 else { return }
        var cx = x
        for segment in memorySegments(m) where segment.bytes > 0 {
            let w = width * CGFloat(Double(segment.bytes) / Double(m.total))
            fillRoundedRect(in: ctx, rect: CGRect(x: cx, y: y, width: max(w - gap, 1), height: height), radius: radius,
                            color: segment.color.withAlphaComponent(alpha))
            cx += w
        }
    }

    // MARK: - Storage

    /// Storage: the NAND chip outlines, and (with a reading) the free-of-total readout with a usage bar. On the photograph
    /// the readout sits on a plate between the two chips, tied to them by dotted lines. With no storage reading only the
    /// chip outlines are drawn. Read and write speed, SMART and temperature belong to the hover card.
    func drawStorage(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        let storage = readings?.storage

        if let a = c.parts.first(where: { $0.name == "nandA" }),
           let b = c.parts.first(where: { $0.name == "nandB" }),
           let plateRect = c.parts.first(where: { $0.name == "plate" }) {
            drawPhotoStorage(in: ctx, a: Self.cgRect(a.rect), b: Self.cgRect(b.rect),
                             plate: Self.cgRect(plateRect.rect), storage: storage)
            return
        }

        let dash: [CGFloat]? = c.confidence == .inferred ? [5, 4] : nil
        let chips = c.parts.filter { $0.name.hasPrefix("chip") }.map { Self.cgRect($0.rect) }
        for chip in chips {
            Self.fillRoundedRect(in: ctx, rect: chip, radius: 6, color: ReadoutStyle.nandFill)
            Self.strokeRoundedRect(in: ctx, rect: chip, radius: 6, color: ReadoutStyle.nandStroke, dash: dash)
            Self.drawLabel("NAND", x: chip.midX, baseline: chip.midY + 4, size: 9.5, align: .center)
        }
        guard let s = storage, let tx = c.parts.first(where: { $0.name == "tx" }) else { return }
        guard chips.count > 1 || (chips.first?.width ?? 0) < 200 else { return }

        let x = CGFloat(tx.rect.x), y = CGFloat(tx.rect.y), w = CGFloat(tx.rect.w)
        Self.drawLabel("STORAGE · SSD", x: x, baseline: y - 8)
        Self.drawRuns([Self.run(Self.storageGigabytesText(s.freeBytes) + (s.freeBytes == nil ? "" : " GB"),
                                Self.numberFont(17), HardwareStyle.ink),
                       Self.run(" free of " + Self.storageGigabytesText(s.totalBytes), Self.sansFont(13), HardwareStyle.dim)],
                      x: x, baseline: y + 12)
        let used = Self.storageUsedFraction(s)
        Self.drawMeter(in: ctx, x: x, y: y + 22, width: w, height: 8, fraction: used,
                       color: (used ?? 0) > 0.9 ? HardwareStyle.warm : HardwareStyle.accent)
    }

    private func drawPhotoStorage(in ctx: CGContext, a: CGRect, b: CGRect, plate p: CGRect, storage: StorageReading?) {
        for chip in [a, b] {
            Self.strokeRoundedRect(in: ctx, rect: chip, radius: 4, color: HardwareStyle.cyan.withAlphaComponent(0.6), dash: [4, 3])
            Self.drawLabel("NAND", x: chip.midX, baseline: chip.midY + 3, size: 8,
                           color: ReadoutStyle.photoNandLabel, align: .center)
        }
        guard let s = storage else { return }

        let lineColor = HardwareStyle.cyan.withAlphaComponent(0.45)
        Self.strokeLine(in: ctx, from: CGPoint(x: a.maxX, y: a.midY), to: CGPoint(x: p.minX, y: p.midY),
                        color: lineColor, dash: [3, 3])
        Self.strokeLine(in: ctx, from: CGPoint(x: p.maxX, y: p.midY), to: CGPoint(x: b.minX, y: b.midY),
                        color: lineColor, dash: [3, 3])
        Self.plate(in: ctx, rect: p, radius: 10, alpha: 0.84, stroke: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14), dash: [5, 4])
        Self.drawLabel("STORAGE", x: p.minX + 12, baseline: p.minY + 16)
        Self.drawRuns([Self.run(Self.storageGigabytesText(s.freeBytes) + (s.freeBytes == nil ? "" : " GB"),
                                Self.numberFont(16), HardwareStyle.ink),
                       Self.run(" free of " + Self.storageGigabytesText(s.totalBytes), Self.sansFont(12), HardwareStyle.dim)],
                      x: p.minX + 12, baseline: p.minY + 35)
        let used = Self.storageUsedFraction(s)
        Self.drawMeter(in: ctx, x: p.minX + 12, y: p.maxY - 10, width: p.width - 24, height: 4, fraction: used,
                       color: (used ?? 0) > 0.9 ? HardwareStyle.warm : HardwareStyle.accent)
    }

    // MARK: - Wi-Fi

    /// Wi-Fi: a plate with the download and upload speed. "—" for both when the network was not read.
    func drawWifi(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect else { return }
        let rect = Self.cgRect(r)
        let net = readings?.network
        let down = Self.rateText(net?.down)
        let up = Self.rateText(net?.up)

        if hardwareLayout.photoResource != nil {
            Self.plate(in: ctx, rect: rect, radius: 10, alpha: 0.82,
                       stroke: HardwareStyle.cyan.withAlphaComponent(0.55), dash: [5, 4])
            Self.drawLabel("WI-FI · BT", x: rect.minX + 12, baseline: rect.minY + 17)
            drawArrowLine("↓", down, x: rect.minX + 12, baseline: rect.minY + 35, size: 13)
            drawArrowLine("↑", up, x: rect.minX + 12, baseline: rect.minY + 52, size: 13)
            return
        }

        let small = c.flags.contains("small")
        // How busy the link is lights the plate a little: a log scale from 1 B/s to about 30 MB/s.
        var live: CGFloat = 0
        if let n = net {
            let total = max(n.down + n.up, 1)
            if total.isFinite { live = CGFloat(max(0, min(1, log10(total) / 7.5))) }
        }
        Self.fillRoundedRect(in: ctx, rect: rect, radius: 8, color: ReadoutStyle.wifiFill)
        Self.strokeRoundedRect(in: ctx, rect: rect, radius: 8, color: HardwareStyle.cyan.withAlphaComponent(0.55),
                               dash: c.confidence == .inferred ? [5, 4] : nil)
        Self.fillRoundedRect(in: ctx, rect: rect, radius: 8, color: HardwareStyle.cyan.withAlphaComponent(0.04 + live * 0.12))
        // A dotted line to the antenna strip the plate belongs with, from the edge that faces it.
        if let antenna = hardwareLayout.components.first(where: { $0.kind == .antenna })?.rect {
            let from = antenna.y < r.y ? rect.minY : rect.maxY
            Self.strokeLine(in: ctx, from: CGPoint(x: rect.midX, y: from), to: CGPoint(x: rect.midX, y: CGFloat(antenna.y)),
                            color: HardwareStyle.cyan.withAlphaComponent(0.28), dash: [3, 4])
        }
        Self.drawLabel(small ? "WI-FI" : "WI-FI · BT", x: rect.minX + 12, baseline: rect.minY + 17,
                       color: ReadoutStyle.wifiLabel)
        let size: CGFloat = small ? 12 : 14.5
        drawArrowLine("↓", down, x: rect.minX + 12, baseline: rect.minY + 38, size: size)
        drawArrowLine("↑", up, x: rect.minX + 12, baseline: rect.minY + 57, size: size)
    }

    /// "↓ 3.5 KB/s": a dim arrow and a number.
    private func drawArrowLine(_ arrow: String, _ value: String, x: CGFloat, baseline: CGFloat, size: CGFloat) {
        Self.drawRuns([Self.run(arrow + " ", Self.sansFont(size), HardwareStyle.dim),
                       Self.run(value, Self.numberFont(size), HardwareStyle.ink)],
                      x: x, baseline: baseline)
    }

    // MARK: - Power in

    /// The power-in plate: the port, and a line "≈ 4.4 W in · not charging". The wording says MagSafe 3, or USB-C where the
    /// layout says this Mac charges over USB-C. With no adapter reading the plate shows "—".
    func drawPowerIn(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let r = c.rect else { return }
        let rect = Self.cgRect(r)
        let usbcPower = c.flags.contains("usbcPower")
        let readout = Self.powerInReadout(readings?.adapter)
        let cyan = HardwareStyle.cyan

        if let port = c.anchors["port"] {
            // The photograph: a dotted line from the plate down to the MagSafe port, and a dot on the port.
            let p = CGPoint(x: port.x, y: port.y)
            Self.strokeLine(in: ctx, from: CGPoint(x: rect.minX + 34, y: rect.maxY), to: p,
                            color: cyan.withAlphaComponent(0.6), dash: [3, 4])
            ctx.saveGState()
            ctx.setFillColor(cyan.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            ctx.restoreGState()
            Self.plate(in: ctx, rect: rect, radius: 10, alpha: 0.84, stroke: cyan.withAlphaComponent(0.5))
        } else {
            let usbcPorts = c.parts.filter { $0.name.hasPrefix("usbc") }.map { Self.cgRect($0.rect) }
            for (i, port) in usbcPorts.enumerated() {
                Self.fillRoundedRect(in: ctx, rect: port, radius: 4, color: ReadoutStyle.portFill)
                // The port that carries power is outlined in the plate's own colour.
                Self.strokeRoundedRect(in: ctx, rect: port, radius: 4,
                                       color: usbcPower && i == 0 ? cyan : ReadoutStyle.portStroke)
            }
            if let magsafe = c.parts.first(where: { $0.name == "port" }).map({ Self.cgRect($0.rect) }) {
                Self.fillRoundedRect(in: ctx, rect: magsafe, radius: 5, color: ReadoutStyle.portFill)
                Self.strokeRoundedRect(in: ctx, rect: magsafe, radius: 5, color: cyan)
                Self.fillRoundedRect(in: ctx, rect: CGRect(x: magsafe.minX + 4, y: magsafe.minY + 9, width: 14, height: 6),
                                     radius: 2, color: cyan.withAlphaComponent(0.6))
            }
            Self.fillRoundedRect(in: ctx, rect: rect, radius: 9, color: cyan.withAlphaComponent(0.07))
            Self.strokeRoundedRect(in: ctx, rect: rect, radius: 9, color: cyan.withAlphaComponent(0.4))
        }

        Self.drawLabel(usbcPower ? "USB-C · POWER IN" : "MAGSAFE 3 · POWER IN", x: rect.minX + 12, baseline: rect.minY + 17)
        var runs = [Self.run(readout.value, Self.numberFont(15), HardwareStyle.ink)]
        if !readout.note.isEmpty { runs.append(Self.run(" " + readout.note, Self.sansFont(12.5), HardwareStyle.dim)) }
        Self.drawRuns(runs, x: rect.minX + 12, baseline: rect.minY + 36)
    }

    // MARK: - Battery

    /// The battery cells. A cell is a plate over the photograph (translucent dark) or a solid cell with a tab on a drawn
    /// layout; it shows one reading, or two or three stacked in the mockup's 40 / 28 / 32 split. A Mac with no battery reading
    /// (a desktop) draws nothing.
    func drawBattery(in ctx: CGContext, scale: CGFloat, component c: HardwareComponent) {
        guard let b = readings?.battery else { return }
        let plated = c.flags.contains("plated")
        let dash: [CGFloat]? = c.confidence == .inferred ? [5, 4] : nil
        let fractions: [CGFloat] = [0.40, 0.28, 0.32]

        for part in c.parts where part.name.hasPrefix("cell") && !part.roles.isEmpty {
            let cell = Self.cgRect(part.rect)
            if plated {
                Self.plate(in: ctx, rect: cell.insetBy(dx: 3, dy: 3), radius: 12, alpha: 0.84)
            } else {
                Self.fillRoundedRect(in: ctx, rect: cell, radius: 12, color: ReadoutStyle.cellFill)
                Self.strokeRoundedRect(in: ctx, rect: cell, radius: 12, color: ReadoutStyle.cellStroke, dash: dash)
                Self.fillRoundedRect(in: ctx, rect: CGRect(x: cell.midX - 24, y: cell.minY - 3, width: 48, height: 5),
                                     radius: 2.5, color: ReadoutStyle.cellStroke)
            }
            var y = cell.minY
            for (i, role) in part.roles.enumerated() {
                let h = part.roles.count > 1 ? cell.height * (i < fractions.count ? fractions[i] : 0) : cell.height
                if i > 0 {
                    Self.strokeLine(in: ctx, from: CGPoint(x: cell.minX + 14, y: y), to: CGPoint(x: cell.maxX - 14, y: y),
                                    color: ReadoutStyle.separator)
                }
                drawBatteryRole(role, in: ctx, x: cell.minX, y: y, w: cell.width, h: h, battery: b)
                y += h
            }
        }
    }

    /// One reading inside its slice of a cell (the mockup's `ROLE.*`).
    private func drawBatteryRole(_ role: String, in ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                                 battery b: BatteryReading) {
        let ink = HardwareStyle.ink
        let dim = HardwareStyle.dim
        let left = x + 16

        switch role {
        case "charge":
            // A faint fill to the percent behind the number: green, or orange at 20 % and under.
            let percent = max(0, min(100, b.percent))
            let fill = CGRect(x: x, y: y, width: w * CGFloat(percent) / 100, height: h)
            Self.fillRoundedRect(in: ctx, rect: fill, radius: 12,
                                 color: (b.percent > 20 ? HardwareStyle.accent : HardwareStyle.warm).withAlphaComponent(0.12))
            Self.drawLabel("CHARGE", x: left, baseline: y + 24)
            Self.drawRuns([Self.run("\(b.percent)", Self.numberFont(h > 110 ? 54 : 44), ink),
                           Self.run(" %", Self.sansFont(20), dim)],
                          x: left, baseline: y + min(h - 14, 72))

        case "temp":
            let temp = b.tempC.flatMap { $0.isFinite ? $0 : nil }
            Self.drawLabel("BATTERY TEMP", x: left, baseline: y + 24)
            var runs = [Self.run(temp.map { Self.readoutNumber($0) } ?? "—", Self.numberFont(34), ink)]
            if temp != nil { runs.append(Self.run(" °C", Self.sansFont(16), dim)) }
            Self.drawRuns(runs, x: left, baseline: y + min(h - 24, 62))
            Self.drawMeter(in: ctx, x: left, y: y + h - 16, width: w - 32, height: 4,
                           fraction: temp.map { max(0, min(1, ($0 - 20) / 30)) },
                           color: temp.map { Self.heatColor($0 + 12) } ?? HardwareStyle.faint)

        case "state":
            Self.drawLabel("STATE · RATE", x: left, baseline: y + 24)
            let fitted = Self.fittedText(Self.batteryStateText(b.state), width: w - 32, startSize: w < 250 ? 19 : 21, weight: .semibold)
            Self.drawText(fitted.text, x: left, baseline: y + 54, font: Self.sansFont(fitted.size, .semibold), color: ink)
            let current = Self.batteryCurrentText(b.amps)
            let time = Self.batteryTimeText(b)
            if h >= 120 {
                Self.drawText(current, x: left, baseline: y + 80, font: Self.numberFont(14), color: ink)
                Self.drawText(time, x: left, baseline: y + 102, font: Self.sansFont(13), color: dim)
            } else {
                Self.drawRuns([Self.run(current, Self.numberFont(14), ink),
                               Self.run("   " + time, Self.sansFont(13), dim)],
                              x: left, baseline: y + min(h - 12, 80))
            }

        case "graph":
            Self.drawLabel("CHARGE · LAST 24 H", x: left, baseline: y + 22)
            let graph = CGRect(x: left, y: y + 32, width: w - 34, height: h - 46)
            if graph.width > 0, graph.height > 0 {
                Self.drawChargeGraph(in: ctx, rect: graph, values: chargeHistory)
            }

        case "draw":
            let watts = b.systemDrawW.value.flatMap { $0.isFinite ? $0 : nil }
            Self.drawLabel("SYSTEM DRAW", x: left, baseline: y + 24)
            var runs = [Self.run(watts.map { Self.estimatePrefix(b.systemDrawW.provenance) + Self.readoutNumber($0) } ?? "—",
                                 Self.numberFont(36), ink)]
            if watts != nil { runs.append(Self.run(" W", Self.sansFont(17), dim)) }
            Self.drawRuns(runs, x: left, baseline: y + min(h - 26, 64))
            Self.drawMeter(in: ctx, x: left, y: y + h - 16, width: w - 32, height: 4,
                           fraction: watts.map { max(0, min(1, $0 / 70)) }, color: HardwareStyle.accent)

        case "health":
            let narrow = w < 250
            Self.drawLabel("HEALTH", x: left, baseline: y + 24)
            let health = b.health.flatMap { $0.isFinite ? $0 : nil }
            var runs = [Self.run(health.map { Self.readoutNumber($0, digits: 0) } ?? "—", Self.numberFont(34), ink)]
            if health != nil { runs.append(Self.run(" %", Self.sansFont(16), dim)) }
            let valueBaseline = y + (narrow ? 64 : min(h - 24, 62))
            Self.drawRuns(runs, x: left, baseline: valueBaseline)
            let cycles = Self.batteryCyclesText(b, stacked: narrow)
            if narrow {
                Self.drawText(cycles, x: left, baseline: y + 90, font: Self.sansFont(13), color: dim)
            } else {
                Self.drawText(cycles, x: x + w - 16, baseline: valueBaseline, font: Self.sansFont(13), color: dim, align: .right)
            }

        default:
            break
        }
    }

    /// The mockup's `spark(...)` with the grid on and a fixed scale of 0 to 100 percent: three faint lines, the line with its
    /// soft area under it (a break wherever a sample is missing), and a dot with a halo on the latest sample. With no samples
    /// at all nothing is drawn. Drawn straight into the context (it is not a SparkGraphView).
    private static func drawChargeGraph(in ctx: CGContext, rect: CGRect, values: [Double?]) {
        guard values.contains(where: { $0 != nil }) else { return }
        let color = HardwareStyle.accent
        let steps = CGFloat(max(values.count - 1, 1))
        func px(_ i: Int) -> CGFloat { rect.minX + CGFloat(i) / steps * rect.width }
        func py(_ v: Double) -> CGFloat { rect.minY + rect.height - CGFloat(max(0, min(100, v)) / 100) * rect.height }

        ctx.saveGState()
        ctx.setStrokeColor(ReadoutStyle.gridLine.cgColor)
        ctx.setLineWidth(1)
        for k in [0.0, 0.5, 1.0] {
            let y = rect.minY + rect.height * CGFloat(k)
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()
        }

        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (i, value) in values.enumerated() {
            if let v = value, v.isFinite {
                current.append(CGPoint(x: px(i), y: py(v)))
            } else {
                if !current.isEmpty { runs.append(current) }
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }

        for run in runs where run.count > 1 {
            let area = CGMutablePath()
            area.move(to: run[0])
            for p in run.dropFirst() { area.addLine(to: p) }
            area.addLine(to: CGPoint(x: run[run.count - 1].x, y: rect.maxY))
            area.addLine(to: CGPoint(x: run[0].x, y: rect.maxY))
            area.closeSubpath()
            ctx.addPath(area)
            ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
            ctx.fillPath()

            let line = CGMutablePath()
            line.move(to: run[0])
            for p in run.dropFirst() { line.addLine(to: p) }
            ctx.addPath(line)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.8)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }

        if let last = runs.last?.last {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6))
            ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
            ctx.fillEllipse(in: CGRect(x: last.x - 6, y: last.y - 6, width: 12, height: 12))
        }
        ctx.restoreGState()
    }
}

/// One formatter per number of decimals, made once (a formatter is costly to build and the canvas draws these every tick).
private func makeReadoutFormatter(digits: Int) -> NumberFormatter {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.minimumFractionDigits = digits
    f.maximumFractionDigits = digits
    return f
}
