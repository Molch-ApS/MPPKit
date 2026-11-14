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

/// Costs as Microsoft Project calculates them. Every expected number below
/// is what Project showed for the same plan.
final class CostTests: XCTestCase {
    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0) -> Date { MPPTime.date(y, m, day, h, 0) }

    /// Monday 2 Nov 2026, Standard calendar; one resource on each listed task.
    private func plan(_ rates: [PayRate], _ tasks: [ProjectTask], units: Double = 1) -> Project {
        var p = Project(title: "Costs", start: d(2026, 11, 2, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        var r = Resource(uid: 1, name: "Crew")
        r.costRateTables = [rates, [], [], [], []]
        p.resources = [r]
        p.tasks = tasks
        for i in p.tasks.indices { p.tasks[i].rowID = i + 1; p.tasks[i].outlineLevel = 1 }
        p.assignments = tasks.filter { $0.name.hasPrefix("work") }.map { Assignment(taskUID: $0.uid, resourceUID: 1, units: units) }
        return p
    }

    private func task(_ uid: Int, _ name: String, _ days: Double, _ configure: (inout ProjectTask) -> Void = { _ in }) -> ProjectTask {
        var t = ProjectTask(uid: uid, name: name)
        t.durationDays = days
        configure(&t)
        return t
    }

    func testWorkIsCostedAtTheRateInForceEachDay() throws {
        // 80/h until Wednesday, 100/h after: two days of each.
        var p = plan([PayRate(standardPerHour: 80, until: d(2026, 11, 4)), PayRate(standardPerHour: 100)],
                     [task(1, "work", 4)])
        try Scheduler.schedule(&p)
        p.recalculateCosts()
        XCTAssertEqual(p.assignments[0].cost, 2880)
        XCTAssertEqual(p.tasks[0].cost, 2880)
    }

    func testCostPerUseAndProgress() throws {
        // 1000 a day (125/h) and 50 a use; half done: 12 hours and the use.
        var p = plan([PayRate(standardPerHour: 125, costPerUse: 50)],
                     [task(1, "work", 3) { $0.percentComplete = 50 }])
        try Scheduler.schedule(&p)
        p.recalculateCosts()
        XCTAssertEqual(p.tasks[0].cost, 3050)
        XCTAssertEqual(p.tasks[0].actualCost, 1550)
    }

    func testFixedCostAccrues() throws {
        func fixed(_ uid: Int, _ accrual: String) -> ProjectTask {
            task(uid, "fixed \(accrual)", 4) { $0.fixedCost = 400; $0.fixedCostAccrual = accrual; $0.percentComplete = 50 }
        }
        var p = plan([PayRate(standardPerHour: 80)], [fixed(1, "start"), fixed(2, "prorated"), fixed(3, "end")])
        try Scheduler.schedule(&p)
        p.recalculateCosts()
        XCTAssertEqual(p.tasks.map(\.cost), [400, 400, 400])
        XCTAssertEqual(p.tasks.map(\.actualCost), [400, 200, 0])
    }

    func testSummaryAddsUpItsChildren() throws {
        var p = plan([PayRate(standardPerHour: 80)],
                     [task(1, "phase", 0) { $0.fixedCost = 10 }, task(2, "work a", 1) { $0.parentUID = 1 },
                      task(3, "work b", 2) { $0.parentUID = 1; $0.fixedCost = 5 }])
        p.tasks[1].outlineLevel = 2; p.tasks[2].outlineLevel = 2
        try Scheduler.schedule(&p)
        p.recalculateCosts()
        XCTAssertEqual(p.tasks[0].cost, 640 + 1280 + 5 + 10)
        XCTAssertEqual(p.totalCost.cost, 1935)
    }

    /// What the file holds is kept where nothing it depends on changed: a cost
    /// MPPKit cannot work out (a contour, overtime) survives a save.
    func testUnchangedAssignmentsKeepTheFilesCost() throws {
        var p = plan([PayRate(standardPerHour: 80)], [task(1, "work", 1), task(2, "work too", 1)])
        try Scheduler.schedule(&p)
        p.assignments[0].cost = 999
        p.assignments[1].cost = 999
        let was = p
        p.tasks[1].durationDays = 2
        try Scheduler.schedule(&p)
        p.recalculateCosts(keepingFrom: was)
        XCTAssertEqual(p.assignments[0].cost, 999)
        XCTAssertEqual(p.assignments[1].cost, 1280)
    }

    func testCostsRoundTripThroughTheWriter() throws {
        let template = try MPP14Template.neutralized(try Fixture.bytes())
        var p = plan([PayRate(standardPerHour: 80, costPerUse: 25)],
                     [task(1, "work", 2) { $0.fixedCost = 100; $0.fixedCostAccrual = "end" }])
        p.assignments[0].costRateTable = 0
        try Scheduler.schedule(&p)
        let back = try MPP14File(bytes: try MPP14Writer(template: template).build(p)).readProject()
        XCTAssertEqual(back.assignments.first?.cost, 1305)
        XCTAssertEqual(back.tasks.first?.cost, 1405)
        XCTAssertEqual(back.tasks.first?.fixedCost, 100)
        XCTAssertEqual(back.tasks.first?.fixedCostAccrual, "end")
        XCTAssertEqual(back.resources.first?.costRateTables.first?.first?.standardPerHour, 80)
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// A new file (the blank template has no resource) keeps tables B to E,
    /// in the bytes Project writes: count, then 44 bytes a rate, the last
    /// one open to 31 Dec 2049.
    func testRateTablesAToEReachANewFile() throws {
        let template = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
        var p = plan([PayRate(standardPerHour: 80, costPerUse: 25)], [task(1, "work", 2)])
        p.resources[0].costRateTables = [
            [PayRate(standardPerHour: 80, costPerUse: 25)],
            [PayRate(standardPerHour: 50, overtimePerHour: 75, until: d(2026, 11, 3, 8)), PayRate(standardPerHour: 60)],
            [], [PayRate(standardPerHour: 0)], [PayRate(standardPerHour: 0, costPerUse: 10)],
        ]
        p.assignments[0].costRateTable = 1
        try Scheduler.schedule(&p)
        p.recalculateCosts()
        let bytes = try MPP14Writer(template: template).build(p)
        let back = try MPP14File(bytes: bytes).readProject()
        let tables = try XCTUnwrap(back.resources.first?.costRateTables)
        XCTAssertEqual(tables, [p.resources[0].costRateTables[0], p.resources[0].costRateTables[1], [], [],
                                p.resources[0].costRateTables[4]])
        XCTAssertEqual(back.assignments.first?.costRateTable, 1)
        XCTAssertEqual(back.assignments.first?.cost, p.assignments[0].cost)

        let f = try MPP14File(bytes: bytes)
        let k = MPP14File.EntityClass(root: f.root, storage: "\(MPP.projectStorage)/TBkndRsc", metaSize: MPP.resourceMetaSize,
                                      meta2Size: 53, propsKey: MPP.PropsKey.resourceFieldMap, props: f.props)
        let b = try XCTUnwrap(k.varBytes(1, MPP.ResourceField.costRateTables[1]))
        XCTAssertEqual(b.count, 16 + 2 * 44)
        XCTAssertEqual(Array(b.prefix(6)), [2, 0, 4, 0, 16, 0])
        XCTAssertEqual(Array(b.suffix(4)), [0xF7, 0x2A, 0xB1, 0x14])
        XCTAssertNil(k.varBytes(1, MPP.ResourceField.costRateTables[2]))
        XCTAssertTrue(f.conformanceIssues().isEmpty, "\(f.conformanceIssues().prefix(3))")
    }

    /// Project's own rate tables (several rates, shown per minute or per
    /// day) come back as Project saved them, and an open-ended rate reads
    /// as open.
    func testProjectsRateTablesSurviveASave() throws {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("mpp14costratetable.mpp")) else {
            throw XCTSkip("no mpp14costratetable.mpp — run Tools/ci/fetch-corpus.sh")
        }
        let bytes = [UInt8](data)
        let read = try MPP14File(bytes: bytes).readProject()
        let three = try XCTUnwrap(read.resources.first { $0.name == "Resource Three" })
        XCTAssertEqual(three.costRateTables.count, 5)
        XCTAssertEqual(three.costRateTables[1].map(\.standardPerHour), [35, 6.25])
        XCTAssertNotNil(three.costRateTables[1][0].until)
        XCTAssertNil(three.costRateTables[1][1].until)
        let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(read)).readProject()
        XCTAssertEqual(back.resources.map(\.costRateTables), read.resources.map(\.costRateTables))
        var edited = read
        let i = try XCTUnwrap(edited.resources.firstIndex { $0.name == "Resource Two" })
        edited.resources[i].costRateTables[2] = [PayRate(standardPerHour: 99)]
        let again = try MPP14File(bytes: try MPP14Writer(template: bytes).build(edited)).readProject()
        XCTAssertEqual(again.resources.map(\.costRateTables), edited.resources.map(\.costRateTables))
    }
}
