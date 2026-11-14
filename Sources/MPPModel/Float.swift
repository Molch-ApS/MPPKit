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

/// Total float (Project's Total Slack) and the critical path, in working time.
///
/// Project's definition: total slack is the smaller of `late start − start` and
/// `late finish − finish`, measured in working time on the task's calendar, and
/// a task is critical when its total slack is at or below the project's
/// threshold (0 by default) — negative slack included, which is what marks a
/// broken deadline or constraint. Comparing clock times instead misses a
/// milestone that finishes Friday 17:00 with a late date of Monday 08:00:
/// 63 hours apart, no working time between them.
extension Project {
    /// The working time each task is scheduled in, built once for a whole
    /// pass: its own calendar or the project's, and where its work resources
    /// have calendars of their own, theirs, as Project schedules it. A
    /// resource works its calendar within the task's own one, and several
    /// resources work side by side (see `WorkingTime.init(sideBySide:)`).
    public func workingTimes() -> (ProjectTask) -> WorkingTime {
        let tasksOwn = taskCalendarTimes()
        let resourceTimes = resourceWorkingTimes()
        guard !resourceTimes.isEmpty else { return { tasksOwn($0.calendar) } }
        var working: [Int: [Int]] = [:]
        let workers = Set(resources.filter { $0.type != "material" && $0.type != "cost" }.map(\.uid))
        for a in assignments where workers.contains(a.resourceUID) {
            working[a.taskUID, default: []].append(a.resourceUID)
        }
        var cache: [String: WorkingTime] = [:]
        return { task in
            let own = tasksOwn(task.calendar)
            guard !task.summary, !task.isElapsed, let uids = working[task.uid],
                  uids.contains(where: { resourceTimes[$0] != nil }) else { return own }
            let key = "\(task.calendar ?? "")|\(uids.sorted())"
            if let t = cache[key] { return t }
            let parts = Set(uids).sorted().map { uid -> WorkingTime in
                guard let r = resourceTimes[uid] else { return own }
                return task.calendar == nil ? r : r.intersecting(own)
            }
            let t = WorkingTime(sideBySide: parts)
            cache[key] = t
            return t
        }
    }

    /// Working time per base calendar name; nil (or an unknown name) is the
    /// project calendar.
    func taskCalendarTimes() -> (String?) -> WorkingTime {
        let projectTime = WorkingTime(calendar: calendar)
        var byName: [String: WorkingTime] = ["Standard": projectTime]
        if let c = calendar { byName[c.name] = projectTime }
        for c in calendars { byName[c.name] = WorkingTime(calendar: c) }
        return { name in name.flatMap { byName[$0] } ?? projectTime }
    }

    /// A resource calendar as Project works it: its base calendar's week and
    /// exceptions, with the resource's own days and exceptions over them.
    public func resolvedResourceCalendar(_ own: ProjectCalendar) -> ProjectCalendar {
        guard let baseUID = own.baseCalendarUID,
              let base = calendar?.uid == baseUID ? calendar : calendars.first(where: { $0.uid == baseUID })
        else { return own }
        var out = own
        out.week = base.week
        for (weekday, ranges) in own.week { out.week[weekday] = ranges }
        // Later exceptions win a day: the resource's own over its base's.
        out.exceptions = base.exceptions + own.exceptions
        return out
    }

    /// Working time per resource whose own calendar works differently from
    /// the project calendar, by resource uid.
    public func resourceWorkingTimes() -> [Int: WorkingTime] {
        var out: [Int: WorkingTime] = [:]
        let byUID = Dictionary(resourceCalendars.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let projectCalendar = calendar ?? ProjectCalendar()
        for r in resources where r.type != "material" && r.type != "cost" {
            guard let own = r.calendarUID.flatMap({ byUID[$0] }) else { continue }
            let cal = resolvedResourceCalendar(own)
            // The same days as the project calendar: nothing to tell apart.
            if (1...7).allSatisfy({ cal.workingRanges(weekday: $0) == projectCalendar.workingRanges(weekday: $0) }),
               cal.exceptions == projectCalendar.exceptions { continue }
            out[r.uid] = WorkingTime(calendar: cal)
        }
        return out
    }

    /// Total float of `task` in working minutes; negative when it is late.
    /// Once a task has started, Project measures its float at the finish only.
    public static func floatMinutes(_ task: ProjectTask, time: WorkingTime) -> Int? {
        let finishFloat = task.finish.flatMap { f in task.lateFinish.map { time.signedMinutes(from: f, to: $0) } }
        if task.actualStart != nil, let finishFloat { return finishFloat }
        guard let s = task.start, let ls = task.lateStart else { return finishFloat }
        let startFloat = time.signedMinutes(from: s, to: ls)
        return finishFloat.map { min(startFloat, $0) } ?? startFloat
    }

    /// Total float of the task in working minutes.
    public func totalFloatMinutes(uid: Int) -> Int? {
        guard let t = task(uid: uid) else { return nil }
        return Self.floatMinutes(t, time: workingTimes()(t))
    }

    /// Total float in working minutes for every task, in one pass.
    public func totalFloats() -> [Int: Int] {
        let time = workingTimes()
        var out: [Int: Int] = [:]
        out.reserveCapacity(tasks.count)
        for t in tasks { if let m = Self.floatMinutes(t, time: time(t)) { out[t.uid] = m } }
        return out
    }

    /// Whether one task is critical, by the same rule as `criticalUIDs`.
    public func isCritical(uid: Int) -> Bool {
        guard let t = task(uid: uid), t.percentComplete < 100, let m = totalFloatMinutes(uid: uid) else { return false }
        return m <= Int.clamped(criticalSlackDays * Double(minutesPerDay))
    }

    /// The critical tasks: unfinished, with total float at or below the
    /// project's threshold.
    public func criticalUIDs() -> Set<Int> {
        let limit = Int.clamped(criticalSlackDays * Double(minutesPerDay))
        let time = workingTimes()
        var out = Set<Int>()
        for t in tasks where t.percentComplete < 100 {
            if let m = Self.floatMinutes(t, time: time(t)), m <= limit { out.insert(t.uid) }
        }
        return out
    }
}

extension WorkingTime {
    /// Working minutes from `a` to `b`; negative when `b` is before `a`.
    public func signedMinutes(from a: Date, to b: Date) -> Int {
        b >= a ? minutes(from: a, to: b) : -minutes(from: b, to: a)
    }
}

extension Project {
    /// Whether `other` gives the scheduler exactly the same problem: the same
    /// tasks in the same outline, durations, constraints, deadlines, progress,
    /// calendars and links. Names, notes, custom fields, resources' names and
    /// the like are not inputs, so an edit to them must not recalculate — and
    /// so move — dates Project calculated.
    public func hasSameSchedulingInputs(as other: Project) -> Bool {
        guard start == other.start, minutesPerDay == other.minutesPerDay,
              calendar == other.calendar, calendars == other.calendars,
              relations == other.relations, tasks.count == other.tasks.count,
              resourceCalendars == other.resourceCalendars else { return false }
        // Who works on what, and by which calendar: resource calendars stretch tasks.
        func workers(_ p: Project) -> [String] {
            let kinds = Dictionary(p.resources.map { ($0.uid, "\($0.type)/\($0.calendarUID ?? -1)") },
                                   uniquingKeysWith: { a, _ in a })
            return p.assignments.map { "\($0.taskUID)/\($0.resourceUID)/\(kinds[$0.resourceUID] ?? "")" }.sorted()
        }
        guard workers(self) == workers(other) else { return false }
        for (a, b) in zip(tasks, other.tasks) {
            guard a.uid == b.uid, a.parentUID == b.parentUID, a.outlineLevel == b.outlineLevel,
                  a.durationDays == b.durationDays, a.durationUnits == b.durationUnits,
                  a.constraint == b.constraint, a.constraintDate == b.constraintDate,
                  a.deadline == b.deadline, a.percentComplete == b.percentComplete,
                  a.actualStart == b.actualStart, a.actualFinish == b.actualFinish,
                  a.manual == b.manual, a.calendar == b.calendar,
                  a.splitMinutes == b.splitMinutes, a.splits == b.splits,
                  a.milestone == b.milestone else { return false }
            // A manual task's dates are typed in, so they are inputs too.
            if a.manual, a.start != b.start || a.finish != b.finish { return false }
        }
        return true
    }
}

extension Project {
    /// How many tasks a recalculation would move: rescheduled with MPPKit, the
    /// tasks whose start or finish differs by any working time from the saved
    /// dates. 0 for a file Project and MPPKit agree on.
    public func recalculationDrift() -> Int {
        var copy = self
        guard (try? Scheduler.schedule(&copy)) != nil else { return 0 }
        let time = workingTimes()
        var moved = 0
        for (a, b) in zip(tasks, copy.tasks) where !a.summary {
            guard let s0 = a.start, let f0 = a.finish, let s1 = b.start, let f1 = b.finish else { continue }
            let t = time(a)
            if t.signedMinutes(from: s0, to: s1) != 0 || t.signedMinutes(from: f0, to: f1) != 0 { moved += 1 }
        }
        return moved
    }
}

extension Project {
    /// Split tasks, as the saved dates show them: a task whose span is longer
    /// than its duration has idle time inside it (`splitMinutes`), which the
    /// scheduler keeps. Called by the readers.
    public mutating func inferSplitGaps() {
        let time = workingTimes()
        let summaries = Set(tasks.map(\.parentUID))
        for i in tasks.indices {
            let t = tasks[i]
            guard !summaries.contains(t.uid), !t.manual, !t.isElapsed, let s = t.start, let f = t.finish else { continue }
            if !t.splits.isEmpty { tasks[i].splitMinutes = t.splits.reduce(0) { $0 + $1.idleMinutes }; continue }
            let gap = time(t).minutes(from: s, to: f) - Int.clamped(t.durationDays * Double(minutesPerDay))
            tasks[i].splitMinutes = gap > 1 ? gap : 0
        }
    }
}
