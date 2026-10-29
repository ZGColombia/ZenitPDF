import Foundation

// MARK: - Point

/// A point in PDF page space: 72 units per inch, origin at the lower-left corner of
/// the page box, y increasing upwards.
///
/// Deliberately not `CGPoint`: the manifest is a value record that must round-trip
/// through `Codable` and compare exactly, and it must be usable from targets that do
/// not import CoreGraphics.
public struct FixturePoint: Sendable, Codable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// Euclidean distance to `other`.
    public func distance(to other: FixturePoint) -> Double {
        (self - other).magnitude
    }

    /// Vector magnitude, computed with `hypot` so that large/small mixed magnitudes
    /// do not overflow or lose precision.
    public var magnitude: Double { (x * x + y * y).squareRoot() }

    public static func - (lhs: FixturePoint, rhs: FixturePoint) -> FixturePoint {
        FixturePoint(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    public static func + (lhs: FixturePoint, rhs: FixturePoint) -> FixturePoint {
        FixturePoint(lhs.x + rhs.x, lhs.y + rhs.y)
    }
}

// MARK: - Rect

/// A PDF box, stored the way PDF stores it: `[llx lly urx ury]`.
///
/// PDF boxes may have a negative origin, and `ZPDFTestingSupport` ships fixtures that
/// exercise exactly that, so the lower-left corner is never assumed to be at or above
/// the origin.
public struct FixtureRect: Sendable, Codable, Hashable {
    public var llx: Double
    public var lly: Double
    public var urx: Double
    public var ury: Double

    public init(llx: Double, lly: Double, urx: Double, ury: Double) {
        self.llx = llx
        self.lly = lly
        self.urx = urx
        self.ury = ury
    }

    /// Convenience constructor from an origin and a size.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(llx: x, lly: y, urx: x + width, ury: y + height)
    }

    public var width: Double { urx - llx }
    public var height: Double { ury - lly }
    public var area: Double { width * height }
    public var perimeter: Double { 2 * (width + height) }

    /// The four corners in counter-clockwise order starting at the lower-left corner.
    public var counterClockwiseCorners: [FixturePoint] {
        [
            FixturePoint(llx, lly),
            FixturePoint(urx, lly),
            FixturePoint(urx, ury),
            FixturePoint(llx, ury)
        ]
    }

    /// The intersection with `other`, or `nil` when the two boxes do not overlap.
    public func intersection(_ other: FixtureRect) -> FixtureRect? {
        let nllx = Swift.max(llx, other.llx)
        let nlly = Swift.max(lly, other.lly)
        let nurx = Swift.min(urx, other.urx)
        let nury = Swift.min(ury, other.ury)
        guard nurx > nllx, nury > nlly else { return nil }
        return FixtureRect(llx: nllx, lly: nlly, urx: nurx, ury: nury)
    }
}

// MARK: - Matrix

/// A PDF transformation matrix `[a b c d e f]`, applied as
/// `x' = a·x + c·y + e`, `y' = b·x + d·y + f`.
public struct FixtureMatrix: Sendable, Codable, Hashable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var e: Double
    public var f: Double

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
    }

    public static let identity = FixtureMatrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    public static func translation(x: Double, y: Double) -> FixtureMatrix {
        FixtureMatrix(a: 1, b: 0, c: 0, d: 1, e: x, f: y)
    }

    public static func scale(x: Double, y: Double) -> FixtureMatrix {
        FixtureMatrix(a: x, b: 0, c: 0, d: y, e: 0, f: 0)
    }

    /// `self` applied first, then `other` — the same order in which PDF composes a
    /// form XObject `/Matrix` with the CTM in force at the `Do` operator.
    public func concatenated(with other: FixtureMatrix) -> FixtureMatrix {
        FixtureMatrix(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            e: e * other.a + f * other.c + other.e,
            f: e * other.b + f * other.d + other.f
        )
    }

    public func apply(to point: FixturePoint) -> FixturePoint {
        FixturePoint(
            a * point.x + c * point.y + e,
            b * point.x + d * point.y + f
        )
    }

    /// The absolute value of the determinant — the factor by which this matrix
    /// scales area.
    public var areaScale: Double { abs(a * d - b * c) }

    /// The uniform length scale, valid only when the matrix is a similarity
    /// (no shear, equal x/y scale). `nil` otherwise, so that a caller cannot
    /// accidentally scale a length by an anisotropic matrix.
    public var uniformLengthScale: Double? {
        let sx = (a * a + b * b).squareRoot()
        let sy = (c * c + d * d).squareRoot()
        let shear = a * c + b * d
        guard abs(sx - sy) <= 1e-12 * Swift.max(sx, sy), abs(shear) <= 1e-12 * sx * sy + 1e-15 else {
            return nil
        }
        return sx
    }
}

// MARK: - Cubic segment

/// A cubic Bézier segment with its four control points recorded exactly as they are
/// written into the content stream.
public struct FixtureCubic: Sendable, Codable, Hashable {
    public var p0: FixturePoint
    public var p1: FixturePoint
    public var p2: FixturePoint
    public var p3: FixturePoint

    public init(p0: FixturePoint, p1: FixturePoint, p2: FixturePoint, p3: FixturePoint) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
    }

    /// De Casteljau evaluation at `t`, clamped to `[0, 1]`.
    public func point(at t: Double) -> FixturePoint {
        let u = Swift.min(Swift.max(t, 0), 1)
        let mu = 1 - u
        let w0 = mu * mu * mu
        let w1 = 3 * mu * mu * u
        let w2 = 3 * mu * u * u
        let w3 = u * u * u
        return FixturePoint(
            w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x,
            w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y
        )
    }
}
