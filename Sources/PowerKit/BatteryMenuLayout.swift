import CoreGraphics

/// Where every part of the Battery menu goes, from the model: a pure flow down the panel, measured against macOS's.
public enum BatteryMenuLayout {

    public enum RowKind: Equatable {
        case title
        case powerSource
        /// "1h 51m until fully charged": under the power source, on the charger only.
        case statusLine
        case divider
        case heading(String)
        case mode(Int)
        case app(Int)
        case footer
        /// Anode's: the gear at the right end of the title line, and the charge limit slider row.
        case gear
        case chargeLimit
    }

    public struct LaidOutRow: Equatable {
        public var kind: RowKind
        public var frame: CGRect
    }

    public struct Result: Equatable {
        public var rows: [LaidOutRow]
        public var height: CGFloat
    }

    public static let energyHeading = "Energy Mode"
    public static let significantEnergyHeading = "Using Significant Energy"
    public static let chargeLimitHeading = "Charge Limit"
    /// The heading carries the limit ("Charge Limit: 80%"), so the row under it has room for its buttons.
    public static func chargeLimitTitle(_ limit: Int) -> String { "\(chargeLimitHeading): \(limit)%" }

    public static func frames(for model: BatteryMenuModel) -> Result {
        typealias M = BatteryMenuMetrics
        var rows: [LaidOutRow] = []
        func add(_ kind: RowKind, y: CGFloat, h: CGFloat) {
            rows.append(LaidOutRow(kind: kind, frame: CGRect(x: M.inset, y: y, width: M.contentWidth, height: h)))
        }
        add(.title, y: M.titleY, h: M.titleHeight)
        if model.showsGear {
            rows.append(LaidOutRow(kind: .gear, frame: CGRect(x: M.inset + M.contentWidth - M.gearSize, y: M.titleY + (M.titleHeight - M.gearSize) / 2,
                                                              width: M.gearSize, height: M.gearSize)))
        }
        add(.powerSource, y: M.powerSourceY, h: M.powerSourceHeight)
        // Everything from the first line down moves by one step when the status line is there.
        let step: CGFloat = model.statusLine == nil ? 0 : M.statusLineStep
        if model.statusLine != nil { add(.statusLine, y: M.powerSourceY + step, h: M.powerSourceHeight) }
        add(.divider, y: M.firstDividerY + step, h: 1)
        add(.heading(energyHeading), y: M.energyHeadingY + step, h: M.headingHeight)
        var y = M.modeRowsY + step
        for i in model.modes.indices { add(.mode(i), y: y, h: M.modeRowHeight); y += M.modeRowHeight }
        // The gaps below a line are measured from the line's top.
        y += M.dividerGapBelowRows
        add(.divider, y: y, h: 1)
        if let chargeLimit = model.chargeLimit {
            // Anode's section, laid out like the apps' one: a heading under the line, then the row, then a line.
            let headingY = y + M.headingGapBelowDivider
            add(.heading(chargeLimitTitle(chargeLimit.limit)), y: headingY, h: M.headingHeight)
            let rowY = headingY + M.headingHeight + M.appsFirstRowGapBelowHeading
            add(.chargeLimit, y: rowY, h: M.chargeRowHeight)
            y = rowY + M.chargeRowHeight + M.dividerGapBelowRows
            add(.divider, y: y, h: 1)
        }
        if !model.energyApps.isEmpty {
            // The section: heading, one row for each app, and a line under them.
            let headingY = y + M.headingGapBelowDivider
            add(.heading(significantEnergyHeading), y: headingY, h: M.headingHeight)
            var ay = headingY + M.headingHeight + M.appsFirstRowGapBelowHeading
            for i in model.energyApps.indices { add(.app(i), y: ay, h: M.appRowHeight); ay += M.appRowPitch }
            y = ay - (M.appRowPitch - M.appRowHeight) + M.dividerGapBelowRows
            add(.divider, y: y, h: 1)
        }
        let footerY = y + M.footerGapBelowDivider
        add(.footer, y: footerY, h: M.footerRowHeight)
        return Result(rows: rows, height: footerY + M.footerRowHeight + M.bottomPadding)
    }
}
