import Foundation
import IOKit
import IOKit.hid

/// The MacBook's lid-angle sensor.
///
/// It is a HID device (Apple vendor 0x05AC, product 0x8104, sensor usage page 0x20, usage 0x8A) that sends
/// nothing by itself: the angle is read by asking for feature report 1, which comes back as three bytes —
/// the report ID, then whole degrees, little-endian. It reads without privileges (measured on Mac17,9: 107°).
/// The hardware refreshes about ten times a second, so polling faster than that only repeats values.

/// The three-byte feature report.
public enum LidAngleReport {
    /// Degrees from a report, or nil when it is short, is not report 1, or is not an angle.
    public static func degrees(from bytes: [UInt8], length: Int) -> Int? {
        guard length >= 3, bytes.count >= 3, bytes[0] == 1 else { return nil }
        let value = Int(bytes[1]) | Int(bytes[2]) << 8
        return (0...360).contains(value) ? value : nil
    }
}

/// How often to read. Idle is the owner's choice, 4 to 30 Hz; once the lid is closing it is 120 Hz, and it
/// drops to 60 Hz when reads are persistently slow so the loop cannot eat the machine.
public struct LidPollPolicy {
    public static let activeHz = 120.0
    public static let degradedHz = 60.0
    /// A read slower than this counts as slow.
    public static let slowRead = 0.008
    public static let slowReadsBeforeDegrading = 5

    public init() {}

    public static func idleHz(_ requested: Double) -> Double {
        min(max(requested, 4), 30)
    }

    private var slowInARow = 0

    /// The rate to use after a read that took `seconds`: `degradedHz` after five slow reads in a row,
    /// `activeHz` again after any fast one.
    public mutating func recordRead(seconds: Double) -> Double {
        if seconds > Self.slowRead { slowInARow += 1 } else { slowInARow = 0 }
        return slowInARow >= Self.slowReadsBeforeDegrading ? Self.degradedHz : Self.activeHz
    }
}

/// Where lid angles come from. A protocol so the controller can be tested without a lid.
public protocol LidAngleSource: AnyObject {
    var isAvailable: Bool { get }
    /// `onSample` gets degrees and a monotonic time in seconds; `onLost` is called once if the sensor stops
    /// answering. Both come from the source's own queue, never the main thread.
    func start(hz: Double, onSample: @escaping (Double, TimeInterval) -> Void, onLost: @escaping () -> Void)
    func setRate(hz: Double)
    func stop()
}

public final class LidAngleSensor: LidAngleSource {

    private let queue = DispatchQueue(label: "anode.lidangle", qos: .userInteractive)
    private let lock = NSRecursiveLock()
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var requestedHz = 8.0
    private var policy = LidPollPolicy()
    private var currentHz = 0.0
    private var failures = 0

    private let readOverride: (() -> Int?)?
    private let availableOverride: Bool?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// `readOverride` and `available` replace the hardware, for tests.
    public init(readOverride: (() -> Int?)? = nil, available: Bool? = nil) {
        self.readOverride = readOverride
        self.availableOverride = available
    }

    deinit { stop() }

    public var isAvailable: Bool {
        if let a = availableOverride { return a }
        if readOverride != nil { return true }
        return openDevice() != nil
    }

    public func start(hz: Double, onSample: @escaping (Double, TimeInterval) -> Void, onLost: @escaping () -> Void) {
        guard isAvailable else { return }
        lock.lock(); defer { lock.unlock() }
        stopLocked()
        generation += 1
        let mine = generation
        requestedHz = hz
        policy = LidPollPolicy()
        failures = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.tick(mine, onSample, onLost) }
        timer = t
        schedule(hz)
        t.resume()
    }

    public func setRate(hz: Double) {
        lock.lock(); defer { lock.unlock() }
        requestedHz = hz
        policy = LidPollPolicy()
        schedule(hz)
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        generation += 1
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        currentHz = 0
    }

    private func schedule(_ hz: Double) {
        guard hz > 0, hz != currentHz else { return }
        currentHz = hz
        timer?.schedule(deadline: .now(), repeating: 1 / hz, leeway: .milliseconds(2))
    }

    /// One read. Timer events on a serial queue cannot overlap, so a read that hangs delays the next tick
    /// instead of stacking another behind it.
    private func tick(_ mine: Int, _ onSample: (Double, TimeInterval) -> Void, _ onLost: () -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        let degrees = read()
        let took = ProcessInfo.processInfo.systemUptime - started

        lock.lock(); defer { lock.unlock() }
        guard mine == generation else { return }
        if let degrees {
            failures = 0
            let rate = min(requestedHz, policy.recordRead(seconds: took))
            schedule(rate)
            onSample(Double(degrees), started)
        } else {
            failures += 1
            if failures >= 3 {
                stopLocked()
                onLost()
            }
        }
    }

    private func read() -> Int? {
        if let readOverride { return readOverride() }
        guard let device = openDevice() else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length)
        guard result == kIOReturnSuccess else { return nil }
        return LidAngleReport.degrees(from: bytes, length: length)
    }

    private func openDevice() -> IOHIDDevice? {
        lock.lock(); defer { lock.unlock() }
        if let device { return device }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = ["VendorID": 0x05AC, "ProductID": 0x8104,
                                    "PrimaryUsagePage": 0x20, "PrimaryUsage": 0x8A]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let found = (IOHIDManagerCopyDevices(m) as NSSet?)?.allObjects.first else { return nil }
        let d = found as! IOHIDDevice  // swiftlint:disable:this force_cast
        manager = m
        device = d
        return d
    }
}
