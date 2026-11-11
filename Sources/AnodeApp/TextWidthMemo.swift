import AppKit

/// What a string measures at a font, remembered.
///
/// Typesetting is the cost of `NSString.size(withAttributes:)`, and the process table asks the same questions every
/// tick: a process name does not change between two ticks and a figure takes few distinct values. In a 40 s profile of
/// the open window, 241 ms of ~2,800 ms was `autosizeColumns` measuring text it had measured two seconds before.
///
/// The font is part of the key (fonts come from `Palette.Font`, which hands out one shared instance per size and
/// weight, so equal fonts compare equal cheaply). The memo is bounded: process names are unbounded over a long run,
/// and what is worth keeping is what the screen has shown recently.
struct TextWidthMemo {

    private struct Key: Hashable {
        let text: String
        let font: NSFont
    }

    static let limit = 4096

    private var memo: [Key: CGFloat] = [:]

    /// How many measurements are held. For tests.
    var count: Int { memo.count }

    mutating func width(of text: String, in font: NSFont) -> CGFloat {
        let key = Key(text: text, font: font)
        if let known = memo[key] { return known }
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        if memo.count >= Self.limit { memo.removeAll(keepingCapacity: true) }
        memo[key] = measured
        return measured
    }
}
