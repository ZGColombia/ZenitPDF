import Foundation
import ZPDFContracts

/// Streaming Kahan-Babuska-Neumaier summation.
///
/// Algorithmically identical to ``NumericPolicy/kahanSum(_:)`` for finite terms — same terms in
/// the same order produce the same bits — but it does not require the caller to materialise an
/// array first.
///
/// Non-finite terms: the compensation of an infinite term is `inf - inf = NaN`, which would
/// turn an honest `inf` total into NaN, and NaN is what downstream `> areaFloor` guards swallow
/// silently. So when the running sum is not finite, ``total`` is the plain sum: `inf` for a
/// sum of one sign of infinity, NaN only when the terms themselves have no sum (BH-555).
/// Perimeters and shoelace sums over a 100 000-vertex ring would otherwise allocate a scratch
/// buffer per call (spec 11.4 mandates compensated summation for large `Double` sums).
public struct KahanAccumulator: Sendable {
    private var sum: Double = 0
    private var compensation: Double = 0

    public init() {}

    public mutating func add(_ value: Double) {
        let candidate = sum + value
        if Swift.abs(sum) >= Swift.abs(value) {
            compensation += (sum - candidate) + value
        } else {
            compensation += (value - candidate) + sum
        }
        sum = candidate
    }

    /// The compensated total.
    public var total: Double { sum.isFinite ? sum + compensation : sum }
}
