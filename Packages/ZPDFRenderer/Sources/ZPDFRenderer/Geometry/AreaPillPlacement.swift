import Foundation
import ZPDFContracts

/// Where an area's value pill goes: **inside the fill**,
/// centred on the polygon's centroid — and when the centroid falls outside a concave
/// outline, or the pill would not fit inside it, the pill steps out to the polygon's
/// bottom vertex on a short leader, the same grammar the visual reference's Count caption uses
/// ("a leader line from the polygon corner to a caption below").
///
/// Pure page-space maths, deterministic, shared by the golden scenes and mirrored
/// point-for-point by the app canvas's `AreaPillLayout` (view space) — the same
/// duplication discipline `DimensionGrammar` set, so the shipping canvas and the
/// renderer cannot drift apart in what they claim about placement.
public enum AreaPillPlacement {

    /// Leader length from the anchor vertex to the pill, in view points.
    public static let leaderLengthViewPoints: Double = 18
    /// Clear space between the leader's end and the pill's edge, in view points.
    public static let leaderClearanceViewPoints: Double = 2

    /// A resolved placement: the pill's centre, and the leader when the pill could not
    /// sit inside the fill.
    public struct Placement: Sendable, Hashable {
        /// The pill's centre, in the polygon's own space.
        public var center: PDFPoint
        /// The leader's start (a polygon vertex), or `nil` for an interior pill.
        public var leaderStart: PDFPoint?
        /// The leader's end (just short of the pill), or `nil` for an interior pill.
        public var leaderEnd: PDFPoint?

        public var isInterior: Bool { leaderStart == nil }
    }

    /// Places one pill for `polygon`.
    ///
    /// - Parameters:
    ///   - polygon: the outer ring, in page points.
    ///   - holes: the area's cutouts, in the same space. The pill sits inside the *fill* — its
    ///     centre in the outer ring and in no hole, and no ring's edge across it — exactly as the canvas's
    ///     `AreaPillLayout` decides it (BH-880). A courtyard's centroid is in the hole, and an
    ///     export that ignored the holes printed the number in the one region it does not
    ///     cover while the screen had moved it onto a leader (S-101).
    ///   - pillHalfWidth: half the pill's width, in the same units as the polygon.
    ///   - pillHalfHeight: half the pill's height, in the same units.
    ///   - leaderLength: the fallback leader's length, in the same units.
    ///   - leaderClearance: gap between leader end and pill edge, in the same units.
    /// - Returns: `nil` for a degenerate polygon (fewer than three distinct vertices or
    ///   a non-finite coordinate) — a pill with nowhere honest to sit is not placed.
    public static func placement(
        polygon: [PDFPoint],
        holes: [[PDFPoint]] = [],
        pillHalfWidth: Double,
        pillHalfHeight: Double,
        leaderLength: Double = leaderLengthViewPoints,
        leaderClearance: Double = leaderClearanceViewPoints
    ) -> Placement? {
        guard polygon.count >= 3, polygon.allSatisfy(\.isFinite),
              pillHalfWidth.isFinite, pillHalfHeight.isFinite,
              pillHalfWidth > 0, pillHalfHeight > 0
        else { return nil }
        guard let centroid = centroid(of: polygon) else { return nil }

        // The pill fits when its centre is in the fill and no edge of the outline or of any
        // hole meets its box. Nothing crossing the box means the whole box lies on the
        // centre's side of every ring, so all of it is fill (T-067). Corners were not enough:
        // a slot or a thin hole can cross the box between them, with all four corners and
        // every vertex of the cut elsewhere, and the number was printed over the recess.
        let inFill = contains(polygon, point: centroid) && !holes.contains { contains($0, point: centroid) }
        let box = (minX: centroid.x - pillHalfWidth, minY: centroid.y - pillHalfHeight,
                   maxX: centroid.x + pillHalfWidth, maxY: centroid.y + pillHalfHeight)
        let crossesBox = ([polygon] + holes).contains { ring in
            ring.indices.contains { index in
                segmentMeetsBox(ring[index], ring[(index + 1) % ring.count],
                                minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY)
            }
        }
        if inFill, !crossesBox {
            return Placement(center: centroid, leaderStart: nil, leaderEnd: nil)
        }

        // Fallback: the visual reference's Count leader pattern. Anchor at the polygon's bottom
        // vertex (page space is y-up, so the bottom is the minimum y; ties break on the
        // smaller x, so the choice is deterministic), leader pointing straight down,
        // pill hanging below with a small clearance.
        let anchor = polygon.min { a, b in
            a.y != b.y ? a.y < b.y : a.x < b.x
        } ?? polygon[0]
        let leaderEnd = PDFPoint(x: anchor.x, y: anchor.y - leaderLength)
        let center = PDFPoint(
            x: leaderEnd.x,
            y: leaderEnd.y - leaderClearance - pillHalfHeight
        )
        return Placement(center: center, leaderStart: anchor, leaderEnd: leaderEnd)
    }

    /// The area-weighted centroid (shoelace), falling back to the vertex mean for a
    /// zero-area outline. `nil` only when the coordinates are unusable.
    public static func centroid(of polygon: [PDFPoint]) -> PDFPoint? {
        guard polygon.count >= 3 else { return nil }
        var twiceArea = 0.0
        var cx = 0.0
        var cy = 0.0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let cross = a.x * b.y - b.x * a.y
            twiceArea += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        if Swift.abs(twiceArea) > 1e-9 {
            let centroid = PDFPoint(x: cx / (3 * twiceArea), y: cy / (3 * twiceArea))
            return centroid.isFinite ? centroid : nil
        }
        let mean = PDFPoint(
            x: polygon.reduce(0) { $0 + $1.x } / Double(polygon.count),
            y: polygon.reduce(0) { $0 + $1.y } / Double(polygon.count)
        )
        return mean.isFinite ? mean : nil
    }

    /// Whether the segment `a`–`b` meets the closed box (Liang–Barsky): a touch counts, so a
    /// pill that would sit flush against an edge steps out rather than overlap it by rounding.
    static func segmentMeetsBox(_ a: PDFPoint, _ b: PDFPoint,
                                minX: Double, minY: Double, maxX: Double, maxY: Double) -> Bool {
        var enter = 0.0, leave = 1.0
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - minX), (dx, maxX - a.x), (-dy, a.y - minY), (dy, maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let r = q / p
                if p < 0 {
                    if r > leave { return false }
                    enter = Swift.max(enter, r)
                } else {
                    if r < enter { return false }
                    leave = Swift.min(leave, r)
                }
            }
        }
        return true
    }

    /// Ray-crossing parity, the same rule the fill itself obeys (even-odd).
    public static func contains(_ polygon: [PDFPoint], point: PDFPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
