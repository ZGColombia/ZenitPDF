import Foundation
import ZPDFContracts

/// The vertices of a stored markup, as one flat editable list, and the way back.
///
/// `DocumentCommand.editVertices(id:geometry:)` has been implemented in `TakeoffSession`
/// — with recompute and an undo inverse — since the engine landed, and until now it had
/// **no caller anywhere in the application**. What was
/// missing between a dragged handle and that command is exactly this: a `MeasurementGeometry`
/// is six parallel collections, and a handle is one index.
///
/// The order is fixed and total so an index means the same vertex before and after a drag:
/// free points, then each segment's start and end, then each polygon's outer ring followed
/// by its holes, then the count marks, then the shape handles of stored circles and arcs
/// (NL-MEASURE-06): a circle's centre and its rim handle (the rim point at angle 0), an arc's
/// centre, start and end. A circle or arc is a centre and a radius, not a vertex list, so its
/// handles carry an explicit meaning instead: the centre moves the shape, the rim sets the
/// radius, an arc's end sets the radius and moves that end along the circle while the other
/// end stays. Appending them last keeps every earlier index what it was.
public enum MarkupVertexEditing {

    /// Every editable vertex of a geometry, in the canonical order.
    public static func vertices(of geometry: MeasurementGeometry) -> [PDFPoint] {
        var result: [PDFPoint] = geometry.points
        for segment in geometry.segments {
            result.append(segment.start)
            result.append(segment.end)
        }
        for polygon in geometry.polygons {
            result.append(contentsOf: polygon.outer.points)
            for hole in polygon.holes { result.append(contentsOf: hole.points) }
        }
        result.append(contentsOf: geometry.countPoints.map(\.position))
        for circle in geometry.circles {
            result.append(circle.center)
            result.append(PDFPoint(x: circle.center.x + circle.radius, y: circle.center.y))
        }
        for arc in geometry.arcs {
            result.append(arc.center)
            result.append(arc.startPoint)
            result.append(arc.endPoint)
        }
        return result
    }

    /// A copy of `geometry` with the vertex at `index` moved to `point`.
    ///
    /// - Returns: `nil` when the index names no vertex, so a stale handle from a markup
    ///   that changed under the pointer cannot write a geometry the user never drew.
    public static func replacing(
        vertexAt index: Int,
        with point: PDFPoint,
        in geometry: MeasurementGeometry
    ) -> MeasurementGeometry? {
        guard index >= 0 else { return nil }
        var edited = geometry
        var cursor = index

        if cursor < edited.points.count {
            edited.points[cursor] = point
            return edited
        }
        cursor -= edited.points.count

        if cursor < edited.segments.count * 2 {
            let segment = cursor / 2
            if cursor % 2 == 0 {
                edited.segments[segment].start = point
            } else {
                edited.segments[segment].end = point
            }
            return edited
        }
        cursor -= edited.segments.count * 2

        for polygonIndex in edited.polygons.indices {
            let outerCount = edited.polygons[polygonIndex].outer.points.count
            if cursor < outerCount {
                edited.polygons[polygonIndex].outer.points[cursor] = point
                return edited
            }
            cursor -= outerCount
            for holeIndex in edited.polygons[polygonIndex].holes.indices {
                let holeCount = edited.polygons[polygonIndex].holes[holeIndex].points.count
                if cursor < holeCount {
                    edited.polygons[polygonIndex].holes[holeIndex].points[cursor] = point
                    return edited
                }
                cursor -= holeCount
            }
        }

        if cursor < edited.countPoints.count {
            edited.countPoints[cursor].position = point
            return edited
        }
        cursor -= edited.countPoints.count

        guard point.isFinite else { return nil }
        for circleIndex in edited.circles.indices {
            if cursor == 0 {
                edited.circles[circleIndex].center = point
                return edited
            }
            if cursor == 1 {
                let radius = edited.circles[circleIndex].center.distance(to: point)
                guard radius > 0, radius.isFinite else { return nil }
                edited.circles[circleIndex].radius = radius
                return edited
            }
            cursor -= 2
        }
        for arcIndex in edited.arcs.indices {
            let arc = edited.arcs[arcIndex]
            switch cursor {
            case 0:
                edited.arcs[arcIndex].center = point
                return edited
            case 1, 2:
                let radius = arc.center.distance(to: point)
                guard radius > 0, radius.isFinite else { return nil }
                let angle = Foundation.atan2(point.y - arc.center.y, point.x - arc.center.x)
                let end = arc.startAngle + arc.sweepAngle
                let start = cursor == 1 ? angle : arc.startAngle
                let sweep = Self.sweep(from: start, to: cursor == 1 ? end : angle, keepingSignOf: arc.sweepAngle)
                guard sweep != 0 else { return nil }
                edited.arcs[arcIndex] = ArcGeometry(center: arc.center, radius: radius, startAngle: start, sweepAngle: sweep)
                return edited
            default:
                cursor -= 3
            }
        }
        return nil
    }

    /// The sweep from `start` to `end` turning the way `sign` turns, in `(0, 2π]` for a
    /// counter-clockwise arc and `[−2π, 0)` for a clockwise one: moving an end never flips the
    /// arc to the other side of the circle.
    static func sweep(from start: Double, to end: Double, keepingSignOf sign: Double) -> Double {
        let turn = 2 * Double.pi
        var delta = (end - start).truncatingRemainder(dividingBy: turn)
        if sign >= 0 {
            if delta <= 0 { delta += turn }
        } else {
            if delta >= 0 { delta -= turn }
        }
        return delta
    }

    /// A copy of `geometry` translated in page space.
    ///
    /// The one translation rule: the **preview** of `DocumentCommand.moveMarkup`, the move the
    /// session commits when the drag is released, and the offset a paste applies all call this,
    /// so the shape under the pointer and the shape that is committed cannot differ by a
    /// rounding — or by a field. It copies the value and changes only positions, so a field
    /// added to a geometry type later survives a move and a paste (W-038: the session used to
    /// rebuild every type field by field).
    public static func translating(
        _ geometry: MeasurementGeometry,
        dx: Double,
        dy: Double
    ) -> MeasurementGeometry {
        func move(_ point: PDFPoint) -> PDFPoint { point.translated(dx: dx, dy: dy) }
        var moved = geometry
        moved.points = geometry.points.map(move)
        moved.segments = geometry.segments.map { SegmentGeometry(start: move($0.start), end: move($0.end)) }
        moved.polygons = geometry.polygons.map { polygon in
            PolygonGeometry(
                // Arc segments ride along: a bulge is relative to its chord (ADR-0030 §5).
                outer: PolygonRing(points: polygon.outer.points.map(move), isClosed: polygon.outer.isClosed, bulges: polygon.outer.bulges),
                holes: polygon.holes.map { PolygonRing(points: $0.points.map(move), isClosed: $0.isClosed, bulges: $0.bulges) }
            )
        }
        moved.arcs = geometry.arcs.map { arc in
            var translated = arc
            translated.center = move(arc.center)
            return translated
        }
        moved.circles = geometry.circles.map { circle in
            var translated = circle
            translated.center = move(circle.center)
            return translated
        }
        moved.countPoints = geometry.countPoints.map { mark in
            var translated = mark
            translated.position = move(mark.position)
            return translated
        }
        return moved
    }
}
