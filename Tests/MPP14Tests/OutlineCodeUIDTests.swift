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
@testable import MPP14

/// A lookup table value has a row (its place) and a uid (its name). Names,
/// parents and task values refer to the uid; in Project's files the two
/// differ.
final class OutlineCodeUIDTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func guid(_ n: UInt8) -> [UInt8] { [n] + [UInt8](repeating: 0x5A, count: 14) + [n] }
    private var list: [UInt8] { guid(9) }

    /// Building A > Level 1 > Room 101, Room 102; Building A > Level 2 > Room 201.
    private func project() throws -> Project {
        var p = SampleProject.make()
        try Scheduler.schedule(&p)
        p.outlineCodeDefinitions[1] = OutlineCodeDefinition(listGUID: list, values: [
            OutlineCodeValue(guid: guid(1), name: "Building A"),
            OutlineCodeValue(guid: guid(2), name: "Level 1", parent: guid(1)),
            OutlineCodeValue(guid: guid(3), name: "Room 101", parent: guid(2)),
            OutlineCodeValue(guid: guid(4), name: "Room 102", parent: guid(2)),
            OutlineCodeValue(guid: guid(5), name: "Level 2", parent: guid(1)),
            OutlineCodeValue(guid: guid(6), name: "Room 201", parent: guid(5)),
        ])
        p.tasks[1].outlineCodeValues[1] = guid(6)
        return p
    }

    private func template() throws -> [UInt8] {
        [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
    }

    private func table(_ bytes: [UInt8]) throws -> OutlineCodeTable {
        try XCTUnwrap(OutlineCodeTable(root: try MPP14File(bytes: bytes).root))
    }

    /// Room 201's path, as read back.
    private func room201(_ bytes: [UInt8]) throws -> String? {
        let p = try MPP14File(bytes: bytes).readProject()
        return p.tasks.first { $0.outlineCodeValues[1] == guid(6) }?.outlineCodes[1]
    }

    func testNewValuesTakeFreeUIDsAndParentsNameThem() throws {
        let template = try template()
        let before = try table(template)
        // The template's own values: their uids run past their rows.
        XCTAssertTrue(before.values.contains { $0.uid != $0.row })
        let bytes = try MPP14Writer(template: template).build(try project())
        let t = try table(bytes)
        let mine = t.values.filter { $0.list == list }
        let others = Set(t.values.filter { $0.list != list }.map(\.uid))
        XCTAssertEqual(mine.count, 6)
        XCTAssertTrue(mine.allSatisfy { !others.contains($0.uid) }, "no uid another value has")
        let uidOf = Dictionary(uniqueKeysWithValues: mine.map { ($0.name, $0.uid) })
        XCTAssertEqual(mine.first { $0.name == "Room 201" }?.parent, uidOf["Level 2"])
        XCTAssertEqual(mine.first { $0.name == "Level 2" }?.parent, uidOf["Building A"])
        XCTAssertEqual(try room201(bytes), "Building A.Level 2.Room 201")
        // The template's values are as they were.
        XCTAssertEqual(t.values.filter { $0.list != list }.map(\.name), before.values.map(\.name))
    }

    /// MPPKit before 0.5.4 wrote each value's uid as its row and parents as
    /// rows, and so could repeat the template's uids. Such a file reads as
    /// it did, and its next save gives the values free uids.
    func testOlderFilesReadAndAreRenumbered() throws {
        let file = try MPP14File(bytes: try MPP14Writer(template: try template()).build(try project()))
        var t = try XCTUnwrap(OutlineCodeTable(root: file.root))
        var rowOf: [Int: Int] = [:]
        for r in t.records where t.isValue(r) && t.list(r) == list { rowOf[t.uid(r)] = t.row(r) }
        for i in t.records.indices where t.isValue(t.records[i]) && t.list(t.records[i]) == list {
            var d = t.records[i].data
            let row = t.row(t.records[i])
            let parent = Int(BinaryReader(d).u32(at: t.listAt18 ? 10 : 8) ?? 0)
            d.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(row).littleEndian) { Array($0) })
            let at = t.listAt18 ? 10 : 8
            d.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: UInt32(rowOf[parent] ?? 0).littleEndian) { Array($0) })
            t.records[i].data = d
        }
        // Their vars went after the file's own, under the row.
        let moved = t.vars.filter { rowOf[$0.uid] != nil }
        t.vars.removeAll { rowOf[$0.uid] != nil }
        t.vars += moved.map { (rowOf[$0.uid]!, $0.field, $0.payload) }
        t.write(to: file.root)
        let old = try CFBWriter.write(root: file.root)
        XCTAssertTrue(try table(old).clashes(list: list), "set up as before 0.5.4")
        XCTAssertEqual(try room201(old), "Building A.Level 2.Room 201")

        let resaved = try MPP14Writer(template: old).build(try MPP14File(bytes: old).readProject())
        XCTAssertFalse(try table(resaved).clashes(list: list))
        XCTAssertEqual(try room201(resaved), "Building A.Level 2.Room 201")
        XCTAssertEqual(try table(resaved).values.filter { $0.list != list }.map(\.name),
                       try table(try template()).values.map(\.name))
    }
}
