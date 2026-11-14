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
import MPPCFB

/// Split tasks: where the gaps fall, read from an assignment's planned work,
/// kept as the task moves, and written back the way Project lays them out.
final class SplitTaskTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    /// Var 49 as Project saved it for a 5-day task at 100%, split after two
    /// days for three days.
    private lazy var projectOneSplit = hex("""
        03 00 20 00 2c 00 00 00 00 00 00 00 00 88 03 41 00 00 00 00 80 4f 42 41 00 b0 04 00 00 00 00 00 \
        00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 4c 2d 41 00 00 00 00 00 88 03 41 00 00 00 00 \
        00 00 00 00 00 2c 01 00 00 00 00 00 00 4c 2d 41 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 \
        00 ee 02 00 00 00 00 00 80 4f 42 41 00 00 00 00 00 88 03 41 00 00 00 00 00 00 00 00 00 b0 04 00
        """.replacingOccurrences(of: "\\\n", with: " ").replacingOccurrences(of: "\n", with: " "))

    func testGapsAreReadFromPlannedWork() {
        XCTAssertEqual(MPP.splitGaps(projectOneSplit), [TaskSplit(workMinutes: 960, idleMinutes: 1440)])
    }

    func testPlannedWorkIsWrittenAsProjectWritesIt() {
        let mine = MPP.splitPlannedWork(minutes: 2400, units: 1, gaps: [TaskSplit(workMinutes: 960, idleMinutes: 1440)])
        XCTAssertEqual(mine, projectOneSplit)
    }

    /// A split task moved by MPPKit keeps its gaps through a save, and a gap
    /// the shortened task no longer reaches is dropped.
    func testSplitTaskKeepsItsPartsWhenMoved() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Corpus")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("mpp14splittask.mpp")) else {
            throw XCTSkip("no mpp14splittask.mpp — run Tools/ci/fetch-corpus.sh")
        }
        let bytes = [UInt8](data)
        var p = try MPP14File(bytes: bytes).readProject()
        let split = try XCTUnwrap(p.tasks.first { $0.splits.count == 2 })
        let gaps = split.splits
        let i = p.tasks.firstIndex { $0.uid == split.uid }!
        p.tasks[i].constraint = "SNET"
        p.tasks[i].constraintDate = MPPTime.adding(days: 7, to: try XCTUnwrap(split.start))
        try Scheduler.schedule(&p)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("split-moved.mpp")
        try MPP14Writer(template: bytes).write(p, to: out)
        let back = try MPP14File(path: out.path).readProject()
        let moved = try XCTUnwrap(back.task(uid: split.uid))
        XCTAssertEqual(moved.splits, gaps)
        XCTAssertEqual(moved.finish, p.task(uid: split.uid)?.finish)

        var q = back
        let j = q.tasks.firstIndex { $0.uid == split.uid }!
        q.tasks[j].durationDays = Double(gaps[0].workMinutes) / Double(q.minutesPerDay) + 0.5
        try Scheduler.schedule(&q)
        XCTAssertEqual(q.task(uid: split.uid)?.splits, [gaps[0]])
    }

    /// A task at 40 % whose predecessor got longer: the done part stays, the
    /// rest resumes after the predecessor (#558). A new file keeps the gap:
    /// the planned work starts where the done part stops, with the gap at its
    /// head, and the task's Stop and Resume are either side of it.
    func testInProgressSplitReachesANewFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let template = [UInt8](try Data(contentsOf: root.appendingPathComponent("Samples/Blank-Template.mpp")))
        var p = Project(title: "Moves", start: MPPTime.date(2026, 1, 5, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        for (uid, name, days) in [(1, "P", 2.0), (2, "S", 3.0), (3, "M", 1.0)] {
            var t = ProjectTask(uid: uid, name: name)
            t.durationDays = days; t.rowID = uid; t.outlineLevel = 1
            p.tasks.append(t)
        }
        p.relations = [Relation(predUID: 1, succUID: 2), Relation(predUID: 1, succUID: 3)]
        p.resources = [Resource(uid: 1, name: "Crew")]
        p.assignments = [Assignment(taskUID: 2, resourceUID: 1)]
        try Scheduler.schedule(&p)
        p.tasks[1].percentComplete = 40
        try Scheduler.schedule(&p)
        p.tasks[0].durationDays = 4
        try Scheduler.schedule(&p)
        let s = try XCTUnwrap(p.task(uid: 2))
        XCTAssertEqual(s.splits, [TaskSplit(workMinutes: 576, idleMinutes: 384)])

        for plan in [p, { var q = p; q.assignments = []; return q }()] {
            let bytes = try MPP14Writer(template: template).build(plan)
            let file = try MPP14File(bytes: bytes)
            let back = try file.readProject()
            let b = try XCTUnwrap(back.task(uid: 2))
            XCTAssertEqual(b.splits, s.splits, "\(plan.assignments.count) assignments")
            XCTAssertEqual(b.percentComplete, 40)
            XCTAssertEqual(b.start, s.start)
            XCTAssertEqual(b.finish, s.finish)
            XCTAssertTrue(file.conformanceIssues().isEmpty)
            let k = MPP14File.EntityClass(root: file.root, storage: "\(MPP.projectStorage)/TBkndTask",
                                          metaSize: MPP.taskMetaSize, meta2Size: MPP.taskMeta2Size,
                                          propsKey: MPP.PropsKey.taskFieldMap, props: file.props)
            let i = try XCTUnwrap(k.records.indices.first { k.u32($0, MPP.TaskField.uniqueID) == 2 })
            XCTAssertEqual(k.timestamp(i, MPP.TaskField.stop), MPPTime.date(2026, 1, 8, 9, 36))
            XCTAssertEqual(k.timestamp(i, MPP.TaskField.resume), MPPTime.date(2026, 1, 9, 8))
            // Rescheduled after reading, it stays where it was.
            var again = back
            try Scheduler.schedule(&again)
            XCTAssertEqual(again.task(uid: 2)?.finish, s.finish)
            XCTAssertEqual(again.task(uid: 2)?.splits, s.splits)
        }
    }

    func testPlannedWorkUnderWayStartsWithTheGap() {
        let gap = TaskSplit(workMinutes: 576, idleMinutes: 384)
        let bytes = MPP.splitPlannedWork(minutes: 1440, units: 1, gaps: [gap], done: 576)
        XCTAssertEqual(BinaryReader(bytes).u16(at: 0), 2)
        XCTAssertEqual(MPP.splitGaps(bytes, done: 576), [gap])
        XCTAssertEqual(MPP.splitGaps(bytes), [])
        // A gap further on is counted from the start of the task.
        let later = TaskSplit(workMinutes: 960, idleMinutes: 480)
        let both = MPP.splitPlannedWork(minutes: 1440, units: 1, gaps: [gap, later], done: 576)
        XCTAssertEqual(MPP.splitGaps(both, done: 576), [gap, later])
    }
}
