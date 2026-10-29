import Foundation
import Testing
import ZPDFContracts

@testable import ZPDFMeasurementEngine

/// QUALITY_BAR **P7** at the primitive that causes it.
///
/// P7 requires exact equality — not agreement to a tolerance — when a polygon's vertex list is
/// rotated or reversed. Rotating the vertex list rotates the per-segment length array, and both
/// `NumericPolicy.pairwiseSum` and `NumericPolicy.kahanSum` are functions of the term *sequence*:
/// the pairing changes, and the last bit of the total moves with it. That bit survives the
/// `Double -> Decimal` crossing at 15 significant digits and lands in the stored value.
///
/// It was found on 2026-08-23 by measuring a 5-gon at 1 ft/pt from each of its five starting
/// vertices: 15.9845047319568 m from three of them, 15.9845047319567 m from the others. At 1 m/pt
/// the same ring summed identically, which is why the case here fixes a non-unit scale and why
/// `AdversarialRoofTests.loopIsRotationInvariant` does too.
///
/// ``EngineNumerics/sum(_:)`` now canonicalises the term order first, so the sum is a function of
/// the multiset. These tests pin that property directly, so a regression is reported where it is
/// caused rather than three call sites away in a roof perimeter.
@Suite("Summation order independence")
struct SummationOrderTests {

    /// A seeded generator, so a failure is reproducible from the seed printed in the name.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 200 term-sets spanning 2 to 91 terms — the pairwise branch below 64 and the
    /// Kahan-Babuska-Neumaier branch above it — each summed in eight shuffles and in reverse.
    ///
    /// Magnitudes span roughly `e^-8` to `e^8` so that the sum is genuinely ill-conditioned: with
    /// terms all of one size the order would not matter and the test would prove nothing.
    @Test("The engine's sum is a function of the multiset, not of the order")
    func sumIsPermutationInvariant() {
        var generator = SplitMix64(seed: 0x5EED_1234_ABCD_0001)
        for _ in 0..<200 {
            let count = 2 + Int(generator.next() % 90)
            let terms = (0..<count).map { _ -> Double in
                let magnitude = Foundation.exp(Double(generator.next() % 1_000_000) / 62_500.0 - 8)
                return generator.next() % 4 == 0 ? -magnitude : magnitude
            }
            let reference = EngineNumerics.sum(terms)
            #expect(reference.isFinite)
            for _ in 0..<8 {
                var shuffled = terms
                for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
                    shuffled.swapAt(index, Int(generator.next() % UInt64(index + 1)))
                }
                #expect(EngineNumerics.sum(shuffled) == reference, "sum depends on term order")
            }
            #expect(EngineNumerics.sum(Array(terms.reversed())) == reference)
            // Rotation is the permutation P7 actually produces.
            for rotation in 1..<Swift.min(count, 6) {
                let rotated = Array(terms[rotation...] + terms[..<rotation])
                #expect(EngineNumerics.sum(rotated) == reference, "sum depends on the starting term")
            }
        }
    }

    /// The canonicalisation must not disturb the trivial cases the exactness claims rest on.
    @Test("Zero, one and two terms are untouched")
    func smallCases() {
        #expect(EngineNumerics.sum([]) == 0)
        #expect(EngineNumerics.sum([40.0]) == 40.0)
        #expect(EngineNumerics.sum([40.0, 0.0]) == 40.0)
        #expect(EngineNumerics.sum([-3.5, 3.5]) == 0)
        #expect(EngineNumerics.sum([3.5, -3.5]) == 0)
    }

    /// A non-finite term must not reach `sort`, whose comparator would stop being a strict weak
    /// ordering. It propagates instead, and the `Double -> Decimal` crossing refuses it.
    @Test("A non-finite term propagates rather than corrupting the sort")
    func nonFiniteShortCircuits() {
        #expect(EngineNumerics.sum([1.0, .nan, 2.0]).isNaN)
        #expect(EngineNumerics.sum([1.0, .infinity, 2.0]) == .infinity)
        #expect(throws: MeasurementEngineError.self) {
            _ = try EngineNumerics.decimal(EngineNumerics.sum([1.0, .nan]))
        }
    }
}
