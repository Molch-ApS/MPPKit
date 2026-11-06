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
import Foundation
import MPPKit
import MPPCFB

/// Tasks deleted in Project can keep their full records, marked deleted in
/// their meta flags. A task added later must not be cloned from one.
final class DeletedTaskTests: XCTestCase {

    private func blankTemplate() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Blank-Template.mpp")
        return [UInt8](try Data(contentsOf: url))
    }

    /// The file with the task records of `uids` marked deleted, as Project
    /// leaves a deleted task.
    private func deleting(_ uids: Set<Int>, in bytes: [UInt8]) throws -> [UInt8] {
        let file = try MPP14File(bytes: bytes)
        let base = "\(MPP.projectStorage)/TBkndTask"
        var fm: [UInt32: MPP.FieldItem] = [:]
        for item in MPP.parseFieldMap(file.props[MPP.PropsKey.taskFieldMap] ?? []) where item.inFixed {
            if fm[item.nativeID] == nil { fm[item.nativeID] = item }
        }
        var meta = try MPP.parseFixedMetaAuto(try file.root.stream(path: "\(base)/FixedMeta"),
                                              defaultItemSize: MPP.taskMetaSize)
        let rows = MPP.splitFixedData(try file.root.stream(path: "\(base)/FixedData"),
                                      metaItems: MPP.declaredItems(meta))
        var marked = 0
        for (i, row) in rows.enumerated() where row.count > 100 {
            guard let uid = fm[MPP.TaskField.uniqueID].flatMap({ BinaryReader(row).u32(at: $0.offset) }),
                  uids.contains(Int(uid)) else { continue }
            meta.items[i][0] |= 0x02
            marked += 1
        }
        XCTAssertEqual(marked, uids.count)
        file.root.setStream(path: "\(base)/FixedMeta", MPP.buildFixedMeta(header: meta.header, items: meta.items))
        return try CFBWriter.write(root: file.root)
    }

    func testATaskAddedAfterDeletedOnesIsSaved() throws {
        var p = Project(title: "Deleted", start: MPPTime.date(2026, 11, 9, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        for uid in 1...5 {
            var t = ProjectTask(uid: uid, name: "Task \(uid)")
            t.outlineLevel = 1; t.durationDays = 2
            // The kept task carries more fields than the deleted ones, so a
            // deleted record would be the leanest leaf to clone.
            if uid == 1 { t.notes = "Kept"; t.text = [1: "North"] }
            p.tasks.append(t)
        }
        try Scheduler.schedule(&p)
        let saved = try deleting([2, 3, 4], in: try MPP14Writer(template: try blankTemplate()).build(p))
        var read = try MPP14File(bytes: saved).readProject()
        XCTAssertEqual(read.tasks.map(\.name), ["Task 1", "Task 5"])

        let added = read.insertTask(after: 5, name: "Added", durationDays: 2)
        try Scheduler.schedule(&read)
        let again = try MPP14File(bytes: try MPP14Writer(template: saved).build(read)).readProject()
        XCTAssertEqual(again.tasks.map(\.name), ["Task 1", "Task 5", "Added"])
        XCTAssertEqual(again.task(uid: added)?.durationDays, 2)
    }
}
