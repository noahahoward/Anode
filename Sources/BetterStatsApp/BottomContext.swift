import AppKit
import PowerKit

/// What the bottom of the window is about: the sliced bar, the card in the
/// corner, and the graph beside it.
///
/// IT FOLLOWS THE SORT, not the tab. Sorting the process table by CPU is a
/// statement that CPU is the question being asked, and answering it with a
/// battery breakdown underneath is three panels describing something the user has
/// just said they are not looking at. So the sort column picks the subject and
/// all three follow it together.
///
/// ── WHAT EACH ONE SHOWS ──────────────────────────────────────────────────────
///
/// The BAR keeps the battery bar's shape — attributed to apps, attributed to
/// system processes, and the remainder that was measured but could not be
/// attributed — because that shape is the honest one for every quantity here:
/// something is measured whole, part of it can be named, and the part that cannot
/// is shown rather than hidden. Only the unit changes.
///
/// It shows the USED portion only. Idle is most of a CPU bar most of the time and
/// carries no information: a bar that is 85 % "nothing is happening" says less
/// about what is happening than the same bar with the idle taken out.
///
/// The rails the battery bar carries — display, memory, storage, USB — do not
/// exist for a utilisation. Nothing is spending CPU on backlight.
public enum BottomContext: String, CaseIterable {
    case battery, cpu, gpu, memory

    /// The subject implied by a sort column.
    ///
    /// Battery is the default and the fallback: it is what the app is for, and
    /// the columns that do not name a subsystem — the app's name, its process
    /// count — leave the question open rather than answering it with a guess.
    ///
    /// The %/hr columns stay on battery even when they are ABOUT the GPU:
    /// "GPU %/hr" is a battery cost, and a user sorting by it is asking what is
    /// draining the battery, not what is loading the GPU.
    public static func forSortKey(_ key: String) -> BottomContext {
        switch key {
        case "cpu":                       return .cpu
        case "gpuPct", "gputime":         return .gpu
        case "memPct", "mem":             return .memory
        // pctHr, window, cost, gpuPctHr, name, procs, diskRead, diskWrite.
        //
        // Disk is deliberately here rather than a case of its own: there is no
        // honest disk UTILISATION on this hardware (see `DiskActivity`), so a
        // disk bar would have no whole to take a portion of. Bytes per second
        // has no ceiling to divide by.
        default:                          return .battery
        }
    }

    /// What the bar's numbers mean, for its own labels.
    public var unit: String {
        switch self {
        case .battery: return "%/hr"
        case .cpu, .gpu, .memory: return "%"
        }
    }

    public var title: String {
        switch self {
        case .battery: return "Battery"
        case .cpu:     return "CPU"
        case .gpu:     return "GPU"
        case .memory:  return "Memory"
        }
    }

    /// Ranges this subject can honestly offer.
    ///
    /// NOT the same set for every subject, and deliberately so. CPU, GPU and
    /// memory are persisted in the history store alongside the battery, so they
    /// can answer for a week. Anything living only in a session's memory cannot,
    /// and offering a 7D button that draws an empty plot is a worse answer than
    /// not offering it.
    public var ranges: [TimeInterval] {
        switch self {
        case .battery, .cpu, .gpu, .memory:
            return [3600, 6 * 3600, 24 * 3600, 7 * 24 * 3600]
        }
    }
}

/// The bar's slices for a utilisation subject.
///
/// Three, mirroring the battery bar: what belongs to apps, what belongs to
/// processes we cannot read, and what was measured but belongs to neither.
public struct UtilizationSlices: Equatable {
    /// Percent of the whole device, not of the used portion — the bar does that
    /// normalisation itself so the numbers here stay comparable to the readings
    /// they came from.
    public let apps: Double
    public let systemProcesses: Double
    /// Measured total minus what could be named.
    ///
    /// Never negative. Per-process figures are sampled per process and the total
    /// is sampled whole, a moment apart, so they disagree slightly in both
    /// directions; a negative remainder is that disagreement and not a discovery,
    /// and drawing it would put a slice on the bar for a thing that does not
    /// exist.
    public let unattributed: Double

    public var used: Double { apps + systemProcesses + unattributed }

    public init(total: Double, apps: Double, systemProcesses: Double) {
        self.apps = max(0, apps)
        self.systemProcesses = max(0, systemProcesses)
        self.unattributed = max(0, total - self.apps - self.systemProcesses)
    }
}
