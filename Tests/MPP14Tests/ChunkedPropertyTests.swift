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

/// zlib, and data split across custom properties.
final class ChunkedPropertyTests: XCTestCase {

    private func json(_ n: Int) -> [UInt8] {
        var rows: [String] = []
        for i in 0..<n { rows.append("{\"guid\":\"\(String(i * 7919, radix: 16))\",\"start\":\(i % 13),\"name\":\"Zone \(i)\"}") }
        return Array(("{\"v\":1,\"rows\":[" + rows.joined(separator: ",") + "]}").utf8)
    }

    func testZlibRoundTrips() {
        for input in [[], Array("a".utf8), json(1), json(2_000), [UInt8](repeating: 7, count: 100_000),
                      (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }] {
            let packed = Zlib.compress(input)
            XCTAssertEqual(Zlib.decompress(packed), input)
        }
        XCTAssertLessThan(Zlib.compress(json(2_000)).count, json(2_000).count / 3)
    }

    /// Streams made by zlib itself (Python's zlib.compress at levels 9 and 0):
    /// dynamic and stored blocks.
    func testReadsZlibsOwnStreams() {
        let dynamic = Data(base64Encoded: "eNqNlLtKQ0EURX9Fpk4x5zWPdOIf2FiHJG2EWIgG/11tLszdbDjlgd2sNcx6lO/327Ucy9vpfnmq5VDO9+vn3/3y/Pp/XU5fH+VYfw6PZSjLULah7Ie6DHUb6n5oy9C2oe2Hvgx9G/p+GMswOExbho3DdKIHYAbRAzCT6AEYqcQPPo0QQYAjSgwBjxhRBEDixBESBZGERI1YQqJOLCHRIJaQaBJLQKSVWAIiFWIJ/48SS0CkRiwBkTqxhERBLCFRI5aQqBNLSDSIJSSaxBIQWSWWgMiEWAIiU2IJI2fEEhCZE0tIFNloW8tW23o62yPbbZvZcHvNltslm27XbLvdsvF2z9bbI1tvb9l6e8/W20e23j6z9Y6arXdItt6h2XqHZesdnq13RLbe0bL1jp6td4xsvWPyev8CGcHJiQ==")!
        var text = ""
        for i in 0..<60 { text += "{\"zone\":\"Ward \(i)\",\"crew\":\"CAR\(i % 7)\",\"days\":\(i % 5)}," }
        XCTAssertEqual(Zlib.decompress([UInt8](dynamic)).map { String(decoding: $0, as: UTF8.self) }, text)
        let stored = Data(base64Encoded: "eAEBBQD6/2hlbGxvBiwCFQ==")!
        XCTAssertEqual(Zlib.decompress([UInt8](stored)).map { String(decoding: $0, as: UTF8.self) }, "hello")
        XCTAssertNil(Zlib.decompress([0x78, 0x9C, 1, 2, 3, 4]))
    }

    func testSplitIntoPropertiesAndBack() {
        var p = Project(title: "T", start: Date())
        p.customProperties["Client"] = "Acme"
        var seed: UInt64 = 42
        let data = (0..<60_000).map { _ -> UInt8 in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        p.setChunkedProperty("Plan", data)
        let parts = p.customProperties.keys.filter { $0.hasPrefix("Plan.") }.sorted()
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.first, "Plan.000")
        XCTAssertTrue(parts.allSatisfy { p.customProperties[$0]!.count <= Project.propertyChunkSize })
        XCTAssertEqual(p.chunkedProperty("Plan"), data)

        // Smaller again: the parts it no longer needs go.
        p.setChunkedProperty("Plan", Array("small".utf8))
        XCTAssertEqual(p.customProperties.keys.filter { $0.hasPrefix("Plan.") }, ["Plan.000"])
        XCTAssertEqual(p.chunkedProperty("Plan"), Array("small".utf8))

        // A part lost or damaged reads as nothing; removing keeps the rest.
        p.customProperties["Plan.000"] = "not base64 !"
        XCTAssertNil(p.chunkedProperty("Plan"))
        p.setChunkedProperty("Plan", nil)
        XCTAssertEqual(p.customProperties, ["Client": "Acme"])
        XCTAssertNil(p.chunkedProperty("Missing"))
    }
}
