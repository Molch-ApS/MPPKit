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
import MPPCFB
import MPPModel
import MPP14

/// A malformed file must fail, not hang or crash. The files are made here,
/// byte by byte, so no real file is needed: each is a small compound file
/// with one thing wrong, the way a damaged or crafted `.mpp` could be. Each
/// must throw, within a second.
final class MalformedFileTests: XCTestCase {

    // MARK: - A compound file, by hand

    private static let free: UInt32 = 0xFFFF_FFFF, end: UInt32 = 0xFFFF_FFFE, fatSect: UInt32 = 0xFFFF_FFFD
    private static let none: UInt32 = 0xFFFF_FFFF

    /// One 128-byte directory entry.
    private static func entry(_ name: String, type: UInt8, left: UInt32 = none, right: UInt32 = none,
                              child: UInt32 = none, start: UInt32 = end, size: UInt64 = 0) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 128)
        let units = Array(name.utf16.prefix(31))
        for (i, u) in units.enumerated() { e[i * 2] = UInt8(u & 0xFF); e[i * 2 + 1] = UInt8(u >> 8) }
        put16(&e, 64, UInt16((units.count + 1) * 2))
        e[66] = type
        e[67] = 1
        put32(&e, 68, left); put32(&e, 72, right); put32(&e, 76, child)
        put32(&e, 116, start)
        put64(&e, 120, size)
        return e
    }

    /// A v3 file (512-byte sectors): the header, one FAT sector (sector 0),
    /// the directory from sector 1, then `data` sectors after it. The FAT
    /// chains the directory, and `chains` adds chains of its own:
    /// `[(first, count)]` sectors of the data area linked in order. `header`
    /// can change any header field afterwards.
    private static func file(_ entries: [[UInt8]], dataSectors: Int = 0, chains: [(Int, Int)] = [],
                             header: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        let dir = entries.flatMap { $0 }
        let dirSectors = max(1, (dir.count + 511) / 512)
        let total = 1 + dirSectors + dataSectors
        precondition(total <= 128, "one FAT sector holds 128 ids")
        var fat = [UInt32](repeating: free, count: 128)
        fat[0] = fatSect
        for i in 0..<dirSectors { fat[1 + i] = i == dirSectors - 1 ? end : UInt32(2 + i) }
        let dataStart = 1 + dirSectors
        for (first, count) in chains {
            for i in 0..<count { fat[dataStart + first + i] = i == count - 1 ? end : UInt32(dataStart + first + i + 1) }
        }
        var h = [UInt8](repeating: 0, count: 512)
        h[0..<8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        put16(&h, 24, 0x3E); put16(&h, 26, 3); put16(&h, 28, 0xFFFE); put16(&h, 30, 9); put16(&h, 32, 6)
        put32(&h, 44, 1)              // FAT sectors
        put32(&h, 48, 1)              // first directory sector
        put32(&h, 56, 4096)           // mini stream cutoff
        put32(&h, 60, end); put32(&h, 64, 0)
        put32(&h, 68, end); put32(&h, 72, 0)
        for i in 0..<109 { put32(&h, 76 + i * 4, i == 0 ? 0 : free) }
        header(&h)
        var out = h
        var fatBytes = [UInt8](repeating: 0, count: 512)
        for (i, v) in fat.enumerated() { put32(&fatBytes, i * 4, v) }
        out += fatBytes
        out += dir + [UInt8](repeating: 0, count: dirSectors * 512 - dir.count)
        out += [UInt8](repeating: 0x41, count: dataSectors * 512)
        return out
    }

    private static func put16(_ b: inout [UInt8], _ at: Int, _ v: UInt16) { b[at] = UInt8(v & 0xFF); b[at + 1] = UInt8(v >> 8) }
    private static func put32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) { for k in 0..<4 { b[at + k] = UInt8(v >> (8 * k) & 0xFF) } }
    private static func put64(_ b: inout [UInt8], _ at: Int, _ v: UInt64) { for k in 0..<8 { b[at + k] = UInt8(v >> (8 * k) & 0xFF) } }

    private static let root = entry("Root Entry", type: 5, child: 1)

    /// Reads `bytes` as an .mpp and wants it to throw, within a second.
    private func assertFails(_ name: String, _ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        let started = Date()
        XCTAssertThrowsError(try MPP14File(bytes: bytes).readProject(), name, file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "\(name): took too long", file: file, line: line)
    }

    // MARK: - The container

    func testAWellFormedEmptyContainerOpens() throws {
        // The builder itself makes a file the container reader takes, so the
        // failures below are each for their one fault.
        // 4,500 bytes: past the mini stream cutoff, so in ordinary sectors.
        let ok = Self.file([Self.root, Self.entry("Props14", type: 2, start: 2, size: 4_500)], dataSectors: 9, chains: [(0, 9)])
        let cfb = try CFBFile(bytes: ok)
        XCTAssertEqual(cfb.allStreams().first?.bytes.count, 4_500)
    }

    func testDIFATCycleWithAHugeCount() {
        // 109 FAT ids in the header, so the DIFAT chain is followed; it points
        // at itself, and the header claims 4 billion DIFAT sectors.
        let bytes = Self.file([Self.root], dataSectors: 1) { h in
            for i in 0..<109 { Self.put32(&h, 76 + i * 4, 0) }
            Self.put32(&h, 68, 2); Self.put32(&h, 72, 0xFFFF_FFFF)
        }
        var looped = bytes
        Self.put32(&looped, 512 * 3 + 508, 2)   // the DIFAT sector's next: itself
        assertFails("DIFAT cycle", looped)
    }

    func testStreamSizePastIntMax() {
        let bytes = Self.file([Self.root, Self.entry("Props14", type: 2, start: 2, size: UInt64.max)], dataSectors: 1, chains: [(0, 1)])
        assertFails("stream size 2⁶⁴−1", bytes)
        XCTAssertThrowsError(try CFBFile(bytes: bytes), "the container itself refuses it")
    }

    func testStoragesNestedThousandsDeep() {
        var entries = [Self.root]
        for i in 1...1_000 { entries.append(Self.entry("S\(i)", type: 1, child: i < 1_000 ? UInt32(i + 1) : Self.none)) }
        // 1,000 entries: more than one FAT sector chains, so build them by hand.
        assertFails("nested storages", Self.bigDirectory(entries))
    }

    func testManyEntriesNamingOneChain() {
        // 500 streams of one 30 KB chain each: 15 MB asked from a 100 KB file.
        var entries = [Self.root]
        let count = 500
        for i in 1...count {
            entries.append(Self.entry("s\(i)", type: 2, right: i < count ? UInt32(i + 1) : Self.none, start: 0, size: 60 * 512))
        }
        assertFails("one chain, many entries", Self.bigDirectory(entries, dataSectors: 60))
    }

    func testMiniSectorShiftOtherThanSix() {
        assertFails("mini shift 7", Self.file([Self.root]) { Self.put16(&$0, 32, 7) })
        assertFails("mini shift 40", Self.file([Self.root]) { Self.put16(&$0, 32, 40) })
    }

    func testMiniStreamCutoffOtherThan4096() {
        assertFails("cutoff 2³²−1", Self.file([Self.root]) { Self.put32(&$0, 56, 0xFFFF_FFFF) })
    }

    func testSectorIdsPast2To31() {
        // Where Int is 32 bits (the web core), Int() of these trapped.
        assertFails("directory at 2³¹", Self.file([Self.root]) { Self.put32(&$0, 48, 0x8000_0000) })
        assertFails("FAT at 2³¹", Self.file([Self.root]) { Self.put32(&$0, 76, 0x8000_0000) })
        assertFails("FAT count 2³²−1", Self.file([Self.root]) { Self.put32(&$0, 44, 0xFFFF_FFFF) })
    }

    func testTruncatedAndEmpty() {
        assertFails("empty", [])
        assertFails("signature only", [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        assertFails("header only", Array(Self.file([Self.root]).prefix(512)))
    }

    /// A file whose directory takes more sectors than one FAT sector chains:
    /// the FAT is two sectors, listed in the header.
    private static func bigDirectory(_ entries: [[UInt8]], dataSectors: Int = 0) -> [UInt8] {
        let dir = entries.flatMap { $0 }
        let dirSectors = (dir.count + 511) / 512
        let fatSectors = 2
        let total = fatSectors + dirSectors + dataSectors
        precondition(total <= fatSectors * 128)
        var fat = [UInt32](repeating: free, count: fatSectors * 128)
        for i in 0..<fatSectors { fat[i] = fatSect }
        for i in 0..<dirSectors { fat[fatSectors + i] = i == dirSectors - 1 ? end : UInt32(fatSectors + i + 1) }
        let dataStart = fatSectors + dirSectors
        for i in 0..<dataSectors { fat[dataStart + i] = i == dataSectors - 1 ? end : UInt32(dataStart + i + 1) }
        var h = [UInt8](repeating: 0, count: 512)
        h[0..<8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        put16(&h, 24, 0x3E); put16(&h, 26, 3); put16(&h, 28, 0xFFFE); put16(&h, 30, 9); put16(&h, 32, 6)
        put32(&h, 44, UInt32(fatSectors)); put32(&h, 48, UInt32(fatSectors)); put32(&h, 56, 4096)
        put32(&h, 60, end); put32(&h, 68, end)
        for i in 0..<109 { put32(&h, 76 + i * 4, i < fatSectors ? UInt32(i) : free) }
        var out = h
        var fatBytes = [UInt8](repeating: 0, count: fatSectors * 512)
        for (i, v) in fat.enumerated() { put32(&fatBytes, i * 4, v) }
        out += fatBytes
        out += dir + [UInt8](repeating: 0, count: dirSectors * 512 - dir.count)
        // The data chain starts at sector 0 of the data area: point the
        // streams there.
        var withData = out + [UInt8](repeating: 0x41, count: dataSectors * 512)
        if dataSectors > 0 {
            for i in 1..<entries.count where entries[i][66] == 2 {
                put32(&withData, 512 + fatSectors * 512 + i * 128 + 116, UInt32(dataStart))
            }
        }
        return withData
    }

    // MARK: - The reader and the model

    func testZlibOutputIsBounded() {
        // 1 MB of zeros packs to about 1 KB.
        let packed = Zlib.compress([UInt8](repeating: 0, count: 1 << 20))
        XCTAssertNil(Zlib.decompress(packed, limit: 1 << 19), "past its limit")
        XCTAssertEqual(Zlib.decompress(packed)?.count, 1 << 20, "within the default")
    }

    func testCalendarExceptionsAreBounded() {
        var cal = ProjectCalendar()
        let start = MPPTime.date(days: 0, tenths: 0)
        for _ in 0..<9_999 {
            cal.exceptions.append(CalendarException(start: start, finish: MPPTime.adding(days: 65_534, to: start), working: []))
        }
        let started = Date()
        let wt = WorkingTime(calendar: cal)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertLessThanOrEqual(wt.exceptionDays.count, WorkingTime.exceptionDayLimit)
    }

    func testIntFromDoubleClamps() {
        XCTAssertEqual(Int.clamped(.nan), 0)
        XCTAssertEqual(Int.clamped(.infinity), Int.clampLimit)
        XCTAssertEqual(Int.clamped(-.infinity), -Int.clampLimit)
        XCTAssertEqual(Int.clamped(1e300), Int.clampLimit)
        XCTAssertEqual(Int.clamped(2.5), 3)
        XCTAssertEqual(Int.clamped(-2.5), -3)
        XCTAssertEqual(Int.clamped(2.9, .down), 2)
        // Room left for the sums after it.
        XCTAssertEqual(Int.clampLimit + Int.clampLimit + Int.clampLimit, 3 * Int.clampLimit)
    }

    func testNumbersFromAFileAreFinite() {
        XCTAssertNil(Double.nan.fromFile)
        XCTAssertNil(Double.infinity.fromFile)
        XCTAssertNil((1e16).fromFile)
        XCTAssertEqual((1234.5).fromFile, 1234.5)
    }
}
