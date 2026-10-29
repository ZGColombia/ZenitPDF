import Foundation

/// A seeded SplitMix64 generator.
///
/// Not `SystemRandomNumberGenerator`, and not `Int.random(in:)` without a generator: every scene
/// in this package must be byte-identical on every machine and in every process, because a golden
/// PNG is only a golden if the scene that produced it is fixed. SplitMix64 is chosen because it
/// is four lines, has no hidden state, and produces the same stream on any architecture.
public struct DeterministicRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A `Double` in `0..<1`.
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A `Double` in `low...high`.
    public mutating func double(_ low: Double, _ high: Double) -> Double {
        low + unit() * (high - low)
    }

    /// An `Int` in `low...high`.
    public mutating func int(_ low: Int, _ high: Int) -> Int {
        guard high > low else { return low }
        return low + Int(next() % UInt64(high - low + 1))
    }

    /// A UUID built from the stream, so markup identifiers are reproducible too.
    public mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((high >> (8 * UInt64(index))) & 0xFF)
            bytes[8 + index] = UInt8((low >> (8 * UInt64(index))) & 0xFF)
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
