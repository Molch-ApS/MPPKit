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
import MPPModel
import MPPKit

/// A started task whose predecessor moves later, against Microsoft Project:
/// P is 2 days, S 3 days, from Monday 5 January 2026; S's % complete is set,
/// then P becomes 4 days long ("longer") or starts no earlier than Wednesday
/// ("later"). With "Split in-progress tasks" on (Project's default) the done
/// part stays and the rest resumes after the predecessor; off, S stays put.
final class StartedTaskTests: XCTestCase {
    private func d(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { MPPTime.date(2026, 1, day, h, m) }

    private struct Row {
        let split: Bool, link: String, pct: Int, longer: Bool
        let start: (Int, Int, Int), finish: (Int, Int, Int)
        /// Where the done part stops and the rest resumes, when S is split.
        let stop: (Int, Int, Int)?, resume: (Int, Int, Int)?
    }

    private func run(_ r: Row) throws -> ProjectTask {
        var p = Project(title: "T", start: d(5, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        p.splitsInProgressTasks = r.split
        var pred = ProjectTask(uid: 1, name: "P"); pred.durationDays = 2; pred.rowID = 1
        var succ = ProjectTask(uid: 2, name: "S"); succ.durationDays = 3; succ.rowID = 2
        p.tasks = [pred, succ]
        p.relations = [Relation(predUID: 1, succUID: 2, type: r.link)]
        try Scheduler.schedule(&p)
        // Progress is entered where S is before P moves.
        if r.pct > 0 {
            p.tasks[1].percentComplete = r.pct
            p.tasks[1].actualStart = p.tasks[1].start
        }
        try Scheduler.schedule(&p)
        if r.longer { p.tasks[0].durationDays = 4 } else {
            p.tasks[0].constraint = "SNET"; p.tasks[0].constraintDate = d(7, 8)
        }
        try Scheduler.schedule(&p)
        return p.tasks[1]
    }

    private func check(_ rows: [Row], file: StaticString = #filePath, line: UInt = #line) throws {
        for r in rows {
            let s = try run(r)
            let label = "split \(r.split) \(r.link) \(r.pct)% \(r.longer ? "longer" : "later")"
            XCTAssertEqual(s.start, d(r.start.0, r.start.1, r.start.2), label, file: file, line: line)
            XCTAssertEqual(s.finish, d(r.finish.0, r.finish.1, r.finish.2), label, file: file, line: line)
            XCTAssertEqual(s.durationDays, 3, label, file: file, line: line)
            if let stop = r.stop, let resume = r.resume {
                XCTAssertEqual(s.splits.count, 1, label, file: file, line: line)
                let wt = WorkingTime(calendar: ProjectCalendar(name: "Standard"))
                let a = try XCTUnwrap(s.actualStart, label)
                let split = try XCTUnwrap(s.splits.first, label)
                let stopAt = wt.advance(a, minutes: split.workMinutes)
                XCTAssertEqual(stopAt, d(stop.0, stop.1, stop.2), label, file: file, line: line)
                XCTAssertEqual(wt.minutes(from: stopAt, to: d(resume.0, resume.1, resume.2)), split.idleMinutes,
                               label, file: file, line: line)
            } else {
                XCTAssertTrue(s.splits.isEmpty, label, file: file, line: line)
            }
        }
    }

    func testSplitInProgressTasksOn() throws {
        try check([
            Row(split: true, link: "FS", pct: 0, longer: true, start: (9, 8, 0), finish: (13, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "FS", pct: 0, longer: false, start: (9, 8, 0), finish: (13, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "FS", pct: 40, longer: true, start: (7, 8, 0), finish: (12, 15, 24),
                stop: (8, 9, 36), resume: (9, 8, 0)),
            Row(split: true, link: "FS", pct: 40, longer: false, start: (7, 8, 0), finish: (12, 15, 24),
                stop: (8, 9, 36), resume: (9, 8, 0)),
            Row(split: true, link: "FS", pct: 100, longer: true, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "FS", pct: 100, longer: false, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "SS", pct: 0, longer: true, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "SS", pct: 0, longer: false, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "SS", pct: 40, longer: true, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "SS", pct: 40, longer: false, start: (5, 8, 0), finish: (8, 15, 24),
                stop: (6, 9, 36), resume: (7, 8, 0)),
            Row(split: true, link: "SS", pct: 100, longer: true, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
            Row(split: true, link: "SS", pct: 100, longer: false, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
        ])
    }

    func testSplitInProgressTasksOff() throws {
        try check([
            Row(split: false, link: "FS", pct: 0, longer: true, start: (9, 8, 0), finish: (13, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "FS", pct: 0, longer: false, start: (9, 8, 0), finish: (13, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "FS", pct: 40, longer: true, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "FS", pct: 40, longer: false, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "FS", pct: 100, longer: true, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "FS", pct: 100, longer: false, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "SS", pct: 0, longer: true, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "SS", pct: 0, longer: false, start: (7, 8, 0), finish: (9, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "SS", pct: 40, longer: true, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "SS", pct: 40, longer: false, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "SS", pct: 100, longer: true, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
            Row(split: false, link: "SS", pct: 100, longer: false, start: (5, 8, 0), finish: (7, 17, 0), stop: nil, resume: nil),
        ])
    }
}
