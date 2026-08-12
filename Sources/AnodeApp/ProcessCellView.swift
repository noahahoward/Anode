import AppKit

/// One cell of the process table: a single label, positioned by hand.
///
/// It exists because of what Auto Layout costs at this cadence. The table
/// refreshes every two seconds, and setting `stringValue` invalidates a text
/// field's intrinsic content size — so three constraints per cell, across eight
/// columns and every visible row, were re-solved on every tick. Profiled with
/// `sample`, that constraint pass was the single largest thing the app did:
/// 943 samples inside the window's layout observer, against 73 for the entire
/// sampling queue behind it.
///
/// There is nothing here Auto Layout was buying. The label is pinned to fixed
/// insets and centred vertically, which is three lines of arithmetic against a
/// bounds rectangle. `layout()` runs on geometry change rather than on every
/// text change, so the per-tick cost of a new string is drawing it and nothing
/// else.
final class ProcessCellView: NSTableCellView {

    /// Matches the constraint constants this replaced, so no row moves a pixel.
    private let leadingInset: CGFloat
    private static let trailingInset: CGFloat = 4

    init(leadingInset: CGFloat, alignment: NSTextAlignment) {
        self.leadingInset = leadingInset
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: "")
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        // The whole point: this view owns the frame, so the engine never sees it.
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let label = textField else { return }
        // A bare NSTextField sits at the top of its cell, so every row read as
        // riding high against its own separator. Centring is the fix, and the
        // height centred is the label's intrinsic one — the exact quantity the
        // `centerYAnchor` constraint used, so no row moves by a pixel. For a
        // single-line label it depends on the font and not on the string, so it
        // is stable across a text change and this only re-runs on geometry.
        let height = label.intrinsicContentSize.height
        let width = max(0, bounds.width - leadingInset - Self.trailingInset)
        label.frame = NSRect(x: leadingInset,
                             y: ((bounds.height - height) / 2).rounded(),
                             width: width,
                             height: height)
    }

    /// The font is what decides the label's height, so a change to it has to
    /// re-run the arithmetic above — nothing else invalidates layout here.
    func setFont(_ font: NSFont) {
        guard textField?.font != font else { return }
        textField?.font = font
        needsLayout = true
    }
}
