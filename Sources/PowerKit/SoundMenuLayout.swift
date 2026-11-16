import CoreGraphics

/// Where every part of the Sound menu goes, from the model: a pure flow down the panel, measured against macOS's.
public enum SoundMenuLayout {

    public enum RowKind: Equatable {
        case title
        case volumeSlider
        case divider
        case heading(String)
        case device(Int)
        case choice(section: String, index: Int)
        /// The lighter block under an opened device.
        case block
        case footer(Int)
        /// A line of Anode's own, only when there is something to say.
        case notice
    }

    public struct LaidOutRow: Equatable {
        public var kind: RowKind
        public var frame: CGRect
    }

    public struct Result: Equatable {
        public var rows: [LaidOutRow]
        public var height: CGFloat
    }

    public static func frames(for model: SoundMenuModel) -> Result {
        typealias M = SoundMenuMetrics
        var rows: [LaidOutRow] = []
        func add(_ kind: RowKind, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
            rows.append(LaidOutRow(kind: kind, frame: CGRect(x: x, y: y, width: w, height: h)))
        }
        add(.title, x: M.sideInset, y: M.titleY, w: M.width - 2 * M.sideInset, h: M.titleHeight)
        add(.volumeSlider, x: M.sliderX, y: M.sliderY, w: M.sliderWidth, h: M.sliderHeight)
        add(.divider, x: M.sideInset, y: M.firstDividerY, w: M.width - 2 * M.sideInset, h: 1)
        add(.heading("Output"), x: M.sideInset, y: M.outputHeadingY, w: M.width - 2 * M.sideInset, h: M.headingHeight)

        var y = M.deviceRowsY
        for (i, device) in model.devices.enumerated() {
            add(.device(i), x: M.rowInset, y: y, w: M.rowWidth, h: M.deviceRowHeight)
            y += M.deviceRowHeight
            guard device.name == model.expandedDevice else { continue }
            let blockTop = y + M.blockGap
            var by = blockTop + M.blockTopPadding
            let sections: [(String, [AppleChoiceRow])] = [(AppleSoundPanel.listeningHeading, model.listening),
                                                           (AppleSoundPanel.spatialHeading, model.spatial),
                                                           (AppleSoundPanel.conversationHeading, model.conversation)].filter { !$0.1.isEmpty }
            var inner: [LaidOutRow] = []
            for (n, (title, choices)) in sections.enumerated() {
                inner.append(LaidOutRow(kind: .heading(title), frame: CGRect(x: M.sideInset, y: by, width: M.width - 2 * M.sideInset, height: M.headingHeight)))
                var ry = by + M.blockHeadingToRows
                for c in choices.indices {
                    inner.append(LaidOutRow(kind: .choice(section: title, index: c),
                                            frame: CGRect(x: M.rowInset, y: ry, width: M.rowWidth, height: M.choiceRowHeight)))
                    ry += M.choiceRowPitch
                }
                let lastBottom = ry - M.choiceRowPitch + M.choiceRowHeight
                if n < sections.count - 1 {
                    let dividerY = lastBottom + M.dividerGapBelowRows
                    inner.append(LaidOutRow(kind: .divider, frame: CGRect(x: M.rowInset, y: dividerY, width: M.rowWidth, height: 1)))
                    by = dividerY + M.headingGapBelowDivider
                } else {
                    by = lastBottom
                }
            }
            let blockBottom = by + M.blockBottomPadding
            rows.append(LaidOutRow(kind: .block, frame: CGRect(x: 0, y: blockTop, width: M.width, height: blockBottom - blockTop)))
            rows += inner
            y = blockBottom + M.afterBlockGap
        }

        if model.notice != nil {
            add(.notice, x: M.sideInset, y: y + M.noticeGap, w: M.width - 2 * M.sideInset, h: M.noticeHeight)
            y += M.noticeGap + M.noticeHeight
        }
        let dividerY = y + M.footerDividerGap
        add(.divider, x: M.sideInset, y: dividerY, w: M.width - 2 * M.sideInset, h: 1)
        var fy = dividerY + M.footerFirstRowGap
        for i in model.footerTitles.indices {
            add(.footer(i), x: M.sideInset, y: fy, w: M.width - 2 * M.sideInset, h: M.footerRowHeight)
            fy += M.footerRowPitch
        }
        let height = fy - M.footerRowPitch + M.footerRowHeight + M.bottomPadding
        return Result(rows: rows, height: height)
    }
}
