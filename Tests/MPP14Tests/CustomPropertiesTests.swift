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
}
