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
@testable import MPP14
import MPPKit

/// Shifts, holiday sets, and calendars renamed, added and deleted — in the
/// model, and through a save and a read.
final class CalendarSetupTests: XCTestCase {

    // MARK: Shifts

    func testDayShiftWithLunchMakesProjectsDefaultDay() {
        let day = Shift.standardDay
        XCTAssertEqual(day.minutes, 480)
        XCTAssertEqual(day.segments.map(\.range), [480...720, 780...1_020])
        XCTAssertEqual(ProjectCalendar.week(from: [day])[2] ?? nil, ProjectCalendar.defaultWorkingDay)
        XCTAssertNil(ProjectCalendar.week(from: [day])[1]!, "Sunday is non-working")
    }

    func testNightShiftRunsIntoTheNextMorning() {
        let night = Shift(kind: .night, isOn: true, start: 1_320, end: 360, weekdays: [2])
        XCTAssertTrue(night.crossesMidnight)
        XCTAssertEqual(night.minutes, 480)
        let week = ProjectCalendar.week(from: [night])
        XCTAssertEqual(week[2] ?? nil, [1_320...1_440], "Monday 22:00–24:00")
        XCTAssertEqual(week[3] ?? nil, [0...360], "Tuesday 00:00–06:00")
    }

    func testNightBreakAfterMidnight() {
        let night = Shift(kind: .night, isOn: true, start: 1_320, end: 360,
                          breakStart: 120, breakEnd: 150, weekdays: [2])
        XCTAssertEqual(night.minutes, 450)
        XCTAssertEqual(night.segments.map(\.range), [1_320...1_440, 0...120, 150...360])
    }

    func testShiftsJoinWhereTheyTouch() {
        let day = Shift(kind: .day, isOn: true, start: 420, end: 900, weekdays: [2])
        let evening = Shift(kind: .evening, isOn: true, start: 900, end: 1_380, weekdays: [2])
        XCTAssertEqual(ProjectCalendar.week(from: [day, evening])[2] ?? nil, [420...1_380])
        XCTAssertTrue(ProjectCalendar.overlaps([day, evening]).isEmpty)
        var late = evening
        late.start = 840
        XCTAssertEqual(ProjectCalendar.overlaps([day, late]).first?.0, .day)
    }

    func testShiftsAreInferredFromAProjectWeek() {
        var cal = ProjectCalendar()
        let none: [ClosedRange<Int>]? = nil
        let split: [ClosedRange<Int>]? = [420...720, 750...960]
        cal.week = [2: split, 3: split, 4: split, 5: split, 6: split, 1: none, 7: none]
        let day = cal.effectiveShifts[0]
        XCTAssertEqual(day.kind, .day)
        XCTAssertEqual(day.start, 420)
        XCTAssertEqual(day.end, 960)
        XCTAssertEqual(day.breakRange, 720...750)
        XCTAssertEqual(day.weekdays, [2, 3, 4, 5, 6])
        XCTAssertFalse(cal.effectiveShifts[1].isOn)
        XCTAssertFalse(cal.effectiveShifts[2].isOn)
    }

    // MARK: Holiday dates

    private func dates(_ country: String, _ year: Int) -> [String: String] {
        let c = HolidayCatalog.country(country)!
        return Dictionary(uniqueKeysWithValues: c.dates(in: year).map { ($0.day.id, MPPTime.iso($0.date)) })
    }

    func testDanishMovableFeasts2026() {
        let d = dates("DK", 2026)
        XCTAssertEqual(d["dk-maundy"], "2026-04-02")
        XCTAssertEqual(d["dk-eastermon"], "2026-04-06")
        XCTAssertEqual(d["dk-ascension"], "2026-05-14")
        XCTAssertEqual(d["dk-whitsun-mon"], "2026-05-25")
    }

    func testUnitedStatesObservedDays() {
        let d = dates("US", 2026)
        XCTAssertEqual(d["us-mlk"], "2026-01-19")
        XCTAssertEqual(d["us-washington"], "2026-02-16")
        XCTAssertEqual(d["us-memorial"], "2026-05-25")
        XCTAssertEqual(d["us-independence"], "2026-07-03", "4 July 2026 is a Saturday")
        XCTAssertEqual(d["us-thanksgiving"], "2026-11-26")
    }

    func testBritishSubstituteDays() {
        XCTAssertEqual(dates("GB-ENG", 2026)["gb-boxing"], "2026-12-28", "Boxing Day on a Saturday")
        let d = dates("GB-ENG", 2027)
        XCTAssertEqual(Set([d["gb-xmas"]!, d["gb-boxing"]!]), ["2027-12-27", "2027-12-28"])
        XCTAssertEqual(dates("GB-ENG", 2026)["gb-spring"], "2026-05-25")
        XCTAssertEqual(dates("GB-SCT", 2026)["sc-summer"], "2026-08-03")
    }

    func testOtherRules() {
        XCTAssertEqual(dates("SE", 2026)["se-midsummer-eve"], "2026-06-19")
        XCTAssertEqual(dates("SE", 2026)["se-allsaints"], "2026-10-31")
        XCTAssertEqual(dates("IE", 2026)["ie-brigid"], "2026-02-02")
        XCTAssertEqual(dates("IE", 2030)["ie-brigid"], "2030-02-01", "1 February 2030 is a Friday")
        XCTAssertEqual(dates("CA", 2026)["ca-victoria"], "2026-05-18")
        XCTAssertEqual(dates("NL", 2025)["nl-king"], "2025-04-26", "27 April 2025 is a Sunday")
    }

    // MARK: Holiday exceptions

    func testOneExceptionPerHolidayAndYear() {
        var cal = ProjectCalendar()
        cal.holidays = [HolidaySelection(country: "DK")]
        cal.exceptions = [CalendarException(start: MPPTime.date(2026, 2, 16), finish: MPPTime.date(2026, 2, 17),
                                            name: "Company offsite")]
        cal.syncHolidays(years: 2026...2027)
        let names = cal.exceptions.map(\.name)
        XCTAssertEqual(names.filter { $0 == "Christmas (DK)" }.count, 2, "one per year")
        XCTAssertTrue(names.contains("Company offsite"))
        XCTAssertFalse(names.contains { $0.hasPrefix("Constitution Day") }, "off by default")
        let xmas = cal.exceptions.first { $0.name == "Christmas (DK)" }!
        XCTAssertEqual(MPPTime.iso(xmas.start), "2026-12-24")
        XCTAssertEqual(MPPTime.iso(xmas.lastDay), "2026-12-26")
        XCTAssertEqual(cal.ownExceptions.map(\.name), ["Company offsite"])

        // Again with a holiday turned off: the old days go.
        let country = HolidayCatalog.country("DK")!
        cal.holidays[0].set(country.days.first { $0.id == "dk-xmaseve" }!, on: false)
        cal.syncHolidays(years: 2026...2026)
        let x = cal.exceptions.first { $0.name == "Christmas (DK)" }!
        XCTAssertEqual(MPPTime.iso(x.start), "2026-12-25")
        XCTAssertEqual(cal.exceptions.filter { $0.name == "Christmas (DK)" }.count, 1)
    }

    func testTwoCountriesShareADay() {
        var cal = ProjectCalendar()
        cal.holidays = [HolidaySelection(country: "DK"), HolidaySelection(country: "GB-ENG")]
        cal.syncHolidays(years: 2026...2026)
        let byDay = Dictionary(cal.exceptions.flatMap { x in
            (MPPTime.dayNumber(x.start)...MPPTime.dayNumber(x.lastDay)).map { ($0, x.name) }
        }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byDay[MPPTime.dayNumber(MPPTime.date(2026, 12, 25))], "Christmas (DK, GB)")
        XCTAssertEqual(byDay[MPPTime.dayNumber(MPPTime.date(2026, 12, 28))], "Christmas (GB)")
        XCTAssertEqual(byDay.count, Set(byDay.keys).count, "no day in two exceptions")
    }

    func testNightShiftKeepsWorkingThroughAHoliday() {
        var cal = ProjectCalendar()
        let night = Shift(kind: .night, isOn: true, start: 1_320, end: 360, weekdays: Shift.weekdaysMonFri)
        cal.setShifts([Shift.standardDay, night])
        var dk = HolidaySelection(country: "DK")
        dk.keepsWorking = [.night]
        dk.short = ["dk-xmaseve"]
        cal.holidays = [dk]
        cal.syncHolidays(years: 2026...2026)
        let goodFriday = cal.exceptions.first { MPPTime.iso($0.start) <= "2026-04-03" && MPPTime.iso($0.lastDay) >= "2026-04-03" }!
        // Friday 3 April: the night from Thursday ends at 06:00, Friday's starts at 22:00.
        XCTAssertEqual(goodFriday.working.isEmpty, false)
        let eve = cal.exceptions.first { MPPTime.iso($0.start) == "2026-12-24" }!
        XCTAssertTrue(eve.working.contains(480...720), "a short day works the first half of the Day shift")
    }

    // MARK: Saving

    private func template() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Projects/Resources/Blank-Template.mpp")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no Blank-Template.mpp") }
        return [UInt8](data)
    }

    func testShiftsHolidaysAndRenamesSurviveASave() throws {
        let blank = try template()
        var p = try MPP14File(bytes: blank).readProject()
        var std = p.calendar ?? ProjectCalendar()
        std.name = "Site Team"
        var evening = Shift.suggested(.evening, after: [Shift.standardDay])
        evening.isOn = true
        std.setShifts([Shift.standardDay, evening])
        std.holidays = [HolidaySelection(country: "DK")]
        std.exceptions = [CalendarException(start: MPPTime.date(2026, 2, 16), name: "Offsite")]
        p.calendar = std
        p.defaultCalendar = "Site Team"
        var spain = ProjectCalendar(name: "Spanish Crew")
        spain.setShifts([Shift(kind: .day, isOn: true, start: 420, end: 960, breakStart: 840, breakEnd: 900,
                               weekdays: Shift.weekdaysMonFri)])
        spain.holidays = [HolidaySelection(country: "ES")]
        p.calendars.append(spain)
        p.syncHolidays()

        let saved = try MPP14Writer(template: blank).build(p)
        var opened = try MPP14File(bytes: saved).readProject()
        XCTAssertEqual(opened.calendar?.name, "Site Team")
        XCTAssertEqual(opened.defaultCalendar, "Site Team")
        XCTAssertEqual(opened.calendar?.shifts, std.shifts)
        XCTAssertEqual(opened.calendar?.holidays, std.holidays)
        XCTAssertEqual(opened.calendar?.ownExceptions.map(\.name), ["Offsite"])
        XCTAssertTrue(opened.calendar?.exceptions.contains { $0.name == "Easter (DK)" } ?? false)
        let crew = try XCTUnwrap(opened.calendars.first { $0.name == "Spanish Crew" })
        XCTAssertEqual(crew.holidays.map(\.country), ["ES"])
        XCTAssertEqual(crew.week[2] ?? nil, [420...840, 900...960])

        // Rename the added calendar and delete the template's leftover one;
        // save over the file.
        let i = opened.calendars.firstIndex { $0.name == "Spanish Crew" }!
        opened.calendars[i].name = "Madrid Crew"
        for c in opened.calendars where c.name != "Madrid Crew" { opened.removedCalendarUIDs.insert(c.uid) }
        opened.calendars.removeAll { $0.name != "Madrid Crew" }
        let resaved = try MPP14Writer(template: saved).build(opened)
        let reread = try MPP14File(bytes: resaved).readProject()
        XCTAssertEqual(reread.calendars.map(\.name), ["Madrid Crew"])
        XCTAssertEqual(reread.calendars.first?.uid, crew.uid, "renamed in place")
        XCTAssertEqual(reread.calendars.first?.holidays.map(\.country), ["ES"])
        XCTAssertEqual(reread.calendar?.name, "Site Team")
    }

    private func blankTemplate() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Blank-Template.mpp")
        return [UInt8](try Data(contentsOf: url))
    }

    /// Each task's calendar uid, from the task records.
    private func taskCalendarUIDs(_ bytes: [UInt8]) throws -> [Int: Int] {
        let file = try MPP14File(bytes: bytes)
        let base = "\(MPP.projectStorage)/TBkndTask"
        var fm: [UInt32: MPP.FieldItem] = [:]
        for item in MPP.parseFieldMap(file.props[MPP.PropsKey.taskFieldMap] ?? []) where item.inFixed {
            if fm[item.nativeID] == nil { fm[item.nativeID] = item }
        }
        let meta = try MPP.parseFixedMetaAuto(try file.root.stream(path: "\(base)/FixedMeta"),
                                              defaultItemSize: MPP.taskMetaSize)
        let rows = MPP.splitFixedData(try file.root.stream(path: "\(base)/FixedData"),
                                      metaItems: MPP.declaredItems(meta))
        var out: [Int: Int] = [:]
        for row in rows where row.count > 100 {
            guard let uid = fm[MPP.TaskField.uniqueID].flatMap({ BinaryReader(row).u32(at: $0.offset) }),
                  let cal = fm[MPP.TaskField.calendarUniqueID].flatMap({ BinaryReader(row).i32(at: $0.offset) })
            else { continue }
            out[Int(uid)] = Int(cal)
        }
        return out
    }

    /// Project lets two base calendars share a name, or have none. Calendars
    /// read from a file are found by their uid, so such a file saves, and
    /// each task keeps the calendar it had.
    func testCalendarsSharingANameOrWithoutOneSave() throws {
        var p = try MPP14File(bytes: try blankTemplate()).readProject()
        p.tasks = []
        p.relations = []
        p.resources = []
        p.assignments = []
        var sixDays = ProjectCalendar(name: "Crew A")
        for day in 2...7 { sixDays.week[day] = ProjectCalendar.defaultWorkingDay }
        var early = ProjectCalendar(name: "Crew B")
        for day in 2...6 { early.week[day] = [420...900] }
        p.calendars = [sixDays, early, ProjectCalendar(name: "Crew C")]
        for (uid, cal) in [(1, "Crew A"), (2, "Crew B"), (3, "Crew C")] {
            var t = ProjectTask(uid: uid, name: "Task \(uid)")
            t.outlineLevel = 1
            t.calendar = cal
            p.tasks.append(t)
        }
        p.normalizeOutline()
        try Scheduler.schedule(&p)
        let first = try MPP14Writer(template: try blankTemplate()).build(p)
        let uids = try taskCalendarUIDs(first)

        // Both crews renamed "Crew", the third left without a name.
        var q = try MPP14File(bytes: first).readProject()
        for i in q.calendars.indices {
            switch q.calendars[i].name {
            case "Crew A", "Crew B": q.calendars[i].name = "Crew"
            case "Crew C": q.calendars[i].name = ""
            default: break
            }
        }
        for i in q.tasks.indices { q.tasks[i].calendar = q.tasks[i].uid == 3 ? "" : "Crew" }
        let second = try MPP14Writer(template: first).build(q)
        XCTAssertEqual(try taskCalendarUIDs(second), uids)
        let back = try MPP14File(bytes: second).readProject()
        XCTAssertEqual(back.calendars.map(\.name).filter { $0.hasPrefix("Crew") || $0.isEmpty }.sorted(),
                       ["", "Crew", "Crew"])
        XCTAssertEqual(back.calendars.first { $0.uid == uids[1] }?.week[7] ?? nil, ProjectCalendar.defaultWorkingDay)
        XCTAssertEqual(back.calendars.first { $0.uid == uids[2] }?.week[2] ?? nil, [420...900])

        // Saved over itself again, nothing moves.
        let third = try MPP14Writer(template: second).build(back)
        XCTAssertEqual(try taskCalendarUIDs(third), uids)
    }

    /// A Project 2013 file from MPXJ's corpus with ten unnamed base
    /// calendars saves over itself with all of them. Skips without the corpus
    /// (`Tools/ci/fetch-corpus.sh`).
    func testCorpusFileWithUnnamedCalendarsSaves() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Corpus")
        let url = dir.appendingPathComponent("ResourceIdAndUniqueId-project2013-mpp14.mpp")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no corpus in \(dir.path) — run Tools/ci/fetch-corpus.sh")
        }
        let bytes = [UInt8](try Data(contentsOf: url))
        let read = try MPP14File(bytes: bytes).readProject()
        XCTAssertEqual(read.calendars.filter { $0.name.isEmpty }.count, 10)
        let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(read)).readProject()
        XCTAssertEqual(back.calendars.map(\.uid), read.calendars.map(\.uid))
        XCTAssertEqual(back.calendars, read.calendars)
        XCTAssertEqual(back.tasks, read.tasks)
        XCTAssertEqual(back.resources.map(\.name), read.resources.map(\.name))
    }
}
