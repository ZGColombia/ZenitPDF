import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Turns page-space linear geometry into real-world metres under a scale (spec 12.2).
///
/// Every edge is mapped through the affine matrix as a *delta*, never as two mapped endpoints
/// subtracted, so a translation in the scale cannot leak into a length. Piece lengths are kept
/// individually because rise/drop per segment (spec 12.9) needs them; the mapped deltas are kept
/// too because the directional slope model (ADR-0004) needs the *direction* of each edge, not
/// only its length. The total is summed with the compensated policy summation rather than
/// `reduce(0, +)`.
enum LinearMeasure {

    struct Result: Sendable {
        /// Real displacement of each straight edge, in metres, in ``GeometryInput/Linear/pieces`` order.
        var segmentDeltas: [RealVector]
        /// Real length of each arc, in metres, in the order ``GeometryInput/Linear/pieces`` lists
        /// them.
        var arcLengths: [Double]
        /// Real length of every piece, straight or arc, in metres, in the order the pieces appear
        /// (``GeometryInput/Linear/pieces``): what the per-segment rise/drop pairs one rise with
        /// each of (S-110).
        var pieceLengths: [Double]
        /// The arcs behind ``arcLengths``, kept for the sloped rule of ``trueLength(under:)``.
        var arcs: [ArcGeometry]
        /// The scale matrix the arcs are mapped through.
        var components: AffineScaleMatrix.Components
        /// Compensated total, in metres.
        var totalMetres: Double

        /// The true length under a directional slope: the per-segment rule on every straight
        /// edge, summed with the policy summation (ADR-0004 §2).
        ///
        /// An arc is integrated on the curve (ADR-0041, X-043): the per-segment rule applied to
        /// the mapped tangent at every quadrature node (``ArcLengthQuadrature/trueLength(of:components:slope:)``),
        /// the same 1e-12 class as its plan length (QUALITY_BAR §2.2 rule 4). It used to be the
        /// exact plan length times the ratio of a 1°-step flattening's true to plan length — a
        /// midpoint rule, about 6e-6 relative off on a 45° arc at a slope of 1. With a zero slope
        /// the rule is the identity, so the plan length is returned as it is, bit for bit.
        func trueLength(under slope: DirectionalSlope) -> Double {
            var parts: [Double] = []
            parts.reserveCapacity(segmentDeltas.count + arcs.count)
            for delta in segmentDeltas {
                parts.append(slope.trueLength(delta))
            }
            for (index, arc) in arcs.enumerated() where index < arcLengths.count {
                parts.append(
                    slope.ratio == 0
                        ? arcLengths[index]
                        : ArcLengthQuadrature.trueLength(of: arc, components: components, slope: slope)
                )
            }
            return EngineNumerics.sum(parts)
        }
    }

    static func measure(
        _ linear: GeometryInput.Linear,
        scale: ScaleTransform
    ) throws(MeasurementEngineError) -> Result {
        let components = scale.matrix.components
        // A uniform scale maps every arc to an arc of radius r·s: its length is r·θ·s exactly.
        // Any other matrix maps it to an arc of an ellipse, whose length is the quadrature of the
        // mapped speed (QUALITY_BAR §2.2 rule 4). Any arc used to refuse the whole measurement
        // under a separate X/Y scale — area included, although the area is exact under every
        // affine map — with an error named for slopes (S-106).
        let metresPerPoint: Double? = scale.isUniform ? scale.matrix.metresPerPointX : nil
        var segmentDeltas: [RealVector] = []
        var arcLengths: [Double] = []
        var arcs: [ArcGeometry] = []
        var pieceLengths: [Double] = []
        for piece in linear.pieces {
            switch piece {
            case .edge(let edge):
                guard edge.start.isFinite, edge.end.isFinite else {
                    throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
                }
                let dx = edge.end.x - edge.start.x
                let dy = edge.end.y - edge.start.y
                let mx = components.a * dx + components.b * dy
                let my = components.c * dx + components.d * dy
                let length = (mx * mx + my * my).squareRoot()
                segmentDeltas.append(RealVector(dx: mx, dy: my))
                pieceLengths.append(length)
            case .arc(let arc):
                guard arc.radius.isFinite, arc.sweepAngle.isFinite else {
                    throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
                }
                let length = metresPerPoint.map { arc.pdfArcLength * $0 }
                    ?? ArcLengthQuadrature.length(of: arc, components: components)
                arcs.append(arc)
                arcLengths.append(length)
                pieceLengths.append(length)
            }
        }

        return Result(
            segmentDeltas: segmentDeltas,
            arcLengths: arcLengths,
            pieceLengths: pieceLengths,
            arcs: arcs,
            components: components,
            totalMetres: EngineNumerics.sum(pieceLengths)
        )
    }

    /// Real length of a set of drawn pieces — straight edges and arcs, in any order — in metres:
    /// the boundary of what is left of an area once its cutouts are taken out on the arcs (C-08).
    /// Each arc is measured exactly as ``measure(_:scale:)`` measures every arc.
    static func pieces(_ edges: [ArcEdge], scale: ScaleTransform) throws(MeasurementEngineError) -> Result {
        var segments: [SegmentGeometry] = []
        var arcs: [ArcGeometry] = []
        for edge in edges {
            if let arc = edge.arc {
                arcs.append(arc)
            } else {
                segments.append(SegmentGeometry(start: edge.start, end: edge.end))
            }
        }
        return try measure(GeometryInput.Linear(polyline: [], isClosed: false, segments: segments, arcs: arcs), scale: scale)
    }

    /// Real length of one closed ring, in metres, and the real deltas of its edges.
    static func ring(
        _ points: [PDFPoint],
        scale: ScaleTransform,
        bulges: [Double]? = nil
    ) throws(MeasurementEngineError) -> Result {
        let linear = GeometryInput.Linear(
            polyline: points,
            isClosed: true,
            segments: [],
            arcs: [],
            polylineBulges: bulges
        )
        return try measure(linear, scale: scale)
    }
}

