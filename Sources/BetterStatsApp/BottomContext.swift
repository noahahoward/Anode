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
    case battery, cpu, gpu, memory, disk
    /// Whole-machine subjects, chosen by the TAB rather than by a sort.
    case network, sensors, fans

    /// What the bottom is about, from the tab first and the sort second.
    ///
    /// THE TAB WINS, and it has to. The sort is a statement about the process
    /// table, and on every tab but Processes that table is not on screen — so the
    /// bottom was answering a question the user could no longer see they had
    /// asked. Sorting by CPU, switching to Fans, and still being shown a CPU
    /// graph is the same defect as the Resources rail updating its highlight and
    /// leaving the readings behind.
    ///
    /// On Processes there is no tab-level subject, so the sort is the only signal
    /// and it stays in charge.
    /// Every tab has a SELECTION inside it, and the bottom follows that too.
    ///
    /// The tab alone is not enough. Resources is six cards behind one tab, and
    /// answering all six with one subject is the same mistake as answering five
    /// tabs with one sort. So the rail's own selection reaches in here, and the
    /// mapping is exact — every resource that rail can show is already a subject
    /// this enum has.
    ///
    /// Note that hiding the Resources GRAPH is not decided here. That is a fact
    /// about the tab (it already draws a graph per card), not about the subject:
    /// CPU is the same subject whether it was reached from a sort or from a card,
    /// and it would be wrong for one of those to come with a graph and the other
    /// not to.
    static func forLens(_ lens: SidebarView.Lens, sortKey: String,
                        resource: Resource) -> BottomContext {
        switch lens {
        case .processes: return forSortKey(sortKey)
        case .resources: return forResource(resource)
        case .network:   return .network
        case .sensors:   return .sensors
        case .fans:      return .fans
        }
    }

    /// A Resources rail card's subject. One-to-one, and it should stay that way:
    /// a resource the rail can select and the bottom cannot describe is a card
    /// that goes dead when you click it.
    static func forResource(_ resource: Resource) -> BottomContext {
        switch resource {
        case .cpu:     return .cpu
        case .memory:  return .memory
        case .gpu:     return .gpu
        case .network: return .network
        case .disk:    return .disk
        case .sensors: return .sensors
        }
    }

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
        // BOTH disk columns land on one subject, and its graph draws both lines.
        // Sorting by writes is a statement that disk is the question, not that
        // reads have stopped mattering — and the two are read from the same
        // counter pair on the same tick, so splitting them into two subjects
        // would halve what is on screen to no end.
        case "diskRead", "diskWrite":     return .disk
        // pctHr, window, cost, gpuPctHr, name, procs.
        default:                          return .battery
        }
    }

    /// What the bar's numbers mean, for its own labels.
    public var unit: String {
        switch self {
        case .battery: return "%/hr"
        case .cpu, .gpu, .memory: return "%"
        case .disk: return "B/s"
        case .network: return "B/s"
        case .sensors, .fans: return "°C"
        }
    }

    public var title: String {
        switch self {
        case .battery: return "Battery"
        case .cpu:     return "CPU"
        case .gpu:     return "GPU"
        case .memory:  return "Memory"
        case .disk:    return "Disk"
        case .network: return "Network"
        case .sensors: return "Temperature"
        case .fans:    return "Fans"
        }
    }

    /// Whether this subject is a percentage of a fixed whole.
    ///
    /// The one thing that genuinely differs between the utilisation subjects. CPU,
    /// GPU and memory are portions of something with a ceiling, so their axis pins
    /// at 100 and their bar's parts are already comparable to each other. Disk is
    /// a RATE — bytes per second has no ceiling to divide by — so it autoscales,
    /// formats through the byte units the rest of the app uses, and never claims a
    /// percentage. There is a "disk busy %" in the IOKit counters and it is not
    /// honest; see `DiskActivity`, where a disk doing 5 KB/s reads as 80 % busy.
    public var isPercentage: Bool {
        switch self {
        case .battery, .cpu, .gpu, .memory: return true
        // Rates and temperatures. A fan graph plots a percentage AND a
        // temperature, and it is the temperature axis that has no ceiling — see
        // `fans` below, which puts them on separate axes for that reason.
        case .disk, .network, .sensors, .fans: return false
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
        // Columns on the interval table, written every tick since the first
        // release. A week of these is as real as a week of drain.
        case .battery, .cpu, .gpu, .memory, .disk, .network:
            return [3600, 6 * 3600, 24 * 3600, 7 * 24 * 3600]
        // NOT persisted. Temperatures and fan speeds live only in this session's
        // memory — the SMC sweep is gated on a tab being open, so there is no
        // week of it to draw and a 7D button here would promise an empty plot.
        // The ranges genuinely need not match across subjects.
        case .sensors, .fans:
            return [3600]
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
