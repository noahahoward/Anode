import AppKit
import PowerKit

// ── The "Possible Memory Leak" badge in the Processes table ─────────────────
//
// When Memory Watch has flagged an app (or a tool) as a possible leak, its row shows a small red button to the right of the
// last column. Pressing it opens the same window clicking the notification opens.
//
// Nothing here runs on its own: the badge is worked out from the table's existing refresh (while the window is on screen),
// and when Memory Watch is off the controller has no findings, so the work is one empty-array check.

enum LeakBadge {

    static let columnID = "leakBadge"
    static let title = "⚠️ Possible Memory Leak"
    static let font = NSFont.systemFont(ofSize: 11)

    /// Wide enough for the title at `font`, measured once.
    static let columnWidth: CGFloat = {
        ceil((LeakBadge.title as NSString).size(withAttributes: [.font: LeakBadge.font]).width) + 14
    }()

    // ── Seams (tests replace these; the defaults are the real thing) ────────

    /// The findings to match rows against, newest first.
    static var findings: () -> [Finding] = { MemoryWatchController.current?.findings ?? [] }

    /// What pressing the badge does: exactly what a click on the notification does.
    static var openLeak: (Finding) -> Void = { finding in
        MemoryWatchController.current?.open(windowKey: finding.windowKey)
    }

    /// Whether the flagged process still deserves the badge: it is still running (the pid is read and its start time must
    /// be the flagged one, so a pid the system has handed to another process does not count) and its memory has not fallen
    /// back (`Finding.hasRecovered`: a leak that goes back down was not one). One cheap call.
    static var isAlive: (Finding) -> Bool = { finding in
        guard let now = ProcessSampler.footprint(of: finding.pid), now.start == finding.processKey.startAbsTime else { return false }
        return !finding.hasRecovered(currentBytes: now.footprint)
    }

    // ── Matching ────────────────────────────────────────────────────────────

    /// The leak finding for this row, if any. Only a leak (fast or slow) counts, never the high-memory warning; an app row
    /// matches by its outermost bundle path, a tool row by process id (tools are grouped by NAME, so the name alone would
    /// tie every `node` on the Mac to one finding); the process must still be running; the newest matching finding wins.
    ///
    /// `isAlive` is asked only about findings that match the row, and not at all when there are none.
    static func leakFinding(for row: Row, among findings: [Finding],
                            isAlive: (Finding) -> Bool) -> Finding? {
        guard !findings.isEmpty, let app = row.app else { return nil }

        var matches: [(index: Int, finding: Finding)] = []
        for (index, finding) in findings.enumerated() where finding.tier != .pressure {
            let isThisRow: Bool
            if app.isApp {
                if let bundle = app.identity.bundlePath {
                    isThisRow = finding.isApp && finding.identityKey == bundle
                } else {
                    isThisRow = false
                }
            } else {
                isThisRow = !finding.isApp && app.pids.contains(finding.pid)
            }
            if isThisRow { matches.append((index, finding)) }
        }
        guard !matches.isEmpty else { return nil }

        // Newest first; on a tie the one listed first (the controller lists newest first).
        matches.sort {
            $0.finding.flaggedAtWall != $1.finding.flaggedAtWall
                ? $0.finding.flaggedAtWall > $1.finding.flaggedAtWall
                : $0.index < $1.index
        }
        return matches.first { isAlive($0.finding) }?.finding
    }

    // ── The column ──────────────────────────────────────────────────────────

    /// The trailing column, hidden until a row needs it. It carries no sort descriptor (clicking its header does nothing)
    /// and is not one of `ProcessColumns.all`, so the sorter, the column sizer and the header tooltips never see it.
    static func makeColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnID))
        column.headerCell = AnodeHeaderCell(textCell: "")
        column.title = ""
        column.width = columnWidth
        column.minWidth = columnWidth
        column.maxWidth = columnWidth
        column.resizingMask = []
        column.isHidden = true
        return column
    }
}

// MARK: Which rows have a badge

/// Works out, once per table refresh, which rows carry a badge.
final class LeakBadgeTracker {

    private(set) var hasBadges = false

    /// Kept on the row itself, so a row that is replaced loses its badge with it.
    func finding(for row: Row) -> Finding? { row.leakFinding }

    /// Re-evaluates every row and answers whether any has a badge. With no findings (Memory Watch off, or nothing flagged)
    /// this is one call returning an empty list and nothing else. Whether each flagged process still runs is read once per
    /// finding, however many rows ask.
    @discardableResult
    func update(rows: [Row]) -> Bool {
        hasBadges = false
        let findings = LeakBadge.findings()
        guard !findings.isEmpty else {
            for row in rows where row.leakFinding != nil { row.leakFinding = nil }
            return false
        }

        let read = LeakBadge.isAlive
        var alive: [ProcessKey: Bool] = [:]
        let isAlive: (Finding) -> Bool = { finding in
            if let known = alive[finding.processKey] { return known }
            let answer = read(finding)
            alive[finding.processKey] = answer
            return answer
        }
        for row in rows {
            let finding = LeakBadge.leakFinding(for: row, among: findings, isAlive: isAlive)
            row.leakFinding = finding
            if finding != nil { hasBadges = true }
        }
        return hasBadges
    }
}

// MARK: The cell

/// Gives the pointing hand over the badge.
final class LeakBadgeButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// One cell of the badge column: a borderless red button, or nothing at all.
final class LeakBadgeCellView: NSView {

    let button = LeakBadgeButton()
    private(set) var finding: Finding?
    private var tint: NSColor?

    private static let inset: CGFloat = 4

    init() {
        super.init(frame: .zero)
        button.title = LeakBadge.title
        button.isBordered = false
        button.alignment = .left
        button.font = LeakBadge.font
        button.imagePosition = .noImage
        button.target = self
        button.action = #selector(pressed)
        button.isHidden = true
        // Positioned by hand like `ProcessCellView`'s label, so the table's refresh never solves constraints for it.
        button.translatesAutoresizingMaskIntoConstraints = true
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the badge for `finding`, or hides it when the row has none.
    func configure(finding: Finding?, name: String) {
        self.finding = finding
        guard finding != nil else {
            if !button.isHidden { button.isHidden = true }
            return
        }
        let colour = Palette.critical
        if tint?.isEqual(colour) != true {
            tint = colour
            button.attributedTitle = NSAttributedString(
                string: LeakBadge.title,
                attributes: [.font: LeakBadge.font, .foregroundColor: colour])
        }
        let label = "Possible memory leak in \(name). Opens its details."
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.isHidden { button.isHidden = false }
        needsLayout = true
    }

    @objc private func pressed() {
        guard let finding else { return }
        LeakBadge.openLeak(finding)
    }

    override func layout() {
        super.layout()
        let height = ceil(button.intrinsicContentSize.height)
        button.frame = NSRect(x: Self.inset,
                              y: ((bounds.height - height) / 2).rounded(),
                              width: max(0, bounds.width - Self.inset),
                              height: height)
    }
}
