import CoreGraphics
import Foundation

/// A 2-D affine map, stored in the same convention as `CGAffineTransform`.
///
/// ```text
/// x' = a·x + c·y + tx
/// y' = b·x + d·y + ty
/// ```
///
/// ### Direction convention, stated once and never varied
///
/// Throughout `ZPDFCompare` an alignment transform maps **revised page space onto
/// baseline page space**. Everything a comparison reports — region bounds, vector
/// difference bounds — is therefore in *baseline* page space, which is the sheet the
/// user is looking at when they ask "what changed?".
///
/// Stored as `Double` rather than `CGFloat` so that the arithmetic is the same on every
/// target and the value round-trips through `Codable` exactly.
public struct AlignmentTransform: Sendable, Hashable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public init(_ transform: CGAffineTransform) {
        self.init(
            a: Double(transform.a),
            b: Double(transform.b),
            c: Double(transform.c),
            d: Double(transform.d),
            tx: Double(transform.tx),
            ty: Double(transform.ty)
        )
    }

    public static let identity = AlignmentTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d),
            tx: CGFloat(tx), ty: CGFloat(ty)
        )
    }

    // MARK: - Constructors

    public static func translation(dx: Double, dy: Double) -> AlignmentTransform {
        AlignmentTransform(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
    }

    public static func scaling(_ factor: Double) -> AlignmentTransform {
        AlignmentTransform(a: factor, b: 0, c: 0, d: factor, tx: 0, ty: 0)
    }

    /// Translation, uniform scale and rotation — the two-point model, written directly.
    ///
    /// The rotation is applied about the origin before the translation, which is the
    /// order the closed-form solver produces.
    public static func similarity(
        scale: Double,
        rotationRadians: Double,
        translation: CGPoint
    ) -> AlignmentTransform {
        let cosine = Foundation.cos(rotationRadians)
        let sine = Foundation.sin(rotationRadians)
        return AlignmentTransform(
            a: scale * cosine,
            b: scale * sine,
            c: -scale * sine,
            d: scale * cosine,
            tx: Double(translation.x),
            ty: Double(translation.y)
        )
    }

    // MARK: - Application

    @inline(__always)
    public func apply(to point: CGPoint) -> CGPoint {
        let x = Double(point.x)
        let y = Double(point.y)
        return CGPoint(x: a * x + c * y + tx, y: b * x + d * y + ty)
    }

    @inline(__always)
    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    /// The axis-aligned bounding box of the image of `rect`, computed from all four
    /// corners so that a rotation is handled correctly.
    public func transformedBounds(of rect: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ].map(apply(to:))
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for corner in corners {
            minX = Swift.min(minX, Double(corner.x))
            minY = Swift.min(minY, Double(corner.y))
            maxX = Swift.max(maxX, Double(corner.x))
            maxY = Swift.max(maxY, Double(corner.y))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Algebra

    /// `self` first, then `other`.
    public func concatenating(_ other: AlignmentTransform) -> AlignmentTransform {
        AlignmentTransform(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public var determinant: Double { a * d - b * c }

    public var isFinite: Bool {
        a.isFinite && b.isFinite && c.isFinite && d.isFinite && tx.isFinite && ty.isFinite
    }

    public func inverted() throws -> AlignmentTransform {
        let det = determinant
        guard det.isFinite, det != 0, abs(det) > 1e-300 else {
            throw AlignmentFault.nonInvertibleTransform(determinant: det)
        }
        let ia = d / det
        let ib = -b / det
        let ic = -c / det
        let id = a / det
        return AlignmentTransform(
            a: ia,
            b: ib,
            c: ic,
            d: id,
            tx: -(tx * ia + ty * ic),
            ty: -(tx * ib + ty * id)
        )
    }

    /// `sqrt(|det|)` — the uniform scale a similarity carries, and the geometric mean of
    /// the two axis scales for a general affine map.
    public var meanScale: Double { abs(determinant).squareRoot() }

    /// The rotation of the x axis, in radians. Meaningful for a similarity; for a
    /// general affine map it is the rotation of the first column only.
    public var rotationRadians: Double { Foundation.atan2(b, a) }

    /// `true` when every coefficient is within `tolerance` of the identity.
    public func isIdentity(tolerance: Double = 1e-9) -> Bool {
        abs(a - 1) <= tolerance && abs(b) <= tolerance && abs(c) <= tolerance
            && abs(d - 1) <= tolerance && abs(tx) <= tolerance && abs(ty) <= tolerance
    }

    /// The largest distance between `self(p)` and `other(p)` over the corners of `rect`.
    ///
    /// This is how a test states "the solver recovered the transform to within 0.01 pt
    /// anywhere on an A1 sheet" without comparing six coefficients whose individual
    /// magnitudes mean nothing.
    public func maximumDeviation(from other: AlignmentTransform, over rect: CGRect) -> Double {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.midY)
        ]
        var worst = 0.0
        for corner in corners {
            let lhs = apply(to: corner)
            let rhs = other.apply(to: corner)
            worst = Swift.max(worst, Double(hypot(lhs.x - rhs.x, lhs.y - rhs.y)))
        }
        return worst
    }
}
