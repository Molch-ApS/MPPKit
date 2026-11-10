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
import MPP14
import MPPModel

/// A summary's % complete is that of the tasks at the bottom under it,
/// each weighted by its duration, as Project rolls it up.
final class SummaryPercentTests: XCTestCase {
    /// Phase A: Task 1 (10 days, done) and sub-phase B, which holds Task 2
    /// and Task 3 (2 days each, side by side). B spans 2 days, its tasks 4.
    /// Project shows A 71 % (10 of 14 days), not 83 % (10 of 12).
    private func plan(task2: Int) throws -> Project {
        var p = Project(title: "Roll-up", start: MPPTime.date(2026, 1, 5, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        func task(_ uid: Int, _ name: String, _ days: Double, _ level: Int, _ pct: Int = 0) -> ProjectTask {
            var t = ProjectTask(uid: uid, name: name)
            t.durationDays = days
            t.outlineLevel = level
            t.percentComplete = pct
            return t
        }
        p.tasks = [task(1, "A", 0, 1), task(2, "Task 1", 10, 2, 100), task(3, "B", 0, 2),
                   task(4, "Task 2", 2, 3, task2), task(5, "Task 3", 2, 3)]
        p.normalizeOutline()
        try Scheduler.schedule(&p)
        return p
    }

    private func blank() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Blank-Template.mpp")
        return [UInt8](try Data(contentsOf: url))
    }

    func testSubPhaseCountsByItsTasksNotItsSpan() throws {
        for (task2, a, b) in [(0, 71, 0), (50, 79, 25)] {
            let p = try plan(task2: task2)
            XCTAssertEqual(Int(p.percentComplete(under: 1).rounded()), a, "A, Task 2 at \(task2) %")
            XCTAssertEqual(Int(p.percentComplete(under: 3).rounded()), b, "B, Task 2 at \(task2) %")
            XCTAssertEqual(Int(p.percentComplete().rounded()), a, "project, Task 2 at \(task2) %")

            let back = try MPP14File(bytes: try MPP14Writer(template: try blank()).build(p)).readProject()
            XCTAssertEqual(back.task(uid: 1)?.percentComplete, a, "A saved, Task 2 at \(task2) %")
            XCTAssertEqual(back.task(uid: 3)?.percentComplete, b, "B saved, Task 2 at \(task2) %")
        }
    }
}
