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

/// A resource's own calendar, its working week and exceptions, is saved
/// with the resource.
final class ResourceCalendarTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testOwnExceptionsAndWeekAreSaved() throws {
        let bytes = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
        var p = try MPP14File(bytes: bytes).readProject()
        var r = Resource(uid: 1, name: "Crew")
        r.calendarUID = 900
        p.resources = [r]
        var own = ProjectCalendar(name: "Crew")
        own.uid = 900
        own.resourceUID = 1
        own.baseCalendarUID = p.calendar?.uid
        own.week = [7: [480...720]]
        own.exceptions = [CalendarException(start: MPPTime.date(2026, 2, 16), name: "Course")]
        p.resourceCalendars = [own]

        let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(p)).readProject()
        let crew = try XCTUnwrap(back.resources.first { $0.uid == 1 })
        let cal = try XCTUnwrap(back.resourceCalendars.first { $0.uid == crew.calendarUID })
        XCTAssertEqual(cal.week, own.week)
        XCTAssertEqual(cal.exceptions.map(\.start), own.exceptions.map(\.start))
        XCTAssertEqual(cal.exceptions.map(\.working), [[]])
    }

    /// MPXJ's corpus (`Tools/ci/fetch-corpus.sh`): resources with days off
    /// and extra working days of their own, saved over themselves.
    func testCorpusResourceCalendarsAreKept() throws {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        var checked = 0
        for name in ["mpp14timephased2.mpp", "mpp14timephasedsegments.mpp", "mpp14timephasedsegmentsmanual.mpp"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            let bytes = [UInt8](data)
            let read = try MPP14File(bytes: bytes).readProject()
            let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(read)).readProject()
            func own(_ p: Project) -> [Int: ProjectCalendar] {
                Dictionary(uniqueKeysWithValues: p.resources.compactMap { r in
                    p.resourceCalendars.first { $0.uid == r.calendarUID }.map { (r.uid, $0) } })
            }
            let a = own(read), b = own(back)
            XCTAssertEqual(a.keys.sorted(), b.keys.sorted(), name)
            XCTAssertFalse(a.values.allSatisfy { $0.exceptions.isEmpty }, "\(name) has resource exceptions")
            for (uid, cal) in a {
                XCTAssertEqual(b[uid]?.week, cal.week, "\(name) resource \(uid)")
                XCTAssertEqual(b[uid]?.exceptions, cal.exceptions, "\(name) resource \(uid)")
                XCTAssertEqual(b[uid]?.name, cal.name, "\(name) resource \(uid)")
            }
            checked += 1
        }
        if checked == 0 { throw XCTSkip("no corpus in \(dir.path) — run Tools/ci/fetch-corpus.sh") }
    }
}
