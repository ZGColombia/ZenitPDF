import Foundation
import GRDB
import ZPDFSpreadsheet

/// Why a geometry blob was rejected.
public enum GeometryBlobError: Error, Sendable, Hashable, CustomStringConvertible {
    case tooShort(byteCount: Int)
    case tooLarge(byteCount: Int, limit: Int)
    case badMagic(found: UInt32)
    case unsupportedFormatVersion(found: UInt16, supported: UInt16)
    case unknownKind(raw: UInt16)
    case ringCountOverLimit(found: UInt32, limit: UInt32)
    case pointCountOverLimit(found: UInt32, limit: UInt32)
    case declaredCountMismatch(declared: UInt32, counted: UInt32)
    case truncated(expected: Int, available: Int)
    case trailingBytes(count: Int)
    case checksumMismatch(expected: UInt32, computed: UInt32)
    case nonFiniteCoordinate(ring: Int, point: Int)
    /// The reserved flags word is not zero: a writer this build does not know set it.
    case reservedFlagsSet(flags: UInt32)

    public var description: String {
        switch self {
        case let .tooShort(byteCount): return "only \(byteCount) bytes"
        case let .tooLarge(byteCount, limit): return "\(byteCount) bytes, limit \(limit)"
        case let .badMagic(found): return String(format: "bad magic 0x%08X", found)
        case let .unsupportedFormatVersion(found, supported):
            return "format version \(found), this build writes \(supported)"
        case let .unknownKind(raw): return "unknown geometry kind \(raw)"
        case let .ringCountOverLimit(found, limit): return "\(found) rings, limit \(limit)"
        case let .pointCountOverLimit(found, limit): return "\(found) points, limit \(limit)"
        case let .declaredCountMismatch(declared, counted):
            return "header declares \(declared) points, rings hold \(counted)"
        case let .truncated(expected, available): return "needs \(expected) bytes, has \(available)"
        case let .trailingBytes(count): return "\(count) unexpected trailing bytes"
        case let .checksumMismatch(expected, computed):
            return String(format: "checksum 0x%08X, computed 0x%08X", expected, computed)
        case let .reservedFlagsSet(flags):
            return String(format: "reserved flags 0x%08X set, this build reads none", flags)
        case let .nonFiniteCoordinate(ring, point):
            return "non-finite coordinate at ring \(ring), point \(point)"
        }
    }
}

/// One page-space coordinate pair, in PDF points, bottom-left origin.
public struct GeometryPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// What the rings in a blob mean.
///
/// Raw values are on-disk contract and are never reused for a different meaning.
public enum GeometryBlobKind: UInt16, Sendable, Hashable, Codable, CaseIterable {
    case point = 1
    case polyline = 2
    case polygon = 3
    case polygonWithHoles = 4
    case rectangle = 5
    case ellipse = 6
    case cubicPath = 7
    case freeform = 8
}

/// The versioned binary layout behind every `geometry_blob`, `polygon_blob` and
/// `bounds_blob` column.
///
/// ```text
/// offset  size  field
/// 0       4     magic 'Z' 'P' 'G' '1'            (big-endian character order)
/// 4       2     formatVersion    UInt16 LE
/// 6       2     kind             UInt16 LE
/// 8       4     flags            UInt32 LE       (reserved, must be 0 in version 1)
/// 12      4     ringCount        UInt32 LE
/// 16      4     totalPointCount  UInt32 LE       (redundant, checked against the rings)
/// 20      …     ring[i]: UInt32 LE pointCount, then pointCount × (Float64 LE x, Float64 LE y)
/// end-4   4     crc32            UInt32 LE       over every preceding byte
/// ```
///
/// Little-endian throughout because every machine this ships on is little-endian and
/// the encoder normalises explicitly, so a file written on one is readable on any.
///
/// Decoding treats the buffer as hostile. Every count is checked against a cap *before*
/// anything is allocated, the declared total is cross-checked against what the rings
/// actually hold, the length must match exactly with no trailing slack, the CRC must
/// agree, and any `NaN` or infinity is a rejection rather than a value — a `NaN`
/// coordinate that reaches the geometry layer poisons every bounding box it touches.
public struct GeometryBlob: Sendable, Hashable {

    /// `'Z' 'P' 'G' '1'` read as a big-endian 32-bit word.
    public static let magic: UInt32 = 0x5A50_4731
    /// The layout this build writes.
    public static let currentFormatVersion: UInt16 = 1

    /// At most this many rings: an outer boundary plus holes. A takeoff polygon with
    /// four thousand holes is a bug or an attack, not a floor slab.
    public static let maximumRingCount: UInt32 = 4_096
    /// At most this many points across all rings — 32 MB of coordinate data.
    public static let maximumTotalPointCount: UInt32 = 2_000_000
    /// Hard cap on a single blob, checked before the header is even read.
    public static let maximumByteCount = 64 * 1024 * 1024

    private static let headerByteCount = 20
    private static let checksumByteCount = 4

    public var kind: GeometryBlobKind
    /// Ring 0 is the outer boundary; rings 1… are holes for `.polygonWithHoles`.
    public var rings: [[GeometryPoint]]

    public init(kind: GeometryBlobKind, rings: [[GeometryPoint]]) {
        self.kind = kind
        self.rings = rings
    }

    /// Convenience for the single-ring kinds.
    public init(kind: GeometryBlobKind, points: [GeometryPoint]) {
        self.init(kind: kind, rings: [points])
    }

    public var totalPointCount: Int { rings.reduce(0) { $0 + $1.count } }

    // MARK: Encoding

    /// Serialises to the layout above. Fails if the value is over a cap or holds a
    /// non-finite coordinate, so a bad blob can never be written in the first place.
    public func encode() throws(GeometryBlobError) -> Data {
        guard rings.count <= Int(Self.maximumRingCount) else {
            throw .ringCountOverLimit(found: UInt32(clamping: rings.count), limit: Self.maximumRingCount)
        }
        let total = totalPointCount
        guard total <= Int(Self.maximumTotalPointCount) else {
            throw .pointCountOverLimit(found: UInt32(clamping: total), limit: Self.maximumTotalPointCount)
        }
        for (ringIndex, ring) in rings.enumerated() {
            for (pointIndex, point) in ring.enumerated() where !point.x.isFinite || !point.y.isFinite {
                throw .nonFiniteCoordinate(ring: ringIndex, point: pointIndex)
            }
        }

        var data = Data()
        data.reserveCapacity(Self.headerByteCount + rings.count * 4 + total * 16 + Self.checksumByteCount)
        appendBigEndian(Self.magic, to: &data)
        appendLittleEndian(Self.currentFormatVersion, to: &data)
        appendLittleEndian(kind.rawValue, to: &data)
        appendLittleEndian(UInt32(0), to: &data)                    // flags
        appendLittleEndian(UInt32(rings.count), to: &data)
        appendLittleEndian(UInt32(total), to: &data)
        for ring in rings {
            appendLittleEndian(UInt32(ring.count), to: &data)
            for point in ring {
                appendLittleEndian(point.x.bitPattern, to: &data)
                appendLittleEndian(point.y.bitPattern, to: &data)
            }
        }
        // The trailer is IEEE CRC-32, the zip formats' own (U-103): so a blob whose bytes rotted
        // on disk fails loudly instead of decoding into plausible-looking coordinates. An
        // integrity check, not a security one.
        appendLittleEndian(ZipCRC32.checksum(data), to: &data)
        guard data.count <= Self.maximumByteCount else {
            throw .tooLarge(byteCount: data.count, limit: Self.maximumByteCount)
        }
        return data
    }

    // MARK: Decoding

    /// Parses the layout above, rejecting anything that does not match it exactly.
    public static func decode(_ data: Data) throws(GeometryBlobError) -> GeometryBlob {
        guard data.count <= maximumByteCount else {
            throw .tooLarge(byteCount: data.count, limit: maximumByteCount)
        }
        guard data.count >= headerByteCount + checksumByteCount else {
            throw .tooShort(byteCount: data.count)
        }
        // Work on a contiguous, zero-based copy so slice indices can never surprise us.
        let bytes = [UInt8](data)

        let foundMagic = readBigEndianUInt32(bytes, 0)
        guard foundMagic == magic else { throw .badMagic(found: foundMagic) }

        let formatVersion = readLittleEndianUInt16(bytes, 4)
        guard formatVersion == currentFormatVersion else {
            throw .unsupportedFormatVersion(found: formatVersion, supported: currentFormatVersion)
        }
        let rawKind = readLittleEndianUInt16(bytes, 6)
        guard let kind = GeometryBlobKind(rawValue: rawKind) else { throw .unknownKind(raw: rawKind) }
        // "Reserved, must be 0 in version 1" is only forward-compatibility protection
        // if a reader enforces it (BH-610): a flag this build does not know changes the
        // meaning of what follows, and guessing is worse than refusing.
        let flags = readLittleEndianUInt32(bytes, 8)
        guard flags == 0 else { throw .reservedFlagsSet(flags: flags) }

        let ringCount = readLittleEndianUInt32(bytes, 12)
        guard ringCount <= maximumRingCount else {
            throw .ringCountOverLimit(found: ringCount, limit: maximumRingCount)
        }
        let declaredTotal = readLittleEndianUInt32(bytes, 16)
        guard declaredTotal <= maximumTotalPointCount else {
            throw .pointCountOverLimit(found: declaredTotal, limit: maximumTotalPointCount)
        }

        // Size the whole body from the declared counts before allocating anything.
        let bodyLimit = bytes.count - checksumByteCount
        var cursor = headerByteCount
        var rings: [[GeometryPoint]] = []
        rings.reserveCapacity(Int(ringCount))
        var counted: UInt32 = 0

        for ringIndex in 0..<Int(ringCount) {
            guard cursor + 4 <= bodyLimit else { throw .truncated(expected: cursor + 4, available: bodyLimit) }
            let pointCount = readLittleEndianUInt32(bytes, cursor)
            cursor += 4
            guard pointCount <= maximumTotalPointCount else {
                throw .pointCountOverLimit(found: pointCount, limit: maximumTotalPointCount)
            }
            let (sum, overflow) = counted.addingReportingOverflow(pointCount)
            guard !overflow, sum <= maximumTotalPointCount else {
                throw .pointCountOverLimit(found: maximumTotalPointCount, limit: maximumTotalPointCount)
            }
            counted = sum
            let ringBytes = Int(pointCount) * 16
            guard cursor + ringBytes <= bodyLimit else {
                throw .truncated(expected: cursor + ringBytes, available: bodyLimit)
            }
            var ring: [GeometryPoint] = []
            ring.reserveCapacity(Int(pointCount))
            for pointIndex in 0..<Int(pointCount) {
                let base = cursor + pointIndex * 16
                let x = Double(bitPattern: readLittleEndianUInt64(bytes, base))
                let y = Double(bitPattern: readLittleEndianUInt64(bytes, base + 8))
                guard x.isFinite, y.isFinite else {
                    throw .nonFiniteCoordinate(ring: ringIndex, point: pointIndex)
                }
                ring.append(GeometryPoint(x: x, y: y))
            }
            cursor += ringBytes
            rings.append(ring)
        }

        guard counted == declaredTotal else {
            throw .declaredCountMismatch(declared: declaredTotal, counted: counted)
        }
        guard cursor == bodyLimit else { throw .trailingBytes(count: bodyLimit - cursor) }

        let storedChecksum = readLittleEndianUInt32(bytes, bodyLimit)
        let computed = bytes[0..<bodyLimit].withUnsafeBytes { ZipCRC32.checksum($0) }
        guard storedChecksum == computed else {
            throw .checksumMismatch(expected: storedChecksum, computed: computed)
        }
        return GeometryBlob(kind: kind, rings: rings)
    }
}

// MARK: - GRDB

extension GeometryBlob: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        // A blob that cannot be encoded (NaN coordinate, over a ring/point cap) must NOT be
        // written as an empty blob: that satisfied `NOT NULL`, so the save "succeeded" and the
        // reopen then failed to decode — a permanently unreadable markup (CR-76). Refuse instead:
        // `NULL` violates the `NOT NULL` on every geometry column, which aborts the transaction
        // rather than committing a corrupt row. The encode is attempted at the throwing call
        // sites too, so this is a backstop, not the primary guard.
        guard let data = try? encode() else { return .null }
        return data.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> GeometryBlob? {
        guard let data = Data.fromDatabaseValue(dbValue) else { return nil }
        return try? decode(data)
    }
}

// MARK: - Byte helpers

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
}
private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}
private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}
private func appendLittleEndian(_ value: UInt64, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}
private func readBigEndianUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
}
private func readLittleEndianUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}
private func readLittleEndianUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
}
private func readLittleEndianUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
        value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
    }
    return value
}
