import Foundation
import ZPDFContracts

/// The real length of a circular page-space arc under any affine scale (QUALITY_BAR §2.2 rule 4).
///
/// A uniform scale maps an arc of radius `r` to an arc of radius `r·s`, and ``LinearMeasure``
/// keeps that fast path: `r·θ·s`, exact. Any other matrix `M` — a separate X/Y calibration, a
/// shear — maps the circle to an ellipse, whose arc length has no closed form (it is an incomplete
/// elliptic integral of the second kind). It is integrated here on the curve itself, never on a
/// flattened polyline:
///
/// ```text
/// L = ∫ |M · r′(φ)| dφ over the sweep,   r′(φ) = r · (−sin φ, cos φ)
/// ```
///
/// The integrand is smooth and periodic, so composite Gauss-Legendre converges geometrically. The
/// sweep starts in panels of at most π/4 and the panel count doubles until two successive
/// estimates agree to ``convergenceTolerance`` relative — a fixed schedule, so two runs on two
/// machines evaluate the same nodes.
///
/// The true length of an arc on a sloped plane (ADR-0004, ADR-0041) is the same integral with the
/// directional slope applied to the mapped tangent at every node, `∫ |M · r′(φ)|_slope dφ`, so a
/// sloped arc reaches the same 1e-12 class as a plan arc instead of a 1° flattening's ratio
/// (X-043).
enum ArcLengthQuadrature {

    /// Nodes per panel.
    static let order = 16
    /// Relative agreement of two successive panel doublings that ends the refinement.
    static let convergenceTolerance = 1e-14
    /// The most panels one arc is split into (65 536 evaluations), reached only for a scale whose
    /// axes differ by orders of magnitude.
    static let maximumPanels = 4096

    /// The 16-point Gauss-Legendre rule on `[-1, 1]`: the roots of `P₁₆` by Newton's method from
    /// the Chebyshev-like initial guesses, weights `2 / ((1 − x²) · P′₁₆(x)²)`.
    static let rule: (nodes: [Double], weights: [Double]) = legendreRule(order: order)

    static func legendreRule(order n: Int) -> (nodes: [Double], weights: [Double]) {
        var nodes = [Double](repeating: 0, count: n)
        var weights = [Double](repeating: 0, count: n)
        func legendre(_ x: Double) -> (value: Double, derivative: Double) {
            var previous = 1.0
            var current = x
            if n == 1 { return (current, 1) }
            for k in 2...n {
                let next = ((2 * Double(k) - 1) * x * current - (Double(k) - 1) * previous) / Double(k)
                previous = current
                current = next
            }
            return (current, Double(n) * (x * current - previous) / (x * x - 1))
        }
        for i in 0..<((n + 1) / 2) {
            var x = Foundation.cos(Double.pi * (Double(i) + 0.75) / (Double(n) + 0.5))
            for _ in 0..<100 {
                let (value, derivative) = legendre(x)
                let step = value / derivative
                x -= step
                if Swift.abs(step) < 1e-16 { break }
            }
            let derivative = legendre(x).derivative
            let weight = 2 / ((1 - x * x) * derivative * derivative)
            nodes[i] = -x
            nodes[n - 1 - i] = x
            weights[i] = weight
            weights[n - 1 - i] = weight
        }
        return (nodes, weights)
    }

    /// The length in metres of `arc` mapped through `components`.
    static func length(of arc: ArcGeometry, components m: AffineScaleMatrix.Components) -> Double {
        length(radius: Swift.abs(arc.radius), startAngle: arc.startAngle, sweep: arc.sweepAngle, a: m.a, b: m.b, c: m.c, d: m.d)
    }

    /// The true length in metres of `arc` mapped through `components` and lying on the sloped
    /// plane `slope`: the directional slope's per-segment rule applied to the mapped tangent at
    /// every node (ADR-0041). Valid under any affine scale, because the slope acts on the real
    /// displacement, and the rule is homogeneous of degree one, so the radius factors out as it
    /// does for the plan length.
    static func trueLength(of arc: ArcGeometry, components m: AffineScaleMatrix.Components, slope: DirectionalSlope) -> Double {
        integral(radius: Swift.abs(arc.radius), startAngle: arc.startAngle, sweep: arc.sweepAngle, a: m.a, b: m.b, c: m.c, d: m.d) { x, y in
            slope.trueLength(dx: x, dy: y)
        }
    }

    /// The length of the circular arc of `radius` from `startAngle` over `sweep`, mapped through
    /// the 2×2 matrix `[a b; c d]`. The matrix is given as four numbers so a caller that is not
    /// holding a scale's components — the ellipse circumference, whose matrix is the scale times
    /// the page semi-axes — integrates through the same rule (T-074).
    static func length(radius: Double, startAngle: Double, sweep: Double, a: Double, b: Double, c: Double, d: Double) -> Double {
        integral(radius: radius, startAngle: startAngle, sweep: sweep, a: a, b: b, c: c, d: d) { x, y in
            (x * x + y * y).squareRoot()
        }
    }

    /// `radius · ∫ norm(M · (−sin φ, cos φ)) dφ` from `startAngle` over `sweep`: the one schedule
    /// both lengths integrate on. `norm` must be homogeneous of degree one.
    ///
    /// A sweep beyond a whole turn is its whole turns plus the rest — the integrand repeats every
    /// turn — so an absurd but finite sweep (BH-565) is still measured on the curve, and the panel
    /// count is clamped while it is a `Double`, so it cannot trap either. A sweep within one turn
    /// takes the direct path.
    private static func integral(
        radius: Double, startAngle: Double, sweep: Double,
        a: Double, b: Double, c: Double, d: Double,
        norm: (Double, Double) -> Double
    ) -> Double {
        guard sweep != 0, radius > 0, sweep.isFinite, radius.isFinite, startAngle.isFinite else { return 0 }
        let turn = 2 * Double.pi
        if Swift.abs(sweep) > turn {
            let turns = (Swift.abs(sweep) / turn).rounded(.down)
            let rest = Swift.max(0, Swift.abs(sweep) - turns * turn)
            let direction: Double = sweep < 0 ? -1 : 1
            let whole = integral(radius: radius, startAngle: startAngle, sweep: direction * turn, a: a, b: b, c: c, d: d, norm: norm)
            let part = rest > 0
                ? integral(radius: radius, startAngle: startAngle, sweep: direction * rest, a: a, b: b, c: c, d: d, norm: norm)
                : 0
            return turns * whole + part
        }
        func speed(_ angle: Double) -> Double {
            let s = Foundation.sin(angle)
            let co = Foundation.cos(angle)
            return norm(-a * s + b * co, -c * s + d * co)
        }
        let (nodes, weights) = rule
        func composite(panels: Int) -> Double {
            let width = sweep / Double(panels)
            var terms: [Double] = []
            terms.reserveCapacity(panels * nodes.count)
            for panel in 0..<panels {
                let middle = startAngle + width * (Double(panel) + 0.5)
                for (node, weight) in zip(nodes, weights) {
                    terms.append(weight * speed(middle + width / 2 * node))
                }
            }
            return Swift.abs(width) / 2 * EngineNumerics.sum(terms)
        }
        let requested = Swift.min(Double(maximumPanels), (Swift.abs(sweep) / (Double.pi / 4)).rounded(.up))
        var panels = Swift.max(1, Int(requested))
        var previous = composite(panels: panels)
        while panels < maximumPanels {
            panels = Swift.min(maximumPanels, panels * 2)
            let current = composite(panels: panels)
            if Swift.abs(current - previous) <= convergenceTolerance * Swift.abs(current) {
                return radius * current
            }
            previous = current
        }
        return radius * previous
    }
}
