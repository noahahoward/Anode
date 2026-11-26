import Foundation

/// A graph the detail wants drawn: the values so far (oldest first, nil for a
/// tick with no reading) and how to caption them. No colours: the UI picks.
public struct HardwareSeriesRef {
    public var name: String
    public var channel: HardwareHistory.Channel
    public var values: [Double?]
    /// Appended to the numbers, for example " rpm". Empty for a rate, which the
    /// UI formats as bytes per second.
    public var unit: String
    public var isRate: Bool
    public var fractionDigits: Int
    /// Where the numbers in the graph came from: `estimate` when the reading the graph follows is one (the card says so on
    /// its now / range line).
    public var provenance: Provenance

    public init(name: String,
                channel: HardwareHistory.Channel,
                values: [Double?],
                unit: String,
                isRate: Bool = false,
                fractionDigits: Int = 1,
                provenance: Provenance = .real) {
        self.name = name
        self.channel = channel
        self.values = values
        self.unit = unit
        self.isRate = isRate
        self.fractionDigits = fractionDigits
        self.provenance = provenance
    }
}

/// What a hover tip or a pinned panel says about one part: a title, how sure
/// the layout is, labelled rows each with where the number came from, an
/// optional note and an optional graph. Plain strings and values, so the model
/// can be tested without a window. A reading that is not available says "—"
/// and carries no provenance.
public struct HardwareDetail {
    public typealias Row = (label: String, value: String, provenance: Provenance?)

    public var title: String
    public var confidenceNote: String
    public var rows: [Row]
    public var note: String?
    /// nil when the part has no graph, and for a battery cell's 24 hour charge
    /// (Anode's history is not part of this in-memory buffer; the caller
    /// attaches it).
    public var series: HardwareSeriesRef?

    public init(title: String,
                confidenceNote: String,
                rows: [Row],
                note: String? = nil,
                series: HardwareSeriesRef? = nil) {
        self.title = title
        self.confidenceNote = confidenceNote
        self.rows = rows
        self.note = note
        self.series = series
    }

    /// The text shown for a reading that is not available.
    public static let missing = "—"

    /// Builds the detail for one component, or nil for a part that has nothing
    /// to say (the board, the SoC, the antenna strip, speakers, the trackpad, a
    /// note), a fan the sensors did not list (it is not on this Mac), or a
    /// battery with no reading (there is no battery). `role` picks a battery cell's reading: charge, temp, state,
    /// graph, draw or health; nil or an unknown role reads as charge.
    public static func make(component: HardwareComponent,
                            readings: HardwareReadings,
                            history: HardwareHistory,
                            role: String?) -> HardwareDetail? {
        let conf = confidenceText(component.confidence)
        switch component.kind {
        case .display:
            return display(component, readings, history, conf)
        case .fan(let index):
            return fan(index, readings, history, conf)
        case .heatPipe:
            return pipe(component, readings, history, conf)
        case .memory:
            return memory(readings, history, conf)
        case .wifi:
            return wifi(readings, history, conf)
        case .storage:
            return storage(readings, history, conf)
        case .powerIn:
            return adapter(component, readings, conf)
        case .psu:
            return psu(readings, conf)
        case .battery:
            return battery(readings, role, conf)
        case .antenna, .speaker, .trackpad, .board, .soc, .note:
            return nil
        }
    }

    // MARK: Wording shared with the approved mock-up

    static func confidenceText(_ c: Confidence) -> String {
        switch c {
        case .verified: return "Layout verified from teardowns"
        case .inferred: return "Position approximate · inferred"
        }
    }

    /// The kernel's own levels, with Apple's green, yellow, red.
    static func pressureName(_ level: Int32?) -> String? {
        switch level {
        case 1?: return "Normal"
        case 2?: return "Warning"
        case 4?: return "Critical"
        default: return nil
        }
    }

    // MARK: Number formatting (en_US, so the text does not depend on the Mac's locale)

    /// One formatter per number of decimals the view uses (0, 1 and 2), made once: a formatter is costly to build and a detail
    /// is rewritten every tick while a card is open.
    private static func makeFormatter(digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }

    private static let wholeFormatter = makeFormatter(digits: 0)
    private static let tenthsFormatter = makeFormatter(digits: 1)
    private static let hundredthsFormatter = makeFormatter(digits: 2)

    static func fmt(_ n: Double, _ digits: Int = 1) -> String {
        let f: NumberFormatter
        switch digits {
        case 0: f = wholeFormatter
        case 1: f = tenthsFormatter
        case 2: f = hundredthsFormatter
        default: f = makeFormatter(digits: digits)
        }
        return f.string(from: NSNumber(value: n)) ?? String(format: "%.\(digits)f", n)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1e9 { return fmt(bytesPerSecond / 1e9, 2) + " GB/s" }
        if bytesPerSecond >= 1e6 { return fmt(bytesPerSecond / 1e6, 1) + " MB/s" }
        return fmt(bytesPerSecond / 1e3, 1) + " KB/s"
    }

    private static let gibibyte = 1_073_741_824.0

    /// Memory is counted in the units macOS uses for it (a "24 GB" Mac is 24 GiB).
    static func gb(_ bytes: UInt64) -> Double { Double(bytes) / gibibyte }

    static func gbText(_ bytes: UInt64) -> String {
        let g = gb(bytes)
        return abs(g - g.rounded()) < 0.05 ? fmt(g, 0) : fmt(g, 1)
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%ld:%02ld", minutes / 60, minutes % 60)
    }

    // MARK: Row and series helpers

    /// A row. A nil value is "—" and carries no provenance.
    private static func row(_ label: String, _ value: String?, _ provenance: Provenance? = nil) -> Row {
        (label: label, value: value ?? missing, provenance: value == nil ? nil : provenance)
    }

    private static func graph(_ name: String,
                               _ channel: HardwareHistory.Channel,
                               _ history: HardwareHistory,
                               unit: String,
                               digits: Int = 1,
                               isRate: Bool = false,
                               scale: Double = 1,
                               provenance: Provenance = .real) -> HardwareSeriesRef {
        let values: [Double?] = history.series(channel).map { v in v.map { $0 * scale } }
        return HardwareSeriesRef(name: name, channel: channel, values: values,
                                 unit: unit, isRate: isRate, fractionDigits: digits, provenance: provenance)
    }

    // MARK: Display

    private static func display(_ c: HardwareComponent, _ r: HardwareReadings,
                                _ h: HardwareHistory, _ conf: String) -> HardwareDetail {
        let d = r.display
        var rows: [Row] = [
            row("Power", d?.watts.value.map { fmt($0, 2) + " W" }, d?.watts.provenance),
            row("Brightness", d?.brightness.map { "\(Int(($0 * 100).rounded())) %" }, .real)
        ]
        // The layout's own words (a panel's resolution and name), when it has them.
        rows.append(row("Panel", c.text.count >= 2 ? c.text[1] : nil))
        rows.append(row("Resolution", c.text.count >= 2 ? c.text[0] : nil))
        rows.append(row("Temperature", "not exposed"))

        let measured = d?.watts.provenance == .real && d?.watts.value != nil
        let first: String
        if d == nil {
            first = "Anode has no display brightness or power reading on this Mac."
        } else if measured {
            first = "Backlight power comes from a rail only identified on this Mac (PDBR)."
        } else {
            first = "Display power is estimated from brightness on this Mac."
        }
        let note = first + " macOS exposes no display temperature. The graph is a live buffer that starts empty and clears when this window closes."
        return HardwareDetail(title: "Display", confidenceNote: conf, rows: rows, note: note,
                              series: graph("Display power · since opened", .displayWatts, h,
                                             unit: " W", digits: 2, provenance: d?.watts.provenance ?? .real))
    }

    // MARK: Fan

    private static func fan(_ index: Int, _ r: HardwareReadings,
                            _ h: HardwareHistory, _ conf: String) -> HardwareDetail? {
        // A fan list that was not swept is "not measured", not "no fans"; a fan the sweep did not list is not on this Mac.
        if r.fansMeasured && !r.fans.contains(where: { $0.index == index }) { return nil }
        let f: FanReading? = r.fansMeasured ? r.fans.first(where: { $0.index == index }) : nil
        let speed: String? = f.map { $0.rpm >= 0.5 ? "\(fmt($0.rpm, 0)) rpm" : "0 rpm · parked" }
        let range: String? = f.map { "\(fmt($0.minRPM, 0)) – \(fmt($0.maxRPM, 0)) rpm" }
        let mode: String? = f.map { $0.isManual ? "Manual" : "Automatic" }
        let rows: [Row] = [
            row("Speed", speed, .real),
            row("Range", range, .real),
            row("Mode", mode),
            row("Control", r.helperInstalled ? "Helper installed" : "Needs helper")
        ]
        let scaled = "Blade motion is scaled for legibility, not literal speed."
        // The fans-stop line is about a reading, so it is only said when this fan was read.
        let note = f == nil ? scaled : "0 rpm is a real reading: the fans stop when the Mac is cool. " + scaled
        return HardwareDetail(
            title: "Fan \(index + 1)", confidenceNote: conf, rows: rows,
            note: note,
            series: graph("Speed · since opened", .fanRPM(index: index), h, unit: " rpm", digits: 0))
    }

    // MARK: Heat pipe

    private static func pipe(_ c: HardwareComponent, _ r: HardwareReadings,
                             _ h: HardwareHistory, _ conf: String) -> HardwareDetail {
        let spreader = c.flags.contains("spreader")
        let short = c.flags.contains("short")
        let dieSideInferred = c.flags.contains("dieSideInferred")

        let cpuCount = r.cpuSensorCount > 0 ? "mean of \(r.cpuSensorCount) die sensors" : "mean of the die sensors"
        let gpuCount = r.gpuSensorCount > 0 ? "mean of \(r.gpuSensorCount) sensors" : "mean of the sensors"
        let rows: [Row] = [
            row("CPU", r.cpuTemp.value.map { fmt($0) + " °C" }, r.cpuTemp.provenance),
            row("CPU sensors", r.cpuTemp.value == nil ? nil : cpuCount),
            row("GPU", r.gpuTemp.value.map { fmt($0) + " °C" }, r.gpuTemp.provenance),
            row("GPU sensors", r.gpuTemp.value == nil ? nil : gpuCount)
        ]
        let note: String
        if spreader {
            note = "No fan: heat leaves through a metal plate and the case."
        } else if short {
            note = "Base chips have one fan and a shorter pipe."
        } else {
            note = "One pipe runs fan to fan across the chip. Each half takes the colour of the part on that side."
        }
        return HardwareDetail(
            title: spreader ? "Passive spreader" : "Heat pipe",
            confidenceNote: dieSideInferred ? "Pipe verified · which half is CPU or GPU is inferred" : conf,
            rows: rows, note: note,
            series: graph("CPU temp · since opened", .cpuTemp, h, unit: " °C"))
    }

    // MARK: Memory

    private static func memory(_ r: HardwareReadings, _ h: HardwareHistory,
                               _ conf: String) -> HardwareDetail {
        let m = r.memory
        // A Mac that reported no total has no "of 0 GB": the total reads "—".
        let inUse: String? = m.map { m in
            "\(fmt(gb(m.app &+ m.wired &+ m.compressed))) of \(m.total == 0 ? missing : gbText(m.total) + " GB")"
        }
        func gbRow(_ label: String, _ bytes: UInt64?) -> Row {
            row(label, bytes.map { fmt(gb($0)) + " GB" }, .real)
        }
        let rows: [Row] = [
            row("In use", inUse, .real),
            gbRow("App", m?.app),
            gbRow("Wired", m?.wired),
            gbRow("Compressed", m?.compressed),
            gbRow("Free + cached", m?.free),
            row("Pressure", pressureName(m?.pressure), .real),
            gbRow("Swap", m?.swapBytes.value)
        ]
        return HardwareDetail(
            title: "Memory", confidenceNote: conf, rows: rows,
            note: "Pressure is the kernel’s own level, with Apple’s green, yellow, red. Active, inactive and cached are not split out by Anode.",
            series: graph("In use · since opened", .memoryUsed, h, unit: " GB",
                           scale: 1 / gibibyte))
    }

    // MARK: Wi-Fi

    private static func wifi(_ r: HardwareReadings, _ h: HardwareHistory,
                             _ conf: String) -> HardwareDetail {
        let rows: [Row] = [
            row("Download", r.network.map { rate($0.down) }, .real),
            row("Upload", r.network.map { rate($0.up) }, .real),
            row("Interface", r.networkInterface),
            row("Signal strength", "not exposed")
        ]
        return HardwareDetail(
            title: "Wi-Fi and Bluetooth", confidenceNote: conf, rows: rows,
            note: "Throughput is the Mac’s total over its network links, not one interface. macOS does not give Anode signal strength, channel or link rate, so none are shown. Antenna positions are approximate.",
            series: graph("Download · since opened", .netDown, h, unit: "", isRate: true))
    }

    // MARK: Storage

    private static func storage(_ r: HardwareReadings, _ h: HardwareHistory,
                                _ conf: String) -> HardwareDetail {
        let s = r.storage
        var free: String? = nil
        if let f = s?.freeBytes, let t = s?.totalBytes {
            free = "\(fmt(Double(f) / 1e9, 0)) of \(fmt(Double(t) / 1e9, 0)) GB"
        }
        var readWrite: String? = nil
        if let rd = s?.readBPS, let wr = s?.writeBPS {
            readWrite = "\(rate(rd)) · \(rate(wr))"
        }
        let rows: [Row] = [
            row("Free", free, .real),
            row("Read / write", readWrite, .real),
            // The drive's model name is not among Anode's readings yet.
            row("Drive", nil),
            row("Temperature", s?.smartTempC.map { fmt($0) + " °C" }, .real),
            row("Wear used", s?.wearPercent.map { "\($0) %" }, .real),
            row("Spare", s?.spare.map { "\($0) %" }, .real),
            row("Written", s?.bytesWritten.map { fmt(Double($0) / 1e12, 2) + " TB" }, .real)
        ]
        return HardwareDetail(
            title: "Storage", confidenceNote: conf, rows: rows,
            note: "Health comes from the drive’s own SMART log. Anode never shows a write allowance because Apple does not publish one.",
            series: graph("Read · since opened", .storageRead, h, unit: "", isRate: true))
    }

    // MARK: Power in

    private static func adapter(_ c: HardwareComponent, _ r: HardwareReadings,
                                _ conf: String) -> HardwareDetail {
        let a = r.adapter
        let state: String
        if let a = a {
            state = a.isCharging ? "charging" : "not charging"
        } else {
            state = "not connected"
        }
        let rows: [Row] = [
            row("Adapter rating", a?.ratedW.map { fmt($0, 0) + " W" }, .real),
            row("Drawing from adapter", a?.drawnW.value.map { "≈ " + fmt($0) + " W" }, a?.drawnW.provenance),
            row("State", state)
        ]
        return HardwareDetail(
            title: c.flags.contains("usbcPower") ? "USB-C power in" : "MagSafe 3 · power in",
            confidenceNote: conf, rows: rows,
            note: "This is what comes in. “System draw” on the battery is what the whole Mac uses. They differ while the battery charges or discharges.")
    }

    private static func psu(_ r: HardwareReadings, _ conf: String) -> HardwareDetail {
        let rows: [Row] = [
            row("Whole-Mac draw", r.systemW.value.map { fmt($0) + " W" }, r.systemW.provenance),
            row("Source", "Wall power")
        ]
        return HardwareDetail(
            title: "Power supply", confidenceNote: conf, rows: rows,
            note: "Desktops have no battery. Draw comes from the same system-power reading.")
    }

    // MARK: Battery

    private static func stateText(_ s: BatteryChargeState) -> String {
        switch s {
        case .charging: return "Charging"
        case .full: return "Full · holding"
        case .pluggedNotCharging: return "Plugged in · not charging"
        case .discharging: return "Discharging"
        }
    }

    private static func currentText(_ amps: Double) -> String {
        let mA = (amps * 1000).rounded()
        if mA == 0 { return "0 mA" }
        let sign = mA > 0 ? "+" : "-"
        if abs(amps) >= 1 { return sign + fmt(abs(amps)) + " A" }
        return sign + fmt(abs(mA), 0) + " mA"
    }

    private static func battery(_ r: HardwareReadings, _ role: String?,
                                _ conf: String) -> HardwareDetail? {
        // No reading is no battery (a desktop, or the pack was not read): there is no card to open.
        guard r.battery != nil else { return nil }
        let b = r.battery
        let pct: String? = b.map { "\($0.percent) %" }
        let health: String? = b?.health.map { fmt($0, 0) + " %" }
        let cycles: String? = b.map { b in
            b.designCycles.map { "\(b.cycles) of \($0)" } ?? "\(b.cycles)"
        }

        var time: String? = nil
        if let b = b, let m = b.timeRemainingMin.value {
            time = "≈ " + clock(m) + (b.isCharging ? " to full" : " remaining")
        }

        let title: String
        let rows: [Row]
        switch role ?? "charge" {
        case "temp":
            title = "Battery temperature"
            rows = [
                row("Pack", b?.tempC.map { fmt($0) + " °C" }, .real),
                row("Sensors", "Pack gas gauge, read through IOKit")
            ]
        case "state":
            title = "State and rate"
            rows = [
                row("State", b.map { stateText($0.state) }),
                row("Current", b.map { currentText($0.amps) }, .real),
                row("Time", time, b?.timeRemainingMin.provenance)
            ]
        case "graph":
            title = "Charge, last 24 hours"
            rows = [
                row("Now", pct, .real),
                row("Source", "Anode history")
            ]
        case "draw":
            title = "System draw"
            rows = [
                row("Whole Mac", b?.systemDrawW.value.map { fmt($0) + " W" }, b?.systemDrawW.provenance),
                row("Not the same as", "charger input")
            ]
        case "health":
            title = "Health"
            rows = [
                row("Capacity vs new", health, .real),
                row("Cycles", cycles, .real)
            ]
        default:
            title = "Charge"
            rows = [
                row("Charge", pct, .real),
                row("Health", health, .real),
                row("Cycles", cycles, .real)
            ]
        }
        return HardwareDetail(
            title: title, confidenceNote: conf, rows: rows,
            note: "macOS reports one reading for the whole pack, so these are pack readings shown on the cells they physically belong to.")
    }
}
