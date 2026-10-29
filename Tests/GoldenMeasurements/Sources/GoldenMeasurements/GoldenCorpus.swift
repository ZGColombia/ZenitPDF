import Foundation
import ZPDFContracts

/// The golden measurement corpus: the acceptance gate for spec 12.
///
/// Cases are grouped only for readability. ``all`` is the list the gate runs, and every case in
/// it carries its own provenance in ``GoldenCase/derivation``.
///
/// ## Provenance
///
/// - ``GoldenDerivation/handDerived``: the expected value is written as the arithmetic itself —
///   `60 * 20 + 20 * 30`, `pi * 1.25 * 1.25`, `sqrt(1 + 1/9)`. A reader checks it by reading it.
/// - ``GoldenDerivation/independentNumericalReference``: an ellipse perimeter, which has no
///   closed form. The literal comes from Simpson's rule on the arc-length integral evaluated
///   outside this codebase, and `EllipsePerimeterCrossCheckTests` re-derives it in the test
///   target with its own integrator so the literal cannot rot unnoticed.
/// - ``GoldenDerivation/invariant``: the case asserts a warning or a "never infinite" property.
///
/// On top of that, `MonteCarloCrossCheckTests` re-estimates the harder net areas by random
/// sampling — a method that shares no line of code with the shoelace formula or with Clipper2.
public enum GoldenCorpus: Sendable {

    /// Every case in the gate.
    public static let all: [GoldenCase] = linear + areal + cutouts + derived + directionalSlope + diagnostics

    /// The scale the corpus expects the engine to be configured against for case `N11`.
    public static let staleScaleExpectedVersion = 7

    /// A staircase of `steps` unit-length right-angle steps: `2 * steps` segments, total length
    /// `2 * steps`. It exists to put a polyline with hundreds of equal terms through the
    /// compensated summation path.
    public static func staircase(steps: Int) -> [(Double, Double)] {
        var result: [(Double, Double)] = [(0, 0)]
        for index in 0..<steps {
            let base = Double(index)
            result.append((base + 1, base))
            result.append((base + 1, base + 1))
        }
        return result
    }

    /// The reference L-shape: a 60 x 20 leg and a 20 x 30 leg, 1800 m2, perimeter 220 m.
    public static let lShape: [(Double, Double)] = [
        (0, 0), (60, 0), (60, 20), (20, 20), (20, 50), (0, 50)
    ]
}
