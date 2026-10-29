import Foundation
import ZPDFUIPresentation

/// Per-tool drawing semantics: how each tool collects its points and when it finishes.
///
/// Three questions decide how a tool finishes, and they are answered here rather than in the
/// canvas so `MeasurementInputStateMachine` can enforce them without a view:
///
/// - Does a fixed number of points complete the geometry? A Length is two clicks and *done* —
///   no Return, no confirmation step. The second click commits.
/// - Is the tool drawn with one press-drag-release gesture? A rectangle area is one gesture,
///   not four clicks.
/// - Does clicking the first vertex again close the geometry? A polygon area closes on the
///   first vertex, on a double-click, or on Return.
extension MeasurementKind {

    /// The exact point count that completes the geometry, or `nil` for variable-vertex tools
    /// the user finishes explicitly (Return, double-click, or the first vertex).
    ///
    /// Placing the last of these points commits the measurement immediately. Tools whose
    /// vertex count is genuinely open-ended — polylines, polygons, counts — return `nil`.
    ///
    /// The rectangle is three *clicks*: two corners define an edge,
    /// the third defines the depth, and the fourth corner is derived — see
    /// ``derivesFourthCorner``. Its one-gesture drag still finishes on release.
    public var completingPointCount: Int? {
        switch self {
        case .length, .dimension, .radius, .diameter, .slope, .trueSlopedLength,
             .ellipseArea, .ellipseCutout:
            return 2
        case .angle, .threePointCircle, .rectangleArea:
            return 3
        // Start, a point on the arc, end: the third click commits, so no fourth point can be
        // placed for the engine to refuse — it used to measure the first three and ignore the
        // rest (X-042).
        case .arcLength:
            return 3
        case .polylength, .perimeter, .area, .polygonCutout, .trueSlopedArea,
             .riseDrop, .volume, .wallArea, .count, .temporaryMeasure:
            return nil
        }
    }

    /// Whether the tool is drawn with a single press-drag-release gesture.
    ///
    /// The press places the anchor corner, the live value follows the drag, and the release
    /// places the opposite corner and commits.
    public var usesDragGesture: Bool {
        switch self {
        case .rectangleArea, .ellipseArea, .ellipseCutout:
            return true
        default:
            return false
        }
    }

    /// Whether clicking the first vertex again closes and commits the geometry.
    ///
    /// True for the closed-polygon tools only. The state machine offers a snap affordance on
    /// the first vertex once enough points exist for a valid shape. Volume is one of them: its
    /// base is an outline the canvas draws closed and filled, and before R-143 a click on its
    /// first vertex stacked a duplicate vertex there instead of closing it.
    public var closesOnFirstVertex: Bool {
        switch self {
        case .area, .perimeter, .polygonCutout, .trueSlopedArea, .volume:
            return true
        default:
            return false
        }
    }

    /// Whether the tool's last corner is derived rather than placed.
    ///
    /// The three-point rectangle: the user places `P1`, `P2`, `P3`
    /// and the geometry closes itself with `P4 = P1 + P3 − P2` — a parallelogram in general,
    /// a true rectangle when the depth point is placed under `Shift` or on an edge snap.
    /// The third click commits, exactly like a length's second click.
    public var derivesFourthCorner: Bool { self == .rectangleArea }

    /// Whether the next segment of the shape being drawn can be an arc (NL-MEASURE-05,
    /// ADR-0030 §5.6): A while drawing toggles it. The chain and area tools whose geometry is a
    /// chain or one ring — a length, a polylength, a perimeter, the area family and the Polygon
    /// Cutout, whose hole the engine subtracts on its arcs since ADR-0037 (C-08). Not the drag
    /// rectangles or ellipses, and not the fixed-geometry tools.
    public var supportsArcSegments: Bool {
        switch self {
        case .length, .polylength, .perimeter, .area, .volume, .wallArea, .trueSlopedArea, .polygonCutout:
            return true
        default:
            return false
        }
    }
}
