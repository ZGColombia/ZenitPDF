import CoreGraphics
import Foundation
import ZPDFClipper2
import ZPDFContracts
import ZPDFGeometry

/// Which side of a directed cut a clip region covers.
enum CutSide: Sendable {
    case left
    case right

    /// The unit normal pointing into this side, for a segment whose unit direction is `u`.
    ///
    /// Left is `u` rotated a quarter turn counter-clockwise, in PDF page space, which is y-up.
    func normal(of u: (dx: Double, dy: Double)) -> (dx: Double, dy: Double) {
        switch self {
        case .left: (dx: -u.dy, dy: u.dx)
        case .right: (dx: u.dy, dy: -u.dx)
        }
    }
}

/// Turns a cutting polyline into the two clip regions a boolean intersection can use.
///
/// # Why a region and not a line
///
/// Clipper2 clips areas against areas. A line has no area, so it cannot be a clip. The standard
/// construction is to replace each side of the line with a closed region so large that, inside
/// the area being cut, "in the region" and "on that side of the line" are the same statement.
/// Intersecting the area with each of the two regions then yields the two sides.
///
/// # What the construction has to survive
///
/// 1. **A cut whose endpoints are inside the area.** A person drags a line across a room and
///    releases the mouse inside the wall, not out in the margin. So the polyline is extended
///    along its first and last segment before anything else happens.
/// 2. **A bent cut.** A cut may be a polyline, not a single segment, and then there is no
///    half-plane to speak of. Each segment contributes a half-strip; where the polyline turns,
///    the two strips on the outside of the turn leave a wedge between them, and that wedge is
///    filled with a fan of triangles. Where they overlap on the inside of the turn, the overlap
///    is harmless: every piece is wound counter-clockwise and the union is taken under the
///    non-zero rule, which is exactly set union for consistently wound input.
/// 3. **Coordinates that stay inside Clipper2's integer lattice.** The reach is a multiple of
///    the geometry's own diagonal, not a fixed astronomical constant, so a cut across a 600 pt
///    page never produces a vertex at 1e12 and never risks
///    ``ClipperError/coordinateOverflow``.
///
/// # Where it does not hold
///
/// A cut that folds back on itself — a hairpin whose two arms leave a narrow wedge between
/// them — has points that are left of one segment and right of another, far from the fold. The
/// two regions then overlap there, and if that overlap falls inside the area being cut, the
/// parts double-count it. This is not silently tolerated: it is precisely what
/// ``PolygonSplitter/areaCheck(original:parts:)`` measures, and the caller refuses the split
/// rather than storing it. Straight cuts and gently bent cuts — everything a split gesture
/// actually produces — are unaffected.
enum CutRegion {

    /// Cleans a cutting polyline: rejects non-finite coordinates, collapses vertices closer
    /// together than the merge epsilon, and requires at least two distinct points to survive.
    static func cleaned(
        _ cut: [PDFPoint],
        epsilon: GeometryEpsilon
    ) throws(MeasurementEngineError) -> [PDFPoint] {
        for point in cut where !point.isFinite {
            throw MeasurementEngineError.measurement(.nonFiniteCoordinate)
        }
        var kept: [PDFPoint] = []
        for point in cut {
            if let last = kept.last, last.distance(to: point) <= epsilon.pointMerge { continue }
            kept.append(point)
        }
        guard kept.count >= 2 else {
            throw MeasurementEngineError.geometry(.degenerateSegment)
        }
        return kept
    }

    /// Extends the polyline backwards past its first vertex and forwards past its last, by at
    /// least `reach` page points each, and **keeps every original vertex**.
    ///
    /// Without the extension, a cut released inside the area produces two regions that both
    /// contain the whole area near the loose end, and the "split" is the original twice over.
    ///
    /// Two details are load-bearing, and both were measured rather than guessed — an L-shape cut
    /// on the line `y = 40 - x/2` came out 4e-5 pt^2 wrong until they were fixed:
    ///
    /// * **The original endpoints stay in the path.** Replacing them with the far endpoints
    ///   would leave the segment that actually crosses the area anchored only at two distant
    ///   points, and a distant anchor multiplies its own rounding by the ratio of the extension
    ///   to the crossing.
    /// * **The extension is an integer multiple of the segment vector, not a unit vector times a
    ///   distance.** `p0 - k * (p1 - p0)` lands exactly on the line through `p0` and `p1` when
    ///   `p0` and `p1` are on the lattice, because it needs no square root; `p0 - reach * û`
    ///   does not, and Clipper2 then clips against a line tilted by the rounding of `û`.
    static func extended(_ cut: [PDFPoint], by reach: Double) -> [PDFPoint] {
        guard cut.count >= 2 else { return cut }
        var result = cut
        result.insert(
            projected(from: cut[0], away: cut[1], atLeast: reach),
            at: 0
        )
        result.append(
            projected(from: cut[cut.count - 1], away: cut[cut.count - 2], atLeast: reach)
        )
        return result
    }

    /// `anchor` moved directly away from `neighbour` by a whole number of `anchor - neighbour`
    /// steps, far enough to cover `distance`.
    private static func projected(
        from anchor: PDFPoint,
        away neighbour: PDFPoint,
        atLeast distance: Double
    ) -> PDFPoint {
        let dx = anchor.x - neighbour.x
        let dy = anchor.y - neighbour.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return anchor }
        let steps = Swift.max(1, (distance / length).rounded(.up))
        return PDFPoint(x: anchor.x + dx * steps, y: anchor.y + dy * steps)
    }

    /// Inserts, into the cut path, the points where it crosses the rings of the region being
    /// split — computed in closed form and snapped onto the Clipper2 lattice.
    ///
    /// # Why this exists
    ///
    /// Clipper2 is exact on the lattice, but it still has to *find* the point where two edges
    /// cross and round it to a lattice node, and that rounding is worth up to one lattice step.
    /// On an axis-aligned cut it costs nothing: the crossing is a lattice node either way. On a
    /// slanted cut it moves the crossing by 1e-6 pt, and an L-shape cut on `y = 40 - x/2` came
    /// out with parts of 1399.99997 and 500.00002 instead of 1400 and 500 — an error of 3e-5
    /// pt^2, and one that shrank by exactly the same factor as the lattice step every time the
    /// scale was raised, which is what identified it.
    ///
    /// Handing Clipper2 the crossing as an explicit vertex of the clip path removes the rounding
    /// rather than shrinking it: the subject edge and the clip edge now meet *at a shared
    /// vertex*, and there is nothing left to round. The closed-form solve is a 2x2 system in
    /// `Double`, so it lands within an ulp or two of the true crossing, and the snap to the
    /// lattice — which every coordinate crossing this bridge undergoes anyway — turns that into
    /// the exactly correct node.
    ///
    /// A crossing that is not on the lattice to begin with is snapped like any other coordinate
    /// and keeps the ordinary half-step error; the gain is confined to the case where the true
    /// answer is representable, which is the case the fixtures and most real drawings are in.
    static func anchored(
        _ path: [PDFPoint],
        crossing rings: [[PDFPoint]],
        scale: Double,
        epsilon: GeometryEpsilon
    ) -> [PDFPoint] {
        guard path.count >= 2, !rings.isEmpty else { return path }
        var result: [PDFPoint] = []
        result.reserveCapacity(path.count)

        for index in 0..<(path.count - 1) {
            let a = path[index]
            let b = path[index + 1]
            result.append(a)

            let rx = b.x - a.x
            let ry = b.y - a.y
            var parameters: [Double] = []
            for ring in rings where ring.count >= 2 {
                for edge in 0..<ring.count {
                    let p = ring[edge]
                    let q = ring[edge + 1 == ring.count ? 0 : edge + 1]
                    let sx = q.x - p.x
                    let sy = q.y - p.y
                    let denominator = rx * sy - ry * sx
                    guard denominator != 0 else { continue }
                    let dx = p.x - a.x
                    let dy = p.y - a.y
                    let t = (dx * sy - dy * sx) / denominator
                    let u = (dx * ry - dy * rx) / denominator
                    guard t > 0, t < 1, u >= 0, u <= 1 else { continue }
                    parameters.append(t)
                }
            }
            guard !parameters.isEmpty else { continue }

            parameters.sort()
            var previous = a
            for t in parameters {
                let point = snapped(
                    PDFPoint(x: a.x + rx * t, y: a.y + ry * t),
                    scale: scale
                )
                guard previous.distance(to: point) > epsilon.pointMerge,
                      point.distance(to: b) > epsilon.pointMerge
                else { continue }
                result.append(point)
                previous = point
            }
        }
        result.append(path[path.count - 1])
        return result
    }

    /// One coordinate pair rounded onto the Clipper2 lattice, the same rounding the bridge
    /// applies on the way in. Doing it here means the value the boolean sees is the value the
    /// closed-form solve intended, not that value plus a stray ulp.
    static func snapped(_ point: PDFPoint, scale: Double) -> PDFPoint {
        PDFPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }

    /// How far the extension and the clip regions have to travel to be sure of covering the
    /// area: a multiple of the diagonal of the box that holds both the area and the cut.
    static func reach(
        outer: [PDFPoint],
        cut: [PDFPoint],
        factor: Double
    ) -> Double {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for point in outer + cut {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        let diagonal = (width * width + height * height).squareRoot()
        return Swift.max(diagonal, 1) * factor
    }

    /// The pieces whose union is one side's clip region: one half-strip per segment, plus one
    /// wedge fan per interior vertex. Every piece is wound counter-clockwise.
    static func pieces(
        along path: [PDFPoint],
        side: CutSide,
        depth: Double,
        maximumFanStep: Double
    ) -> ClipperPaths {
        guard path.count >= 2 else { return [] }

        var normals: [(dx: Double, dy: Double)] = []
        var strips: ClipperPaths = []
        for index in 0..<(path.count - 1) {
            let start = path[index]
            let end = path[index + 1]
            let normal = side.normal(of: unitVector(from: start, to: end))
            normals.append(normal)
            strips.append(
                counterClockwise([
                    CGPoint(x: start.x, y: start.y),
                    CGPoint(x: end.x, y: end.y),
                    CGPoint(x: end.x + normal.dx * depth, y: end.y + normal.dy * depth),
                    CGPoint(x: start.x + normal.dx * depth, y: start.y + normal.dy * depth)
                ])
            )
        }

        var fans: ClipperPaths = []
        guard normals.count >= 2 else { return strips }
        for index in 1..<(path.count - 1) {
            let vertex = path[index]
            let before = normals[index - 1]
            let after = normals[index]
            let cross = before.dx * after.dy - before.dy * after.dx
            let dot = before.dx * after.dx + before.dy * after.dy
            let sweep = atan2(cross, dot)
            guard Swift.abs(sweep) > 1e-12 else { continue }
            let steps = Swift.max(1, Int(ceil(Swift.abs(sweep) / Swift.max(maximumFanStep, 1e-3))))
            var fan: ClipperPath = [CGPoint(x: vertex.x, y: vertex.y)]
            for step in 0...steps {
                let angle = sweep * Double(step) / Double(steps)
                let cosine = cos(angle)
                let sine = sin(angle)
                let dx = before.dx * cosine - before.dy * sine
                let dy = before.dx * sine + before.dy * cosine
                fan.append(CGPoint(x: vertex.x + dx * depth, y: vertex.y + dy * depth))
            }
            fans.append(counterClockwise(fan))
        }
        return strips + fans
    }

    // MARK: - Helpers

    /// Unit direction from `start` to `end`. Coincident points cannot reach here: the cut is
    /// cleaned first, so every consecutive pair is at least `pointMerge` apart.
    static func unitVector(from start: PDFPoint, to end: PDFPoint) -> (dx: Double, dy: Double) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return (dx: 1, dy: 0) }
        return (dx: dx / length, dy: dy / length)
    }

    /// Returns the ring wound counter-clockwise, reversing it if it was not.
    ///
    /// Uniform winding is what lets the non-zero union of overlapping pieces be plain set union.
    /// A single clockwise piece among counter-clockwise ones would punch a hole in the region.
    static func counterClockwise(_ ring: ClipperPath) -> ClipperPath {
        Clipper2.area(of: ring) >= 0 ? ring : ring.reversed()
    }
}
