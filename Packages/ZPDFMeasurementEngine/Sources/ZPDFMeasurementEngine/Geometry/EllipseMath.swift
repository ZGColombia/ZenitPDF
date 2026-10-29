import Foundation
import ZPDFContracts

/// Ellipse area and circumference under an arbitrary affine scale (spec 12.1 Ellipse Area).
enum EllipseMath {

    /// The real-world semi-axes of a page-space axis-aligned ellipse, in metres, and how far
    /// apart they are.
    ///
    /// An affine map sends an ellipse to an ellipse, but not to one with the same axis ratio and
    /// not, in general, to an axis-aligned one. Reading `metresPerPointX` and `metresPerPointY`
    /// off the matrix is right only when the map is diagonal; under a rotated page or a sheared
    /// calibration it silently reports the wrong shape.
    ///
    /// The honest answer is the singular values of `N = M · diag(a, b)`, where `M` is the 2x2
    /// part of the scale: they are the real ellipse's semi-major and semi-minor axes. Their
    /// product is `|det N| = |det M| · a · b`, the determinant area factor the rest of the engine
    /// uses. They are taken from two sums of squares that never cancel:
    ///
    /// ```text
    /// S = hypot(n00 + n11, n10 − n01)     D = hypot(n00 − n11, n10 + n01)
    /// major = (S + D) / 2                 major − minor = min(S, D)
    /// ```
    ///
    /// The minor axis is `|det N| / major` (S-107): a subtraction of two values the size of `a`
    /// would lose a thin ellipse's area to cancellation.
    ///
    /// Until T-073 the major axis was `sqrt((F + sqrt(F² − 4det²)) / 2)` with `F = ‖N‖²`. For a
    /// circle `F² ≈ 4det²`, so the discriminant was rounding noise and its square root made the
    /// two axes differ by about `sqrt(ε)·r` — 1.6e-5 pt on a drawn circle, far above the 1e-6 pt
    /// circle test — and 6 % of round Ellipse Areas lost Radius and Diameter depending only on
    /// where they sat on the sheet. `min(S, D)` is the axis difference itself, exact to
    /// rounding: zero for identical box sides under any similarity (a rotation, a reflection).
    static func realSemiAxes(
        pageSemiAxisX: Double,
        pageSemiAxisY: Double,
        scale: ScaleTransform
    ) -> (major: Double, minor: Double, difference: Double) {
        let n = mappedAxes(pageSemiAxisX: pageSemiAxisX, pageSemiAxisY: pageSemiAxisY, scale: scale)
        let sum = Foundation.hypot(n.n00 + n.n11, n.n10 - n.n01)
        let difference = Foundation.hypot(n.n00 - n.n11, n.n10 + n.n01)
        let major = (sum + difference) / 2
        let determinant = n.n00 * n.n11 - n.n01 * n.n10
        let minor = major > 0 ? Swift.min(Swift.abs(determinant) / major, major) : 0
        return (major, minor, Swift.min(sum, difference))
    }

    /// `N = M · diag(a, b)`: the page semi-axis vectors `(a, 0)` and `(0, b)` mapped to metres,
    /// as its columns.
    static func mappedAxes(
        pageSemiAxisX: Double,
        pageSemiAxisY: Double,
        scale: ScaleTransform
    ) -> (n00: Double, n01: Double, n10: Double, n11: Double) {
        let m = scale.matrix.components
        return (m.a * pageSemiAxisX, m.b * pageSemiAxisY, m.c * pageSemiAxisX, m.d * pageSemiAxisY)
    }

    /// Exact ellipse area: `pi * a * b`.
    static func area(semiMajor: Double, semiMinor: Double) -> Double {
        Double.pi * semiMajor * semiMinor
    }

    /// The real circumference of the page-space axis-aligned ellipse with semi-axes `a`, `b`, in
    /// metres, under any affine scale (T-074).
    ///
    /// The page ellipse is `r(φ) = (a cos φ, b sin φ)`; mapped through `M` its speed is
    /// `|N · (−sin φ, cos φ)|` with `N = M · diag(a, b)`, so the circumference is the arc length
    /// of a unit circle mapped through `N` over one full turn — the same composite Gauss-Legendre
    /// quadrature (``ArcLengthQuadrature``) that measures every arc under a separate X/Y scale,
    /// converged to 1e-14 relative. It is an elliptic integral with no closed form; it is
    /// integrated on the curve, never on a polyline (QUALITY_BAR §2.2 rule 4).
    ///
    /// This replaced Ramanujan's second approximation, whose documentation claimed "below 1e-12
    /// up to 2:1, below 1e-8 up to 10:1". Against a 50-digit AGM reference it is −4.56e-10 at
    /// 2:1, −1.156e-5 at 10:1 (a 10 m × 1 m ellipse 0.235 mm short) and −2.39e-4 at 100:1.
    static func circumference(
        pageSemiAxisX: Double,
        pageSemiAxisY: Double,
        scale: ScaleTransform
    ) -> Double {
        let n = mappedAxes(pageSemiAxisX: Swift.abs(pageSemiAxisX), pageSemiAxisY: Swift.abs(pageSemiAxisY), scale: scale)
        return ArcLengthQuadrature.length(
            radius: 1,
            startAngle: 0,
            sweep: 2 * Double.pi,
            a: n.n00, b: n.n01, c: n.n10, d: n.n11
        )
    }
}
