import Foundation
import ZPDFContracts
import ZPDFGeometry

/// A cheap, conservative test for "this cutout lies strictly inside its parent" (IM-071).
///
/// Conservative means it may answer `false` for a hole that is inside — a hole touching the
/// boundary, one closer to an edge than `epsilon.onSegment`, anything ambiguous — and the caller
/// then falls back to the exact Clipper2 boolean. It must never answer `true` for a hole that is
/// not strictly inside, because the caller skips the containment check (and, for one hole, the
/// whole boolean pipeline) on that answer.
///
/// The argument: the outer ring is one simple ring (the caller guarantees it). If no hole edge
/// meets any outer edge, the hole's boundary lies entirely on one side of the outer boundary
/// (Jordan curve theorem), so one strictly interior hole vertex puts all of it inside. Every hole
/// vertex is tested anyway, with the boundary band excluded, which costs little and removes any
/// reliance on the intersection test's tolerance at a near-touch.
enum CutoutContainment {

    static func isStrictlyInside(
        _ hole: [PDFPoint],
        outer: [PDFPoint],
        epsilon: GeometryEpsilon
    ) -> Bool {
        guard hole.count >= 3, outer.count >= 3 else { return false }
        let margin = epsilon.onSegment
        let holeBox = Box(hole)
        let outerBox = Box(outer)
        // The hole's box must sit strictly inside the outer box, by more than the boundary band.
        guard holeBox.minX > outerBox.minX + margin, holeBox.maxX < outerBox.maxX - margin,
              holeBox.minY > outerBox.minY + margin, holeBox.maxY < outerBox.maxY - margin
        else { return false }

        // Only outer edges whose box reaches the hole's box (grown by the band) can meet a hole
        // edge or pass within the band of a hole vertex.
        let reach = holeBox.grown(by: margin)
        var nearEdges: [SegmentGeometry] = []
        let count = outer.count
        for index in 0..<count {
            let start = outer[index]
            let end = outer[index + 1 == count ? 0 : index + 1]
            if Swift.max(start.x, end.x) < reach.minX || Swift.min(start.x, end.x) > reach.maxX
                || Swift.max(start.y, end.y) < reach.minY || Swift.min(start.y, end.y) > reach.maxY {
                continue
            }
            nearEdges.append(SegmentGeometry(start: start, end: end))
        }

        // Every hole vertex strictly inside (winding number) and outside the boundary band of
        // every nearby outer edge.
        for vertex in hole {
            guard PolygonMath.windingNumber(of: vertex, in: outer) != 0 else { return false }
            for edge in nearEdges where SegmentMath.nearestPoint(on: edge, to: vertex).distance <= margin {
                return false
            }
        }

        // No hole edge meets a nearby outer edge, and no nearby outer vertex falls in the band
        // of a hole edge.
        let holeCount = hole.count
        for index in 0..<holeCount {
            let holeEdge = SegmentGeometry(start: hole[index], end: hole[index + 1 == holeCount ? 0 : index + 1])
            for edge in nearEdges {
                switch SegmentMath.intersect(holeEdge, edge, epsilon: epsilon) {
                case .none, .parallelDisjoint:
                    break
                default:
                    return false
                }
                if SegmentMath.nearestPoint(on: holeEdge, to: edge.start).distance <= margin {
                    return false
                }
            }
        }
        return true
    }

    /// The most edge pairs ``arePairwiseApart(_:epsilon:)`` examines for one pair of rings whose
    /// boxes overlap before it answers the conservative "not known to be apart".
    static let pairwiseEdgeBudget = 250_000

    /// True when no two of the rings meet: no shared point, no edge closer to another ring's
    /// vertex than `epsilon.onSegment`, neither inside the other (R-181).
    ///
    /// Conservative in the same sense as ``isStrictlyInside(_:outer:epsilon:)``: `false` means
    /// "not known to be apart", and the caller then measures the boundary of the union instead.
    /// Two simple rings whose boundaries do not meet are either nested or apart (Jordan curve
    /// theorem), so after the edge test one vertex of each, tested against the other, settles it.
    static func arePairwiseApart(_ rings: [[PDFPoint]], epsilon: GeometryEpsilon) -> Bool {
        guard rings.count > 1 else { return true }
        let margin = epsilon.onSegment
        let boxes = rings.map(Box.init)
        for first in 0..<rings.count {
            for second in (first + 1)..<rings.count {
                let a = boxes[first].grown(by: margin)
                let b = boxes[second]
                if a.maxX < b.minX || b.maxX < a.minX || a.maxY < b.minY || b.maxY < a.minY {
                    continue
                }
                guard ringsAreApart(rings[first], rings[second], margin: margin, epsilon: epsilon) else {
                    return false
                }
            }
        }
        return true
    }

    private static func ringsAreApart(
        _ left: [PDFPoint],
        _ right: [PDFPoint],
        margin: Double,
        epsilon: GeometryEpsilon
    ) -> Bool {
        guard left.count >= 3, right.count >= 3,
              left.count * right.count <= pairwiseEdgeBudget else { return false }
        let leftEdges = edges(of: left)
        let rightEdges = edges(of: right)
        for leftEdge in leftEdges {
            for rightEdge in rightEdges {
                switch SegmentMath.intersect(leftEdge, rightEdge, epsilon: epsilon) {
                case .none, .parallelDisjoint:
                    break
                default:
                    return false
                }
                if SegmentMath.nearestPoint(on: leftEdge, to: rightEdge.start).distance <= margin
                    || SegmentMath.nearestPoint(on: rightEdge, to: leftEdge.start).distance <= margin {
                    return false
                }
            }
        }
        return PolygonMath.windingNumber(of: left[0], in: right) == 0
            && PolygonMath.windingNumber(of: right[0], in: left) == 0
    }

    private static func edges(of ring: [PDFPoint]) -> [SegmentGeometry] {
        ring.indices.map { index in
            SegmentGeometry(start: ring[index], end: ring[index + 1 == ring.count ? 0 : index + 1])
        }
    }

    private struct Box {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        init(_ points: [PDFPoint]) {
            minX = .greatestFiniteMagnitude
            minY = .greatestFiniteMagnitude
            maxX = -.greatestFiniteMagnitude
            maxY = -.greatestFiniteMagnitude
            for point in points {
                minX = Swift.min(minX, point.x)
                minY = Swift.min(minY, point.y)
                maxX = Swift.max(maxX, point.x)
                maxY = Swift.max(maxY, point.y)
            }
        }

        func grown(by amount: Double) -> Box {
            var box = self
            box.minX -= amount
            box.minY -= amount
            box.maxX += amount
            box.maxY += amount
            return box
        }
    }
}
