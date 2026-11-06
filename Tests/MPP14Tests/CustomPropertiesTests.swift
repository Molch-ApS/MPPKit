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

/// File > Properties > Custom: the user-defined section of
/// `DocumentSummaryInformation`, read and written by name.
final class CustomPropertiesTests: XCTestCase {

    /// A `DocumentSummaryInformation` with only its first section: a code
    /// page (1252) and a company.
    private func firstSectionOnly() -> [UInt8] {
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        let fmtid: [UInt8] = [0x02, 0xD5, 0xCD, 0xD5, 0x9C, 0x2E, 0x1B, 0x10,
                              0x93, 0x97, 0x08, 0x00, 0x2B, 0x2C, 0xF9, 0xAE]
        let codePage: [UInt8] = le(2) + [0xE4, 0x04, 0, 0]
        let company: [UInt8] = le(30) + le(5) + Array("Acme".utf8) + [0, 0, 0, 0]
        let body = codePage + company
        let section = le(UInt32(8 + 16 + body.count)) + le(2) + le(1) + le(24) + le(15) + le(32) + body
        let header: [UInt8] = [0xFE, 0xFF, 0, 0, 0x06, 0x01, 0x02, 0] + [UInt8](repeating: 0, count: 16) + le(1)
        return header + fmtid + le(48) + section
    }

    private func strings(_ bytes: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in OLEPropertySet.userProperties(bytes) { out[name] = value.stringValue }
        return out
    }

    func testAddsTheSectionInUTF8AndKeepsTheRest() {
        let base = firstSectionOnly()
        let bytes = OLEPropertySet.updatingUserProperties(base, ["Client": "Ærø Ølbryggeri", "Phase": "2"])
        XCTAssertEqual(strings(bytes), ["Client": "Ærø Ølbryggeri", "Phase": "2"])
        let doc = OLEPropertySet.parse(bytes)
        XCTAssertEqual(doc.sections.count, 2)
        XCTAssertEqual(doc[0]?.string(15), "Acme")
        XCTAssertEqual(doc[1]?.formatID, OLEPropertySet.userDefinedFormatID)
        XCTAssertEqual(doc[1]?[1], .int(-535))       // 65001 as a VT_I2, as Project writes it
        // Nothing to remove: unchanged.
        XCTAssertEqual(OLEPropertySet.updatingUserProperties(base, ["Gone": nil]), base)
    }

    func testReplacesAndRemovesByNameWithoutCase() {
        var bytes = OLEPropertySet.updatingUserProperties(firstSectionOnly(), ["A": "1", "B": "2", "C": "3"])
        bytes = OLEPropertySet.updatingUserProperties(bytes, ["b": "two", "C": nil, "D": "4"])
        XCTAssertEqual(strings(bytes), ["A": "1", "B": "two", "D": "4"])
        XCTAssertEqual(OLEPropertySet.parse(bytes)[0]?.string(15), "Acme")
    }

    func testManyLargeValues() {
        var values: [String: String?] = [:]
        for i in 0..<12 { values[String(format: "Part.%03d", i)] = String(repeating: "x\(i)", count: 6_000) }
        let bytes = OLEPropertySet.updatingUserProperties(firstSectionOnly(), values)
        XCTAssertEqual(strings(bytes), values.mapValues { $0! })
    }

    /// Through the writer and reader: set, changed, removed; a value of
    /// another type in the file is kept.
    func testRoundTripThroughTheWriter() throws {
        let template = try MPP14Template.neutralized(try Fixture.bytes())
        var p = SampleProject.make()
        try Scheduler.schedule(&p)
        p.customProperties = ["Plan.000": "eJzLSM3JyVcozy/KSQEAGgQEXQ==", "Owner": "Åsa"]
        let first = try MPP14Writer(template: template).build(p)
        var read = try MPP14File(bytes: first).readProject()
        XCTAssertEqual(read.customProperties, p.customProperties)

        read.customProperties["Owner"] = nil
        read.customProperties["Plan.001"] = "more"
        let again = try MPP14File(bytes: try MPP14Writer(template: first).build(read)).readProject()
        XCTAssertEqual(again.customProperties, ["Plan.000": "eJzLSM3JyVcozy/KSQEAGgQEXQ==", "Plan.001": "more"])
    }

    // MARK: Properties linked to content

    /// The blank template's `DocumentSummaryInformation`: seven properties
    /// linked to content (% Complete, Cost, …), each a value at its id and
    /// its source at the id plus the link flag.
    private func templateDSI() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Blank-Template.mpp")
        return try MPP14File(bytes: [UInt8](try Data(contentsOf: url))).root.stream("\u{5}DocumentSummaryInformation")
    }

    /// The user-defined section's property ids, and its names by id
    /// (code page 1252: one byte a character, names not padded).
    private func ids(_ bytes: [UInt8]) -> (ids: Set<UInt32>, names: [UInt32: String]) {
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        let section = Int(u32(28 + 20 + 16))
        var ids = Set<UInt32>(), names: [UInt32: String] = [:]
        for k in 0..<Int(u32(section + 4)) {
            let entry = section + 8 + 8 * k
            ids.insert(u32(entry))
            guard u32(entry) == 0 else { continue }
            var q = section + Int(u32(entry + 4))
            let n = Int(u32(q)); q += 4
            for _ in 0..<n {
                let length = Int(u32(q + 4))
                names[u32(q)] = String(decoding: bytes[(q + 8)..<(q + 8 + length)].prefix { $0 != 0 }, as: UTF8.self)
                q += 8 + length
            }
        }
        return (ids, names)
    }

    func testLinkedPropertiesAreProjects() throws {
        let dsi = try templateDSI()
        XCTAssertEqual(strings(dsi), [:], "linked properties aren't the plan's")
        let before = ids(dsi)
        XCTAssertTrue(before.ids.contains(5 | OLEPropertySet.linkFlag))

        // A new value takes the next value id, never one with the link flag.
        let bytes = OLEPropertySet.updatingUserProperties(dsi, ["Client": "Northfield", "Planlagt slutdato": nil])
        XCTAssertEqual(strings(bytes), ["Client": "Northfield"])
        let after = ids(bytes)
        let client = try XCTUnwrap(after.names.first { $0.value == "Client" }?.key)
        XCTAssertEqual(client & OLEPropertySet.linkFlag, 0)
        XCTAssertFalse(after.ids.contains(client | OLEPropertySet.linkFlag), "no link is left at its id")
        // Every linked property is kept, value and source.
        XCTAssertTrue(before.ids.isSubset(of: after.ids))
        XCTAssertEqual(after.names.filter { $0.value != "Client" }, before.names)
    }

    /// MPPKit before 0.5.4 gave new values ids after a link's: they're read,
    /// and the next write moves them to values' ids.
    func testValuesNumberedAsLinksMove() throws {
        var bytes = OLEPropertySet.updatingUserProperties(try templateDSI(), ["Client": "Northfield", "Phase": "2"])
        let (_, names) = ids(bytes)
        for (id, name) in names where ["Client", "Phase"].contains(name) {
            bytes = Self.renumber(bytes, id, id | OLEPropertySet.linkFlag)
        }
        XCTAssertTrue(ids(bytes).names.keys.contains { $0 & OLEPropertySet.linkFlag != 0 }, "set up as before 0.5.4")
        XCTAssertEqual(strings(bytes), ["Client": "Northfield", "Phase": "2"])

        let moved = OLEPropertySet.updatingUserProperties(bytes, [:])
        XCTAssertEqual(strings(moved), ["Client": "Northfield", "Phase": "2"])
        XCTAssertFalse(ids(moved).names.keys.contains { $0 & OLEPropertySet.linkFlag != 0 })
        // Nothing to move: left as it is.
        XCTAssertEqual(OLEPropertySet.updatingUserProperties(moved, [:]), moved)
    }

    /// Text a 1252 section can't hold makes it UTF-8; what it had is kept.
    func testTextOutsideTheCodePageMakesTheSectionUTF8() throws {
        let dsi = try templateDSI()
        XCTAssertEqual(OLEPropertySet.parse(dsi)[1]?[1], .int(1252))
        var bytes = OLEPropertySet.updatingUserProperties(dsi, ["Client": "Blåbærgrød, Straße, café"])
        XCTAssertEqual(OLEPropertySet.parse(bytes)[1]?[1], .int(1252), "1252 holds these")
        let world = ["Greek": "Ελληνικά", "Polish": "Łódź, Gdańsk", "Chinese": "日本語, 北京",
                     "Emoji": "Done ✓ 🏗️", "Ærø zone": "Kælder"]
        bytes = OLEPropertySet.updatingUserProperties(bytes, world.mapValues { $0 })
        XCTAssertEqual(OLEPropertySet.parse(bytes)[1]?[1], .int(-535), "65001 as a VT_I2")
        XCTAssertEqual(strings(bytes), world.merging(["Client": "Blåbærgrød, Straße, café"]) { a, _ in a })
        // The linked properties' names and values come through.
        let names = Set(OLEPropertySet.parse(bytes)[1]!.properties.keys)
        XCTAssertTrue(names.isSuperset(of: [5, 5 | OLEPropertySet.linkFlag]))
        XCTAssertEqual(OLEPropertySet.parse(bytes)[1]?.string(5 | OLEPropertySet.linkFlag), "Planlagt slutdato")
    }

    /// Changes property `from` to `to` in the user-defined section: its
    /// entry in the id table and in the dictionary (code page 1252, so the
    /// dictionary's names aren't padded).
    private static func renumber(_ bytes: [UInt8], _ from: UInt32, _ to: UInt32) -> [UInt8] {
        var b = bytes
        func u32(_ at: Int) -> UInt32 { UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24 }
        func put(_ at: Int, _ v: UInt32) { for k in 0..<4 { b[at + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) } }
        let section = Int(u32(28 + 20 + 16))
        let count = Int(u32(section + 4))
        for k in 0..<count {
            let entry = section + 8 + 8 * k
            if u32(entry) == from { put(entry, to) }
            if u32(entry) == 0 {
                var q = section + Int(u32(entry + 4))
                let n = Int(u32(q)); q += 4
                for _ in 0..<n {
                    if u32(q) == from { put(q, to) }
                    q += 8 + Int(u32(q + 4))
                }
            }
        }
        return b
    }
}
