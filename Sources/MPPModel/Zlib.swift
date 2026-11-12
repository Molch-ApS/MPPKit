// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

/// zlib streams (RFC 1950 around RFC 1951 DEFLATE), in plain Swift so it
/// builds everywhere MPPKit does, WebAssembly included.
///
/// `compress` finds repeats with hash chains and writes them with the fixed
/// Huffman codes: simple, and close to zlib for JSON. `decompress` reads any
/// zlib stream: stored, fixed and dynamic blocks.
public enum Zlib {

    // MARK: Compress

    public static func compress(_ input: [UInt8]) -> [UInt8] {
        var out = BitWriter()
        out.bytes = [0x78, 0x9C]                      // deflate, 32 KB window, default level
        let n = input.count
        let windowSize = 32_768, hashSize = 1 << 15, maxChain = 64
        var head = [Int](repeating: -1, count: hashSize)
        var prev = [Int](repeating: -1, count: windowSize)
        func hash(_ i: Int) -> Int {
            (Int(input[i]) << 10 ^ Int(input[i + 1]) << 5 ^ Int(input[i + 2])) & (hashSize - 1)
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i & (windowSize - 1)] = head[h]
            head[h] = i
        }
        out.bits(1, 1)                                // the only block, the last
        out.bits(1, 2)                                // fixed Huffman codes
        var i = 0
        while i < n {
            var bestLength = 0, bestDistance = 0
            if i + 2 < n {
                var candidate = head[hash(i)], chain = 0
                let limit = min(258, n - i)
                while candidate >= 0, i - candidate <= windowSize, chain < maxChain {
                    var length = 0
                    while length < limit, input[candidate + length] == input[i + length] { length += 1 }
                    if length > bestLength {
                        bestLength = length
                        bestDistance = i - candidate
                        if length == limit { break }
                    }
                    candidate = prev[candidate & (windowSize - 1)]
                    chain += 1
                }
            }
            if bestLength >= 3 {
                writeLength(bestLength, &out)
                writeDistance(bestDistance, &out)
                for k in 0..<bestLength { insert(i + k) }
                i += bestLength
            } else {
                writeLiteral(Int(input[i]), &out)
                insert(i)
                i += 1
            }
        }
        writeLiteral(256, &out)                       // end of block
        out.flush()
        let a = adler32(input)
        out.bytes += [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)]
        return out.bytes
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// A literal/length symbol in the fixed code (RFC 1951 3.2.6).
    private static func writeLiteral(_ symbol: Int, _ out: inout BitWriter) {
        switch symbol {
        case 0...143: out.code(0x30 + symbol, 8)
        case 144...255: out.code(0x190 + symbol - 144, 9)
        case 256...279: out.code(symbol - 256, 7)
        default: out.code(0xC0 + symbol - 280, 8)
        }
    }

    private static func writeLength(_ length: Int, _ out: inout BitWriter) {
        var k = lengthBase.count - 1
        while lengthBase[k] > length { k -= 1 }
        writeLiteral(257 + k, &out)
        if lengthExtra[k] > 0 { out.bits(length - lengthBase[k], lengthExtra[k]) }
    }

    private static func writeDistance(_ distance: Int, _ out: inout BitWriter) {
        var k = distanceBase.count - 1
        while distanceBase[k] > distance { k -= 1 }
        out.code(k, 5)
        if distanceExtra[k] > 0 { out.bits(distance - distanceBase[k], distanceExtra[k]) }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var buffer = 0, count = 0

        /// `n` bits of `value`, least significant first.
        mutating func bits(_ value: Int, _ n: Int) {
            buffer |= value << count
            count += n
            while count >= 8 { bytes.append(UInt8(buffer & 0xFF)); buffer >>= 8; count -= 8 }
        }

        /// A Huffman code, most significant bit first.
        mutating func code(_ value: Int, _ n: Int) {
            var reversed = 0
            for k in 0..<n where value & (1 << k) != 0 { reversed |= 1 << (n - 1 - k) }
            bits(reversed, n)
        }

        mutating func flush() {
            if count > 0 { bytes.append(UInt8(buffer & 0xFF)) }
            buffer = 0
            count = 0
        }
    }

    // MARK: Decompress

    /// The bytes a zlib stream holds, or nil when it isn't one, its check
    /// value doesn't match, or it holds more than `limit` bytes. Deflate
    /// packs up to about 1,000 to 1: a few KB in a file can ask for gigabytes,
    /// so the output is bounded (64 MB unless said).
    public static func decompress(_ input: [UInt8], limit: Int = 64 << 20) -> [UInt8]? {
        guard input.count >= 6, input[0] & 0x0F == 8, (Int(input[0]) << 8 | Int(input[1])) % 31 == 0,
              input[1] & 0x20 == 0 else { return nil }
        var reader = BitReader(bytes: input, position: 2)
        var out: [UInt8] = []
        var last = false
        while !last {
            guard let final = reader.bits(1), let type = reader.bits(2) else { return nil }
            last = final == 1
            switch type {
            case 0:
                reader.alignToByte()
                guard let len = reader.bytes(2), let nlen = reader.bytes(2) else { return nil }
                let length = Int(len[0]) | Int(len[1]) << 8
                guard length == ~(Int(nlen[0]) | Int(nlen[1]) << 8) & 0xFFFF, out.count + length <= limit,
                      let data = reader.bytes(length) else { return nil }
                out += data
            case 1:
                guard inflate(&reader, &out, literal: fixedLiteral, distance: fixedDistance, limit: limit) else { return nil }
            case 2:
                guard let (literal, distance) = dynamicTables(&reader),
                      inflate(&reader, &out, literal: literal, distance: distance, limit: limit) else { return nil }
            default:
                return nil
            }
        }
        reader.alignToByte()
        guard let check = reader.bytes(4) else { return nil }
        let a = adler32(out)
        guard check == [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)] else { return nil }
        return out
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position: Int
        var buffer = 0, count = 0

        init(bytes: [UInt8], position: Int) {
            self.bytes = bytes
            self.position = position
        }

        mutating func bits(_ n: Int) -> Int? {
            while count < n {
                guard position < bytes.count else { return nil }
                buffer |= Int(bytes[position]) << count
                position += 1
                count += 8
            }
            let value = buffer & ((1 << n) - 1)
            buffer >>= n
            count -= n
            return value
        }

        mutating func alignToByte() { buffer = 0; count = 0 }

        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard position + n <= bytes.count else { return nil }
            defer { position += n }
            return Array(bytes[position..<position + n])
        }
    }

    /// A canonical Huffman code: symbols by code length, as RFC 1951 3.2.2.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init?(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<16 { offsets[l] = offsets[l - 1] + counts[l - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l > 0 { symbols[offsets[l]] = s; offsets[l] += 1 }
        }

        func decode(_ reader: inout BitReader) -> Int? {
            var code = 0, first = 0, index = 0
            for l in 1..<16 {
                guard let bit = reader.bits(1) else { return nil }
                code |= bit
                let count = counts[l]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            return nil
        }
    }

    private static let fixedLiteral = Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })!
    private static let fixedDistance = Huffman(lengths: [Int](repeating: 5, count: 30))!

    private static func dynamicTables(_ reader: inout BitReader) -> (Huffman, Huffman)? {
        guard let hlit = reader.bits(5), let hdist = reader.bits(5), let hclen = reader.bits(4) else { return nil }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for k in 0..<(hclen + 4) {
            guard let v = reader.bits(3) else { return nil }
            codeLengths[order[k]] = v
        }
        guard let lengthCode = Huffman(lengths: codeLengths) else { return nil }
        var lengths: [Int] = []
        let total = hlit + 257 + hdist + 1
        while lengths.count < total {
            guard let symbol = lengthCode.decode(&reader) else { return nil }
            switch symbol {
            case 0...15: lengths.append(symbol)
            case 16:
                guard let previous = lengths.last, let r = reader.bits(2) else { return nil }
                lengths += [Int](repeating: previous, count: 3 + r)
            case 17:
                guard let r = reader.bits(3) else { return nil }
                lengths += [Int](repeating: 0, count: 3 + r)
            default:
                guard let r = reader.bits(7) else { return nil }
                lengths += [Int](repeating: 0, count: 11 + r)
            }
        }
        guard lengths.count == total, let literal = Huffman(lengths: Array(lengths[0..<(hlit + 257)])),
              let distance = Huffman(lengths: Array(lengths[(hlit + 257)...])) else { return nil }
        return (literal, distance)
    }

    private static func inflate(_ reader: inout BitReader, _ out: inout [UInt8], literal: Huffman, distance: Huffman,
                                limit: Int) -> Bool {
        while true {
            guard let symbol = literal.decode(&reader) else { return false }
            if symbol < 256 { guard out.count < limit else { return false }; out.append(UInt8(symbol)); continue }
            if symbol == 256 { return true }
            let k = symbol - 257
            guard k < lengthBase.count, let extra = reader.bits(lengthExtra[k]) else { return false }
            let length = lengthBase[k] + extra
            guard let d = distance.decode(&reader), d < distanceBase.count,
                  let dextra = reader.bits(distanceExtra[d]) else { return false }
            let back = distanceBase[d] + dextra
            guard back <= out.count, out.count + length <= limit else { return false }
            let start = out.count - back
            for i in 0..<length { out.append(out[start + i]) }
        }
    }

    // MARK: Check value

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let end = min(i + 5_552, bytes.count)
            while i < end { a += UInt32(bytes[i]); b += a; i += 1 }
            a %= 65_521
            b %= 65_521
        }
        return b << 16 | a
    }
}
