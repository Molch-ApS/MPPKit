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

/// A project whose calendar is not the one called Standard keeps both: its
/// own calendar in its own row, and Standard as it was, with the resources
/// based on it.
final class ProjectCalendarTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func blank() throws -> [UInt8] {
        [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
    }

    func testProjectCalendarOtherThanStandardKeepsBoth() throws {
        let bytes = try blank()
        var p = try MPP14File(bytes: bytes).readProject()
        let standard = try XCTUnwrap(p.calendar)
        var day = try XCTUnwrap(p.calendars.first)
        XCTAssertNotEqual(day.uid, standard.uid)
        day.name = "24 Hours"
        day.week = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, [0...1440]) })
        p.calendar = day
        p.calendars = [standard]
        p.defaultCalendar = day.name

        var r = Resource(uid: 1, name: "Crew")
        r.calendarUID = 900
        p.resources = [r]
        var own = ProjectCalendar(name: "")
        own.uid = 900
        own.resourceUID = 1
        own.baseCalendarUID = standard.uid
        p.resourceCalendars = [own]

        let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(p)).readProject()
        XCTAssertEqual(back.calendar?.name, "24 Hours")
        XCTAssertEqual(back.calendar?.uid, day.uid)
        XCTAssertEqual(back.calendar?.week, day.week)
        let std = try XCTUnwrap(back.calendars.first { $0.name == "Standard" })
        XCTAssertEqual(std.uid, standard.uid)
        XCTAssertEqual(std.week, standard.week)
        let crew = try XCTUnwrap(back.resources.first { $0.uid == 1 })
        XCTAssertEqual(back.resourceCalendars.first { $0.uid == crew.calendarUID }?.baseCalendarUID, standard.uid)
    }

    /// mpp14header.mpp, from MPXJ's corpus (`Tools/ci/fetch-corpus.sh`): its
    /// project calendar is "24 Hours", and its resource is based on Standard.
    func testCorpusFileOn24HoursSavesItsCalendars() throws {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        let url = dir.appendingPathComponent("mpp14header.mpp")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no mpp14header.mpp in \(dir.path)") }
        let bytes = [UInt8](data)
        let read = try MPP14File(bytes: bytes).readProject()
        let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(read)).readProject()
        XCTAssertEqual(back.calendar, read.calendar)
        XCTAssertEqual(back.calendars, read.calendars)
        XCTAssertEqual(back.resourceCalendars.map(\.baseCalendarUID), read.resourceCalendars.map(\.baseCalendarUID))
    }
}
