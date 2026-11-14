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

/// Scheduling rules where Project's answer is set by its own options and
/// field definitions: constraints that win over links, actual finishes,
/// summaries, free slack and inactive tasks.
final class ProjectRulesTests: XCTestCase {
    private func d(_ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date { MPPTime.date(2026, m, day, h, min) }

    /// Monday 2 Nov 2026, Monday to Friday 08:00–12:00, 13:00–17:00.
    private func plan(_ tasks: [ProjectTask], _ relations: [Relation] = []) -> Project {
        var p = Project(title: "Rules", start: d(11, 2, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        p.tasks = tasks
        for i in p.tasks.indices {
            p.tasks[i].rowID = i + 1
            if p.tasks[i].outlineLevel == 0 { p.tasks[i].outlineLevel = 1 }
        }
        p.relations = relations
        return p
    }

    private func task(_ uid: Int, _ days: Double, _ configure: (inout ProjectTask) -> Void = { _ in }) -> ProjectTask {
        var t = ProjectTask(uid: uid, name: "Task \(uid)")
        t.durationDays = days
        configure(&t)
        return t
    }

    // MARK: No later than

    /// Project honours constraint dates by default: a Start No Later Than
    /// holds the task at its date against a later link, and the predecessor
    /// shows the overlap as negative slack.
    func testStartNoLaterThanWinsOverALink() throws {
        var p = plan([task(1, 5), task(2, 2) { $0.constraint = "SNLT"; $0.constraintDate = self.d(11, 4, 8) }],
                     [Relation(predUID: 1, succUID: 2)])
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[1].start, d(11, 4, 8))
        XCTAssertEqual(p.tasks[1].finish, d(11, 5, 17))
        // Finish Friday 17:00, late finish Tuesday 17:00: three days short.
        XCTAssertEqual(p.totalFloatMinutes(uid: 1), -3 * 480)
        XCTAssertTrue(p.isCritical(uid: 1))

        p.honorsConstraintDates = false
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[1].start, d(11, 9, 8))
    }

    func testFinishNoLaterThanWinsOverALink() throws {
        var p = plan([task(1, 5), task(2, 2) { $0.constraint = "FNLT"; $0.constraintDate = self.d(11, 6, 17) }],
                     [Relation(predUID: 1, succUID: 2)])
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[1].start, d(11, 5, 8))
        XCTAssertEqual(p.tasks[1].finish, d(11, 6, 17))
        XCTAssertEqual(p.totalFloatMinutes(uid: 1), -2 * 480)
    }

    /// With room to spare the constraint changes nothing: the task starts as
    /// soon as it can.
    func testNoLaterThanWithRoomStaysAsSoonAsPossible() throws {
        var p = plan([task(1, 2), task(2, 2) { $0.constraint = "SNLT"; $0.constraintDate = self.d(11, 20, 8) }],
                     [Relation(predUID: 1, succUID: 2)])
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[1].start, d(11, 4, 8))
        XCTAssertEqual(p.totalFloatMinutes(uid: 1), 0)
    }
}
