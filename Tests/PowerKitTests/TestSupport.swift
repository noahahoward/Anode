import Foundation
@testable import PowerKit

/// Shared fixtures. Everything here is synthetic and deterministic — no IOKit, no
/// wall clock, no dependence on the host being a laptop.

/// A scale chosen so `joulesPerPercent` is EXACTLY 3600, making 1 W == 1 %/hr.
/// Round numbers on purpose: conversion tests can assert bit-exact equality, so a
/// swapped numerator or an off-by-1000 unit slip cannot hide inside a tolerance.
///   10,000 mAh × 10 V × 3600 s = 360,000 J full  →  3600 J per 1%.
func makeExactScale() -> BatteryScale {
    BatteryScale(fullChargeCapacity_mAh: 10_000,
                 designCapacity_mAh: 10_000,
                 nominalVoltage_V: 10.0,
                 isCalibrated: false)
}

/// This machine's documented pack: 6197 mAh full-charge against the 11.58 V 3S seed.
/// Used to pin the headline constants (≈2588 J/%, 1 W ≈ 1.39 %/hr) as regression
/// anchors independent of the live gas gauge.
func makeMachineScale(design: Double = 6251) -> BatteryScale {
    BatteryScale(fullChargeCapacity_mAh: 6197,
                 designCapacity_mAh: design,
                 nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                 isCalibrated: false)
}

/// Synthetic process sample. `nJ` is CUMULATIVE-since-process-start, exactly like
/// `ri_energy_nj` — the tests exist because that cumulativeness was once mishandled.
func makeProcess(pid: pid_t,
                 start: UInt64 = 1,
                 nJ: UInt64,
                 name: String? = nil,
                 path: String = "") -> ProcessEnergy {
    ProcessEnergy(pid: pid,
                  name: name ?? "proc\(pid)",
                  energy_nJ: nJ,
                  pEnergy_nJ: 0,
                  cycles: 0,
                  pCycles: 0,
                  startAbsTime: start,
                  path: path)
}

/// Sweep at a fixed synthetic timestamp (seconds since reference date), so `dt`
/// between two sweeps is an exact Double and watts come out bit-exact.
func makeSweep(at seconds: TimeInterval, _ procs: [ProcessEnergy]) -> ProcessSampler.Sweep {
    var dict: [ProcessKey: ProcessEnergy] = [:]
    for p in procs { dict[p.key] = p }
    return ProcessSampler.Sweep(processes: dict,
                                timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                                attempted: procs.count,
                                denied: 0)
}

/// Pre-computed drain row for rollup tests. Default `percentPerHour` assumes the
/// exact scale (1 W == 1 %/hr).
func makeDrain(pid: pid_t,
               path: String,
               joules: Double,
               watts: Double,
               name: String = "p") -> ProcessDrain {
    ProcessDrain(name: name,
                 pid: pid,
                 path: path,
                 joules: joules,
                 watts: watts,
                 percentPerHour: watts)
}
