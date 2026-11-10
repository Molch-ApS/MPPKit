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
import MPPModel

/// A file Project saved, read and saved over itself with no edit, reads back
/// as it was: saving must not change what the file says.
final class RoundTripTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// MPXJ's Project 2010/2013 files, from `Tools/ci/fetch-corpus.sh`: the
    /// folder in `MPP_CORPUS`, else `Corpus/`. Skips when there is none.
    private func corpus() throws -> [URL] {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mpp" }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw XCTSkip("no corpus in \(dir.path) — run Tools/ci/fetch-corpus.sh") }
        return files
    }

    /// What a save over itself still changes, by file: a field name, or
    /// "save" for a file that cannot be saved. Each line is a known gap;
    /// remove it once fixed (the test fails on a line no longer needed).
    private static let knownDifferences: [String: Set<String>] = [
        // Ten unnamed base calendars: refused as duplicate names.
        "ResourceIdAndUniqueId-project2013-mpp14.mpp": ["save"],
        // Tasks after an FF or SF link, a link on their summary or none at
        // all are given a Start No Earlier Than constraint at their start.
        "mpp14barstyle.mpp": ["constraint", "constraintDate"],
        "mpp14baseline.mpp": ["constraint", "constraintDate"],
        "mpp14embedded.mpp": ["constraint", "constraintDate"],
        "mpp14relations.mpp": ["constraint", "constraintDate"],
        "mpp14resource.mpp": ["constraint", "constraintDate"],
        "mpp14timephased.mpp": ["constraint", "constraintDate"],
        // The project calendar is "24 Hours": the Standard calendar is
        // written under its name.
        "mpp14header.mpp": ["calendar", "calendars"],
        // Blank task rows are not supported: the rows after one are renumbered.
        "mpp14nulltasks.mpp": ["rowID"],
        // Inserted subprojects are not supported.
        "mpp14subproject.mpp": ["summary"],
    ]

    private func equal<T: Equatable>(_ a: T, _ b: Any) -> Bool { (b as? T) == a }

    /// The names of the fields that differ between two values of one type.
    private func differences<T>(_ a: T, _ b: T) -> Set<String> {
        var out: Set<String> = []
        for (x, y) in zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children) {
            let same = (x.value as? any Equatable).map { equal($0, y.value) }
                ?? (String(describing: x.value) == String(describing: y.value))
            if !same { out.insert(x.label ?? "?") }
        }
        return out
    }

    func testCorpusSavedOverItselfReadsTheSame() throws {
        for url in try corpus() {
            let name = url.lastPathComponent
            let bytes = [UInt8](try Data(contentsOf: url))
            let read = try MPP14File(bytes: bytes).readProject()
            var found: Set<String> = []
            do {
                let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(read)).readProject()
                if back.tasks.map(\.uid) != read.tasks.map(\.uid) { found.insert("task uids") }
                for (a, b) in zip(read.tasks, back.tasks) { found.formUnion(differences(a, b)) }
                if back.assignments.count != read.assignments.count { found.insert("assignment count") }
                // The writer numbers assignments afresh, and gives a resource's
                // own calendar a new row: those uids are its own.
                for (a, b) in zip(read.assignments, back.assignments) {
                    var b = b
                    b.uid = a.uid
                    found.formUnion(differences(a, b))
                }
                if back.resources.count != read.resources.count { found.insert("resource count") }
                for (a, b) in zip(read.resources, back.resources) {
                    var b = b
                    b.calendarUID = a.calendarUID
                    found.formUnion(differences(a, b))
                }
                if back.relations != read.relations { found.insert("relations") }
                if back.calendar != read.calendar { found.insert("calendar") }
                if back.calendars != read.calendars { found.insert("calendars") }
            } catch {
                found.insert("save")
            }
            let known = Self.knownDifferences[name] ?? []
            XCTAssert(found.subtracting(known).isEmpty, "\(name): \(found.subtracting(known).sorted()) changed")
            XCTAssert(known.subtracting(found).isEmpty, "\(name): \(known.subtracting(found).sorted()) no longer changes")
        }
    }

    /// Task A in mpp14resource.mpp: three people at 24 hours each over six
    /// days, each on their own calendar. Saved unchanged it keeps 72 hours
    /// and each person's dates; once its duration changes, its work is
    /// duration × units again.
    func testWorkIsKeptUntilItsTaskChanges() throws {
        guard let url = try corpus().first(where: { $0.lastPathComponent == "mpp14resource.mpp" }) else {
            throw XCTSkip("no mpp14resource.mpp in the corpus")
        }
        let bytes = [UInt8](try Data(contentsOf: url))
        let read = try MPP14File(bytes: bytes).readProject()
        let back = try MPP14File(bytes: try MPP14Writer(template: bytes).build(read)).readProject()
        XCTAssertEqual(back.task(uid: 2)?.workHours, 72)
        XCTAssertEqual(back.assignments.filter { $0.taskUID == 2 }.map(\.workHours), [24, 24, 24])
        XCTAssertEqual(back.assignments.filter { $0.taskUID == 2 }.map(\.finish),
                       read.assignments.filter { $0.taskUID == 2 }.map(\.finish))

        var edited = read
        let i = try XCTUnwrap(edited.tasks.firstIndex { $0.uid == 2 })
        edited.tasks[i].durationDays = 2
        try Scheduler.schedule(&edited)
        let saved = try MPP14File(bytes: try MPP14Writer(template: bytes).build(edited)).readProject()
        XCTAssertEqual(saved.task(uid: 2)?.workHours, 48)
        XCTAssertEqual(saved.assignments.filter { $0.taskUID == 2 }.map(\.workHours), [16, 16, 16])
    }
}
