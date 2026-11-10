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

/// Set Baseline copies a task's work and cost as they are, as Project's does.
final class SetBaselineTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A file from MPXJ's corpus (`Tools/ci/fetch-corpus.sh`): the folder in
    /// `MPP_CORPUS`, else `Corpus/`. Skips when it is not there.
    private func corpus(_ name: String) throws -> Project {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no \(name) in \(dir.path) — run Tools/ci/fetch-corpus.sh")
        }
        return try MPP14File(path: url.path).readProject()
    }

    /// Two days at 50/h, one person full time: 800 on the task, the
    /// assignment and the resource.
    func testBaselineHoldsTheCost() throws {
        var p = Project(title: "Baseline cost", start: MPPTime.date(2026, 11, 2, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        var r = Resource(uid: 1, name: "Crew")
        r.costRateTables = [[PayRate(standardPerHour: 50)], [], [], [], []]
        p.resources = [r]
        var t = ProjectTask(uid: 1, name: "Pour")
        t.durationDays = 2
        t.rowID = 1
        p.tasks = [t]
        p.assignments = [Assignment(taskUID: 1, resourceUID: 1)]
        try Scheduler.schedule(&p)
        p.setBaseline(slot: 0)
        XCTAssertEqual(p.tasks[0].baselines[0]?.cost, 800)
        XCTAssertEqual(p.assignments[0].baselines[0]?.cost, 800)
        XCTAssertEqual(p.resources[0].baselines[0]?.cost, 800)
        XCTAssertEqual(p.tasks[0].baselines[0]?.workHours, 16)

        let blank = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
        let back = try MPP14File(bytes: try MPP14Writer(template: blank).build(p)).readProject()
        XCTAssertEqual(back.tasks[0].baselines[0]?.cost, 800)
        XCTAssertEqual(back.assignments[0].baselines[0]?.cost, 800)
        XCTAssertEqual(back.resources[0].baselines[0]?.cost, 800)
    }

    /// Baseline Cost is held in hundredths, like Cost: a baseline Project
    /// saved over an unchanged plan reads the same as the cost.
    func testBaselineCostReadsInCurrency() throws {
        let p = try corpus("mpp14timephased2.mpp")
        let t = try XCTUnwrap(p.task(uid: 1))
        XCTAssertEqual(t.cost, 880)
        XCTAssertEqual(t.baselines[0]?.cost, 880)
    }

    /// Task A has three people at 24 hours each over six days, and costs
    /// 5 400: duration × units would make it 144 hours. Read and baselined
    /// with nothing changed, the baseline holds Project's numbers.
    func testBaselineKeepsWorkAndCostProjectSaved() throws {
        let read = try corpus("mpp14resource.mpp")
        var p = read
        p.setBaseline(slot: 1, keepingFrom: read)
        let a = try XCTUnwrap(p.task(uid: 2))
        XCTAssertEqual(a.baselines[1]?.workHours, 72)
        XCTAssertEqual(a.baselines[1]?.cost, 5_400)
        for x in p.assignments where x.taskUID == 2 {
            XCTAssertEqual(x.baselines[1]?.workHours, 24)
        }

        // Once the duration changes, the work follows it.
        var edited = read
        let i = try XCTUnwrap(edited.tasks.firstIndex { $0.uid == 2 })
        edited.tasks[i].durationDays = 2
        edited.setBaseline(slot: 1, keepingFrom: read)
        XCTAssertEqual(edited.tasks[i].baselines[1]?.workHours, 48)
    }
}
