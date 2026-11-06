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
}
