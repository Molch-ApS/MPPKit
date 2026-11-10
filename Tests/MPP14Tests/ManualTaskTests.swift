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

/// A task's mode in files saved before Project 2016, which have no field 1408:
/// a bit of the task's Fixed2Meta item. Checked in Microsoft Project by
/// flipping that bit alone: in `mpp14columns.mpp` (92-byte items) bit 0x08
/// makes its task automatic, and in the Project 2013 outline-code file
/// (93-byte items) bit 0x80 does, while 0x08 changes nothing there.
final class ManualTaskTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func corpus(_ name: String) -> [UInt8]? {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        return (try? Data(contentsOf: dir.appendingPathComponent(name))).map { [UInt8]($0) }
    }

    /// The tasks Project shows as manual: the one in `mpp14columns.mpp`, all
    /// 20 in the 2013 file, none in the 2010 file with the same tasks.
    func testCorpusTaskModeIsRead() throws {
        var checked = 0
        for (name, manual) in [("mpp14columns.mpp", 1), ("task-outlinecodes-project2013-mpp14.mpp", 20),
                               ("task-outlinecodes-project2010-mpp14.mpp", 0)] {
            guard let bytes = corpus(name) else { continue }
            let p = try MPP14File(bytes: bytes).readProject()
            let leaves = p.tasks.filter { !$0.summary }
            XCTAssertEqual(leaves.filter(\.manual).count, manual, name)
            checked += 1
        }
        if checked == 0 { throw XCTSkip("no corpus — run Tools/ci/fetch-corpus.sh") }
    }

    /// Saved over themselves, manual tasks keep their mode, their Start,
    /// Finish and Duration, and every field Project schedules them by, byte
    /// for byte: the manual pair and duration, the units word, the schedule
    /// driver and its dates, and the flag word.
    func testCorpusManualTasksAreSavedAsTheyWere() throws {
        var checked = 0
        for name in ["mpp14columns.mpp", "task-outlinecodes-project2013-mpp14.mpp"] {
            guard let bytes = corpus(name) else { continue }
            let read = try MPP14File(bytes: bytes).readProject()
            let saved = try MPP14Writer(template: bytes).build(read)
            let back = try MPP14File(bytes: saved).readProject()
            for t in read.tasks where !t.summary {
                let b = try XCTUnwrap(back.task(uid: t.uid), name)
                XCTAssertTrue(b.manual, "\(name) task \(t.uid)")
                XCTAssertEqual(b.start, t.start, "\(name) task \(t.uid)")
                XCTAssertEqual(b.finish, t.finish, "\(name) task \(t.uid)")
                XCTAssertEqual(b.durationDays, t.durationDays, "\(name) task \(t.uid)")
            }

            func table(_ b: [UInt8]) throws -> MPP14File.EntityClass {
                let f = try MPP14File(bytes: b)
                return MPP14File.EntityClass(root: f.root, storage: "\(MPP.projectStorage)/TBkndTask",
                                             metaSize: MPP.taskMetaSize, meta2Size: MPP.taskMeta2Size,
                                             propsKey: MPP.PropsKey.taskFieldMap, props: f.props)
            }
            let a = try table(bytes), z = try table(saved)
            func rows(_ k: MPP14File.EntityClass) -> [UInt32: Int] {
                var out: [UInt32: Int] = [:]
                for i in k.records.indices where k.records[i].count > 100 {
                    if let uid = k.u32(i, MPP.TaskField.uniqueID), uid > 0 { out[uid] = i }
                }
                return out
            }
            let ra = rows(a), rz = rows(z)
            let F = MPP.TaskField.self
            let fields: [(UInt32, Int)] = [(F.manualStart, 4), (F.manualFinish, 4), (F.manualDuration, 4),
                                           (F.manualDurationUnits, 2), (F.actualDurationUnits, 2),
                                           (F.scheduleDriver, 4), (F.summaryProgress, 4),
                                           (F.summaryProgressPrior, 4), (F.taskFlags, 4)]
            for (uid, i) in ra {
                let j = try XCTUnwrap(rz[uid], "\(name) task \(uid)")
                XCTAssertTrue(z.manuallyScheduled(j), "\(name) task \(uid)")
                for (id, n) in fields where a.fieldMap[id] != nil {
                    XCTAssertEqual(z.bytes(j, id, count: n), a.bytes(i, id, count: n), "\(name) task \(uid) field \(id)")
                }
            }
            checked += 1
        }
        if checked == 0 { throw XCTSkip("no corpus — run Tools/ci/fetch-corpus.sh") }
    }

    /// Switched to automatic and saved, the old file's bit is cleared, so
    /// Project shows the task as automatic too.
    func testSwitchingToAutoClearsTheOldBit() throws {
        guard let bytes = corpus("mpp14columns.mpp") else { throw XCTSkip("no corpus — run Tools/ci/fetch-corpus.sh") }
        var p = try MPP14File(bytes: bytes).readProject()
        let i = try XCTUnwrap(p.tasks.firstIndex { $0.manual })
        p.tasks[i].manual = false
        let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(p)).readProject()
        XCTAssertFalse(back.tasks.contains { $0.manual })
    }
}
