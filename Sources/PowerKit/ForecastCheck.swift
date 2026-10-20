import Foundation

/// Checks the time-left forecast against what the battery actually did.
///
/// Every stored interval carries the time left Anode was showing. A prediction of
/// `P` seconds made at charge `S0` claims the pack falls linearly to zero over
/// `P`, so `h` seconds later it should read `S0 · (1 − h/P)`. Drawing that claim
/// at the moment it comes due, beside the level really measured then, gives two
/// lines that coincide exactly when the forecast was right: below the actual
/// line means it predicted too little time left, above means too much.
///
/// Linear in charge, deliberately, although `timeToEmpty` applies a small
/// constant-power correction: the horizon is an hour or two, over which that
/// correction moves the answer by well under a percentage point.
public enum ForecastCheck {

    public struct Sample {
        public let time: Date
        public let socPercent: Double?
        public let predictedSeconds: Double?
        public let shownPctHr: Double?
        /// The load-following time left stored beside the headline, checked the
        /// same way. nil on rows recorded before it existed.
        public let paceSeconds: Double?
        public init(time: Date, socPercent: Double?, predictedSeconds: Double?,
                    shownPctHr: Double?, paceSeconds: Double? = nil) {
            self.time = time
            self.socPercent = socPercent
            self.predictedSeconds = predictedSeconds
            self.shownPctHr = shownPctHr
            self.paceSeconds = paceSeconds
        }
    }

    public struct Point: Equatable {
        public let time: Date
        public let value: Double
    }

    public struct Result {
        /// Measured battery level.
        public let actualLevel: [Point]
        /// The level each prediction said the battery would be at, drawn when due.
        public let predictedLevel: [Point]
        /// %/hr the level actually fell over the trailing `drainWindow`.
        public let actualDrain: [Point]
        /// %/hr the app divided by — the average drain it was showing.
        public let shownDrain: [Point]
        /// Mean of predicted − actual level, in percentage points, over every
        /// moment both exist. Negative: the forecast gave too little time.
        public let meanErrorPoints: Double?
        /// The same error as a share of the time the prediction had left to run
        /// out, which is what a user feels: "it said 5 h and it lasted 6".
        public let meanErrorFraction: Double?
        /// The same two, for the load-following forecast.
        public let paceLevel: [Point]
        public let paceErrorFraction: Double?
    }

    /// How far a sample may sit from the moment it is looked up for. Stored rows
    /// are ~60 s apart while hidden and buckets get wider over long ranges, so the
    /// callers pass something like two bucket widths.
    public static func evaluate(_ samples: [Sample], horizon: TimeInterval,
                                drainWindow: TimeInterval = 1800,
                                tolerance: TimeInterval) -> Result {
        let s = samples.sorted { $0.time < $1.time }
        let levels = s.compactMap { x in x.socPercent.map { Point(time: x.time, value: $0) } }

        func nearest(_ t: Date, in pts: [Sample]) -> Sample? {
            var lo = 0, hi = pts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pts[mid].time < t { lo = mid + 1 } else { hi = mid }
            }
            let near = [lo - 1, lo].filter { $0 >= 0 && $0 < pts.count }
                .min { abs(pts[$0].time.timeIntervalSince(t)) < abs(pts[$1].time.timeIntervalSince(t)) }
            guard let i = near, abs(pts[i].time.timeIntervalSince(t)) <= tolerance else { return nil }
            return pts[i]
        }

        /// One forecast, checked: the level it said the pack would be at when each
        /// prediction came due, and its mean error. Run once per forecast so the
        /// headline and the load-following figure are scored by the same rule.
        func check(_ seconds: (Sample) -> Double?)
            -> (level: [Point], points: Double?, fraction: Double?) {
            var predicted: [Point] = []
            var errPts: [Double] = [], errFrac: [Double] = []
            for x in s {
                guard let then = nearest(x.time.addingTimeInterval(-horizon), in: s),
                      let s0 = then.socPercent, let p = seconds(then), p > 0 else { continue }
                let elapsed = x.time.timeIntervalSince(then.time)
                guard elapsed > 0 else { continue }
                let level = max(0, s0 * (1 - elapsed / p))
                predicted.append(Point(time: x.time, value: level))
                guard let actual = x.socPercent, s0 > actual else { continue }
                errPts.append(level - actual)
                // Time the pack really took per point, projected across all of s0,
                // against what was predicted: < 0 when it lasted longer than said.
                let actualLife = elapsed * s0 / (s0 - actual)
                errFrac.append((p - actualLife) / actualLife)
            }
            func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
            return (predicted, mean(errPts), mean(errFrac))
        }
        let headline = check { $0.predictedSeconds }
        let pace = check { $0.paceSeconds }

        var drain: [Point] = []
        for x in s {
            guard let now = x.socPercent,
                  let back = nearest(x.time.addingTimeInterval(-drainWindow), in: s),
                  let then = back.socPercent else { continue }
            let hours = x.time.timeIntervalSince(back.time) / 3600
            guard hours > 0 else { continue }
            drain.append(Point(time: x.time, value: max(0, (then - now) / hours)))
        }

        let shown = s.compactMap { x in x.shownPctHr.map { Point(time: x.time, value: $0) } }
        return Result(actualLevel: levels, predictedLevel: headline.level,
                      actualDrain: drain, shownDrain: shown,
                      meanErrorPoints: headline.points, meanErrorFraction: headline.fraction,
                      paceLevel: pace.level, paceErrorFraction: pace.fraction)
    }
}
