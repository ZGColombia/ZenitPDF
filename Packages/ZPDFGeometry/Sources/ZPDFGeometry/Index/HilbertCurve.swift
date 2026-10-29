import Foundation

/// The Hilbert space-filling curve on a 2^16 x 2^16 grid.
///
/// Packing an R-tree by Hilbert order rather than by row order (or by a Morton/Z-order curve) is
/// what keeps the leaf nodes square-ish: the Hilbert curve has no long jumps, so consecutive
/// items are always spatially adjacent and a node of 16 consecutive items has a small bounding
/// box. Z-order's diagonal jumps produce nodes that straddle half the page, which shows up
/// directly as extra nodes visited per query.
///
/// 16 bits per axis is the standard resolution: it fits the interleaved result in `UInt32`, and
/// on a 14 400-point page one grid cell is 0.22 points — far finer than the clustering decision
/// needs to be.
public enum HilbertCurve {
    /// Grid resolution per axis.
    public static let gridSize: UInt32 = 1 << 16

    /// Hilbert distance for a grid coordinate. Both inputs must be < 2^16.
    ///
    /// This is `hilbertXYToIndex` from rawrunprotected's public-domain hilbert_curves
    /// (github.com/rawrunprotected/hilbert_curves), fixed at 16 bits per axis with the bit
    /// interleave written inline. It computes the curve index with a parallel prefix scan over
    /// the bits of (x, y): a fixed, branch-free sequence of shifts and bitwise operations, so
    /// its cost does not depend on the input and it never touches memory.
    public static func distance(x: UInt32, y: UInt32) -> UInt32 {
        var a = x ^ y
        var b: UInt32 = 0xFFFF ^ a
        var c: UInt32 = 0xFFFF ^ (x | y)
        var d: UInt32 = x & (y ^ 0xFFFF)

        var A = a | (b >> 1)
        var B = (a >> 1) ^ a
        var C = ((c >> 1) ^ (b & (d >> 1))) ^ c
        var D = ((a & (c >> 1)) ^ (d >> 1)) ^ d

        a = A; b = B; c = C; d = D
        A = (a & (a >> 2)) ^ (b & (b >> 2))
        B = (a & (b >> 2)) ^ (b & ((a ^ b) >> 2))
        C ^= (a & (c >> 2)) ^ (b & (d >> 2))
        D ^= (b & (c >> 2)) ^ ((a ^ b) & (d >> 2))

        a = A; b = B; c = C; d = D
        A = (a & (a >> 4)) ^ (b & (b >> 4))
        B = (a & (b >> 4)) ^ (b & ((a ^ b) >> 4))
        C ^= (a & (c >> 4)) ^ (b & (d >> 4))
        D ^= (b & (c >> 4)) ^ ((a ^ b) & (d >> 4))

        a = A; b = B; c = C; d = D
        C ^= (a & (c >> 8)) ^ (b & (d >> 8))
        D ^= (b & (c >> 8)) ^ ((a ^ b) & (d >> 8))

        a = C ^ (C >> 1)
        b = D ^ (D >> 1)

        var i0 = x ^ y
        var i1 = b | (0xFFFF ^ (i0 | a))

        i0 = (i0 | (i0 << 8)) & 0x00FF00FF
        i0 = (i0 | (i0 << 4)) & 0x0F0F0F0F
        i0 = (i0 | (i0 << 2)) & 0x33333333
        i0 = (i0 | (i0 << 1)) & 0x55555555

        i1 = (i1 | (i1 << 8)) & 0x00FF00FF
        i1 = (i1 | (i1 << 4)) & 0x0F0F0F0F
        i1 = (i1 | (i1 << 2)) & 0x33333333
        i1 = (i1 | (i1 << 1)) & 0x55555555

        return (i1 << 1) | i0
    }

    /// Quantises a value from `[lower, upper]` into `0 ..< gridSize`.
    ///
    /// A zero-extent range (every primitive at the same x, which happens on a page of purely
    /// vertical grid lines) maps everything to 0 rather than dividing by zero; the other axis
    /// then does all the ordering work, which is exactly right.
    public static func quantise(_ value: Double, lower: Double, upper: Double) -> UInt32 {
        let span = upper - lower
        guard span > 0, span.isFinite else { return 0 }
        let normalised = (value - lower) / span
        let scaled = normalised * Double(gridSize - 1)
        if !scaled.isFinite || scaled <= 0 { return 0 }
        if scaled >= Double(gridSize - 1) { return gridSize - 1 }
        return UInt32(scaled)
    }
}
