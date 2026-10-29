import Foundation

/// Deterministic 64-bit identifiers for index entries that did not come from the PDF.
///
/// `QUALITY_BAR` S15 forbids any ordering that depends on `Hasher`, which is randomly seeded
/// per process. Markup and boundary entries therefore derive their index-local identifier from
/// their **content** with FNV-1a, not from an insertion counter and not from `hashValue`:
/// inserting the same three markups in six different orders produces the same six identifiers,
/// and therefore the same total order and the same winner.
///
/// The algorithm is fixed here rather than imported so that the value can never change as a
/// side effect of a dependency update: a changed identifier is a changed tie-break, and a
/// changed tie-break is a changed snap.
public struct SnapFNV1a: Sendable, Hashable {

    public private(set) var value: UInt64

    public static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    public static let prime: UInt64 = 0x0000_0100_0000_01b3

    public init(seed: UInt64 = SnapFNV1a.offsetBasis) {
        self.value = seed
    }

    public mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* Self.prime
    }

    public mutating func combine(_ bits: UInt64) {
        var remaining = bits
        for _ in 0..<8 {
            combine(UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }

    public mutating func combine(_ int: Int) {
        combine(UInt64(bitPattern: Int64(int)))
    }

    /// Hashes the IEEE-754 bit pattern, with `-0` normalised to `+0` so that two geometrically
    /// identical points cannot receive different identifiers.
    public mutating func combine(_ double: Double) {
        combine((double == 0 ? 0 : double).bitPattern)
    }

    public mutating func combine(_ string: String) {
        for byte in string.utf8 { combine(byte) }
        combine(UInt8(0))
    }
}

/// The identifier space is partitioned by domain so that a markup entry and a PDF entry can
/// never collide by accident, and so that a collision that does occur is resolvable by probing
/// inside one domain.
public enum SnapIdentifierDomain: UInt64, Sendable, CaseIterable {
    /// PDF vector content keeps the extractor's own dense identifiers unchanged.
    case pdfVector = 0
    case markup = 0x4d41_524b_0000_0000
    case boundary = 0x424f_554e_0000_0000
}

public enum SnapIdentifier {

    /// A stable identifier for one component of one owning object.
    ///
    /// - Parameters:
    ///   - domain: the partition the identifier lives in.
    ///   - ownerID: the owning object's stable identity string.
    ///   - component: the index of this geometry within the owner, so a polygon markup's
    ///     outer ring and its third hole get different identifiers.
    ///   - discriminator: bumped by the collision-probing loop in the index builder.
    public static func make(
        domain: SnapIdentifierDomain,
        ownerID: String,
        component: Int,
        discriminator: UInt64 = 0
    ) -> UInt64 {
        var hash = SnapFNV1a()
        hash.combine(domain.rawValue)
        hash.combine(ownerID)
        hash.combine(component)
        hash.combine(discriminator)
        // Keep the high bits of the domain tag so the partition stays legible in a log, and
        // never return 0, which the engine uses as "no primitive".
        let body = (hash.value & 0x0000_0000_ffff_ffff) | 0x0000_0001_0000_0000
        let tagged = domain.rawValue | body
        return tagged == 0 ? 1 : tagged
    }
}
