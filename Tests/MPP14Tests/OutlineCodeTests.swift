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

/// Task outline codes with a lookup tree, read from files Project saved and
/// written back.
final class OutlineCodeTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// MPXJ's task-outlinecodes files: tasks 1-10 each set Outline Code n to
    /// "OCnA", tasks 11-20 to "OCnA.OCnB", one level down.
    private func corpus(_ version: Int) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        let url = dir.appendingPathComponent("task-outlinecodes-project\(version)-mpp14.mpp")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("no \(url.lastPathComponent) — run Tools/ci/fetch-corpus.sh")
        }
        return [UInt8](data)
    }

    private func guid(_ n: UInt8) -> [UInt8] { [n] + [UInt8](repeating: 0x5A, count: 14) + [n] }

    func testReadsTreesProjectSaved() throws {
        for version in [2010, 2013] {
            let p = try MPP14File(bytes: try corpus(version)).readProject()
            for n in 1...10 {
                let def = try XCTUnwrap(p.outlineCodeDefinitions[n], "\(version) Outline Code\(n)")
                XCTAssertEqual(def.values.map(\.name), ["OC\(n)A", "OC\(n)B"])
                XCTAssertEqual(def.values[1].parent, def.values[0].guid)
                XCTAssertEqual(def.depth, 2)
                let flat = p.tasks.first { $0.rowID == n }, deep = p.tasks.first { $0.rowID == n + 10 }
                XCTAssertEqual(flat?.outlineCodes, [n: "OC\(n)A"], "\(version) task \(n)")
                XCTAssertEqual(deep?.outlineCodes, [n: "OC\(n)A.OC\(n)B"], "\(version) task \(n + 10)")
            }
        }
    }

    /// Saved unchanged, every table, value and task value reads back the same.
    func testUnchangedSaveKeepsThem() throws {
        let bytes = try corpus(2013)
        let p = try MPP14File(bytes: bytes).readProject()
        var options = MPP14Writer.Options()
        options.scrubTemplateIdentity = false
        let back = try MPP14File(bytes: try MPP14Writer(template: bytes, options: options).build(p)).readProject()
        XCTAssertEqual(back.outlineCodeDefinitions, p.outlineCodeDefinitions)
        XCTAssertEqual(back.tasks.map(\.outlineCodes), p.tasks.map(\.outlineCodes))
    }

    /// A new outline code with a tree, written over a blank template: the
    /// tree, the order, the name and every task's value come back, and the
    /// file keeps the rules Project's own files keep.
    func testWritesANewTree() throws {
        let template = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
        var p = SampleProject.make()
        try Scheduler.schedule(&p)
        let clinic = guid(1), wardA = guid(2), wardB = guid(3), imaging = guid(4), roomA2 = guid(5)
        let def = OutlineCodeDefinition(listGUID: guid(9), values: [
            OutlineCodeValue(guid: clinic, name: "Clinic"),
            OutlineCodeValue(guid: wardA, name: "Ward A", parent: clinic),
            OutlineCodeValue(guid: roomA2, name: "Room 2", description: "By the lift", parent: wardA),
            OutlineCodeValue(guid: wardB, name: "Ward B", parent: clinic),
            OutlineCodeValue(guid: imaging, name: "Imaging suite"),
        ])
        p.outlineCodeDefinitions[3] = def
        p.fieldAliases["outlinecode3"] = "Location"
        p.tasks[1].outlineCodeValues[3] = roomA2
        p.tasks[2].outlineCodeValues[3] = imaging

        let written = try MPP14Writer(template: template).build(p)
        let file = try MPP14File(bytes: written)
        XCTAssertTrue(file.conformanceIssues().isEmpty, "\(file.conformanceIssues().prefix(5))")
        let back = try file.readProject()
        XCTAssertEqual(back.outlineCodeDefinitions[3], def)
        XCTAssertEqual(back.fieldAliases["outlinecode3"], "Location")
        XCTAssertEqual(back.task(uid: p.tasks[1].uid)?.outlineCodes[3], "Clinic.Ward A.Room 2")
        XCTAssertEqual(back.task(uid: p.tasks[2].uid)?.outlineCodeValues[3], imaging)
        XCTAssertNil(back.task(uid: p.tasks[3].uid)?.outlineCodes[3])

        // The new values' rows (the last five 14-byte records) fit in 16
        // bits, as MPXJ reads them, and follow the template's own rows.
        let data = try CFBFile(bytes: written).root.stream(path: "   114/TBkndOutlCode/FixedData")
        let rows = (0..<5).map { i -> UInt32 in
            let at = data.count - (5 - i) * 14
            return data[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        XCTAssertTrue(rows.allSatisfy { $0 > 0 && $0 < 0x10000 }, "\(rows)")
        XCTAssertEqual(rows, (0..<5).map { rows[0] + UInt32($0) })

        // Changed again over the written file: a value renamed, one removed,
        // one added; the rows that stay keep their places.
        var next = back
        next.outlineCodeDefinitions[3]?.values.removeAll { $0.guid == wardB }
        next.outlineCodeDefinitions[3]?.values[1].name = "Ward A (east)"
        next.outlineCodeDefinitions[3]?.values.append(OutlineCodeValue(guid: guid(6), name: "Plant room"))
        let again = try MPP14File(bytes: try MPP14Writer(template: written).build(next)).readProject()
        XCTAssertEqual(again.outlineCodeDefinitions[3], next.outlineCodeDefinitions[3])
        XCTAssertEqual(again.task(uid: p.tasks[1].uid)?.outlineCodes[3], "Clinic.Ward A (east).Room 2")
    }

    /// Changing one outline code leaves the others in the same file as
    /// Project wrote them.
    func testChangingOneKeepsTheOthers() throws {
        let bytes = try corpus(2013)
        var p = try MPP14File(bytes: bytes).readProject()
        p.outlineCodeDefinitions[4]?.values.append(OutlineCodeValue(guid: guid(7), name: "OC4C"))
        var options = MPP14Writer.Options()
        options.scrubTemplateIdentity = false
        let file = try MPP14File(bytes: try MPP14Writer(template: bytes, options: options).build(p))
        let back = try file.readProject()
        XCTAssertEqual(back.outlineCodeDefinitions, p.outlineCodeDefinitions)
        XCTAssertEqual(back.tasks.map(\.outlineCodes), p.tasks.map(\.outlineCodes))
        XCTAssertTrue(file.conformanceIssues().isEmpty, "\(file.conformanceIssues().prefix(5))")
    }
}
