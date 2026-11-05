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

/// Data Project has no field for, kept where Project keeps it: in the file's
/// custom properties.
///
/// Microsoft Project drops every root stream it doesn't know when it saves,
/// but keeps custom properties, within limits it doesn't announce: a single
/// value over about 41.5 KB is dropped, and so is every property once they
/// pass about 512 KB together (Project 2609, Nov 2026). So a value is stored
/// zlib-compressed and base64-encoded, split into properties `name.000`,
/// `name.001`, … of at most `propertyChunkSize` characters, and the whole
/// file's properties are kept under `propertyBudget`.
extension Project {
    /// Characters in one property: well under the 41.5 KB Project keeps.
    public static let propertyChunkSize = 20_000
    /// All custom properties together, leaving room under Project's 512 KB.
    public static let propertyBudget = 450_000

    /// The bytes stored under `name`, or nil when they are missing or
    /// damaged (a part gone, or text that doesn't decode).
    public func chunkedProperty(_ name: String) -> [UInt8]? {
        Self.chunkedProperty(name, in: customProperties)
    }

    /// The bytes stored under `name` in a set of custom properties.
    public static func chunkedProperty(_ name: String, in properties: [String: String]) -> [UInt8]? {
        var text = ""
        var i = 0
        while let part = properties[chunkName(name, i)] {
            text += part
            i += 1
        }
        guard i > 0, let data = Data(base64Encoded: text) else { return nil }
        return Zlib.decompress([UInt8](data))
    }

    /// Store `data` under `name`, replacing what was there; nil removes it.
    public mutating func setChunkedProperty(_ name: String, _ data: [UInt8]?) {
        var i = 0
        while customProperties[Self.chunkName(name, i)] != nil {
            customProperties[Self.chunkName(name, i)] = nil
            i += 1
        }
        guard let data else { return }
        let text = Array(Data(Zlib.compress(data)).base64EncodedString())
        for (n, start) in stride(from: 0, to: text.count, by: Self.propertyChunkSize).enumerated() {
            customProperties[Self.chunkName(name, n)] = String(text[start..<min(start + Self.propertyChunkSize, text.count)])
        }
    }

    /// The characters `data` takes once stored under a name.
    public static func storedSize(_ data: [UInt8]) -> Int {
        (Zlib.compress(data).count + 2) / 3 * 4
    }

    /// The characters every custom property takes, names included.
    public var customPropertySize: Int {
        customProperties.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }

    static func chunkName(_ name: String, _ i: Int) -> String {
        let n = String(i)
        return name + "." + String(repeating: "0", count: max(0, 3 - n.count)) + n
    }
}
