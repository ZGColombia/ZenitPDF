import CryptoKit
import Foundation
import ZPDFContracts

/// The stable digest of a ``MeasurementGeometry`` (ADR-0007).
///
/// The digest is SHA-256 over a **canonical byte encoding** of the geometry, defined here and
/// nowhere else. Canonical means: a fixed header naming the encoding version, every collection
/// in declaration order behind a fixed tag, every count as an explicit 64-bit big-endian
/// integer, and every coordinate as the big-endian bit pattern of its `Double` (with negative
/// zero normalised to zero, so `-0.0` and `0.0` — equal as geometry — digest equally).
///
/// It is deliberately *not* `Codable` output: JSON key order, float formatting and locale are
/// all things a digest must never depend on. Two identical drawings digest identically on every
/// machine and in every build that stamps the same ``encodingVersion``.
public enum GeometryDigest {

    /// Version of the canonical encoding. Bumped only if the byte layout ever changes, so a
    /// stored digest can always be told apart from one produced under different rules.
    public static let encodingVersion = 1

    /// The lowercase-hex SHA-256 digest of the canonical encoding of `geometry`.
    public static func digest(of geometry: MeasurementGeometry) -> String {
        let hash = SHA256.hash(data: canonicalEncoding(of: geometry))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// The canonical byte encoding itself, exposed so a test can assert on the layout rather
    /// than trusting the hash blindly.
    public static func canonicalEncoding(of geometry: MeasurementGeometry) -> Data {
        var data = Data()
        data.append(contentsOf: "zpdf-geometry-canonical-v\(encodingVersion)".utf8)
        append(uuid: geometry.pageID.rawValue, to: &data)

        append(tag: "PT", count: geometry.points.count, to: &data)
        for point in geometry.points {
            append(point: point, to: &data)
        }

        append(tag: "SG", count: geometry.segments.count, to: &data)
        for segment in geometry.segments {
            append(point: segment.start, to: &data)
            append(point: segment.end, to: &data)
        }

        append(tag: "PG", count: geometry.polygons.count, to: &data)
        for polygon in geometry.polygons {
            append(ring: polygon.outer, to: &data)
            append(tag: "HO", count: polygon.holes.count, to: &data)
            for hole in polygon.holes {
                append(ring: hole, to: &data)
            }
        }

        append(tag: "AR", count: geometry.arcs.count, to: &data)
        for arc in geometry.arcs {
            append(point: arc.center, to: &data)
            append(double: arc.radius, to: &data)
            append(double: arc.startAngle, to: &data)
            append(double: arc.sweepAngle, to: &data)
        }

        append(tag: "CI", count: geometry.circles.count, to: &data)
        for circle in geometry.circles {
            append(point: circle.center, to: &data)
            append(double: circle.radius, to: &data)
        }

        // Arc segments (ADR-0030 §5), appended only when present, so every digest of a
        // geometry without them is byte-identical to the one it had before.
        if let bulges = geometry.pointBulges {
            append(tag: "PB", count: bulges.count, to: &data)
            for bulge in bulges { append(double: bulge, to: &data) }
        }
        for (index, polygon) in geometry.polygons.enumerated() {
            let rings = [polygon.outer] + polygon.holes
            guard rings.contains(where: { $0.bulges != nil }) else { continue }
            append(tag: "RB", count: index, to: &data)
            for ring in rings {
                let bulges = ring.bulges ?? []
                append(tag: "B", count: bulges.count, to: &data)
                for bulge in bulges { append(double: bulge, to: &data) }
            }
        }

        append(tag: "CP", count: geometry.countPoints.count, to: &data)
        for countPoint in geometry.countPoints {
            append(uuid: countPoint.id.rawValue, to: &data)
            append(point: countPoint.position, to: &data)
            append(optionalInt: countPoint.sequenceNumber, to: &data)
            append(optionalUUID: countPoint.groupID?.rawValue, to: &data)
            append(optionalUUID: countPoint.symbolID?.rawValue, to: &data)
        }

        return data
    }

    // MARK: - Primitives

    private static func append(tag: String, count: Int, to data: inout Data) {
        data.append(contentsOf: tag.utf8)
        append(integer: UInt64(count), to: &data)
    }

    private static func append(integer value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(double value: Double, to data: inout Data) {
        // Negative zero equals zero as geometry, so it must digest as zero.
        let canonical = value == 0 ? 0.0 : value
        append(integer: canonical.bitPattern, to: &data)
    }

    private static func append(point: PDFPoint, to data: inout Data) {
        append(double: point.x, to: &data)
        append(double: point.y, to: &data)
    }

    private static func append(ring: PolygonRing, to data: inout Data) {
        append(tag: ring.isClosed ? "RC" : "RO", count: ring.points.count, to: &data)
        for point in ring.points {
            append(point: point, to: &data)
        }
    }

    private static func append(uuid: UUID, to data: inout Data) {
        let bytes = uuid.uuid
        data.append(contentsOf: [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15
        ])
    }

    private static func append(optionalInt value: Int?, to data: inout Data) {
        if let value {
            data.append(1)
            append(integer: UInt64(bitPattern: Int64(value)), to: &data)
        } else {
            data.append(0)
        }
    }

    private static func append(optionalUUID value: UUID?, to data: inout Data) {
        if let value {
            data.append(1)
            append(uuid: value, to: &data)
        } else {
            data.append(0)
        }
    }
}
