import CoreGraphics
import Foundation

/// The view-space decoration of a committed length — the drawing's own dimension grammar:
/// an arrowhead at each end of the path whose **tip is exactly the
/// measured point**, and a perpendicular extension tick through every measured point.
///
/// Sizes are in **view points** — the same policy `RenderDimensionLine` documents for the Metal
/// path and the one selection handles already use — so the decoration stays one legible physical
/// size at every zoom while the measured span keeps scaling with the page. Decoration that grew
/// with the page would vanish at 25 % zoom and swallow the drawing at 800 %; decoration that
/// moved the tips would be a lie about what was measured. Neither is allowed.
///
/// Pure geometry, no AppKit, so the maths is testable without a display.
public enum DimensionGrammar {

    /// Arrowhead length from tip to base, in view points (matches `RenderDimensionLine`).
    public static let arrowLength: CGFloat = 9
    /// Arrowhead half-width at the base, in view points.
    public static let arrowHalfWidth: CGFloat = 3.5
    /// Full length of the perpendicular extension tick through each measured point.
    public static let tickLength: CGFloat = 9
    /// The longest an arrowhead may be, as a fraction of the path's length, so the two heads
    /// of a short dimension never cross (matches `MarkupCompiler.DimensionGrammar`; R-157).
    ///
    /// These four numbers are the renderer's `RenderDimensionLine` defaults and its clamp.
    /// This package is portable canvas arithmetic and does not link the renderer, so the
    /// values are repeated here, and `DimensionGrammarTests` in the application — the one
    /// target that links both — fails if the two copies ever differ.
    public static let maximumArrowFractionOfSpan: CGFloat = 1.0 / 3.0

    /// Everything to draw for one dimensioned path, in view space.
    public struct Decoration: Equatable, Sendable {
        /// Filled triangles, three vertices each; the first vertex is the measured tip, exactly.
        public var arrowheads: [[CGPoint]] = []
        /// Extension ticks as two-point segments, centred on each measured point.
        public var ticks: [[CGPoint]] = []
    }

    /// The decoration for a polyline already mapped to view points.
    ///
    /// Interior vertices get a tick only; the two path ends get a tick and an arrowhead whose
    /// tip is the endpoint and whose base points inward along the adjacent segment. Vertices
    /// with no resolvable direction (all points coincident) yield no decoration rather than NaN.
    ///
    /// An arrowhead is ``arrowLength`` long, or a third of the path's length when that is
    /// shorter: a 12-point dimension in a snippet or print export used to get two 9-point heads
    /// that crossed, where the renderer already clamped (R-157).
    public static func decoration(forViewPoints points: [CGPoint]) -> Decoration {
        var result = Decoration()
        guard points.count >= 2 else { return result }
        var pathLength: CGFloat = 0
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            pathLength += (dx * dx + dy * dy).squareRoot()
        }
        let headLength = min(arrowLength, pathLength * maximumArrowFractionOfSpan)

        func direction(at index: Int) -> CGPoint? {
            // The nearest distinct neighbour decides the local direction; a run of coincident
            // vertices keeps looking further along rather than dividing by zero.
            if index + 1 < points.count {
                for next in (index + 1)..<points.count {
                    if let d = normalised(from: points[index], to: points[next]) { return d }
                }
            }
            for previous in stride(from: index - 1, through: 0, by: -1) {
                if let d = normalised(from: points[previous], to: points[index]) { return d }
            }
            return nil
        }

        for (index, vertex) in points.enumerated() {
            guard let along = direction(at: index) else { continue }
            let perp = CGPoint(x: -along.y, y: along.x)
            let half = tickLength / 2
            result.ticks.append([
                CGPoint(x: vertex.x - perp.x * half, y: vertex.y - perp.y * half),
                CGPoint(x: vertex.x + perp.x * half, y: vertex.y + perp.y * half),
            ])
        }

        // Arrowheads at the two path ends: tip exactly on the measured point, base inward.
        for (endIndex, inwardSign) in [(0, 1.0), (points.count - 1, -1.0)] {
            guard let along = direction(at: endIndex) else { continue }
            let tip = points[endIndex]
            let inward = CGPoint(x: along.x * inwardSign, y: along.y * inwardSign)
            let base = CGPoint(x: tip.x + inward.x * headLength, y: tip.y + inward.y * headLength)
            let perp = CGPoint(x: -inward.y, y: inward.x)
            result.arrowheads.append([
                tip,
                CGPoint(x: base.x + perp.x * arrowHalfWidth, y: base.y + perp.y * arrowHalfWidth),
                CGPoint(x: base.x - perp.x * arrowHalfWidth, y: base.y - perp.y * arrowHalfWidth),
            ])
        }
        return result
    }

    private static func normalised(from a: CGPoint, to b: CGPoint) -> CGPoint? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.000_001 else { return nil }
        return CGPoint(x: dx / length, y: dy / length)
    }
}
