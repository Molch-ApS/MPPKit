// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

// Plain Swift and FoundationEssentials only (dates, numbers and the XML
// reader are written here), so Microsoft Project XML is read and written the
// same on Apple platforms, Linux and in the WebAssembly build.
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// Microsoft Project's XML format (MSPDI, the schema Project writes as
/// "XML Format"): the plan as text, for Project versions, tools and services
/// that do not read `.mpp`.
///
/// Written and read: project settings, base calendars (week, exceptions with
/// their working hours), tasks (outline, duration and its units, constraints,
/// deadline, manual scheduling, progress, notes, Text1–Text30, baseline 0–10),
/// links (type, lag and its units), resources, and assignments.
public enum MSPDI {
    // MARK: Writing

    public static func data(_ p: Project) -> Data {
        var x = XMLOut()
        x.raw("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        x.open("Project", attrs: "xmlns=\"http://schemas.microsoft.com/project\"")
        x.leaf("SaveVersion", "14")
        x.leaf("Name", p.title)
        x.leaf("Title", p.title)
        if let v = p.author { x.leaf("Author", v) }
        if let v = p.company { x.leaf("Company", v) }
        if let v = p.manager { x.leaf("Manager", v) }
        x.leaf("ScheduleFromStart", "1")
        x.leaf("StartDate", date(p.start))
        if let f = p.finish ?? p.tasks.compactMap(\.finish).max() { x.leaf("FinishDate", date(f)) }
        x.leaf("CalendarUID", "1")
        x.leaf("DefaultStartTime", clock(p.defaultStartTime))
        x.leaf("DefaultFinishTime", clock(p.defaultFinishTime))
        x.leaf("MinutesPerDay", "\(p.minutesPerDay)")
        x.leaf("MinutesPerWeek", "\(p.minutesPerWeek)")
        x.leaf("DaysPerMonth", "\(p.daysPerMonth)")
        if let s = p.statusDate { x.leaf("StatusDate", date(s)) }
        if let c = p.currencySymbol { x.leaf("CurrencySymbol", c) }

        // Text field names.
        let aliases = p.fieldAliases.compactMap { key, name -> (Int, String)? in
            guard key.lowercased().hasPrefix("text"), let n = Int(key.dropFirst(4)), let id = textFieldID(n) else { return nil }
            return (id, name)
        }.sorted { $0.0 < $1.0 }
        if !aliases.isEmpty {
            x.open("ExtendedAttributes")
            for (id, name) in aliases {
                x.open("ExtendedAttribute")
                x.leaf("FieldID", "\(id)")
                x.leaf("FieldName", "Text\(textNumber(id) ?? 0)")
                x.leaf("Alias", name)
                x.close("ExtendedAttribute")
            }
            x.close("ExtendedAttributes")
        }

        // Calendars: the project's as uid 1, then the other base calendars.
        var calendarUIDs: [String: Int] = [:]
        x.open("Calendars")
        let base = [p.calendar ?? ProjectCalendar()] + p.calendars.filter { $0.name != (p.calendar?.name ?? "Standard") }
        for (i, cal) in base.enumerated() {
            calendarUIDs[cal.name] = i + 1
            writeCalendar(cal, uid: i + 1, to: &x)
        }
        x.close("Calendars")

        x.open("Tasks")
        let summaries = Set(p.tasks.map(\.parentUID))
        for t in p.tasks {
            x.open("Task")
            x.leaf("UID", "\(t.uid)")
            x.leaf("ID", "\(t.rowID)")
            x.leaf("Name", t.name)
            x.leaf("Manual", t.manual ? "1" : "0")
            x.leaf("OutlineLevel", "\(t.outlineLevel)")
            if let w = t.wbs { x.leaf("WBS", w) }
            x.leaf("Priority", "\(t.priority)")
            if let s = t.start { x.leaf("Start", date(s)) }
            if let f = t.finish { x.leaf("Finish", date(f)) }
            x.leaf("Duration", duration(minutes: Int.clamped(t.durationDays * Double(p.minutesPerDay))))
            x.leaf("DurationFormat", "\(unitCode(t.durationUnits) + (t.estimated ? 32 : 0))")
            x.leaf("Estimated", t.estimated ? "1" : "0")
            x.leaf("Milestone", t.milestone || t.durationDays == 0 ? "1" : "0")
            x.leaf("Summary", summaries.contains(t.uid) ? "1" : "0")
            x.leaf("PercentComplete", "\(t.percentComplete)")
            if let a = t.actualStart { x.leaf("ActualStart", date(a)) }
            if let a = t.actualFinish { x.leaf("ActualFinish", date(a)) }
            x.leaf("ConstraintType", "\(constraintCode(t.constraint))")
            if let d = t.constraintDate { x.leaf("ConstraintDate", date(d)) }
            if let d = t.deadline { x.leaf("Deadline", date(d)) }
            if let c = t.calendar, let uid = calendarUIDs[c] { x.leaf("CalendarUID", "\(uid)") }
            x.leaf("Type", "\(["fixed_units": 0, "fixed_duration": 1, "fixed_work": 2][t.taskType] ?? 0)")
            x.leaf("EffortDriven", t.effortDriven ? "1" : "0")
            if !t.notes.isEmpty { x.leaf("Notes", t.notes) }
            for r in p.relations where r.succUID == t.uid {
                x.open("PredecessorLink")
                x.leaf("PredecessorUID", "\(r.predUID)")
                x.leaf("Type", "\(["FF": 0, "FS": 1, "SF": 2, "SS": 3][r.type] ?? 1)")
                let lag = r.lagIsPercent ? Int.clamped(r.lagDays * 10_000)
                                         : Int.clamped(r.lagDays * Double(p.minutesPerDay) * 10)
                x.leaf("LinkLag", "\(lag)")
                x.leaf("LagFormat", "\(unitCode(r.lagUnits))")
                x.close("PredecessorLink")
            }
            for (n, v) in t.text.sorted(by: { $0.key < $1.key }) {
                guard let id = textFieldID(n) else { continue }
                x.open("ExtendedAttribute")
                x.leaf("FieldID", "\(id)")
                x.leaf("Value", v)
                x.close("ExtendedAttribute")
            }
            for (n, b) in t.baselines.projectSlots.sorted(by: { $0.key < $1.key }) {
                x.open("Baseline")
                x.leaf("Number", "\(n)")
                if let s = b.start { x.leaf("Start", date(s)) }
                if let f = b.finish { x.leaf("Finish", date(f)) }
                x.leaf("Duration", duration(minutes: Int.clamped(b.durationDays * Double(p.minutesPerDay))))
                x.leaf("Work", duration(minutes: Int.clamped(b.workHours * 60)))
                x.close("Baseline")
            }
            x.close("Task")
        }
        x.close("Tasks")

        x.open("Resources")
        for (i, r) in p.resources.enumerated() {
            x.open("Resource")
            x.leaf("UID", "\(r.uid)")
            x.leaf("ID", "\(r.rowID == 0 ? i + 1 : r.rowID)")
            x.leaf("Name", r.name)
            x.leaf("Type", r.type == "material" ? "0" : (r.type == "cost" ? "2" : "1"))
            if !r.initials.isEmpty { x.leaf("Initials", r.initials) }
            if !r.email.isEmpty { x.leaf("EmailAddress", r.email) }
            if !r.group.isEmpty { x.leaf("Group", r.group) }
            x.leaf("MaxUnits", fixed2(r.maxUnits))
            x.close("Resource")
        }
        x.close("Resources")

        x.open("Assignments")
        for (i, a) in p.assignments.enumerated() {
            x.open("Assignment")
            x.leaf("UID", "\(a.uid == 0 ? i + 1 : a.uid)")
            x.leaf("TaskUID", "\(a.taskUID)")
            x.leaf("ResourceUID", "\(a.resourceUID)")
            x.leaf("Units", fixed2(a.units))
            let hours = a.workHours > 0 ? a.workHours
                : (p.task(uid: a.taskUID).map { $0.durationDays * Double(p.minutesPerDay) / 60 * a.units } ?? 0)
            x.leaf("Work", duration(minutes: Int.clamped(hours * 60)))
            x.close("Assignment")
        }
        x.close("Assignments")
        x.close("Project")
        return Data(x.text.utf8)
    }

    private static func writeCalendar(_ cal: ProjectCalendar, uid: Int, to x: inout XMLOut) {
        x.open("Calendar")
        x.leaf("UID", "\(uid)")
        x.leaf("Name", cal.name)
        x.leaf("IsBaseCalendar", "1")
        x.leaf("BaseCalendarUID", "-1")
        x.open("WeekDays")
        for day in 1...7 {
            let ranges = cal.workingRanges(weekday: day)
            x.open("WeekDay")
            x.leaf("DayType", "\(day)")
            x.leaf("DayWorking", ranges.isEmpty ? "0" : "1")
            if !ranges.isEmpty { writeTimes(ranges, to: &x) }
            x.close("WeekDay")
        }
        x.close("WeekDays")
        if !cal.exceptions.isEmpty {
            x.open("Exceptions")
            for e in cal.exceptions {
                x.open("Exception")
                x.leaf("EnteredByOccurrences", "0")
                x.open("TimePeriod")
                x.leaf("FromDate", date(e.start))
                x.leaf("ToDate", date(e.lastDay.addingTimeInterval(86_340)))
                x.close("TimePeriod")
                x.leaf("Occurrences", "1")
                x.leaf("Name", e.name)
                x.leaf("Type", "1")
                x.leaf("DayWorking", e.isNonWorking ? "0" : "1")
                if !e.isNonWorking { writeTimes(e.working, to: &x) }
                x.close("Exception")
            }
            x.close("Exceptions")
        }
        x.close("Calendar")
    }

    private static func writeTimes(_ ranges: [ClosedRange<Int>], to x: inout XMLOut) {
        x.open("WorkingTimes")
        for r in ranges {
            x.open("WorkingTime")
            x.leaf("FromTime", clock(r.lowerBound) + ":00")
            x.leaf("ToTime", clock(r.upperBound % 1_440) + ":00")
            x.close("WorkingTime")
        }
        x.close("WorkingTimes")
    }

    // MARK: Reading

    public enum Failure: Error { case notMSPDI }

    public static func project(from data: Data) throws -> Project {
        let tree = try XMLTree.parse(data)
        guard tree.name == "Project" else { throw Failure.notMSPDI }
        func dateOf(_ s: String?) -> Date? { s.flatMap(parseDate) }
        let start = dateOf(tree["StartDate"]) ?? Date()
        var p = Project(title: tree["Name"] ?? tree["Title"] ?? "Project", start: start)
        p.author = tree["Author"]
        p.company = tree["Company"]
        p.manager = tree["Manager"]
        p.finish = dateOf(tree["FinishDate"])
        p.statusDate = dateOf(tree["StatusDate"])
        if let v = tree["MinutesPerDay"].flatMap(Int.init), v > 0 { p.minutesPerDay = v }
        if let v = tree["MinutesPerWeek"].flatMap(Int.init), v > 0 { p.minutesPerWeek = v }
        if let v = tree["DaysPerMonth"].flatMap(Int.init), v > 0 { p.daysPerMonth = v }
        if let v = tree["DefaultStartTime"].flatMap(parseClock) { p.defaultStartTime = v }
        if let v = tree["DefaultFinishTime"].flatMap(parseClock) { p.defaultFinishTime = v }
        p.currencySymbol = tree["CurrencySymbol"]
        for a in tree.child("ExtendedAttributes")?.children("ExtendedAttribute") ?? [] {
            if let id = a["FieldID"].flatMap(Int.init), let n = textNumber(id), let alias = a["Alias"], !alias.isEmpty {
                p.fieldAliases["text\(n)"] = alias
            }
        }

        // Calendars.
        var calendarNames: [Int: String] = [:]
        let projectCalendarUID = tree["CalendarUID"].flatMap(Int.init) ?? 1
        for c in tree.child("Calendars")?.children("Calendar") ?? [] {
            guard c["IsBaseCalendar"] == "1", let uid = c["UID"].flatMap(Int.init) else { continue }
            var cal = ProjectCalendar(name: c["Name"] ?? "Calendar \(uid)")
            for d in c.child("WeekDays")?.children("WeekDay") ?? [] {
                guard let type = d["DayType"].flatMap(Int.init) else { continue }
                if type == 0 {
                    // Type 0 is an exception in Project 2003's layout.
                    if let e = exception(from: d) { cal.exceptions.append(e) }
                    continue
                }
                let times = workingTimes(d)
                cal.week[type] = d["DayWorking"] == "1" && !times.isEmpty ? times : .some(nil)
            }
            for e in c.child("Exceptions")?.children("Exception") ?? [] {
                if let x = exception(from: e) { cal.exceptions.append(x) }
            }
            calendarNames[uid] = cal.name
            if uid == projectCalendarUID { p.calendar = cal } else { p.calendars.append(cal) }
        }
        if p.calendar == nil { p.calendar = ProjectCalendar(name: "Standard") }

        // Tasks; the project summary (UID 0) is the project itself.
        for t in tree.child("Tasks")?.children("Task") ?? [] {
            guard let uid = t["UID"].flatMap(Int.init), uid != 0, t["IsNull"] != "1" else { continue }
            var task = ProjectTask(uid: uid, name: t["Name"] ?? "", start: dateOf(t["Start"]), finish: dateOf(t["Finish"]))
            task.rowID = t["ID"].flatMap(Int.init) ?? 0
            task.outlineLevel = t["OutlineLevel"].flatMap(Int.init) ?? 1
            task.wbs = t["WBS"]
            task.priority = t["Priority"].flatMap(Int.init) ?? 500
            task.manual = t["Manual"] == "1"
            let format = t["DurationFormat"].flatMap(Int.init) ?? 7
            task.estimated = t["Estimated"] == "1" || format >= 32
            task.durationUnits = unitLabel(format % 32 == 0 ? 7 : format % 32) ?? "d"
            if let m = t["Duration"].flatMap(parseDuration) { task.durationDays = Double(m) / Double(p.minutesPerDay) }
            task.milestone = t["Milestone"] == "1"
            task.percentComplete = t["PercentComplete"].flatMap(Int.init) ?? 0
            task.actualStart = dateOf(t["ActualStart"])
            task.actualFinish = dateOf(t["ActualFinish"])
            let constraint = constraintLabel(t["ConstraintType"].flatMap(Int.init) ?? 0)
            task.constraint = constraint == "ASAP" ? nil : constraint
            task.constraintDate = dateOf(t["ConstraintDate"])
            task.deadline = dateOf(t["Deadline"])
            if let c = t["CalendarUID"].flatMap(Int.init), c >= 0 { task.calendar = calendarNames[c] }
            task.taskType = ["0": "fixed_units", "1": "fixed_duration", "2": "fixed_work"][t["Type"] ?? "0"] ?? "fixed_units"
            task.effortDriven = t["EffortDriven"] == "1"
            task.notes = t["Notes"] ?? ""
            for a in t.children("ExtendedAttribute") {
                if let id = a["FieldID"].flatMap(Int.init), let n = textNumber(id), let v = a["Value"] { task.text[n] = v }
            }
            for b in t.children("Baseline") {
                guard let n = b["Number"].flatMap(Int.init), (0...10).contains(n) else { continue }
                task.baselines[n] = Baseline(start: dateOf(b["Start"]), finish: dateOf(b["Finish"]),
                                             durationDays: Double(b["Duration"].flatMap(parseDuration) ?? 0) / Double(p.minutesPerDay),
                                             workHours: Double(b["Work"].flatMap(parseDuration) ?? 0) / 60)
            }
            for l in t.children("PredecessorLink") {
                guard let pred = l["PredecessorUID"].flatMap(Int.init) else { continue }
                let type = ["0": "FF", "1": "FS", "2": "SF", "3": "SS"][l["Type"] ?? "1"] ?? "FS"
                let units = unitLabel(l["LagFormat"].flatMap(Int.init) ?? 7) ?? "d"
                let raw = Double(l["LinkLag"].flatMap(Int.init) ?? 0)
                let lag = units.hasSuffix("%") ? raw / 10_000 : raw / 10 / Double(p.minutesPerDay)
                p.relations.append(Relation(predUID: pred, succUID: uid, type: type, lagDays: lag, lagUnits: units))
            }
            p.tasks.append(task)
        }
        p.normalizeOutline()

        for r in tree.child("Resources")?.children("Resource") ?? [] {
            guard let uid = r["UID"].flatMap(Int.init), uid != 0, let name = r["Name"], !name.isEmpty else { continue }
            var res = Resource(uid: uid, name: name)
            res.rowID = r["ID"].flatMap(Int.init) ?? 0
            res.initials = r["Initials"] ?? ""
            res.email = r["EmailAddress"] ?? ""
            res.group = r["Group"] ?? ""
            res.type = ["0": "material", "1": "work", "2": "cost"][r["Type"] ?? "1"] ?? "work"
            res.maxUnits = r["MaxUnits"].flatMap(Double.init) ?? 1
            p.resources.append(res)
        }
        let taskUIDs = Set(p.tasks.map(\.uid)), resourceUIDs = Set(p.resources.map(\.uid))
        for a in tree.child("Assignments")?.children("Assignment") ?? [] {
            guard let t = a["TaskUID"].flatMap(Int.init), let r = a["ResourceUID"].flatMap(Int.init),
                  taskUIDs.contains(t), resourceUIDs.contains(r) else { continue }
            var asg = Assignment(taskUID: t, resourceUID: r)
            asg.uid = a["UID"].flatMap(Int.init) ?? 0
            asg.units = a["Units"].flatMap(Double.init) ?? 1
            asg.workHours = Double(a["Work"].flatMap(parseDuration) ?? 0) / 60
            p.assignments.append(asg)
        }
        p.relations.removeAll { !taskUIDs.contains($0.predUID) || !taskUIDs.contains($0.succUID) }
        p.inferSplitGaps()
        return p
    }

    private static func workingTimes(_ node: XMLTree) -> [ClosedRange<Int>] {
        (node.child("WorkingTimes")?.children("WorkingTime") ?? []).compactMap { w in
            guard let a = w["FromTime"].flatMap(parseClock), var b = w["ToTime"].flatMap(parseClock) else { return nil }
            if b <= a { b += 1_440 }   // 00:00 as an end means midnight
            return a...b
        }
    }

    private static func exception(from node: XMLTree) -> CalendarException? {
        guard let period = node.child("TimePeriod"), let from = period["FromDate"].flatMap(parseDate),
              let to = period["ToDate"].flatMap(parseDate) else { return nil }
        let first = MPPTime.startOfDay(from), last = MPPTime.startOfDay(to)
        let hours = node["DayWorking"] == "1" ? workingTimes(node) : []
        return CalendarException(start: first, finish: last == first ? nil : last, name: node["Name"] ?? "", working: hours)
    }

    // MARK: Values

    /// `2026-11-19T08:00:00`: the date's wall clock (dates here are UTC-based
    /// wall times), whole seconds, as DateFormatter's `yyyy-MM-dd'T'HH:mm:ss`
    /// in en_US_POSIX and GMT wrote it.
    static func date(_ d: Date) -> String {
        let t = Int(d.timeIntervalSince1970.rounded(.down))
        let days = t >= 0 ? t / 86_400 : -((-t + 86_399) / 86_400)
        let s = t - days * 86_400
        let (y, m, day) = civil(days)
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(day, 2))T\(pad(s / 3600, 2)):\(pad(s % 3600 / 60, 2)):\(pad(s % 60, 2))"
    }

    /// The first 19 characters as `yyyy-MM-ddTHH:mm:ss` (a time zone or
    /// fraction after them is ignored, as before); nil when they aren't a date.
    static func parseDate(_ s: String) -> Date? {
        let c = Array(s.utf8.prefix(19))
        guard c.count == 19, c[4] == 0x2D, c[7] == 0x2D, c[10] == 0x54, c[13] == 0x3A, c[16] == 0x3A else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r { guard (0x30...0x39).contains(c[i]) else { return nil }; v = v * 10 + Int(c[i] - 0x30) }
            return v
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let se = num(17..<19),
              (1...12).contains(m), d >= 1, d <= daysIn(m, y), h < 24, mi < 60, se < 60 else { return nil }
        let seconds = days(y, m, d) * 86_400 + h * 3600 + mi * 60 + se
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func clock(_ minutes: Int) -> String { "\(pad(minutes / 60, 2)):\(pad(minutes % 60, 2))" }

    /// Two decimals, exactly as `%.2f`: `1.00`, `0.50`, `0.12` for 0.125 (a tie
    /// goes to even), `2.67` for 2.675 (just under it in binary), `-0.00`.
    static func fixed2(_ v: Double) -> String {
        guard v.isFinite else { return "0.00" }
        let a = abs(v)
        var cents = (a * 100).rounded(.down)
        // Which side of the half-way point the exact a × 100 is: one rounding (fma), so its sign is exact.
        let past = (-(cents + 0.5)).addingProduct(a, 100)
        if past > 0 || (past == 0 && cents.truncatingRemainder(dividingBy: 2) == 1) { cents += 1 }
        let c = Int(cents)
        return "\(v.sign == .minus ? "-" : "")\(c / 100).\(pad(c % 100, 2))"
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(abs(n))
        return (n < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - s.count)) + s
    }

    // Days from 1970-01-01 and back, proleptic Gregorian (H. Hinnant's algorithms).
    static func days(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
    static func civil(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
    private static func daysIn(_ m: Int, _ y: Int) -> Int {
        if m == 2 { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28 }
        return [4, 6, 9, 11].contains(m) ? 30 : 31
    }
    static func parseClock(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        return parts.count >= 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// `PT8H0M0S`, working (or elapsed) time.
    static func duration(minutes: Int) -> String {
        let m = abs(minutes)
        return "\(minutes < 0 ? "-" : "")PT\(m / 60)H\(m % 60)M0S"
    }

    static func parseDuration(_ s: String) -> Int? {
        var rest = Substring(s), sign = 1
        if rest.hasPrefix("-") { sign = -1; rest = rest.dropFirst() }
        guard rest.hasPrefix("PT") else { return nil }
        rest = rest.dropFirst(2)
        var minutes = 0.0, number = ""
        for ch in rest {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            let v = Double(number) ?? 0
            switch ch {
            case "H": minutes += v * 60
            case "M": minutes += v
            case "S": minutes += v / 60
            default: break
            }
            number = ""
        }
        return sign * Int.clamped(minutes)
    }

    static func unitCode(_ label: String) -> Int {
        ["m": 3, "em": 4, "h": 5, "eh": 6, "d": 7, "ed": 8, "w": 9, "ew": 10, "mo": 11, "emo": 12, "%": 19, "e%": 20][label] ?? 7
    }
    static func unitLabel(_ code: Int) -> String? {
        [3: "m", 4: "em", 5: "h", 6: "eh", 7: "d", 8: "ed", 9: "w", 10: "ew", 11: "mo", 12: "emo", 19: "%", 20: "e%",
         35: "m", 36: "em", 37: "h", 38: "eh", 39: "d", 40: "ed", 41: "w", 42: "ew", 43: "mo", 44: "emo"][code]
    }
    static func constraintCode(_ c: String?) -> Int {
        ["ASAP": 0, "ALAP": 1, "MSO": 2, "MFO": 3, "SNET": 4, "SNLT": 5, "FNET": 6, "FNLT": 7][c ?? "ASAP"] ?? 0
    }
    static func constraintLabel(_ code: Int) -> String {
        ["ASAP", "ALAP", "MSO", "MFO", "SNET", "SNLT", "FNET", "FNLT"][min(max(code, 0), 7)]
    }

    /// Project's field ids for Text1...Text30 (`pjTaskText1` …).
    static let textFieldIDs: [Int] = [188_743_731, 188_743_734, 188_743_737, 188_743_740, 188_743_743,
                                      188_743_746, 188_743_747, 188_743_748, 188_743_749, 188_743_750]
        + (0..<20).map { 188_743_997 + $0 }
    static func textFieldID(_ n: Int) -> Int? { (1...30).contains(n) ? textFieldIDs[n - 1] : nil }
    static func textNumber(_ id: Int) -> Int? { textFieldIDs.firstIndex(of: id).map { $0 + 1 } }
}

// MARK: - XML plumbing

private struct XMLOut {
    var text = ""
    private var depth = 0
    mutating func raw(_ s: String) { text += s }
    mutating func open(_ tag: String, attrs: String = "") {
        text += String(repeating: "  ", count: depth) + "<\(tag)\(attrs.isEmpty ? "" : " " + attrs)>\n"
        depth += 1
    }
    mutating func close(_ tag: String) {
        depth -= 1
        text += String(repeating: "  ", count: depth) + "</\(tag)>\n"
    }
    mutating func leaf(_ tag: String, _ value: String) {
        text += String(repeating: "  ", count: depth) + "<\(tag)>\(Self.escape(value))</\(tag)>\n"
    }
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

/// A small DOM, enough for MSPDI, from a reader of our own (no XMLParser, which
/// the WebAssembly build doesn't have). Well-formed XML only: elements, text,
/// the five named entities and character references, CDATA, comments,
/// processing instructions and a DOCTYPE (skipped, never resolved). Attributes
/// are read past and kept out of the tree, as before. Names keep any prefix.
final class XMLTree {
    let name: String
    var text = ""
    private(set) var kids: [XMLTree] = []
    init(name: String) { self.name = name }
    /// Freed without recursion, as it was read: a very deep file can't exhaust the stack.
    deinit {
        var rest = kids
        kids = []
        while let n = rest.popLast() { rest += n.kids; n.kids = [] }
    }

    func child(_ name: String) -> XMLTree? { kids.first { $0.name == name } }
    func children(_ name: String) -> [XMLTree] { kids.filter { $0.name == name } }
    /// The text of a direct child element: a leaf's exactly (a task name may
    /// end in a space), an element with children's trimmed of the layout.
    subscript(_ name: String) -> String? {
        child(name).map { $0.kids.isEmpty ? $0.text : Self.trimmed($0.text) }
    }
    static func trimmed(_ s: String) -> String {
        let blank: (Character) -> Bool = { $0.isWhitespace || $0.isNewline }
        guard let a = s.firstIndex(where: { !blank($0) }), let b = s.lastIndex(where: { !blank($0) }) else { return "" }
        return String(s[a...b])
    }

    struct Malformed: Error, CustomStringConvertible {
        let offset: Int, reason: String
        var description: String { "Not well-formed XML at byte \(offset): \(reason)" }
    }

    static func parse(_ data: Data) throws -> XMLTree {
        var reader = Reader(bytes: decode(data))
        return try reader.document()
    }

    /// UTF-8 bytes: UTF-16 (with its byte order mark) is converted, a UTF-8 BOM dropped.
    private static func decode(_ data: Data) -> [UInt8] {
        let b = [UInt8](data)
        if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) {
            let little = b[0] == 0xFF
            var units: [UInt16] = []
            units.reserveCapacity(b.count / 2)
            var i = 2
            while i + 1 < b.count { units.append(little ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1])); i += 2 }
            return Array(String(decoding: units, as: UTF16.self).utf8)
        }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return Array(b[3...]) }
        return b
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        func fail(_ reason: String) -> Malformed { Malformed(offset: i, reason: reason) }
        func at(_ s: String) -> Bool {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count else { return false }
            for k in 0..<u.count where bytes[i + k] != u[k] { return false }
            return true
        }
        mutating func skip(past s: String) throws {
            while i < bytes.count { if at(s) { i += s.utf8.count; return }; i += 1 }
            throw fail("\(s) expected")
        }
        mutating func spaces() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        static func isNameByte(_ c: UInt8) -> Bool {
            c >= 0x80 || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
                || c == 0x5F || c == 0x3A || c == 0x2D || c == 0x2E
        }
        mutating func name() throws -> String {
            let start = i
            while i < bytes.count, Self.isNameByte(bytes[i]) { i += 1 }
            guard i > start, !(0x30...0x39).contains(bytes[start]), bytes[start] != 0x2D, bytes[start] != 0x2E else { throw fail("a name expected") }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        /// Comments, processing instructions and a DOCTYPE, where markup may stand outside elements.
        mutating func misc() throws {
            while true {
                spaces()
                if at("<!--") { try skip(past: "-->") }
                else if at("<?") { try skip(past: "?>") }
                else if at("<!DOCTYPE") { try doctype() }
                else { return }
            }
        }
        mutating func doctype() throws {
            var depth = 0
            while i < bytes.count {
                let c = bytes[i]; i += 1
                if c == 0x5B { depth += 1 } else if c == 0x5D { depth -= 1 } else if c == 0x3E, depth <= 0 { return }
            }
            throw fail("the DOCTYPE isn't closed")
        }

        mutating func document() throws -> XMLTree {
            try misc()
            guard at("<") else { throw fail("no root element") }
            let root = try element()
            try misc()
            guard i == bytes.count else { throw fail("content after the root element") }
            return root
        }

        /// One element and everything in it, with an explicit stack (no recursion, any depth).
        mutating func element() throws -> XMLTree {
            var stack: [XMLTree] = []
            var root: XMLTree?
            var text: [UInt8] = []
            func flush() { if let top = stack.last, !text.isEmpty { top.text += String(decoding: text, as: UTF8.self); text.removeAll(keepingCapacity: true) } }
            repeat {
                guard i < bytes.count else { throw fail("<\(stack.last?.name ?? "?")> isn't closed") }
                if bytes[i] != 0x3C {
                    if bytes[i] == 0x26 { try reference(into: &text) } else { newline(into: &text) }
                    continue
                }
                if at("<!--") { try skip(past: "-->"); continue }
                if at("<![CDATA[") {
                    i += 9
                    while !at("]]>") {
                        guard i < bytes.count else { throw fail("the CDATA section isn't closed") }
                        newline(into: &text)
                    }
                    i += 3
                    continue
                }
                if at("<?") { try skip(past: "?>"); continue }
                if at("</") {
                    i += 2
                    let n = try name()
                    spaces()
                    guard i < bytes.count, bytes[i] == 0x3E else { throw fail("> expected after </\(n)") }
                    i += 1
                    guard let open = stack.last, open.name == n else { throw fail("</\(n)> doesn't close <\(stack.last?.name ?? "")>") }
                    flush()
                    stack.removeLast()
                    continue
                }
                guard !at("<!") else { throw fail("unexpected markup") }
                i += 1
                let node = XMLTree(name: try name())
                try attributes()
                flush()
                if let parent = stack.last { parent.kids.append(node) } else if root == nil { root = node }
                if at("/>") { i += 2 } else { i += 1; stack.append(node) }
            } while !stack.isEmpty
            return root!
        }

        /// One byte of text, with line ends read as XML says: CR LF and a lone CR are LF.
        mutating func newline(into out: inout [UInt8]) {
            if bytes[i] == 0x0D {
                out.append(0x0A); i += 1
                if i < bytes.count, bytes[i] == 0x0A { i += 1 }
            } else { out.append(bytes[i]); i += 1 }
        }

        /// Attributes, checked and skipped; the tag's end left at `>` or `/>`.
        mutating func attributes() throws {
            while true {
                let before = i
                spaces()
                guard i < bytes.count else { throw fail("the tag isn't closed") }
                if bytes[i] == 0x3E || at("/>") { return }
                guard i > before else { throw fail("space expected between attributes") }
                _ = try name()
                spaces()
                guard i < bytes.count, bytes[i] == 0x3D else { throw fail("= expected") }
                i += 1
                spaces()
                guard i < bytes.count, bytes[i] == 0x22 || bytes[i] == 0x27 else { throw fail("a quoted value expected") }
                let quote = bytes[i]
                i += 1
                while i < bytes.count, bytes[i] != quote { guard bytes[i] != 0x3C else { throw fail("< in an attribute") }; i += 1 }
                guard i < bytes.count else { throw fail("the attribute isn't closed") }
                i += 1
            }
        }

        /// `&amp;` and friends, `&#38;`, `&#x26;`. Any other entity is refused: none is ever resolved.
        mutating func reference(into out: inout [UInt8]) throws {
            let start = i
            i += 1
            while i < bytes.count, bytes[i] != 0x3B, i - start < 12 { i += 1 }
            guard i < bytes.count, bytes[i] == 0x3B else { i = start; throw fail("an & that isn't a reference") }
            let body = String(decoding: bytes[(start + 1)..<i], as: UTF8.self)
            i += 1
            let named: [String: UInt8] = ["amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27]
            if let c = named[body] { out.append(c); return }
            if body.hasPrefix("#") {
                let hex = body.hasPrefix("#x")
                if let v = UInt32(body.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), v != 0, let u = Unicode.Scalar(v) {
                    out.append(contentsOf: Array(String(Character(u)).utf8)); return
                }
            }
            i = start
            throw fail("unknown entity &\(body);")
        }
    }
}

