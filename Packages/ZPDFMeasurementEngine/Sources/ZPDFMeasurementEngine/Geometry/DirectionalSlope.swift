import Foundation
import ZPDFContracts

/// A slope resolved into a magnitude **and** a fall-line direction in real space (ADR-0004).
///
/// The scalar rule `trueLength = planLength * sqrt(1 + s^2)` is the length factor for a line
/// running straight up the fall line and for nothing else. A plane tilted by `theta` has a
/// steepest-ascent unit vector `u`; a plan displacement `d` on that plane changes elevation by
/// `s * (d . u)`, so its true length is
///
/// ```text
/// |d_true| = sqrt( |d|^2 + ( s * (d . u) )^2 )
/// ```
///
/// An eave or a ridge runs perpendicular to `u`, so `d . u == 0` and the true length equals the
/// plan length **exactly** — not to within a tolerance. That exactness is the whole point of this
/// type, and it is why ``trueLength(dx:dy:)`` is built from `hypot`, which returns `|x|` bit-for-
/// bit when the other argument is zero.
struct DirectionalSlope: Sendable {
    /// `s = rise / run`, dimensionless.
    let ratio: Double
    /// `sqrt(1 + s^2)`: the exact area factor, and the *maximum* length factor — reached only by
    /// a segment parallel to the fall line.
    let areaFactor: Double
    /// Steepest ascent in real (metre) space, x component.
    let ux: Double
    /// Steepest ascent in real (metre) space, y component.
    let uy: Double

    /// True length of one real-space displacement, in metres.
    func trueLength(dx: Double, dy: Double) -> Double {
        let along = dx * ux + dy * uy
        return Foundation.hypot(Foundation.hypot(dx, dy), ratio * along)
    }

    /// True length of one real-space displacement, in metres.
    func trueLength(_ delta: RealVector) -> Double {
        trueLength(dx: delta.dx, dy: delta.dy)
    }

    /// Resolves a page-space azimuth into the real-space fall line.
    ///
    /// The arrow the user draws lives on the page, but the elongation happens in the world, so
    /// the direction is pushed through the scale matrix as a *delta* and renormalised. Under an
    /// anisotropic calibration a fall line drawn at 45 degrees on the page is not at 45 degrees
    /// in the world, and this is where that is accounted for.
    ///
    /// Axis-aligned azimuths under an axis-aligned scale come out exactly `(0, ±1)` or `(±1, 0)`,
    /// which is what preserves the exactness of the contour-parallel case.
    static func resolve(
        ratio: Double,
        areaFactor: Double,
        azimuth: SlopeAzimuth,
        scale: ScaleTransform
    ) throws(MeasurementEngineError) -> DirectionalSlope {
        guard ratio.isFinite, areaFactor.isFinite else {
            throw MeasurementEngineError.slope(.nonFiniteSlopeRatio)
        }
        let components = scale.matrix.components
        let direction = azimuth.direction
        let mx = components.a * direction.x + components.b * direction.y
        let my = components.c * direction.x + components.d * direction.y
        let norm = Foundation.hypot(mx, my)
        guard norm.isFinite, norm > 0 else {
            throw MeasurementEngineError.scale(.singularMatrix)
        }
        return DirectionalSlope(
            ratio: ratio,
            areaFactor: areaFactor,
            ux: mx / norm,
            uy: my / norm
        )
    }
}
