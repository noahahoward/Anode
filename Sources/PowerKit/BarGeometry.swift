import Foundation
import CoreGraphics

// ── Where the covers and the pill go (Menu Bar Hider) ───────────────────────

public enum CoverPlanner {

    /// The rectangles to cover, in top-left screen points: one per maximal run of on-bar items the owner put behind the
    /// chevron. An item that stays on the bar (pinned, or locked like the clock) between two hidden ones splits the run, so it
    /// is left showing in a gap between two covers: macOS decides the order and Anode cannot move other apps' icons. A cover
    /// never extends over a neighbour that stays. Items off the bar (parked, zero-sized) are not covered, they are not drawn.
    public static func covers(items: [BarItem], arrangement: BarArrangement, screen: CGRect, pad: CGFloat = 3) -> [CGRect] {
        let onBar = items.filter { $0.isOnBar(screens: [screen]) }.sorted { $0.frame.minX < $1.frame.minX }
        guard !onBar.isEmpty else { return [] }
        let top = screen.minY
        let bottom = max(onBar.map { $0.frame.maxY }.max() ?? top, top)

        var rects: [CGRect] = []
        var run: [BarItem] = []
        var leftLimit = screen.minX      // the right edge of the last item that stays, or the screen edge

        func flush(rightLimit: CGFloat) {
            guard let first = run.first, let last = run.last else { return }
            let lo = max(first.frame.minX - pad, leftLimit, screen.minX)
            let hi = min(last.frame.maxX + pad, rightLimit, screen.maxX)
            if hi > lo { rects.append(CGRect(x: lo, y: top, width: hi - lo, height: bottom - top)) }
            run.removeAll()
        }

        for item in onBar {
            if arrangement.group(of: item.key, items: items) == .behindChevron {
                run.append(item)
            } else {
                flush(rightLimit: item.frame.minX)
                leftLimit = item.frame.maxX
            }
        }
        flush(rightLimit: screen.maxX)
        return rects
    }
}

public enum PillLayout {

    /// Cells laid left to right in rows, wrapping when the next cell would pass `maxWidth` (padding included); at least one
    /// cell sits on every row. Frames are in the pill's own space, origin top-left. With no cells the size is padding only.
    public static func frames(count: Int, cell: CGSize, maxWidth: CGFloat, padding: CGFloat,
                              spacing: CGFloat) -> (cells: [CGRect], size: CGSize) {
        guard count > 0 else { return ([], CGSize(width: 2 * padding, height: 2 * padding)) }
        let inner = max(maxWidth - 2 * padding, cell.width)
        let perRow = max(1, Int((inner + spacing) / (cell.width + spacing)))
        var cells: [CGRect] = []
        for i in 0..<count {
            let row = i / perRow, col = i % perRow
            cells.append(CGRect(x: padding + CGFloat(col) * (cell.width + spacing),
                                y: padding + CGFloat(row) * (cell.height + spacing),
                                width: cell.width, height: cell.height))
        }
        let rows = (count + perRow - 1) / perRow
        let cols = min(count, perRow)
        let width = 2 * padding + CGFloat(cols) * cell.width + CGFloat(cols - 1) * spacing
        let height = 2 * padding + CGFloat(rows) * cell.height + CGFloat(rows - 1) * spacing
        return (cells, CGSize(width: width, height: height))
    }

    /// The pill's top-left corner: centred on the notch (or the screen when there is none), just under the menu bar, and
    /// kept inside the screen.
    public static func origin(size: CGSize, screen: CGRect, notch: CGRect?, menuBarHeight: CGFloat, gap: CGFloat = 4) -> CGPoint {
        let centre = notch?.midX ?? screen.midX
        let x = min(max(centre - size.width / 2, screen.minX), max(screen.minX, screen.maxX - size.width))
        return CGPoint(x: x, y: screen.minY + menuBarHeight + gap)
    }
}
