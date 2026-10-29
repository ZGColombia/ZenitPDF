import Foundation
import ZPDFContracts

/// A displacement in canonical PDF page space, in points.
///
/// `ZPDFContracts` ships ``RealVector`` (metres) but no page-space vector, because the contract
/// layer only ever needed points and rectangles. Segment mathematics needs the difference of two
/// points to be a first-class value, so it lives here.
public struct PDFVector: Hashable, Sendable, Codable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    /// The displacement `end - start`.
    public init(from start: PDFPoint, to end: PDFPoint) {
        self.init(dx: end.x - start.x, dy: end.y - start.y)
    }

    public static let zero = PDFVector(dx: 0, dy: 0)

    public var isFinite: Bool { dx.isFinite && dy.isFinite }
    public var magnitude: Double { (dx * dx + dy * dy).squareRoot() }
    public var squaredMagnitude: Double { dx * dx + dy * dy }

    public func dot(_ other: PDFVector) -> Double { dx * other.dx + dy * other.dy }

    /// The z component of the 3-D cross product. Positive when `other` is counter-clockwise
    /// from `self`.
    public func cross(_ other: PDFVector) -> Double { dx * other.dy - dy * other.dx }

    /// Rotated a quarter turn counter-clockwise.
    public var perpendicular: PDFVector { PDFVector(dx: -dy, dy: dx) }

    public func scaled(by factor: Double) -> PDFVector {
        PDFVector(dx: dx * factor, dy: dy * factor)
    }

    /// - Throws: ``GeometryError/zeroLengthVector`` when the magnitude is zero or non-finite.
    public func normalized() throws -> PDFVector {
        let length = magnitude
        guard length.isFinite, length > 0 else { throw GeometryError.zeroLengthVector }
        return PDFVector(dx: dx / length, dy: dy / length)
    }

    /// The direction in radians, `atan2(dy, dx)`, in `(-pi, pi]`.
    public var angle: Double { Foundation.atan2(dy, dx) }
}

extension PDFPoint {
    /// `self + vector`.
    public func offset(by vector: PDFVector) -> PDFPoint {
        PDFPoint(x: x + vector.dx, y: y + vector.dy)
    }

    /// The displacement from `self` to `other`, i.e. `other - self` — the same convention as
    /// ``PDFVector/init(from:to:)``, so `p.offset(by: p.vector(to: q)) == q`.
    public func vector(to other: PDFPoint) -> PDFVector {
        PDFVector(from: self, to: other)
    }

    /// Squared distance. Avoids the square root in comparisons and nearest-neighbour loops.
    public func squaredDistance(to other: PDFPoint) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return dx * dx + dy * dy
    }
}
