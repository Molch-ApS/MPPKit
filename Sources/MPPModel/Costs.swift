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

/// Costs as Microsoft Project calculates them for work resources: each hour
/// of work at the standard rate in force that day, from the assignment's cost
/// rate table, plus the table's cost per use; a task adds its fixed cost, and
/// a summary adds up its children. Actual cost follows the accrual: at the
/// start, at the end, or as work is done (prorated; cost per use is due once
/// work has started). Overtime is not modelled.
extension Project {
    /// Recalculates every assignment whose cost the plan as it was read
    /// (`was`) does not already describe, then every task's and summary's
    /// cost from them. Assignments to material resources and to resources
    /// without rates (cost resources) keep what they have.
    public mutating func recalculateCosts(keepingFrom was: Project? = nil) {
        let time = workingTimes()
        let resources = Dictionary(uniqueKeysWithValues: self.resources.map { ($0.uid, $0) })
        let byUID = Dictionary(uniqueKeysWithValues: tasks.indices.map { (tasks[$0].uid, $0) })
        for i in assignments.indices {
            let a = assignments[i]
            guard let ti = byUID[a.taskUID], let r = resources[a.resourceUID], r.type == "work",
                  !r.costRateTables.isEmpty else { continue }
            let t = tasks[ti]
            if let was, Self.sameCostInputs(a, t, r, in: was) { continue }
            let table = a.costRateTable < r.costRateTables.count ? r.costRateTables[a.costRateTable] : []
            let (cost, actual) = Self.cost(of: a, on: t, rates: table, accrual: r.accrueAt, time: time(t),
                                           minutesPerDay: minutesPerDay)
            assignments[i].cost = cost
            assignments[i].actualCost = actual
        }
        var cost: [Int: Double] = [:], actual: [Int: Double] = [:]
        for a in assignments {
            cost[a.taskUID, default: 0] += a.cost
            actual[a.taskUID, default: 0] += a.actualCost
        }
        // Children before their parents: deepest first.
        let order = tasks.indices.sorted { tasks[$0].outlineLevel > tasks[$1].outlineLevel }
        for i in order {
            let t = tasks[i]
            let total = (cost[t.uid] ?? 0) + t.fixedCost
            let done = (actual[t.uid] ?? 0) + Self.accrued(t.fixedCost, t.fixedCostAccrual, percent: t.percentComplete)
            tasks[i].cost = total
            tasks[i].actualCost = done
            if t.parentUID != 0 {
                cost[t.parentUID, default: 0] += total
                actual[t.parentUID, default: 0] += done
            }
        }
    }

    /// The task total over the leaves: what Project shows on its project
    /// summary row.
    public var totalCost: (cost: Double, actual: Double) {
        let top = tasks.filter { $0.parentUID == 0 }
        return (top.reduce(0) { $0 + $1.cost }, top.reduce(0) { $0 + $1.actualCost })
    }

    static func sameCostInputs(_ a: Assignment, _ t: ProjectTask, _ r: Resource, in was: Project) -> Bool {
        guard let wt = was.task(uid: t.uid), let wr = was.resource(uid: r.uid),
              let wa = was.assignments.first(where: { $0.taskUID == a.taskUID && $0.resourceUID == a.resourceUID })
        else { return false }
        return wt.start == t.start && wt.finish == t.finish && wt.durationDays == t.durationDays
            && wt.percentComplete == t.percentComplete && wt.splits == t.splits && wt.calendar == t.calendar
            && wa.units == a.units && wa.costRateTable == a.costRateTable
            && wr.costRateTables == r.costRateTables && wr.accrueAt == r.accrueAt
            && wa.cost == a.cost && wa.actualCost == a.actualCost
    }

    public static func accrued(_ amount: Double, _ accrual: String, percent: Int) -> Double {
        switch accrual {
        case "start": return percent > 0 ? amount : 0
        case "end": return percent >= 100 ? amount : 0
        default: return amount * Double(percent) / 100
        }
    }

    /// One assignment's cost and actual cost, its work laid over the rates
    /// in force on the days it falls on.
    static func cost(of a: Assignment, on t: ProjectTask, rates: [PayRate], accrual: String,
                     time: WorkingTime, minutesPerDay: Int) -> (Double, Double) {
        guard let start = t.start, let finish = t.finish, !rates.isEmpty else { return (0, 0) }
        let minutes = Int((t.durationDays * Double(minutesPerDay)).rounded())
        let gaps = t.splits.filter { $0.workMinutes < minutes }
        /// The task's working minutes from its start to `date`, its gaps left out.
        func work(until date: Date) -> Int {
            guard date > start else { return 0 }
            var span = time.minutes(from: start, to: min(date, finish))
            var at = 0
            for g in gaps {
                let gapStart = g.workMinutes + at
                span -= max(0, min(span, gapStart + g.idleMinutes) - gapStart)
                at += g.idleMinutes
            }
            return min(minutes, max(0, span))
        }
        let done = Int((Double(minutes) * Double(t.percentComplete) / 100).rounded())
        var total = 0.0, actual = 0.0, before = 0
        for (n, rate) in rates.enumerated() {
            let upTo = n == rates.count - 1 ? minutes : work(until: rate.until ?? finish)
            guard upTo > before else { continue }
            let perMinute = rate.standardPerHour / 60 * a.units
            total += Double(upTo - before) * perMinute
            actual += Double(max(0, min(done, upTo) - before)) * perMinute
            before = upTo
        }
        let first = rates.first { ($0.until ?? .distantFuture) > start } ?? rates[rates.count - 1]
        total += first.costPerUse
        if done > 0 { actual += first.costPerUse }
        switch accrual {
        case "start": actual = t.percentComplete > 0 ? total : 0
        case "end": actual = t.percentComplete >= 100 ? total : 0
        default: break
        }
        return ((total * 100).rounded() / 100, (actual * 100).rounded() / 100)
    }
}
