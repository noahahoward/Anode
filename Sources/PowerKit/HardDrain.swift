import Darwin
import Foundation

// Hard Drain: bringing the battery down faster than the Mac's own use does, by giving the processor and the GPU work.
//
// A battery that is above the level it is held at only comes down as fast as the Mac uses power: about four percent an
// hour when it is idle. Hard Drain runs extra work, in processes of its own, so that the Mac uses many times that.
// Nothing here starts a process: this file is the rule for how much work there is at a given moment, and the readings
// the rule goes by.
//
// MEASURED on a Mac17,9 (M5 Pro, 5 + 10 cores, 16 GPU cores), whole-system power from the SMC, 2026-11-15, plugged in
// and held below the charge (the battery supplied it all, the charger 0.6 W): idle 4 W; an integer loop on 15 cores 35
// W; vector multiply-adds on 15 cores 60 W at the default priority, 23 to 48 W at the utility priority or nice 20 (the
// scheduler keeps low-priority work off the fast cores and their top clocks), 9 W at the background priority; the GPU
// alone, in 4 ms command buffers, 42 W; vector work and the GPU together 89 W, settling to 75 W in a minute as the chip
// warmed (about 115% of this battery an hour). The battery warmed from 28 to 30 °C in that minute.

public enum HardDrainRule {

    /// Cores that are never given a worker, so that something is always free for whatever starts next.
    public static let coresLeftFree = 2
    /// How often the amount of work is decided again.
    public static let lookEvery: TimeInterval = 2
    /// How long nobody has to have touched the keyboard or the pointer before the work goes all out: until then the
    /// person is taken to be using the Mac, and the work is gentle.
    public static let awayAfter: TimeInterval = 60
    /// The longest it runs before it ends by itself, whatever the battery says: nobody means to heat a Mac for longer.
    public static let longest: TimeInterval = 3 * 3600
    /// Once the battery has been too warm, how far below that it has to cool before the work starts again, so that a
    /// battery at the threshold does not start and stop it at every look.
    public static let coolBy = 2.0

    /// How many workers there should be now.
    ///
    /// One for every core that other programs are not using, less the cores always left free: counting them out leaves
    /// them the processor, the heat and the fans. None at all while the battery is too warm (the work would warm it
    /// further), while macOS says the Mac's thermal state is critical, or while Low Power Mode is on (whoever switched
    /// that on is saving power, not spending it).
    public static func workers(cores: Int, busyWithOthers: Double, hot: Bool, thermalPressure: Bool,
                               lowPowerMode: Bool) -> Int {
        guard !hot, !thermalPressure, !lowPowerMode, cores > coresLeftFree else { return 0 }
        let others = busyWithOthers.isFinite ? max(0, busyWithOthers) : Double(cores)
        return max(0, cores - coresLeftFree - Int(others.rounded(.up)))
    }

    /// How hard the workers work. All out, the processor work runs at the default priority and the GPU without a gap,
    /// which is what draws the most (about 75 to 90 W here). Gently, the processor work runs at the utility priority,
    /// which the scheduler puts behind anything the person is doing, and the GPU a third of the time, so that the
    /// windows the person is looking at still get the GPU when they need it.
    public enum Intensity: String, Equatable {
        case full
        case gentle
    }

    /// All out only while nobody is using the Mac and macOS does not say it is hot: someone at the keyboard, or a Mac
    /// that macOS says is hot (serious), gets the gentle kind; a critical one gets none (`workers`).
    ///
    /// Not at macOS's first step, fair. MEASURED in a 30-minute run from 85 to 40% with nobody at the Mac: the thermal
    /// state went to fair within a minute of going all out and back to nominal a minute after going gentle, again and
    /// again, so the Mac swung between 11 and 88 W and averaged about 90% of the battery an hour; the battery itself
    /// never passed 36.2 °C. Fair is the state any long render runs in, and the battery's own temperature
    /// (`isHot`) is what guards the battery.
    public static func intensity(secondsSinceInput: TimeInterval, thermalSerious: Bool) -> Intensity {
        secondsSinceInput >= awayAfter && !thermalSerious ? .full : .gentle
    }

    /// Whether the battery counts as too warm for the work, given whether it did at the last look: too warm at the
    /// threshold, and cool again only `coolBy` below it. A temperature that cannot be read changes nothing.
    public static func isHot(temperature: Double?, threshold: Double, wasHot: Bool) -> Bool {
        guard let t = temperature, t.isFinite else { return wasHot }
        return wasHot ? t > threshold - coolBy : t >= threshold
    }
}

/// How busy the processor is, read from the system as the user: the whole Mac's, and one process's.
public enum ProcessorTime {

    /// The Mac's processor ticks since it started: busy (running anything at all) and all of them.
    public struct HostTicks: Equatable {
        public var busy: UInt64
        public var total: UInt64

        public init(busy: UInt64, total: UInt64) {
            self.busy = busy
            self.total = total
        }
    }

    public static func hostTicks() -> HostTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // user, system, idle, nice. (Measured on macOS 27: a niced process's time is counted as user or system, not as
        // nice, so the workers' own time cannot be told from other programs' here; it is read per process instead.)
        let t = info.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        return HostTicks(busy: busy, total: busy + UInt64(t.2))
    }

    /// How many cores were busy between two readings: 0 when nothing ran, the number of cores when all of them did.
    /// nil when no time passed between them, or the counters went backwards.
    public static func busyCores(from a: HostTicks, to b: HostTicks, cores: Int) -> Double? {
        guard b.total > a.total, b.busy >= a.busy else { return nil }
        return Double(cores) * Double(b.busy - a.busy) / Double(b.total - a.total)
    }

    /// The processor time one process has used since it started, in seconds; nil when it is not there.
    public static func seconds(usedBy pid: pid_t) -> Double? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        // In the units of the Mac's own clock, which are not nanoseconds on Apple silicon.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom != 0 else { return nil }
        let ticks = Double(usage.ri_user_time) + Double(usage.ri_system_time)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
