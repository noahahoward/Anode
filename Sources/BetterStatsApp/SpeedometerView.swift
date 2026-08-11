import AppKit
import PowerKit

/// The speed-test dial: an arc, a big live number, and two result tiles.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// THE SCALE IS LOGARITHMIC, and that is the only interesting decision in here.
///
/// Connections people actually have span three orders of magnitude — a phone
/// tether at 3 Mbps and a fibre line at 900 Mbps are both ordinary. On a linear
/// dial the tether is a sliver indistinguishable from zero and every home
/// connection crowds into the bottom fifth, which is a dial that can only tell
/// you what you already knew. Log spacing gives 1, 10 and 100 Mbps the same room
/// as each other, so the needle MOVES for the differences a person cares about.
///
/// It ends at "100+" rather than at a number, because the top of a speed dial is
/// a claim about the fastest connection anyone might have and there is no such
/// number. Past the last tick the arc is full and the figure in the middle is the
/// answer — the dial has stopped being the readout and gone back to being
/// decoration, which is the honest thing for it to do.
final class SpeedometerView: NSView {

    /// Ticks, in Mbps. The gaps are even on screen because the scale is log.
    private static let ticks: [Double] = [0, 1, 5, 10, 20, 50, 100]

    /// Where the arc starts and ends, measured clockwise from due south. An
    /// almost-closed circle with a gap at the bottom, which is where the button
    /// and the phase label live.
    private static let startAngle: CGFloat = 215
    private static let endAngle: CGFloat = -35

    /// The live figure, or nil for "nothing measured yet" — which draws an empty
    /// dial rather than a confident zero.
    var mbps: Double? { didSet { needsDisplay = true } }
    /// Shown under the number: "Testing download…", or nothing when idle.
    var phase: String? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 18, dy: 12)
        guard box.width > 40, box.height > 40 else { return }
        let radius = min(box.width, box.height) / 2 - 14
        let centre = NSPoint(x: box.midX, y: box.midY + 6)

        drawTrack(centre: centre, radius: radius)
        if let mbps { drawFill(centre: centre, radius: radius, mbps: mbps) }
        drawTicks(centre: centre, radius: radius)
        drawReadout(centre: centre, radius: radius)
    }

    // ── The arc ─────────────────────────────────────────────────────────────

    private func drawTrack(centre: NSPoint, radius: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: Self.startAngle, endAngle: Self.endAngle, clockwise: true)
        path.lineWidth = 12
        path.lineCapStyle = .round
        Palette.surfaceAlt.setStroke()
        path.stroke()
    }

    private func drawFill(centre: NSPoint, radius: CGFloat, mbps: Double) {
        let f = Self.fraction(forMbps: mbps)
        guard f > 0.001 else { return }
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: Self.startAngle,
                       endAngle: Self.angle(at: f), clockwise: true)
        path.lineWidth = 12
        path.lineCapStyle = .round
        Palette.accent.setStroke()
        path.stroke()

        // The head of the arc, so the eye has something to track while it moves.
        let head = Self.point(centre: centre, radius: radius, fraction: f)
        let dot = NSBezierPath(ovalIn: NSRect(x: head.x - 6, y: head.y - 6, width: 12, height: 12))
        Palette.background.setFill(); dot.fill()
        Palette.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: head.x - 4.5, y: head.y - 4.5,
                                    width: 9, height: 9)).fill()
    }

    private func drawTicks(centre: NSPoint, radius: CGFloat) {
        let font = Palette.Font.sans(10)
        for (i, tick) in Self.ticks.enumerated() {
            let f = Self.fraction(forMbps: tick)
            let at = Self.point(centre: centre, radius: radius + 16, fraction: f)
            let last = i == Self.ticks.count - 1
            let text = last ? "\(Int(tick))+" : "\(Int(tick))"
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: Palette.dim,
            ])
            let size = attributed.size()
            attributed.draw(at: NSPoint(x: at.x - size.width / 2, y: at.y - size.height / 2))
        }
    }

    private func drawReadout(centre: NSPoint, radius: CGFloat) {
        let number: String
        let unit: String
        if let mbps {
            // One decimal, like every other speed test — the second decimal is
            // noise on a measurement whose run-to-run spread is percent-scale.
            number = String(format: "%.1f", mbps)
            unit = "Megabits per second"
        } else {
            number = "—"
            unit = "not measured"
        }

        let big = NSAttributedString(string: number, attributes: [
            .font: Palette.Font.sans(38, .medium), .foregroundColor: Palette.text,
        ])
        let bigSize = big.size()
        big.draw(at: NSPoint(x: centre.x - bigSize.width / 2, y: centre.y - bigSize.height / 3))

        let small = NSAttributedString(string: unit, attributes: [
            .font: Palette.Font.sans(10.5), .foregroundColor: Palette.dim,
        ])
        let smallSize = small.size()
        small.draw(at: NSPoint(x: centre.x - smallSize.width / 2,
                               y: centre.y - bigSize.height / 3 - smallSize.height - 4))

        if let phase, !phase.isEmpty {
            let p = NSAttributedString(string: phase, attributes: [
                .font: Palette.Font.sans(11), .foregroundColor: Palette.dim,
            ])
            let ps = p.size()
            p.draw(at: NSPoint(x: centre.x - ps.width / 2, y: centre.y - radius * 0.62))
        }
    }

    // ── The log scale, as arithmetic ────────────────────────────────────────

    /// Where a rate sits on the dial, 0 at the start of the arc and 1 at the end.
    ///
    /// Log-spaced between the first non-zero tick and the last, with everything
    /// below the first tick compressed into the first segment so that "very slow"
    /// still has somewhere to be. Exposed for tests: a dial whose scale is wrong
    /// is wrong quietly, in a way no screenshot review catches.
    static func fraction(forMbps mbps: Double) -> Double {
        guard mbps.isFinite, mbps > 0 else { return 0 }
        let ticks = SpeedometerView.ticks
        guard let top = ticks.last, top > 0 else { return 0 }
        // Segment index for the tick below this value.
        let positive = ticks.filter { $0 > 0 }
        guard let first = positive.first else { return 0 }
        // Each interval between ticks gets an equal share of the arc, and within
        // an interval the position is log-interpolated. Equal shares are what
        // makes 1→5 as legible as 50→100.
        let share = 1.0 / Double(ticks.count - 1)
        if mbps <= first { return share * (mbps / first) }
        for i in 1..<(ticks.count - 1) {
            let lo = ticks[i], hi = ticks[i + 1]
            if mbps <= hi {
                let within = (log(mbps) - log(lo)) / (log(hi) - log(lo))
                return min(1, share * (Double(i) + within))
            }
        }
        return 1
    }

    private static func angle(at fraction: Double) -> CGFloat {
        startAngle + (endAngle - startAngle) * CGFloat(min(max(fraction, 0), 1))
    }

    private static func point(centre: NSPoint, radius: CGFloat, fraction: Double) -> NSPoint {
        let radians = angle(at: fraction) * .pi / 180
        return NSPoint(x: centre.x + cos(radians) * radius,
                       y: centre.y + sin(radians) * radius)
    }
}

/// One of the two result squares under the dial.
final class SpeedTileView: NSView {

    private let valueLabel = NSTextField(labelWithString: "—")
    private let captionLabel = NSTextField(labelWithString: "")

    init(caption: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        captionLabel.stringValue = caption
        valueLabel.font = Palette.Font.sans(24, .medium)
        valueLabel.alignment = .center
        captionLabel.font = Palette.Font.sans(10.5)
        captionLabel.alignment = .center

        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// nil is a dash, never a zero. An unmeasured connection is not a stopped
    /// one, and this app says so everywhere else.
    var mbps: Double? {
        didSet {
            valueLabel.stringValue = mbps.map { String(format: "%.1f", $0) } ?? "—"
            restyle()
        }
    }

    override func viewDidChangeEffectiveAppearance() { restyle() }

    private func restyle() {
        valueLabel.textColor = mbps == nil ? Palette.dim : Palette.text
        captionLabel.textColor = Palette.dim
        needsDisplay = true
    }
}
