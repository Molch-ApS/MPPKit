// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

// Numbers read from a file, as Int, on every platform.
//
// Where Int is 32 bits (the web app's WebAssembly core), Swift's Int(UInt32)
// traps for a value past 2³¹, an Int32.max read as Int overflows at the next
// + 1, and Project writes such values: 0xFFFFFFFF for "no record", and a
// damaged file has any. The trap stopped the whole core on files that open in
// the Apple apps (MPP Studio #978). These overloads are chosen over the
// standard library's generic init for every Int(…) of these types in this
// module, so no call site can forget: a value up to `tooLarge` is exact, as
// before; a larger one reads as `tooLarge`, which every bounds check refuses.
// Not Int.max: 0x7FFFFFFF fits a 32-bit Int, and the reader's next
// `offset + size` overflowed. On 64 bits no 32-bit value comes near it, so
// the Apple apps read every file exactly as before.
// Each module has its own copy, internal, so no other code changes meaning.

extension Int {
    /// What a file's number past Int's range reads as: past any real offset,
    /// count or size, and far enough from Int.max that adding to it can't overflow.
    static let tooLarge = Int.max >> 2

    init(_ v: UInt32) { self = UInt64(v) <= UInt64(Int.tooLarge) ? Int(truncatingIfNeeded: v) : .tooLarge }
    init(_ v: UInt64) { self = v <= UInt64(Int.tooLarge) ? Int(truncatingIfNeeded: v) : .tooLarge }
    init(_ v: UInt) { self = UInt64(v) <= UInt64(Int.tooLarge) ? Int(truncatingIfNeeded: v) : .tooLarge }
    init(_ v: Int32) { self = Int(Int64(v)) }
    init(_ v: Int64) { self = Int(truncatingIfNeeded: Swift.max(-Int64(Int.tooLarge), Swift.min(Int64(Int.tooLarge), v))) }
}
