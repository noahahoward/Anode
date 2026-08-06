import Foundation
import PowerKit

/// Bridge from the measurement stack to the drill-down view.
///
/// Lives apart from AppDetailView.swift on purpose: the view stays PowerKit-free so
/// it can be built and offscreen-rendered standalone, and this file owns the one
/// decision that matters — WHICH totals the two share figures divide by.
extension AppDetailView.Model {

    /// Build the drill-down model for one app out of a snapshot.
    ///
    /// Denominator choices, deliberately different and deliberately labelled:
    ///   - shareOfAttributed divides by `snapshot.attributed_W`: the sum of every
    ///     app row. Same-uid CPU + nothing else — an UNDER-count (~63% of pids are
    ///     readable; WindowServer and all root daemons are not).
    ///   - shareOfMeasured divides by a whole-machine MEASUREMENT: the battery gas
    ///     gauge when a 60 s batch has published (authoritative mean), else
    ///     gain-corrected SMC PSTR (live, validated against the gauge), else nil.
    ///     Never the smoothed display figure — that mixes estimate into what this
    ///     view promises is measured.
    /// The two shares differ a lot (attributed is often <15% of measured); showing
    /// one number without saying which denominator it uses is the exact dishonesty
    /// this project exists to avoid.
    public init(app: AppDrain, snapshot: PowerMonitor.Snapshot) {
        // Match by pid: AppDrain.pids came from this same snapshot's drains, so
        // set-membership is exact. Rows exist only for processes that drew
        // measurable energy THIS interval — an idle helper has no row, which is
        // why processCount here can be smaller than a lifetime process list.
        let pids = Set(app.pids)
        let procs = snapshot.drains
            .filter { pids.contains($0.pid) }
            .map {
                AppDetailView.ProcessRow(name: $0.name, pid: $0.pid, path: $0.path,
                                         percentPerHour: $0.percentPerHour, joules: $0.joules)
            }
            .sorted { $0.percentPerHour > $1.percentPerHour }

        let attributedShare = snapshot.attributed_W > 0
            ? min(1, max(0, app.watts / snapshot.attributed_W))
            : 0

        // Internal watts only — nothing here is displayed as W.
        let measuredTotal_W = snapshot.measured_W ?? snapshot.smcTotal_W
        let measuredShare = measuredTotal_W.flatMap { total -> Double? in
            total > 0 ? min(1, max(0, app.watts / total)) : nil
        }

        self.init(appName: app.identity.name,
                  bundlePath: app.identity.bundlePath,
                  bundleID: app.identity.bundleID,
                  isApp: app.identity.isApp,
                  totalPercentPerHour: app.percentPerHour,
                  shareOfAttributed: attributedShare,
                  shareOfMeasured: measuredShare,
                  processes: procs)
    }
}
