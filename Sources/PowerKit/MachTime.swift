import Foundation

/// Converts mach absolute time units to seconds.
///
/// `proc_pid_rusage`'s `ri_user_time` and `ri_system_time` are NOT nanoseconds,
/// however much their names suggest it — XNU fills them from
/// `task_absolutetime_info`, whose unit is the mach timebase. On Apple Silicon
/// that timebase is 125/3, so one unit is 41.667 ns and treating it as one
/// nanosecond under-reports CPU by 41.667x.
///
/// That is not theoretical. Measured against a process pegging one core:
///
///     treated as nanoseconds  ->   2.397 % of one core
///     treated as mach ticks   ->  99.872 % of one core   (ps agreed: 98.3 %)
///
/// The consequence was worse than a mis-scaled column. Two display floors sit on
/// this value, so a process genuinely using 2% of a core computed to 0.048% and
/// was filtered out of the CPU lens entirely — the lens was not merely wrong, it
/// was close to empty, and it is the one number a user can trivially check
/// against Activity Monitor.
///
/// `ri_energy_nj` really is nanojoules, so the joule path — the app's actual
/// subject — was never affected.
public enum MachTime {

    /// Nanoseconds per mach absolute time unit. Read once: `mach_timebase_info`
    /// is a syscall, and this is consulted per process per tick.
    public static let nanosPerUnit: Double = {
        var tb = mach_timebase_info_data_t()
        guard mach_timebase_info(&tb) == KERN_SUCCESS, tb.denom != 0 else { return 1 }
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Seconds of CPU represented by a delta of mach absolute time units.
    public static func seconds(units: UInt64) -> Double {
        Double(units) * nanosPerUnit / 1e9
    }

    /// Percent of ONE core, Activity Monitor's convention: a fully busy
    /// four-thread process reads 400%, not 100%.
    public static func corePercent(units: UInt64, over dt: TimeInterval) -> Double {
        guard dt > 0 else { return 0 }
        return seconds(units: units) / dt * 100
    }
}
