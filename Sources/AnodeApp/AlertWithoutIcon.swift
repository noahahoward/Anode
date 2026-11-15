import AppKit

/// An alert with no icon, its text across the whole width.
///
/// `NSAlert` always draws an icon (the app's, when it is given none) in a column of its own to the left of the text,
/// and keeps that column when the icon is blank. A notice with three paragraphs in it, like the helper's, was left
/// with the app's logo beside a narrow block of text. An alert may be laid out and then changed (`NSAlert.layout()`
/// is there for that), so this lays it out, hides the icon, and moves what stood in the text column to where the icon
/// began; text that wraps is widened by the icon's column and made no taller than it then needs, and the window
/// shrinks by what that saved.
///
/// It goes by the alert's geometry and by public classes only (an image view, buttons, text fields). An alert that
/// is not built the way this expects is left exactly as `layout()` made it.
enum AlertWithoutIcon {

    /// Call last, after the texts, the buttons and any accessory view are set: nothing may be added afterwards.
    /// True when the icon was taken away.
    @discardableResult
    static func apply(to alert: NSAlert) -> Bool {
        // Nothing is drawn where the icon was, also if the rest of this finds an alert it does not know.
        alert.icon = NSImage(size: NSSize(width: 1, height: 1))
        alert.layout()
        let window = alert.window
        guard let content = window.contentView, !content.isFlipped,
              let icon = content.subviews.first(where: { $0 is NSImageView }) else { return false }
        // What stands to the right of the icon and is not a button: the two texts, and an accessory view.
        let column = content.subviews.filter { $0 !== icon && !($0 is NSButton) && $0.frame.minX >= icon.frame.maxX }
        guard let columnLeft = column.map(\.frame.minX).min() else { return false }
        let gain = columnLeft - icon.frame.minX
        guard gain > 0 else { return false }
        icon.isHidden = true
        // From the bottom up: a text that needs fewer lines when it is wider keeps its foot where it is, and what is
        // above it comes down by as much.
        var saved: CGFloat = 0
        for view in column.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            var frame = view.frame
            frame.origin.x -= gain
            frame.origin.y -= saved
            if let text = view as? NSTextField, text.cell?.wraps == true {
                frame.size.width += gain
                let needed = ceil(text.sizeThatFits(NSSize(width: frame.width, height: 10_000)).height)
                if needed > 0, needed < frame.height {
                    saved += frame.height - needed
                    frame.size.height = needed
                }
            }
            view.frame = frame
        }
        if saved > 0 {
            var outer = window.frame
            outer.size.height -= saved
            window.setFrame(outer, display: false)
        }
        return true
    }
}
