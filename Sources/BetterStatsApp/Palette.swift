import AppKit

/// The app's colour system, in one place.
///
/// Deliberately NOT semantic NSColors for the content surfaces. macOS's semantic
/// greys assume a mid-dark window; this design commits to a true black ground with
/// saturated accents, which reads far better against a busy wallpaper and gives the
/// hatched "unattributed" fill somewhere to sit. Semantic colours are still used for
/// anything the system owns — selection rings, focus, menu chrome — so keyboard and
/// accessibility behaviour stays native.
///
/// Every value is defined for both appearances and resolved at draw time, so a
/// theme switch needs no notification handling: views just redraw.
enum Palette {

    /// `NSApp` is optional and this used to force-unwrap it, so asking for any
    /// colour before the application object existed crashed rather than answered.
    ///
    /// That was survivable only because the code paths reachable that early
    /// happened to use macOS's own inks instead of these — which is exactly the
    /// inconsistency this palette exists to stop. Moving those onto Palette turned
    /// a latent trap into a crash in the test suite, which is the good version of
    /// finding out.
    ///
    /// Falling back to `NSAppearance.currentDrawing()` rather than to a guess:
    /// inside a draw it is the appearance actually being drawn in, and outside one
    /// it is the system default. Dark is the last resort because this app is
    /// dark-first and a wrong light palette on a black ground is unreadable, where
    /// the reverse merely looks heavy.
    private static var isDark: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func pick(_ dark: NSColor, _ light: NSColor) -> NSColor {
        isDark ? dark : light
    }

    private static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green:   CGFloat((v >> 8) & 0xFF) / 255,
                blue:    CGFloat(v & 0xFF) / 255,
                alpha:   alpha)
    }

    // ── Grounds ─────────────────────────────────────────────────────────────
    /// True black behind everything. Panels lift off it rather than the ground
    /// dropping away from them — on pure black a drop shadow has nothing darker to
    /// fall onto and just reads as haze.
    static var background: NSColor { pick(hex(0x000000), hex(0xFFFFFF)) }
    static var surface:    NSColor { pick(hex(0x0A0E12), hex(0xFFFFFF)) }
    static var surfaceAlt: NSColor { pick(hex(0x141A20), hex(0xEEF3F6)) }
    static var sidebar:    NSColor { pick(hex(0x050709), hex(0xE6EDF1)) }

    // ── Ink ─────────────────────────────────────────────────────────────────
    static var text:  NSColor { pick(hex(0xFFFFFF), hex(0x000000)) }
    static var dim:   NSColor { pick(hex(0xA6BCC8), hex(0x41535E)) }
    static var faint: NSColor { pick(hex(0x6E838F), hex(0x6E838F)) }
    static var line:  NSColor { pick(hex(0x2A3A45), hex(0xC2D0D8)) }
    /// Row separators sit lighter than structural rules.
    ///
    /// 0.40, not the 0.55 this started at. The table went from five columns at a
    /// 22 pt pitch to twelve at 20 pt, and a rule under every row is then a rule
    /// every 20 pt down a very wide surface — thirty of them on screen at once.
    /// The hairline still has to be there (twelve columns is a lot of horizontal
    /// distance for the eye to hold one row across), it just has no business
    /// being the loudest thing in the table.
    static var lineSoft: NSColor { line.withAlphaComponent(0.40) }

    // ── Accents ─────────────────────────────────────────────────────────────
    static var accent: NSColor { pick(hex(0x00E5A0), hex(0x00996B)) }
    static var blue:   NSColor { pick(hex(0x2E9BFF), hex(0x0A6FD6)) }
    /// Measured process energy we cannot name. Same hue family as `accent` so it
    /// reads as "the same kind of thing, less certain".
    static var accentDim: NSColor { pick(hex(0x0A8F66), hex(0x63C4A6)) }
    /// Battery charge line on the graph's right axis. Deep blue: distinct from the
    /// GPU blue used in the ledger, and clearly a different KIND of quantity from
    /// the green rate line rather than a variation of it.
    static var chargeLine: NSColor { pick(hex(0x3D6FD6), hex(0x1E4FA8)) }
    /// The same charge line across the spans where the pack was FILLING. Green
    /// because "was it plugged in?" is the one thing people scan a charge history
    /// for, and it has to answer without a legend. A pure green, not `accent`'s
    /// mint: the drain line on the other axis wears that, and two greens on one
    /// chart must still be tellable apart at a glance.
    static var chargingLine: NSColor { pick(hex(0x36E85C), hex(0x0E8F35)) }
    /// The two categorical hues that were `NSColor.systemPurple` and
    /// `.systemTeal` — the only inks in the app that came from macOS rather than
    /// from here.
    ///
    /// System colours are tuned for macOS's own surfaces, not for this app's
    /// near-black ground, and they do not follow the light/dark pair every token
    /// beside them uses. So the ledger's memory and storage segments sat a
    /// noticeable step outside the palette they were meant to belong to, and did
    /// it differently in light mode than in dark.
    static var violet: NSColor { pick(hex(0xB07CFF), hex(0x6B34C9)) }
    static var teal:   NSColor { pick(hex(0x2BD9D9), hex(0x0F8A8A)) }

    static var warn:   NSColor { pick(hex(0xFFB020), hex(0xB37200)) }
    static var critical: NSColor { pick(hex(0xFF5252), hex(0xC62828)) }

    /// Selection wash behind a highlighted row.
    static var selection: NSColor { accent.withAlphaComponent(isDark ? 0.16 : 0.15) }
    /// The diagonal hatch that marks measured-but-unattributable energy.
    static var hatch: NSColor { pick(hex(0xA6BCC8, alpha: 0.34), hex(0x41535E, alpha: 0.30)) }
    /// Text drawn ON the accent fill.
    static var onAccent: NSColor { hex(0x05130E) }
    static var onBlue: NSColor { pick(hex(0x03121E), hex(0xFFFFFF)) }

    // ── Geometry ────────────────────────────────────────────────────────────
    /// macOS 26 corner scale — containers round more than their contents.
    enum Radius {
        static let window: CGFloat = 20
        static let card: CGFloat = 14
        static let inner: CGFloat = 10
        static let chip: CGFloat = 7
        /// Row selection. Table separators inset their ends by exactly this so the
        /// hairline stops where the selection pill's straight edge begins.
        static let row: CGFloat = 8
        /// Bars and pills only a few points tall — ledger segments, the menu bar
        /// battery, a graph's hover chip. `chip` and up are wider than the shapes
        /// themselves and would round them into lozenges, which is why these were
        /// written as bare numbers; they are still tokens, so "the small rounding"
        /// is one decision rather than four.
        static let bar: CGFloat = 2
    }

    // ── Type ────────────────────────────────────────────────────────────────
    enum Font {
        static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            .systemFont(ofSize: size, weight: weight)
        }
        /// The small-label voice: uppercase, kerned, monospaced. It names a table
        /// column, a graph axis and a Resources card, and those three are the same
        /// kind of thing — a word that labels a measurement rather than being one.
        /// Defined once so they cannot drift into three near-identical fonts,
        /// which is exactly how a header row and a chart axis stop looking related.
        static func label(_ size: CGFloat = 9.5, _ weight: NSFont.Weight = .semibold) -> NSFont {
            .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        /// Tracking for `label`. Uppercase at 9 pt sets too tight without it.
        static let labelKern: CGFloat = 0.4
    }

    /// Draw attributes for a small uppercase label — `Font.label` plus its
    /// tracking. Callers uppercase the string themselves, because only the caller
    /// knows whether the string is a label or a name (a process name must not be
    /// shouted).
    static func labelAttributes(_ color: NSColor,
                                size: CGFloat = 9.5,
                                weight: NSFont.Weight = .semibold)
        -> [NSAttributedString.Key: Any] {
        [.font: Font.label(size, weight), .foregroundColor: color, .kern: Font.labelKern]
    }
}

extension NSView {
    /// Repaint on appearance change. Views that draw from `Palette` need this
    /// because the palette resolves at draw time rather than being observed.
    func redrawOnAppearanceChange() { needsDisplay = true }
}
