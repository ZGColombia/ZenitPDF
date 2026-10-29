import Foundation

/// FNV-1a, 64-bit.
///
/// Used wherever a hash must be **stable across processes**: cache keys and the option
/// fingerprint. Swift's `Hasher` is seeded randomly per process, so a key built with it
/// would miss every entry written by an earlier launch, and — worse, per `QUALITY_BAR`
/// 3.4 — would make any ordering derived from it differ between runs.
struct FNVHash {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    init() {}

    mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* Self.prime
    }

    mutating func combine<T: FixedWidthInteger>(_ number: T) {
        var bits = UInt64(truncatingIfNeeded: number)
        for _ in 0..<8 {
            combine(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    mutating func combine(_ flag: Bool) {
        combine(UInt8(flag ? 1 : 0))
    }

    /// Hashes the IEEE-754 bit pattern, so `0.95` fingerprints identically everywhere.
    mutating func combine(_ number: Double) {
        combine(number.bitPattern)
    }

    mutating func combine(_ string: String) {
        combine(UInt64(string.utf8.count))
        for byte in string.utf8 { combine(byte) }
    }

    mutating func combine(_ bytes: some Sequence<UInt8>) {
        for byte in bytes { combine(byte) }
    }
}
