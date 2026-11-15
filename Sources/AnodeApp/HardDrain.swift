import Darwin
import Foundation
import IOKit.pwr_mgt
import Metal
import PowerKit

/// Hard Drain's work: processes of Anode's own that keep the processor and the GPU busy, so the battery comes down
/// faster.
///
/// Each worker is this same program started with `--hard-drain-worker <Anode's pid> <cpu|gpu> <full|gentle>`. A
/// processor worker is one loop of vector multiply-adds on one core; the GPU worker keeps the GPU busy with short
/// command buffers. How many processor workers there are is decided every two seconds (`HardDrainRule.workers`) from
/// how busy other programs are; how hard all of them work (`HardDrainRule.intensity`) from whether macOS says the Mac
/// is hot, and they are told with a signal. No work at all while the battery
/// is too warm, while macOS says the Mac is hot, or in Low Power Mode or Ultra Low Power Mode. While it runs, the Mac
/// is kept from going to sleep by itself (closing the lid still sleeps it, and that ends Hard Drain). A worker ends
/// itself the moment Anode is no longer its parent, so none is left behind by an Anode that crashed.
protocol HardDraining: AnyObject {
    /// Starts the work. `temperature` is the battery's, asked at every look (nil when it cannot be read), and
    /// `hotAt` the temperature at which the work stops until the battery has cooled.
    func start(temperature: @escaping () -> Double?, hotAt: @escaping () -> Double)
    /// Ends every worker. Does nothing when none runs.
    func stop()
    /// Started and not stopped, and not past its longest time. (There may be no worker at this moment: the battery is
    /// warm, or other programs have the processor.)
    var isRunning: Bool { get }
    /// How many workers there are now, the GPU's among them.
    var workers: Int { get }
    /// Why there is no worker at this moment, in a few words for the section; nil while it is working.
    var waitingBecause: String? { get }
}

final class LiveHardDrain: HardDraining {

    /// What the engine needs of the Mac; the real ones except in tests, which start no process, read no counter and
    /// keep nothing awake.
    struct System {
        var cores: () -> Int
        var hostTicks: () -> ProcessorTime.HostTicks?
        var seconds: (pid_t) -> Double?
        /// macOS says the Mac's thermal state is critical: no work.
        var thermalPressure: () -> Bool
        /// macOS says the Mac is hot (serious): gentle work only.
        var thermalSerious: () -> Bool
        var lowPowerMode: () -> Bool
        /// Ultra Low Power Mode is on, or being started. That mode is there to make a low battery last, it does not
        /// always switch macOS's Low Power Mode on (no helper, a refusal), and while it starts it watches the
        /// processor for something spinning, which is what a worker looks like.
        var ultraLowPower: () -> Bool
        /// Calls `changed` whenever Ultra Low Power Mode starts or ends, until what it returns is called: the work has
        /// to stop when the mode begins, not at the next look.
        var followUltraLowPower: (_ changed: @escaping () -> Void) -> () -> Void
        var launch: (_ arguments: [String]) throws -> WatchdogProcess
        var signal: (_ pid: pid_t, _ signal: Int32) -> Void
        /// Keeps the Mac from going to sleep by itself until what it returns is called.
        var holdAwake: () -> () -> Void
        var now: () -> Date
        /// Calls `work` every `interval` until what it returns is called.
        var every: (_ interval: TimeInterval, _ work: @escaping () -> Void) -> () -> Void

        static let real = System(
            cores: { ProcessInfo.processInfo.activeProcessorCount },
            hostTicks: { ProcessorTime.hostTicks() },
            seconds: { ProcessorTime.seconds(usedBy: $0) },
            thermalPressure: { ProcessInfo.processInfo.thermalState == .critical },
            thermalSerious: { ProcessInfo.processInfo.thermalState == .serious },
            lowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            ultraLowPower: { UltraLowPowerController.current.map { $0.state != .off } ?? false },
            followUltraLowPower: { changed in
                let token = NotificationCenter.default.addObserver(forName: UltraLowPowerController.didChange, object: nil,
                                                                   queue: .main) { _ in changed() }
                return { NotificationCenter.default.removeObserver(token) }
            },
            launch: LiveUltraWatchdog.launchThisProgram,
            signal: { _ = kill($0, $1) },
            holdAwake: {
                var id: IOPMAssertionID = 0
                let made = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                       "Anode Hard Drain" as CFString, &id)
                return made == kIOReturnSuccess ? { _ = IOPMAssertionRelease(id) } : {}
            },
            now: Date.init,
            every: { interval, work in
                let timer = Timer(timeInterval: interval, repeats: true) { _ in work() }
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            })
    }

    /// How often a line goes to the charge log while it runs: what it is doing and how warm the battery is.
    static let logEvery: TimeInterval = 60

    private let system: System
    private let log: (String) -> Void
    private var processes: [WatchdogProcess] = []
    private var gpu: WatchdogProcess?
    private var intensity: HardDrainRule.Intensity = .full
    private var cancelTimer: (() -> Void)?
    private var stopFollowing: (() -> Void)?
    private var releaseAwake: (() -> Void)?
    /// What other programs were using at the last look, for a look that is made between two readings.
    private var lastOthers = 0.0
    private(set) var waitingBecause: String?
    private var startedAt: Date?
    private var loggedAt: Date?
    private var temperature: () -> Double? = { nil }
    private var hotAt: () -> Double = { ChargePolicy.defaultMaxTemperatureC }
    private var wasHot = false
    /// The last reading of the Mac's ticks and of each worker's own time, to take the next one from.
    private var lastHost: ProcessorTime.HostTicks?
    private var lastLook: Date?
    private var lastSeconds: [pid_t: Double] = [:]
    private var saidWhy: String?

    init(system: System = .real, log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) }) {
        self.system = system
        self.log = log
    }

    var isRunning: Bool { startedAt != nil }
    var workers: Int { processes.count + (gpu == nil ? 0 : 1) }
    /// For the tests: how hard the workers are told to work.
    var currentIntensity: HardDrainRule.Intensity { intensity }

    func start(temperature: @escaping () -> Double?, hotAt: @escaping () -> Double) {
        guard startedAt == nil else { return }
        self.temperature = temperature
        self.hotAt = hotAt
        startedAt = system.now()
        loggedAt = nil
        wasHot = false
        saidWhy = nil
        lastHost = system.hostTicks()
        lastLook = system.now()
        lastSeconds = [:]
        // Nothing is known yet about what other programs are doing, so it begins with what an idle Mac gets and is
        // corrected at the first look.
        look(busyWithOthers: 0)
        cancelTimer = system.every(HardDrainRule.lookEvery) { [weak self] in self?.lookAgain() }
        stopFollowing = system.followUltraLowPower { [weak self] in
            guard let self, self.startedAt != nil else { return }
            self.look(busyWithOthers: self.lastOthers)
        }
    }

    func stop() {
        cancelTimer?()
        cancelTimer = nil
        stopFollowing?()
        stopFollowing = nil
        releaseAwake?()
        releaseAwake = nil
        startedAt = nil
        waitingBecause = nil
        set(cpu: 0, gpu: false)
    }

    /// One look: how busy the Mac was with other programs since the last one, and how many workers that leaves.
    private func lookAgain() {
        guard let started = startedAt else { return }
        if system.now().timeIntervalSince(started) >= HardDrainRule.longest {
            log("Hard Drain ended: it had run for \(Int(HardDrainRule.longest / 3600)) hours")
            stop()
            return
        }
        // Workers that have ended by themselves are no longer counted.
        processes.removeAll { !$0.isRunning }
        if gpu?.isRunning == false { gpu = nil }
        let cores = system.cores()
        var others = Double(cores)      // taken for busy when it cannot be read: no work is added on a guess
        if let before = lastHost, let now = system.hostTicks(), let looked = lastLook,
           let busy = ProcessorTime.busyCores(from: before, to: now, cores: cores) {
            let elapsed = system.now().timeIntervalSince(looked)
            var mine = 0.0
            var seconds: [pid_t: Double] = [:]
            for p in processes + (gpu.map { [$0] } ?? []) {
                guard let used = system.seconds(p.pid) else { continue }
                seconds[p.pid] = used
                mine += max(0, used - (lastSeconds[p.pid] ?? 0))
            }
            lastSeconds = seconds
            lastHost = now
            others = elapsed > 0 ? max(0, busy - mine / elapsed) : Double(cores)
        } else {
            lastHost = system.hostTicks()
        }
        lastLook = system.now()
        look(busyWithOthers: others)
    }

    private func look(busyWithOthers others: Double) {
        lastOthers = others
        let battery = temperature()
        wasHot = HardDrainRule.isHot(temperature: battery, threshold: hotAt(), wasHot: wasHot)
        let thermal = system.thermalPressure(), lowPower = system.lowPowerMode(), ultra = system.ultraLowPower()
        let wanted = HardDrainRule.workers(cores: system.cores(), busyWithOthers: others, hot: wasHot,
                                           thermalPressure: thermal, lowPowerMode: lowPower || ultra)
        // Why there is no work, said once each time the reason changes.
        let why: String? = ultra ? "Ultra Low Power Mode is on" : wasHot ? "the battery is warm"
            : thermal ? "the Mac is hot" : lowPower ? "Low Power Mode is on" : nil
        if why != saidWhy {
            saidWhy = why
            log(why.map { "Hard Drain is waiting: \($0)" } ?? "Hard Drain is working again")
        }
        let next = HardDrainRule.intensity(thermalSerious: system.thermalSerious())
        if next != intensity {
            intensity = next
            // Every worker that runs is told; one started from here on is started that way.
            let sig = next == .full ? HardDrainWorker.fullSignal : HardDrainWorker.gentleSignal
            for p in processes + (gpu.map { [$0] } ?? []) where p.isRunning { system.signal(p.pid, sig) }
        }
        // The GPU is worked whenever the processor may be: its work does not take a core from anyone.
        set(cpu: wanted, gpu: why == nil)
        // Awake while it works, and through a pause for heat, which is part of a drain (one that the Mac slept through
        // would be over). Not while Low Power Mode or Ultra Low Power Mode is on: those are there to make the battery
        // last, and a Mac kept awake for nothing would work against them.
        keepAwake(!(ultra || lowPower))
        // With none of those, no processor worker means other programs have it, which comes and goes and is not logged.
        waitingBecause = why ?? (processes.isEmpty && gpu == nil ? "other apps are using the processor" : nil)
        logNow(battery: battery)
    }

    private func keepAwake(_ wanted: Bool) {
        if wanted, releaseAwake == nil {
            releaseAwake = system.holdAwake()
        } else if !wanted, let release = releaseAwake {
            releaseAwake = nil
            release()
        }
    }

    /// A line a minute: enough to see afterwards what it did and how warm it got.
    private func logNow(battery: Double?) {
        let now = system.now()
        if let last = loggedAt, now.timeIntervalSince(last) < Self.logEvery { return }
        loggedAt = now
        let warmth = battery.map { String(format: "%.1f °C", $0) } ?? "unknown"
        log("Hard Drain: \(processes.count) processor workers, the GPU \(gpu == nil ? "idle" : "working"), "
            + "\(intensity == .full ? "all out" : "gently"); battery \(warmth)")
    }

    private func set(cpu wanted: Int, gpu wantGPU: Bool) {
        while processes.count > wanted, let last = processes.popLast() {
            lastSeconds[last.pid] = nil
            if last.isRunning { last.terminate() }
        }
        while processes.count < wanted {
            guard let p = launch(.cpu) else { break }
            processes.append(p)
        }
        if !wantGPU, let g = gpu {
            gpu = nil
            lastSeconds[g.pid] = nil
            if g.isRunning { g.terminate() }
        } else if wantGPU, gpu == nil {
            gpu = launch(.gpu)
        }
    }

    private func launch(_ kind: HardDrainWorker.Kind) -> WatchdogProcess? {
        do {
            let p = try system.launch(HardDrainWorker.arguments(parent: getpid(), kind: kind, intensity: intensity))
            return p.isRunning ? p : nil
        } catch {
            log("Hard Drain: a worker could not be started (\(error.localizedDescription))")
            return nil
        }
    }
}

// ── A worker ────────────────────────────────────────────────────────────────

enum HardDrainWorker {

    static let argument = "--hard-drain-worker"

    enum Kind: String { case cpu, gpu }

    /// Sent to a worker to make it work all out, and gently.
    static let fullSignal = SIGUSR2
    static let gentleSignal = SIGUSR1

    struct Request: Equatable {
        var parent: pid_t
        var kind: Kind
        var intensity: HardDrainRule.Intensity
    }

    static func arguments(parent: pid_t, kind: Kind, intensity: HardDrainRule.Intensity) -> [String] {
        [argument, String(parent), kind.rawValue, intensity.rawValue]
    }

    /// `["Anode", "--hard-drain-worker", "123", "cpu", "full"]`; anything else is nil.
    static func parse(_ arguments: [String]) -> Request? {
        guard arguments.count == 5, arguments[1] == argument, let parent = pid_t(arguments[2]), parent > 1,
              let kind = Kind(rawValue: arguments[3]), let intensity = HardDrainRule.Intensity(rawValue: arguments[4])
        else { return nil }
        return Request(parent: parent, kind: kind, intensity: intensity)
    }

    /// Whether to work all out, as last told. Written by the signal handlers, read by the loop.
    nonisolated(unsafe) private static var full: Int32 = 0
    /// What the loops leave behind, so that the compiler cannot find that they do nothing and take them away.
    nonisolated(unsafe) private static var sink: Float = 0

    /// Among the first things the program does. Returns at once unless the flag is there; with it, never returns: it
    /// works until Anode ends it or is no longer its parent. No window, no `NSApplication`, no settings.
    static func runIfRequested(_ arguments: [String]) {
        guard arguments.contains(argument) else { return }
        guard let request = parse(arguments) else { exit(2) }
        signal(SIGTERM, SIG_DFL)
        full = request.intensity == .full ? 1 : 0
        signal(fullSignal) { _ in HardDrainWorker.full = 1 }
        signal(gentleSignal) { _ in HardDrainWorker.full = 0 }
        let parent = request.parent
        // The work runs on a thread of its own, whose priority it sets itself as it is told; this one only watches that
        // Anode is still there (a parent that has ended hands its children to launchd).
        let worker = Thread {
            switch request.kind {
            case .cpu: cpuLoop(parent: parent)
            case .gpu: gpuLoop(parent: parent)
            }
            exit(0)
        }
        worker.qualityOfService = request.intensity == .full ? .default : .utility
        worker.start()
        while getppid() == parent { usleep(250_000) }
        exit(0)
    }

    /// The thread's own priority, set when it changes: the default all out (the scheduler gives it the fast cores and
    /// their top clocks), utility gently (it waits behind anything the person is doing).
    private static func applyPriority(_ wantFull: Bool, _ current: inout Bool?) {
        guard current != wantFull else { return }
        current = wantFull
        pthread_set_qos_class_self_np(wantFull ? QOS_CLASS_DEFAULT : QOS_CLASS_UTILITY, 0)
    }

    /// Vector multiply-adds in eight independent chains: what draws the most from a core (measured: 60 W across 15
    /// cores, against 35 W for a loop of integer shifts).
    private static func cpuLoop(parent: pid_t) {
        var a0 = SIMD4<Float>(1, 1.0001, 0.9999, 1), a1 = a0 * 0.5, a2 = a0 * 0.25, a3 = a0 * 2
        var a4 = a0, a5 = a1, a6 = a2, a7 = a3
        let m = SIMD4<Float>(0.99999, 0.99998, 1.00001, 0.99997), c = SIMD4<Float>(0.00001, 0.00002, 0.00001, 0.00003)
        var current: Bool?
        while getppid() == parent {
            applyPriority(full == 1, &current)
            for _ in 0..<1_000_000 {
                a0 = a0 * m + c; a1 = a1 * m + c; a2 = a2 * m + c; a3 = a3 * m + c
                a4 = a4 * m + c; a5 = a5 * m + c; a6 = a6 * m + c; a7 = a7 * m + c
            }
            sink = (a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7).sum()
        }
    }

    /// How long one GPU command buffer is meant to take. Short, always: the GPU is shared with everything on screen,
    /// and one long job would hold the windows up for as long as it took.
    static let gpuSlice: TimeInterval = 0.004

    /// The GPU's work: a kernel of multiply-adds over a quarter of a million threads, sized so that each command buffer
    /// takes `gpuSlice`, one after the other all out, and with twice as long between them gently.
    private static func gpuLoop(parent: pid_t) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: gpuKernel, options: nil),
              let function = library.makeFunction(name: "burn"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let output = device.makeBuffer(length: gpuThreads * 16, options: .storageModePrivate) else { return }
        var iterations: UInt32 = 256
        var current: Bool?
        while getppid() == parent {
            let wantFull = full == 1
            applyPriority(wantFull, &current)
            guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(output, offset: 0, index: 0)
            encoder.setBytes(&iterations, length: 4, index: 1)
            encoder.dispatchThreads(MTLSize(width: gpuThreads, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            let took = buffer.gpuEndTime - buffer.gpuStartTime
            iterations = nextIterations(iterations, took: took)
            if !wantFull { usleep(useconds_t(max(0, took) * 2 * 1_000_000)) }
        }
    }

    static let gpuThreads = 1 << 18

    /// The next command buffer's size, so that it takes `gpuSlice`: a buffer that took longer (the GPU is clocked down,
    /// or shared) gets fewer iterations. Kept between 16 and 65536.
    static func nextIterations(_ iterations: UInt32, took: TimeInterval) -> UInt32 {
        guard took > 0, took.isFinite else { return iterations }
        let scaled = Double(iterations) * gpuSlice / took
        return UInt32(Swift.max(16.0, Swift.min(65536.0, scaled)))
    }

    private static let gpuKernel = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void burn(device float4 *out [[buffer(0)]], constant uint &iterations [[buffer(1)]],
                     uint id [[thread_position_in_grid]]) {
        float4 a = float4(id * 1e-6, 1.0001, 0.9999, 1.0), b = a * 0.5, c = a * 0.25, d = a * 2.0;
        const float4 m = float4(0.99999, 0.99998, 1.00001, 0.99997), k = float4(1e-5, 2e-5, 1e-5, 3e-5);
        for (uint i = 0; i < iterations; i++) { a = fma(a, m, k); b = fma(b, m, k); c = fma(c, m, k); d = fma(d, m, k); }
        out[id] = a + b + c + d;
    }
    """
}
