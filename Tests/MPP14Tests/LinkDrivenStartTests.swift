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

/// The writer pins a start nothing explains with Start No Earlier Than, as
/// Project pins a typed-in date. A start a link produces is not pinned,
/// whatever the link.
final class LinkDrivenStartTests: XCTestCase {
    private func blank() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Blank-Template.mpp")
        return [UInt8](try Data(contentsOf: url))
    }

    private func task(_ uid: Int, _ days: Double, level: Int = 1) -> ProjectTask {
        var t = ProjectTask(uid: uid, name: "Task \(uid)")
        t.durationDays = days
        t.outlineLevel = level
        return t
    }

    /// Monday 5 Jan 2026, Standard calendar.
    private func plan(_ tasks: [ProjectTask], _ relations: [Relation]) throws -> Project {
        var p = Project(title: "Links", start: MPPTime.date(2026, 1, 5, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        p.tasks = tasks
        p.normalizeOutline()
        p.relations = relations
        try Scheduler.schedule(&p)
        return p
    }

    private func saved(_ p: Project) throws -> Project {
        try MPP14File(bytes: try MPP14Writer(template: try blank()).build(p)).readProject()
    }

    func testStartsLinksProduceAreNotPinned() throws {
        let p = try plan([task(1, 3),              // A
                          task(2, 1),              // FF from A
                          task(3, 0),              // a summary linked from A
                          task(4, 1, level: 2),    //   under it
                          task(5, 1),              // FS from A, 3 elapsed days
                          task(6, 1),              // SS from A, half of A
                          task(7, 2),              // FS from A
                          task(8, 1)],             // SF from 7
                         [Relation(predUID: 1, succUID: 2, type: "FF"),
                          Relation(predUID: 1, succUID: 3),
                          Relation(predUID: 1, succUID: 5, lagDays: 3, lagUnits: "ed"),
                          Relation(predUID: 1, succUID: 6, type: "SS", lagDays: 0.5, lagUnits: "%"),
                          Relation(predUID: 1, succUID: 7),
                          Relation(predUID: 7, succUID: 8, type: "SF")])
        for uid in [2, 4, 5, 6, 8] {
            XCTAssertGreaterThan(p.task(uid: uid)!.start!, p.start, "task \(uid) starts after the project")
        }
        let back = try saved(p)
        for t in back.tasks {
            XCTAssertNil(t.constraint, "task \(t.uid)")
            XCTAssertEqual(t.start, p.task(uid: t.uid)?.start, "task \(t.uid)")
        }
    }

    /// The reason for the rule: a start set on a task, with nothing to
    /// explain it, stays where it was put once Project recalculates.
    func testAStartNothingExplainsIsPinned() throws {
        var p = try plan([task(1, 2), task(2, 1)], [])
        let wednesday = MPPTime.date(2026, 1, 7, 8)
        p.tasks[1].start = wednesday
        p.tasks[1].finish = MPPTime.date(2026, 1, 7, 17)
        let back = try saved(p)
        XCTAssertNil(back.task(uid: 1)?.constraint)
        XCTAssertEqual(back.task(uid: 2)?.constraint, "SNET")
        XCTAssertEqual(back.task(uid: 2)?.constraintDate, wednesday)
    }
}
