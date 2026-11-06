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
extension MPP {
    static let splitRecordSize = 28

    /// The gaps a planned-work payload holds; empty for work in one piece.
    public static func splitGaps(_ planned: [UInt8]) -> [TaskSplit] {
        let r = BinaryReader(planned)
        guard let count = r.u16(at: 0), count >= 3, let first = r.u32(at: 4) else { return [] }
        var gaps: [TaskSplit] = []
        var work = 0, previous = 0
        for i in 0..<Int(count) {
            let at = Int(first) + i * splitRecordSize
            guard let units = r.f64(at: at + 8), let end = r.u32(at: at + 24) else { return [] }
            let minutes = Int((Double(end) / 80).rounded()) - previous
            previous += minutes
            if units == 0 {
                if work > 0, minutes > 0 { gaps.append(TaskSplit(workMinutes: work, idleMinutes: minutes)) }
            } else {
                work += minutes
            }
        }
        return gaps
    }

    /// Planned work laid out around `gaps`, as Project writes it: `minutes` of
    /// the task's working time at `units` (1.0 = 100%).
    static func splitPlannedWork(minutes: Int, units: Double, gaps: [TaskSplit]) -> [UInt8] {
        let rate = units * percentScale * 16
        let perMinute = 1_000 * units
        var stretches: [(work: Int, rate: Double, end: Int)] = []
        var work = 0, end = 0
        for gap in gaps.sorted(by: { $0.workMinutes < $1.workMinutes }) where gap.workMinutes > work && gap.workMinutes < minutes {
            end += gap.workMinutes - work
            work = gap.workMinutes
            stretches.append((work, rate, end))
            end += gap.idleMinutes
            stretches.append((work, 0, end))
        }
        end += minutes - work
        stretches.append((minutes, rate, end))
        var w = BinaryWriter()
        w.u16(UInt16(stretches.count))
        w.u16(32)
        w.u32(44)
        w.f64(rate)
        w.f64(Double(minutes) * perMinute)
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
