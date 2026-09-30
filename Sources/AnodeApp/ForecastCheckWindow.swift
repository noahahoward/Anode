import AppKit
import PowerKit

/// Developer view: was the time-left forecast right?
///
/// Top graph, battery level: the measured line, and the level each prediction
/// said the battery would be at, drawn when it came due (see `ForecastCheck`).
/// They coincide when the forecast was right; the forecast line sits below the
/// measured one when it gave too little time left.
///
/// Bottom graph, drain: how fast the level actually fell, against the average
/// the app was dividing by. A gap here is the reason for a gap above.
final class ForecastCheckWindowController: NSWindowController {

    private let store: HistoryStore
    private let levelGraph = HistoryGraphView()
    private let drainGraph = HistoryGraphView()
    private let range = NSPopUpButton()
    private let horizon = NSSegmentedControl(labels: ["30 min", "1 hr", "2 hr"],
                                             trackingMode: .selectOne, target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")

    private static let ranges: [(String, TimeInterval?)] = [
        ("Last discharge", nil), ("Last 24 hours", 86_400), ("Last 7 days", 7 * 86_400),
    ]
    private static let horizons: [TimeInterval] = [1800, 3600, 7200]

    init(store: HistoryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Forecast Check"
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.background.cgColor

        range.addItems(withTitles: Self.ranges.map(\.0))
        range.target = self
        range.action = #selector(reload)
        horizon.selectedSegment = 1
        horizon.target = self
        horizon.action = #selector(reload)
        summary.textColor = Palette.text
        summary.font = .systemFont(ofSize: 12)
        summary.lineBreakMode = .byTruncatingTail

        let horizonLabel = NSTextField(labelWithString: "Prediction made")
        horizonLabel.textColor = Palette.faint
        let aheadLabel = NSTextField(labelWithString: "ahead")
        aheadLabel.textColor = Palette.faint
        let controls = NSStackView(views: [range, horizonLabel, horizon, aheadLabel, summary])
        controls.spacing = 10
        controls.setCustomSpacing(18, after: range)
        controls.setCustomSpacing(18, after: aheadLabel)

        levelGraph.yAxisLabel = "% battery"
        levelGraph.yMax = 100
        drainGraph.yAxisLabel = "%/hr"

        let stack = NSStackView(views: [controls, levelGraph, drainGraph])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            levelGraph.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            drainGraph.widthAnchor.constraint(equalTo: levelGraph.widthAnchor),
            drainGraph.heightAnchor.constraint(equalTo: levelGraph.heightAnchor, multiplier: 0.7),
        ])
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reload()
    }

    @objc private func reload() {
        let span = Self.ranges[max(0, range.indexOfSelectedItem)].1
        let ahead = Self.horizons[max(0, horizon.selectedSegment)]
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Date()
            let start = span.map { now.addingTimeInterval(-$0) }
                ?? store.lastUnplug(before: now) ?? now.addingTimeInterval(-86_400)
            let pts = store.forecastSeries(since: start, until: now, maxPoints: 700)
            // Two bucket widths, and never under the ~60 s hidden-tick cadence.
            let width = now.timeIntervalSince(start) / 700
            let samples = pts.filter(\.onBattery).map {
                ForecastCheck.Sample(time: $0.time, socPercent: $0.socPercent,
                                     predictedSeconds: $0.predictedSeconds,
                                     shownPctHr: $0.shownPctHr)
            }
            let r = ForecastCheck.evaluate(samples, horizon: ahead,
                                           tolerance: max(150, 2 * width))
            DispatchQueue.main.async { self.apply(r, start: start, end: now, ahead: ahead) }
        }
    }

    private func apply(_ r: ForecastCheck.Result, start: Date, end: Date, ahead: TimeInterval) {
        func pts(_ p: [ForecastCheck.Point]) -> [HistoryGraphView.Point] {
            p.map { .init(time: $0.time, value: $0.value) }
        }
        let aheadText = ahead >= 3600 ? "\(Int(ahead / 3600)) hr" : "\(Int(ahead / 60)) min"
        levelGraph.timeDomain = (start, end)
        drainGraph.timeDomain = (start, end)
        levelGraph.series = [
            .init(name: "actual battery", color: Palette.chargeLine,
                  points: pts(r.actualLevel), filled: true),
            .init(name: "predicted \(aheadText) earlier", color: Palette.drainTrendLine,
                  points: pts(r.predictedLevel)),
        ]
        drainGraph.series = [
            .init(name: "actual drain", color: Palette.accent, points: pts(r.actualDrain)),
            .init(name: "average drain used", color: Palette.violet, points: pts(r.shownDrain)),
        ]
        if let pct = r.meanErrorFraction, let points = r.meanErrorPoints {
            let direction = pct < 0 ? "too little time left" : "too much time left"
            summary.stringValue = String(format: "Forecast gave %@ by %.0f%% on average (%+.1f points)",
                                         direction, abs(pct) * 100, points)
        } else {
            summary.stringValue = "No stored predictions in this range yet — "
                + "they are recorded from this build on, while on battery."
        }
    }
}
