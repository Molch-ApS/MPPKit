// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import MPP14
import MPPModel

/// A task is worked in its resources' calendars, as Project schedules it: a
/// crew on leave stretches the task, and the leave stays on its days when the
/// task moves.
final class ResourceCalendarSchedulingTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func d(_ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date { MPPTime.date(2026, m, day, h, min) }

    /// Monday 2 Nov 2026; "Crew" (uid 1) on leave Wednesday 4 Nov, "Other"
    /// (uid 2) on the project calendar.
    private func plan(_ days: Double = 3, resources: [Int] = [1]) -> Project {
        var p = Project(title: "Leave", start: d(11, 2, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        p.calendar?.uid = 1
        var crew = Resource(uid: 1, name: "Crew"); crew.calendarUID = 10
        var other = Resource(uid: 2, name: "Other"); other.calendarUID = 11
        p.resources = [crew, other]
        var leave = ProjectCalendar(name: "Crew")
        leave.uid = 10; leave.resourceUID = 1; leave.baseCalendarUID = 1
        leave.exceptions = [CalendarException(start: d(11, 4), name: "Leave")]
        var plain = ProjectCalendar(name: "Other")
        plain.uid = 11; plain.resourceUID = 2; plain.baseCalendarUID = 1
        p.resourceCalendars = [leave, plain]
        var t = ProjectTask(uid: 1, name: "Pour"); t.durationDays = days; t.rowID = 1; t.outlineLevel = 1
        p.tasks = [t]
        p.assignments = resources.map { Assignment(taskUID: 1, resourceUID: $0) }
        return p
    }

    func testLeaveStretchesTheTask() throws {
        var p = plan()
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[0].start, d(11, 2, 8))
        XCTAssertEqual(p.tasks[0].finish, d(11, 5, 17))
        XCTAssertEqual(p.tasks[0].durationDays, 3)
        // On the project calendar, the same task is done on Wednesday.
        var q = plan(resources: [2])
        try Scheduler.schedule(&q)
        XCTAssertEqual(q.tasks[0].finish, d(11, 4, 17))
    }

    func testTheLeaveStaysOnItsDayWhenTheTaskMoves() throws {
        var p = plan()
        p.tasks[0].constraint = "SNET"
        p.tasks[0].constraintDate = d(11, 5, 8)
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[0].start, d(11, 5, 8))
        XCTAssertEqual(p.tasks[0].finish, d(11, 9, 17))
        XCTAssertEqual(p.tasks[0].splitMinutes, 0)
        // Starting on the day off, the work begins the day after.
        p.tasks[0].constraintDate = d(11, 4, 8)
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[0].start, d(11, 5, 8))
    }

    /// Two resources each work their own calendar: the task is done when the
    /// one on leave is.
    func testResourcesWorkSideBySide() throws {
        var p = plan(resources: [1, 2])
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[0].start, d(11, 2, 8))
        XCTAssertEqual(p.tasks[0].finish, d(11, 5, 17))
    }

    /// A task with a calendar of its own is worked where it and the
    /// resource's calendar overlap.
    func testTaskCalendarAndResourceCalendarOverlap() throws {
        var p = plan(2)
        var mornings = ProjectCalendar(name: "Mornings")
        mornings.uid = 2
        for weekday in 2...6 { mornings.week[weekday] = [480...720] }
        p.calendars = [mornings]
        p.tasks[0].calendar = "Mornings"
        try Scheduler.schedule(&p)
        // Four mornings of four hours, Wednesday off: Mon, Tue, Thu, Fri.
        XCTAssertEqual(p.tasks[0].finish, d(11, 6, 12))
    }

    /// A material resource has no calendar to keep.
    func testMaterialDoesNotStretch() throws {
        var p = plan()
        p.resources[0].type = "material"
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[0].finish, d(11, 4, 17))
    }

    /// Read back from a file, the leave is the resource's, not a split: moved
    /// a week later, the task takes its three days (the old reading kept the
    /// day off as a gap and finished a day late).
    func testAFileKeepsTheLeaveWithTheResource() throws {
        let template = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
        var p = try MPP14File(bytes: template).readProject()
        let base = p.calendar?.uid
        var crew = Resource(uid: 1, name: "Crew"); crew.calendarUID = 900
        p.resources = [crew]
        var leave = ProjectCalendar(name: "Crew")
        leave.uid = 900; leave.resourceUID = 1; leave.baseCalendarUID = base
        leave.exceptions = [CalendarException(start: d(11, 4), name: "Leave")]
        p.resourceCalendars = [leave]
        p.start = d(11, 2, 8)
        var t = ProjectTask(uid: 1, name: "Pour"); t.durationDays = 3; t.rowID = 1; t.outlineLevel = 1
        p.tasks = [t]
        p.relations = []
        p.assignments = [Assignment(taskUID: 1, resourceUID: 1)]
        try Scheduler.schedule(&p)
        let finish = try XCTUnwrap(p.tasks[0].finish)
        var back = try MPP14File(bytes: try MPP14Writer(template: template).build(p)).readProject()
        XCTAssertEqual(back.task(uid: 1)?.finish, finish)
        XCTAssertEqual(back.task(uid: 1)?.splitMinutes, 0)
        let i = try XCTUnwrap(back.tasks.firstIndex { $0.uid == 1 })
        back.tasks[i].constraint = "SNET"
        back.tasks[i].constraintDate = d(11, 9, 8)
        var unassigned = back
        unassigned.assignments = []
        try Scheduler.schedule(&back)
        try Scheduler.schedule(&unassigned)
        XCTAssertEqual(back.tasks[i].finish, unassigned.tasks[i].finish)
        XCTAssertGreaterThan(finish, try XCTUnwrap(p.tasks[0].start).addingTimeInterval(3 * 86_400))
    }

    /// MPXJ's corpus: resources with days off of their own. Project's dates
    /// come out of the scheduler unchanged, and none of the stretch is read as
    /// a split.
    func testCorpusTasksOnResourceCalendars() throws {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        var checked = 0
        for name in ["mpp14timephased2.mpp", "mpp14timephasedsegments.mpp"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            let read = try MPP14File(bytes: [UInt8](data)).readProject()
            var mine = read
            try Scheduler.schedule(&mine)
            let leaveTasks = Set(read.assignments.filter { read.resourceWorkingTimes()[$0.resourceUID] != nil }.map(\.taskUID))
            XCTAssertFalse(leaveTasks.isEmpty, name)
            for t in read.tasks where !t.summary {
                let m = try XCTUnwrap(mine.task(uid: t.uid))
                // Project keeps seconds MPPKit doesn't: to the minute.
                XCTAssertEqual(m.start.map(MPPTime.isoMinute), t.start.map(MPPTime.isoMinute), "\(name) \(t.name)")
                XCTAssertEqual(m.finish.map(MPPTime.isoMinute), t.finish.map(MPPTime.isoMinute), "\(name) \(t.name)")
                if leaveTasks.contains(t.uid) { XCTAssertEqual(t.splitMinutes, 0, "\(name) \(t.name)") }
            }
            checked += 1
        }
        if checked == 0 { throw XCTSkip("no corpus in \(dir.path) — run Tools/ci/fetch-corpus.sh") }
    }
}
