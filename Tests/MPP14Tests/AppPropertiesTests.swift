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

extension MPP14File {
    private static let dsiName = "\u{5}DocumentSummaryInformation"

    /// The names of the file's custom properties.
    var customPropertyNames: [String] {
        guard let dsi = try? root.stream(Self.dsiName) else { return [] }
        return OLEPropertySet.userProperties(dsi).map(\.name)
    }

    func hasAppProperty(_ name: String) -> Bool {
        customPropertyNames.contains(name + ".000")
    }

    /// The file as Project leaves it when MPPKit's properties are lost.
    func removeAppProperties() {
        guard let dsi = try? root.stream(Self.dsiName) else { return }
        var removed: [String: String?] = [:]
        for name in customPropertyNames where MPP.AppProperty.isOwn(name) { removed[name] = .some(nil) }
        root.addStream(Self.dsiName, OLEPropertySet.updatingUserProperties(dsi, removed))
    }
}

/// What Project has no field for, kept in custom properties.
final class AppPropertiesTests: XCTestCase {

    private func blankTemplate() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Blank-Template.mpp")
        return [UInt8](try Data(contentsOf: url))
    }

    private func project(baselines: Int) -> Project {
        var p = SampleProject.make()
        for i in p.tasks.indices { p.tasks[i].baselines = [:] }
        for i in p.assignments.indices { p.assignments[i].baselines = [:] }
        for i in p.resources.indices { p.resources[i].baselines = [:] }
        p.baselineInfo = [:]
        for slot in 0..<baselines {
            _ = p.saveNewBaseline(name: "Plan \(slot)", now: MPPTime.date(2026, 1, 1).addingTimeInterval(Double(slot) * 86_400), by: nil)
        }
        p.viewColumns = ["id", "name:240", "duration", "text3"]
        p.customProperties["Client"] = "North Yard"
        return p
    }

    func testStoredInPropertiesNotStreams() throws {
        let file = try MPP14File(bytes: try MPP14Writer(template: try blankTemplate()).build(project(baselines: 14)))
        for stream in [MPP.viewColumnsStream, MPP.calendarSetupStream, MPP.extraBaselinesStream] {
            XCTAssertNil(try? file.root.stream(stream), stream)
        }
        XCTAssertTrue(file.hasAppProperty(MPP.AppProperty.columns))
        XCTAssertTrue(file.hasAppProperty(MPP.AppProperty.baselines))
        let read = try file.readProject()
        XCTAssertEqual(read.viewColumns, ["id", "name:240", "duration", "text3"])
        XCTAssertEqual(read.baselineSlots, Array(0..<14))
        XCTAssertEqual(read.baselineLabel(slot: 13), "B13 · Plan 13")
        // MPPKit's properties are not the project's.
        XCTAssertEqual(read.customProperties, ["Client": "North Yard"])
    }

    /// A file written before keeps its data in streams; it still opens, and
    /// saving it again moves the data to properties.
    func testReadsOldStreams() throws {
        let file = try MPP14File(bytes: try MPP14Writer(template: try blankTemplate()).build(project(baselines: 14)))
        let expected = try file.readProject()
        let columns = Array(expected.viewColumns!.joined(separator: ",").utf8)
        var properties: [String: String] = [:]
        for (name, value) in OLEPropertySet.userProperties(try file.root.stream("\u{5}DocumentSummaryInformation")) {
            if case .string(let text) = value { properties[name] = text }
        }
        let baselines = try XCTUnwrap(Project.chunkedProperty(MPP.AppProperty.baselines, in: properties))
        file.removeAppProperties()
        file.root.addStream(MPP.viewColumnsStream, columns)
        file.root.addStream(MPP.extraBaselinesStream, baselines)
        let old = try file.readProject()
        XCTAssertEqual(old.viewColumns, expected.viewColumns)
        XCTAssertEqual(old.baselineSlots, expected.baselineSlots)
        XCTAssertEqual(old.baselineInfo, expected.baselineInfo)

        let resaved = try MPP14File(bytes: try MPP14Writer(template: try CFBWriter.write(root: file.root)).build(old))
        XCTAssertNil(try? resaved.root.stream(MPP.extraBaselinesStream))
        XCTAssertNil(try? resaved.root.stream(MPP.viewColumnsStream))
        XCTAssertEqual(try resaved.readProject().baselineSlots, expected.baselineSlots)
    }

    /// Past the budget, the oldest baselines past Project's eleven go first;
    /// Project's own and the newest stay.
    func testBudgetDropsOldestExtraBaselines() throws {
        let template = try blankTemplate()
        var options = MPP14Writer.Options()
        options.propertyBudget = 1
        let none = try MPP14File(bytes: try MPP14Writer(template: template, options: options).build(project(baselines: 30))).readProject()
        XCTAssertEqual(none.baselineSlots, Array(0...10))
        XCTAssertEqual(none.customProperties, ["Client": "North Yard"])

        // Room for some: the kept extras are the newest.
        var sized = project(baselines: 20)
        for name in MPP.AppProperty.all { sized.setChunkedProperty(name, nil) }
        var stored = sized
        stored.setChunkedProperty(MPP.AppProperty.columns, Array(sized.viewColumns!.joined(separator: ",").utf8))
        stored.setChunkedProperty(MPP.AppProperty.baselines, ExtraBaselines(sized).encode())
        options.propertyBudget = stored.customPropertySize
        let some = try MPP14File(bytes: try MPP14Writer(template: template, options: options).build(project(baselines: 30))).readProject()
        let extras = some.baselineSlots.filter { $0 > 10 }
        XCTAssertFalse(extras.isEmpty)
        XCTAssertLessThan(extras.count, 19)
        XCTAssertEqual(extras, Array((30 - extras.count)..<30))
        XCTAssertEqual(Array(some.baselineSlots.prefix(11)), Array(0...10))
    }
}
