// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import MPPCFB
import MPPModel

/// An assignment's planned work (var 49) as Project lays out a split task: a
/// 44-byte header, then a 28-byte record per stretch of time, working or
/// idle, each with the work done by its end (f64), its units (f64, 0 for a
/// gap), 8 zero bytes and its end (u32, working minutes × 80 from the start).
/// Once work has begun, var 49 holds only the work still to do, counted from
/// where the done part stops (its actual work, var 50, holds the rest): a
/// gap between the two is an idle stretch at its head.
extension MPP {
    static let splitRecordSize = 28

    /// The gaps a planned-work payload holds; empty for work in one piece.
    /// `done` is the working time already done (see `actualWorkMinutes`): the
    /// planned work starts there.
    public static func splitGaps(_ planned: [UInt8], done: Int = 0) -> [TaskSplit] {
        let r = BinaryReader(planned)
        // A u32 past 2³¹ doesn't fit where Int is 32 bits (the web core): Int(_:)
        // reads it as .tooLarge there (FileIntegers.swift).
        guard let count = r.u16(at: 0), count >= (done > 0 ? 2 : 3),
              let first = r.u32(at: 4).map(Int.init) else { return [] }
        var gaps: [TaskSplit] = []
        var work = done, previous = 0
        for i in 0..<Int(count) {
            let at = first + i * splitRecordSize
            guard let units = r.f64(at: at + 8)?.fromFile, let end = r.u32(at: at + 24) else { return [] }
            let minutes = Int((Double(end) / 80).rounded()) - previous
            previous += minutes
            if units == 0 {
                if work > 0, minutes > 0 { gaps.append(TaskSplit(workMinutes: work, idleMinutes: minutes)) }
            } else {
                // Capped: damaged ends summed past a 32-bit Int (#978).
                work = Swift.min(work + minutes, .tooLarge)
            }
        }
        return gaps
    }

    /// The working minutes an actual-work payload (var 50) holds: a 36-byte
    /// header, then 24 bytes a stretch: the work done by its end (f64), its
    /// units (f64, 0 for a gap) and its end (u32, minutes × 80).
    public static func actualWorkMinutes(_ actual: [UInt8]) -> Int {
        let r = BinaryReader(actual)
        guard let count = r.u16(at: 0), let size = r.u16(at: 2), size >= 24,
              let first = r.u32(at: 4).map(Int.init) else { return 0 }
        var minutes = 0, previous = 0
        for i in 0..<Int(min(count, 1_000)) {
            let at = first + i * Int(size)
            guard let units = r.f64(at: at + 8)?.fromFile, let end = r.u32(at: at + 16) else { break }
            let span = Int((Double(end) / 80).rounded()) - previous
            previous += span
            if units != 0 { minutes = Swift.min(minutes + span, .tooLarge) }
        }
        return minutes
    }

    /// Planned work laid out around `gaps`, as Project writes it: `minutes` of
    /// the task's working time at `units` (1.0 = 100%), of which `done` are
    /// done (their gaps are in the actual work, not here).
    static func splitPlannedWork(minutes: Int, units: Double, gaps: [TaskSplit], done: Int = 0) -> [UInt8] {
        let rate = units * percentScale * 16
        let perMinute = 1_000 * units
        var stretches: [(work: Int, rate: Double, end: Int)] = []
        var work = done, end = 0
        for gap in gaps.sorted(by: { $0.workMinutes < $1.workMinutes }) where gap.workMinutes < minutes
            && (gap.workMinutes > work || (done > 0 && gap.workMinutes == done && stretches.isEmpty)) {
            if gap.workMinutes > work {
                end += gap.workMinutes - work
                work = gap.workMinutes
                stretches.append((work - done, rate, end))
            }
            end += gap.idleMinutes
            stretches.append((work - done, 0, end))
        }
        end += minutes - work
        stretches.append((minutes - done, rate, end))
        var w = BinaryWriter()
        w.u16(UInt16(stretches.count))
        w.u16(32)
        w.u32(44)
        w.f64(rate)
        w.f64(Double(minutes - done) * perMinute)
        w.u32(UInt32(end * 80))
        w.append([UInt8](repeating: 0, count: 16))
        for s in stretches {
            w.f64(Double(s.work) * perMinute)
            w.f64(s.rate)
            w.f64(0)
            w.u32(UInt32(s.end * 80))
        }
        return w.bytes
    }
}
