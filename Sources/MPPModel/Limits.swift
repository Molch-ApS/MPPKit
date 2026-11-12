// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

/// Numbers a damaged file can carry, made safe to compute with.
///
/// `Int(_ : Double)` traps on NaN, on infinity and past `Int`'s range, and a
/// file can hold any of those in a duration, a lag or a percentage. A value
/// within range can still overflow in the sum after it, so whole numbers are
/// held to a quarter of `Int`'s range: about 1,000 years of minutes where
/// `Int` is 32 bits (the WebAssembly core), far more elsewhere.
extension Int {
    /// The largest whole number `clamped` gives, either way.
    public static let clampLimit = Int.max >> 2

    /// `value` rounded with `rule`: NaN as 0, and held within ±`clampLimit`.
    public static func clamped(_ value: Double, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int {
        guard !value.isNaN else { return 0 }
        let r = value.rounded(rule)
        if r >= Double(clampLimit) { return clampLimit }
        if r <= -Double(clampLimit) { return -clampLimit }
        return Int(r)
    }
}

extension Double {
    /// The largest magnitude a number read from a file may have: far past any
    /// real cost (in hundredths), work (in tenths of minutes) or units.
    public static let fileLimit = 1e15

    /// A number read from a file, or nil when it is NaN, infinite or past
    /// ±`fileLimit`, so nothing downstream computes with it.
    public var fromFile: Double? { isFinite && abs(self) <= Double.fileLimit ? self : nil }
}
