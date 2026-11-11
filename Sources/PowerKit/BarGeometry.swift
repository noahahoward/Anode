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
