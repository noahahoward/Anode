import CoreGraphics

/// Where every part of the Battery menu goes, from the model: a pure flow down the panel, measured against macOS's.
public enum BatteryMenuLayout {

    public enum RowKind: Equatable {
        case title
        case powerSource
        case divider
        case heading(String)
        case mode(Int)
        case app(Int)
        case footer
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

    public static func frames(for model: BatteryMenuModel) -> Result {
        typealias M = BatteryMenuMetrics
        var rows: [LaidOutRow] = []
        func add(_ kind: RowKind, y: CGFloat, h: CGFloat) {
            rows.append(LaidOutRow(kind: kind, frame: CGRect(x: M.inset, y: y, width: M.contentWidth, height: h)))
        }
        add(.title, y: M.titleY, h: M.titleHeight)
        add(.powerSource, y: M.powerSourceY, h: M.powerSourceHeight)
        add(.divider, y: M.firstDividerY, h: 1)
        add(.heading(energyHeading), y: M.energyHeadingY, h: M.headingHeight)
        var y = M.modeRowsY
        for i in model.modes.indices { add(.mode(i), y: y, h: M.modeRowHeight); y += M.modeRowHeight }
        // The gaps below a line are measured from the line's top.
        y += M.dividerGapBelowRows
        add(.divider, y: y, h: 1)
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
