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
import MPPCFB
import MPPModel

extension MPP {
    /// Task outline codes: Outline Code1...10. The value is a var field
    /// (`01 07`, the `u32` row of its value in the lookup table, the value's
    /// GUID, 4 bytes; some Project 2013 files have `01 04`); the definition, in `TBkndTask/Props` key 0x04400001,
    /// has the field's lookup table GUID at byte 36.
    public enum OutlineCode {
        public static let value: [UInt32] = (0..<10).map { 0x1A1 + 2 * $0 }
        public static let definition: [UInt32] = (0..<10).map { 0x1A0 + 2 * $0 }
    }
}

/// The lookup tables of custom fields and outline codes: `   114/TBkndOutlCode`.
///
/// Every table's values share these streams, told apart by their list GUID.
/// Laid out as Project 2013 and later save it (checked on MPXJ's
/// task-outlinecodes files and on Project-saved plans):
///
/// - FixedMeta: 16-byte header, then 10-byte items: `u32` flags (0x20000 for
///   a value, 0x10000 for the root, 4 for the three header records), `u32`
///   offset, `u16` presence bits (0x1D3, 0x1DB for a value with children).
/// - FixedData: per value, `u32` row, `u32` row, `u16` level (1 at the top),
///   `u32` parent row (0 at the top); the root is row 0. Project 2010 has the
///   parent first, then the level.
/// - Fixed2Meta, Fixed2Data: per value, the value's GUID, the `u16` data type
///   (0x15 text) and the list GUID. Project 2010 has the list GUID at 16 and
///   the type at 32.
/// - VarMeta, Var2Data (class 0x1640): 0x16 the name, 0x17 the sort order (a
///   double), 0x08 the description.
///
/// Rows of tables the writer doesn't rebuild are kept byte for byte.
struct OutlineCodeTable {
    static let base = "\(MPP.projectStorage)/TBkndOutlCode"
    static let varClass: UInt16 = 0x1640
    enum Var { static let name: UInt32 = 0x16, sort: UInt32 = 0x17, description: UInt32 = 0x08 }

    struct Record {
        var item: [UInt8], data: [UInt8], item2: [UInt8], data2: [UInt8]
    }

    /// A value: `row` is its place in the table; `uid` names it. Its name
    /// and other var fields, its parent and a task's value all refer to the
    /// uid. Project numbers both from 1 per file; MPPKit before 0.5.4 wrote
    /// both as the next row, which can repeat a uid already in the table.
    struct Value {
        var row: Int, uid: Int, level: Int, parent: Int
        var guid: [UInt8], list: [UInt8]
        var name: String, sort: Double, description: String
    }

    var metaHeader: [UInt8], meta2Header: [UInt8], varHeader: [UInt8]
    var records: [Record]
    var vars: [(uid: Int, field: UInt32, payload: [UInt8])]
    /// Project 2013 and later: list GUID at 18; Project 2010: at 16.
    var listAt18: Bool

    init?(root: CFBStorage) {
        guard let m = root.streamIfPresent(path: "\(Self.base)/FixedMeta"),
              let d = root.streamIfPresent(path: "\(Self.base)/FixedData"),
              let m2 = root.streamIfPresent(path: "\(Self.base)/Fixed2Meta"),
              let d2 = root.streamIfPresent(path: "\(Self.base)/Fixed2Data"),
              let vm = root.streamIfPresent(path: "\(Self.base)/VarMeta"),
              let vd = root.streamIfPresent(path: "\(Self.base)/Var2Data"),
              let meta = try? MPP.parseFixedMetaAuto(m, defaultItemSize: 10),
              let meta2 = try? MPP.parseFixedMetaAuto(m2, defaultItemSize: 10) else { return nil }
        let items = MPP.declaredItems(meta), items2 = MPP.declaredItems(meta2)
        guard items.count == items2.count else { return nil }
        let data = MPP.splitFixedData(d, metaItems: items), data2 = MPP.splitFixedData(d2, metaItems: items2)
        metaHeader = meta.header
        meta2Header = meta2.header
        records = (0..<items.count).map { Record(item: items[$0], data: data[$0], item2: items2[$0], data2: data2[$0]) }
        let parsed = MPP.parseVarMeta(vm)
        varHeader = parsed.header
        vars = parsed.entries.map { ($0.uid, $0.field & 0xFFFF, MPP.readVar(vd, offset: $0.offset)) }
        // The root's second GUID sits where the list GUID does.
        let rootRow: [UInt8] = records.first(where: { Self.flags($0.item) == 0x10000 }).map(\.data2) ?? []
        listAt18 = !(rootRow.count >= 24
                     && rootRow[16..<24].elementsEqual([0x7E, 0x8B, 0xCB, 0xA0, 0x8C, 0x2A, 0x6D, 0x43]))
    }

    static func flags(_ item: [UInt8]) -> UInt32 { BinaryReader(item).u32(at: 0) ?? 0 }

    func isValue(_ r: Record) -> Bool { Self.flags(r.item) == 0x20000 && r.data.count >= 14 && r.data2.count >= 34 }

    func row(_ r: Record) -> Int { Int(BinaryReader(r.data).u32(at: 0) ?? 0) }

    func uid(_ r: Record) -> Int { Int(BinaryReader(r.data).u32(at: 4) ?? 0) }

    func list(_ r: Record) -> [UInt8] { listAt18 ? Array(r.data2[18..<34]) : Array(r.data2[16..<32]) }

    /// Every value of every table.
    var values: [Value] {
        var byRow: [Int: [UInt32: [UInt8]]] = [:]
        for v in vars { byRow[v.uid, default: [:]][v.field] = v.payload }
        return records.filter(isValue).map { r in
            let b = BinaryReader(r.data)
            let uid = uid(r), v = byRow[uid] ?? [:]
            let level = listAt18 ? b.u16(at: 8) : b.u16(at: 12), parent = listAt18 ? b.u32(at: 10) : b.u32(at: 8)
            return Value(row: row(r), uid: uid, level: Int(level ?? 1), parent: Int(parent ?? 0),
                         guid: Array(r.data2[0..<16]), list: list(r),
                         name: v[Var.name].map(MPP.decodeUnicode) ?? "",
                         sort: v[Var.sort].flatMap { BinaryReader($0).f64(at: 0) } ?? 0,
                         description: v[Var.description].map(MPP.decodeUnicode) ?? "")
        }
    }

    /// Whether a value of `list` has a uid a value of another list has too,
    /// as an older MPPKit wrote them: the list is written again, renumbered.
    func clashes(list: [UInt8]) -> Bool {
        let values = records.filter(isValue)
        let others = Set(values.filter { self.list($0) != list }.map(uid))
        return values.contains { self.list($0) == list && others.contains(uid($0)) }
    }

    /// The definition read back from the values of `list`, in table order.
    func definition(list: [UInt8]) -> OutlineCodeDefinition {
        let mine = values.filter { $0.list == list }.sorted { ($0.sort, $0.row) < ($1.sort, $1.row) }
        // A parent is the uid of a value in the same list.
        let guidOf = Dictionary(mine.map { ($0.uid, $0.guid) }, uniquingKeysWith: { a, _ in a })
        return OutlineCodeDefinition(listGUID: list, values: mine.map {
            OutlineCodeValue(guid: $0.guid, name: $0.name, description: $0.description,
                             parent: $0.parent == 0 ? nil : guidOf[$0.parent])
        })
    }

    /// Replace the values of these lists with the definitions' own, keeping
    /// every other row. A value keeps its row and uid while its GUID is in
    /// the table and its uid is its own; new ones get rows and uids after
    /// the highest. Returns each value's uid, which a task's value names.
    mutating func replace(lists: Set<[UInt8]>, with definitions: [OutlineCodeDefinition]) -> [[UInt8]: Int] {
        let values = records.filter(isValue)
        let replaced = values.filter { lists.contains(list($0)) }
        let kept = values.filter { !lists.contains(list($0)) }
        let old = Dictionary(replaced.map { (Array($0.data2[0..<16]), (row: row($0), uid: uid($0))) },
                             uniquingKeysWith: { a, _ in a })
        // Uids the other lists hold. An older MPPKit could give a value one
        // of these, and Project then renumbers one of the two and loses
        // every child's parent; such a value takes a new uid.
        let taken = Set(kept.map(uid))
        // Vars of the replaced values go. Where another list holds the uid
        // too, only the last of each field goes: the older MPPKit's, which it
        // wrote after the file's own.
        let dropped = Set(replaced.map(uid))
        let shared = dropped.intersection(taken)
        var seen = Set<String>()
        var keptVars: [(uid: Int, field: UInt32, payload: [UInt8])] = []
        for v in vars.reversed() {
            guard dropped.contains(v.uid) else { keptVars.append(v); continue }
            if shared.contains(v.uid), !seen.insert("\(v.uid)/\(v.field)").inserted { keptVars.append(v) }
        }
        vars = Array(keptVars.reversed())
        let gone = Set(records.indices.filter { isValue(records[$0]) && lists.contains(list(records[$0])) })
        records = records.indices.filter { !gone.contains($0) }.map { records[$0] }
        // Only value rows count: the header records hold 0xFFFF000n there.
        var nextRow = (values.map(row).max() ?? 0) + 1
        var nextUID = max(values.map(uid).max() ?? 0, vars.map(\.uid).max() ?? 0) + 1
        var ids: [[UInt8]: (row: Int, uid: Int)] = [:]
        for def in definitions {
            for v in def.values {
                if let o = old[v.guid], !taken.contains(o.uid), !ids.values.contains(where: { $0.uid == o.uid }) {
                    ids[v.guid] = o
                } else {
                    ids[v.guid] = (nextRow, nextUID)
                    nextRow += 1; nextUID += 1
                }
            }
        }
        for def in definitions {
            let parents = Set(def.values.compactMap(\.parent))
            for (i, v) in def.values.enumerated() {
                let id = ids[v.guid]!
                let parent = v.parent.flatMap { ids[$0]?.uid } ?? 0
                let level = le16(UInt16(def.level(of: v.guid)))
                let data = le(UInt32(id.row)) + le(UInt32(id.uid))
                    + (listAt18 ? level + le(UInt32(parent)) : le(UInt32(parent)) + level)
                let item = le(0x20000) + le(0) + le16(parents.contains(v.guid) ? 0x1DB : 0x1D3)
                let data2 = listAt18 ? v.guid + [0x15, 0] + def.listGUID : v.guid + def.listGUID + [0x15, 0]
                let item2 = le(0) + le(0) + le16(0x1F)
                records.append(Record(item: item, data: data, item2: item2, data2: data2))
                vars.append((id.uid, Var.name, MPP.encodeUnicode(v.name)))
                vars.append((id.uid, Var.sort, withUnsafeBytes(of: Double(i + 1).bitPattern.littleEndian) { Array($0) }))
                if !v.description.isEmpty { vars.append((id.uid, Var.description, MPP.encodeUnicode(v.description))) }
            }
        }
        return ids.mapValues(\.uid)
    }

    /// The six streams, offsets and counts recomputed.
    func write(to root: CFBStorage) {
        var data = BinaryWriter(), data2 = BinaryWriter()
        var items: [[UInt8]] = [], items2: [[UInt8]] = []
        for r in records {
            var item = r.item, item2 = r.item2
            item.replaceSubrange(4..<8, with: le(UInt32(data.count)))
            item2.replaceSubrange(4..<8, with: le(UInt32(data2.count)))
            items.append(item)
            items2.append(item2)
            data.append(r.data)
            data2.append(r.data2)
        }
        root.setStream(path: "\(Self.base)/FixedMeta", MPP.buildFixedMeta(header: metaHeader, items: items, dataLength: data.count))
        root.setStream(path: "\(Self.base)/FixedData", data.bytes)
        root.setStream(path: "\(Self.base)/Fixed2Meta", MPP.buildFixedMeta(header: meta2Header, items: items2, dataLength: data2.count))
        root.setStream(path: "\(Self.base)/Fixed2Data", data2.bytes)
        let (vm, vd) = MPP.buildVarBlocks(header: varHeader, values: vars, fieldClass: Self.varClass)
        root.setStream(path: "\(Self.base)/VarMeta", vm)
        root.setStream(path: "\(Self.base)/Var2Data", vd)
    }

    private func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    private func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
}

/// The code masks of lookup tables: project Props key 0x0240138C. A `u32`
/// count, then per table its list GUID, a `u32` level count and per level a
/// `u32` sequence (3 is Characters), a `u32` separator character and a `u32`
/// length (0 is Any); a table with levels ends with 6 more bytes (written as
/// Project 2013 and later write them).
enum OutlineCodeMasks {
    static let key: UInt32 = 0x0240_138C

    static func entries(_ value: [UInt8]) -> [(list: [UInt8], bytes: [UInt8])]? {
        let r = BinaryReader(value)
        guard let count = r.u32(at: 0).map(Int.init), count < 4096 else { return nil }
        var out: [(list: [UInt8], bytes: [UInt8])] = []
        var pos = 4
        for _ in 0..<count {
            guard let levels = r.u32(at: pos + 16).map(Int.init), levels < 64 else { return nil }
            let size = 20 + levels * 12 + (levels > 0 ? 6 : 0)
            guard pos + size <= value.count else { return nil }
            out.append((Array(value[pos..<pos + 16]), Array(value[pos..<pos + size])))
            pos += size
        }
        return out
    }

    /// The masks with `list` set to `levels` levels of any characters,
    /// separated by ".".
    static func setting(_ value: [UInt8]?, list: [UInt8], levels: Int) -> [UInt8]? {
        var all = value.map { entries($0) } ?? []
        guard all != nil else { return nil }
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var entry = list + le(UInt32(levels))
        for _ in 0..<levels { entry += le(3) + le(0x2E) + le(0) }
        if levels > 0 { entry += [0x05, 0x01, 0x00, 0x00, 0x00, 0x00] }
        if let i = all!.firstIndex(where: { $0.list == list }) { all![i] = (list, entry) } else { all!.append((list, entry)) }
        return le(UInt32(all!.count)) + all!.flatMap(\.bytes)
    }
}
