// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// Baselines past the eleven Project has fields for. Project stores each slot
/// in its own fixed field ids (`Baseline` and `Baseline1`...`Baseline10`) and
/// has none beyond, so slot 11 and up are kept by the app in a stream of its
/// own, keyed by task uid, resource uid and "task:resource" for assignments.
/// Project never sees them.
///
/// The same stream keeps what Project has no place for on any slot: each
/// baseline's name, lock and who saved it (`info`, keyed by slot), and which
/// slot is the current one (`current`).
public struct ExtraBaselines: Codable, Equatable, Sendable {
    /// The slots Project itself stores.
    public static let projectSlots = 0...10

    public var tasks: [String: [String: Baseline]] = [:]
    public var resources: [String: [String: Baseline]] = [:]
    public var assignments: [String: [String: Baseline]] = [:]
    public var info: [String: BaselineInfo] = [:]
    public var current: Int?

    public init() {}

    public var isEmpty: Bool {
        tasks.isEmpty && resources.isEmpty && assignments.isEmpty && info.isEmpty && current == nil
    }

    /// The slots of `project` past Project's eleven, and its baseline info.
    public init(_ project: Project) {
        func extra(_ b: [Int: Baseline]) -> [String: Baseline]? {
            let out = Dictionary(uniqueKeysWithValues: b.filter { !Self.projectSlots.contains($0.key) }
                .map { (String($0.key), $0.value) })
            return out.isEmpty ? nil : out
        }
        for t in project.tasks { if let e = extra(t.baselines) { tasks[String(t.uid)] = e } }
        for r in project.resources { if let e = extra(r.baselines) { resources[String(r.uid)] = e } }
        for a in project.assignments {
            if let e = extra(a.baselines) { assignments["\(a.taskUID):\(a.resourceUID)"] = e }
        }
        // A slot of Project's own with only a saved date says nothing its
        // `BaselineSaved` doesn't, so a file Project saved gains no stream.
        for (slot, i) in project.baselineInfo
        where !(Self.projectSlots.contains(slot) && i == BaselineInfo(saved: i.saved)) {
            info[String(slot)] = i
        }
        current = project.currentBaseline
    }

    /// Put the extra slots back on the tasks, resources and assignments they
    /// were saved for; entries whose owner is gone are dropped. Info and the
    /// current slot go on the project.
    public func apply(to project: inout Project) {
        func merge(_ into: inout [Int: Baseline], _ from: [String: Baseline]?) {
            for (k, b) in from ?? [:] {
                if let slot = Int(k), !Self.projectSlots.contains(slot) { into[slot] = b }
            }
        }
        for i in project.tasks.indices { merge(&project.tasks[i].baselines, tasks[String(project.tasks[i].uid)]) }
        for i in project.resources.indices {
            merge(&project.resources[i].baselines, resources[String(project.resources[i].uid)])
        }
        for i in project.assignments.indices {
            let a = project.assignments[i]
            merge(&project.assignments[i].baselines, assignments["\(a.taskUID):\(a.resourceUID)"])
        }
        for (k, i) in info { if let slot = Int(k), slot >= 0 { project.baselineInfo[slot] = i } }
        project.currentBaseline = current
    }

    private enum CodingKeys: String, CodingKey { case tasks, resources, assignments, info, current }

    /// Every key is optional: files written before `info` and `current`
    /// existed have only the slots.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent(type(of: tasks), forKey: .tasks) ?? [:]
        resources = try c.decodeIfPresent(type(of: resources), forKey: .resources) ?? [:]
        assignments = try c.decodeIfPresent(type(of: assignments), forKey: .assignments) ?? [:]
        info = try c.decodeIfPresent(type(of: info), forKey: .info) ?? [:]
        current = try c.decodeIfPresent(Int.self, forKey: .current)
    }

    public func encode() -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).map(Array.init)
    }

    public static func decode(_ bytes: [UInt8]) -> ExtraBaselines {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ExtraBaselines.self, from: Data(bytes))) ?? ExtraBaselines()
    }
}

/// What Project keeps about a baseline besides its dates, and more: a name, a
/// lock, when it was saved and by whom. Project itself records only the
/// saved date, for slots 0...10 (`BaselineSaved`); the rest lives in the
/// app's stream (`ExtraBaselines.info`).
public struct BaselineInfo: Codable, Equatable, Sendable {
    public var name: String?
    public var saved: Date?
    /// A display name, when the saver is known.
    public var savedBy: String?
    /// A locked baseline can't be updated, renamed or deleted.
    public var locked: Bool = false

    public init(name: String? = nil, saved: Date? = nil, savedBy: String? = nil, locked: Bool = false) {
        self.name = name
        self.saved = saved
        self.savedBy = savedBy
        self.locked = locked
    }

    private enum CodingKeys: String, CodingKey { case name, saved, savedBy, locked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        saved = try c.decodeIfPresent(Date.self, forKey: .saved)
        savedBy = try c.decodeIfPresent(String.self, forKey: .savedBy)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}

public enum BaselineError: Error, Equatable, Sendable {
    /// The slot is locked; unlock it first.
    case locked(slot: Int)
}

extension Project {
    /// Where the next new baseline goes: one past the highest slot in use, so
    /// a number freed by a delete is not given to another baseline. Past 10
    /// it is one of the app's own slots, which have no upper limit.
    public var nextBaselineSlot: Int {
        (baselineSlots.last ?? -1) + 1
    }

    /// The slots that hold a baseline (dates on any task, resource or
    /// assignment, or info), ascending.
    public var baselineSlots: [Int] {
        var used = Set(baselineInfo.keys)
        for t in tasks { used.formUnion(t.baselines.keys) }
        for r in resources { used.formUnion(r.baselines.keys) }
        for a in assignments { used.formUnion(a.baselines.keys) }
        return used.sorted()
    }

    /// The slot variance is measured against: `currentBaseline` while it
    /// holds a baseline, otherwise slot 0 when it does, as in Project.
    public var effectiveBaseline: Int? {
        let slots = baselineSlots
        if let c = currentBaseline, slots.contains(c) { return c }
        return slots.contains(0) ? 0 : nil
    }

    /// "B3 · Change order 3", or "B3" without a name.
    public func baselineLabel(slot: Int) -> String {
        guard let name = baselineInfo[slot]?.name, !name.isEmpty else { return "B\(slot)" }
        return "B\(slot) · \(name)"
    }

    private func unlocked(_ slot: Int) throws {
        if baselineInfo[slot]?.locked == true { throw BaselineError.locked(slot: slot) }
    }

    private static func clean(_ name: String?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? nil : n
    }

    /// Save the schedule as it is now into a new slot (`nextBaselineSlot`),
    /// never over an existing one. Returns the slot. `now` is wall-clock
    /// time, like every date in the model.
    @discardableResult
    public mutating func saveNewBaseline(name: String? = nil, now: Date, by: String? = nil) -> Int {
        let slot = nextBaselineSlot
        setBaseline(slot: slot)
        baselineInfo[slot] = BaselineInfo(name: Self.clean(name), saved: now, savedBy: Self.clean(by))
        return slot
    }

    /// Replace a baseline's dates with the schedule as it is now. The name
    /// and lock stay; the saved date and saver become now's.
    public mutating func updateBaseline(slot: Int, now: Date, by: String? = nil) throws {
        try unlocked(slot)
        setBaseline(slot: slot)
        var info = baselineInfo[slot] ?? BaselineInfo()
        info.saved = now
        info.savedBy = Self.clean(by)
        baselineInfo[slot] = info
    }

    /// An empty name removes it. Does nothing to a slot without a baseline.
    public mutating func renameBaseline(slot: Int, name: String?) throws {
        try unlocked(slot)
        guard baselineSlots.contains(slot) else { return }
        baselineInfo[slot, default: BaselineInfo()].name = Self.clean(name)
    }

    /// Does nothing to a slot without a baseline.
    public mutating func setBaselineLocked(slot: Int, _ locked: Bool) {
        guard baselineSlots.contains(slot) else { return }
        baselineInfo[slot, default: BaselineInfo()].locked = locked
    }

    /// Remove a baseline's dates and info everywhere. When it was the
    /// current one, the newest remaining slot becomes current.
    public mutating func deleteBaseline(slot: Int) throws {
        try unlocked(slot)
        let wasCurrent = effectiveBaseline == slot
        clearBaseline(slot: slot)
        baselineInfo[slot] = nil
        if wasCurrent || currentBaseline == slot { currentBaseline = baselineSlots.last }
    }
}

extension [Int: Baseline] {
    /// Only the slots Project has fields for.
    public var projectSlots: [Int: Baseline] { filter { ExtraBaselines.projectSlots.contains($0.key) } }
}
