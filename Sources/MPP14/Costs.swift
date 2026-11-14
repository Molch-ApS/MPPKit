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
    /// Accrual codes, for fixed costs and resources: 1 start, 2 end, 3 prorated.
    public static let accrualCodes: [String: UInt16] = ["start": 1, "end": 2, "prorated": 3]

    static func accrual(_ code: UInt16?) -> String {
        accrualCodes.first { $0.value == code }?.key ?? "prorated"
    }

    /// The end of the last pay rate: no end (31 Dec 2049 23:59, Project's
    /// last date).
    static let openRateEnd: UInt32 = 0x14B1_2AF7

    /// A cost rate table (resource var 61-65): a 16-byte header with the
    /// count, then 44 bytes a rate: standard pay per hour (f64) and its unit
    /// (u32, 4 bytes free), overtime the same, cost per use in hundredths
    /// (f64), and the moment it holds until (u32 tenths of a minute since
    /// the MPP epoch).
    static func payRates(_ b: [UInt8]) -> [PayRate] {
        let r = BinaryReader(b)
        guard let count = r.u16(at: 0) else { return [] }
        var out: [PayRate] = []
        for n in 0..<Int(min(count, 25)) {
            let o = 16 + n * 44
            guard let std = r.f64(at: o)?.fromFile, let ot = r.f64(at: o + 16)?.fromFile, let cpu = r.f64(at: o + 32)?.fromFile,
                  let until = r.u32(at: o + 40) else { break }
            out.append(PayRate(standardPerHour: std, overtimePerHour: ot, costPerUse: cpu / 100,
                               until: until >= openRateEnd ? nil : MPPTime.date(days: Int(until / 14_400), tenths: Int(until % 14_400))))
        }
        return out
    }

    /// The bytes of a cost rate table, as Project writes them: rates in
    /// hours, the last one open-ended.
    static func encodePayRates(_ rates: [PayRate]) -> [UInt8] {
        var w = BinaryWriter()
        w.u16(UInt16(rates.count)); w.u16(4); w.u16(16)
        w.append([UInt8](repeating: 0, count: 10))
        for (n, rate) in rates.enumerated() {
            for value in [rate.standardPerHour, rate.overtimePerHour] {
                w.f64(value)
                w.u16(2); w.u16(0); w.u32(0)   // per hour
            }
            w.f64(rate.costPerUse * 100)
            if n < rates.count - 1, let until = rate.until {
                let (days, tenths) = MPPTime.wire(from: until)
                w.u32(UInt32(clamping: max(0, days) * 14_400 + tenths))
            } else {
                w.u32(openRateEnd)
            }
        }
        return w.bytes
    }
}
