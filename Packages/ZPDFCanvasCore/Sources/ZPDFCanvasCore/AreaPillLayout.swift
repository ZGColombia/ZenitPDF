import CoreGraphics
import Foundation

/// Where an area's value pill goes on the canvas: **inside
/// the fill**, centred on the polygon's centroid — and when the centroid falls outside a
/// concave outline, or the pill would not fit, the pill steps out below the polygon's
/// bottom vertex on a short leader, the mockup's Count-caption pattern.
///
/// View-space maths (flipped, y down — "below" is +y), mirroring the renderer's
/// page-space `AreaPillPlacement` point for point, the same duplication discipline
/// `DimensionGrammar` set. Pure geometry, no AppKit, testable without a display.
public enum AreaPillLayout {

    /// Leader length from the anchor vertex to the pill, in view points
    /// (matches `AreaPillPlacement.leaderLengthViewPoints`).
    public static let leaderLength: CGFloat = 18
    /// Clear space between the leader's end and the pill's edge, in view points.
    public static let leaderClearance: CGFloat = 2

    /// A resolved placement: the pill's centre, and the leader when the pill could not
    /// sit inside the fill.
    public struct Placement: Equatable, Sendable {
        public init(center: CGPoint, leaderStart: CGPoint? = nil, leaderEnd: CGPoint? = nil) {
            self.center = center
            self.leaderStart = leaderStart
            self.leaderEnd = leaderEnd
        }

        public var center: CGPoint
        /// The leader's start (a polygon vertex), or `nil` for an interior pill.
        public var leaderStart: CGPoint?
        /// The leader's end (just short of the pill), or `nil` for an interior pill.
        public var leaderEnd: CGPoint?

        public var isInterior: Bool { leaderStart == nil }
    }

    /// Places one pill for a polygon already mapped to view points.
    /// Returns `nil` for degenerate input — a pill with nowhere honest to sit.
    public static func placement(
        polygon: [CGPoint],
        holes: [[CGPoint]] = [],
        pillHalfWidth: CGFloat,
        pillHalfHeight: CGFloat
    ) -> Placement? {
        guard polygon.count >= 3,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              pillHalfWidth.isFinite, pillHalfHeight.isFinite,
              pillHalfWidth > 0, pillHalfHeight > 0
        else { return nil }
        guard let centroid = centroid(of: polygon) else { return nil }

        // Inside the *fill*: the centre in the outer ring and in no hole (a courtyard's centroid
        // is in the hole, BH-880), and no edge of the outline or of any hole across the pill's
        // box, so the whole box is fill (T-067: a slot or a thin hole could cross the box between
        // its corners with no vertex inside, and the number sat over the recess).
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

        // Fallback: anchor at the bottom vertex. The view is flipped, so the bottom is
        // the *maximum* y; ties break on the smaller x — the same vertex the renderer's
        // page-space rule picks.
        let anchor = polygon.max { a, b in
            a.y != b.y ? a.y < b.y : a.x > b.x
        } ?? polygon[0]
        let leaderEnd = CGPoint(x: anchor.x, y: anchor.y + leaderLength)
        let center = CGPoint(
            x: leaderEnd.x,
            y: leaderEnd.y + leaderClearance + pillHalfHeight
        )
        return Placement(center: center, leaderStart: anchor, leaderEnd: leaderEnd)
    }

    // MARK: Pills that would cover each other (L-70)

    /// The clear space kept between two pills a layout moved apart, in view points.
    public static let pillSeparation: CGFloat = 4
    /// How many times a pill may be moved along before it is left where it is.
    static let maximumSeparationSteps = 64

    /// One area's pill as ``placement(polygon:holes:pillHalfWidth:pillHalfHeight:)`` placed it on
    /// its own, with the half size of its box.
    public struct PagePill: Sendable {
        public init(id: UUID, placement: Placement, halfWidth: CGFloat, halfHeight: CGFloat) {
            self.id = id
            self.placement = placement
            self.halfWidth = halfWidth
            self.halfHeight = halfHeight
        }

        public var id: UUID
        public var placement: Placement
        public var halfWidth: CGFloat
        public var halfHeight: CGFloat
    }

    /// Every area pill on a page, laid out together so none covers another (L-70).
    ///
    /// Each pill is placed on its own, so two areas side by side whose pills do not fit inside
    /// them — the two halves of a split, say — both stepped out below their bottom-left corner and
    /// one printed over the other: *"Kitchen floo[r] Kitchen floor.2: 15,02 m²"*. Interior pills
    /// stay where they are (each sits inside its own fill). A pill on a leader that would cover a
    /// pill already laid out moves right, past it, in the same row, and its leader runs from its
    /// corner to the nearest point of the pill's top edge — so it never crosses the pill it
    /// stepped past. Pills are taken in the order given (the canvas's drawing order), which makes
    /// the layout the same on every redraw of the same page at the same zoom.
    public static func separating(_ pills: [PagePill]) -> [UUID: Placement] {
        var resolved: [UUID: Placement] = [:]
        var occupied = PillGrid()
        for pill in pills where pill.placement.isInterior {
            resolved[pill.id] = pill.placement
            occupied.insert(box(of: pill, at: pill.placement.center))
        }
        for pill in pills where !pill.placement.isInterior {
            var placement = pill.placement
            var rect = box(of: pill, at: placement.center)
            var steps = 0
            while steps < maximumSeparationSteps, let hit = occupied.firstHit(rect, clearance: pillSeparation) {
                placement.center.x = hit.maxX + pillSeparation + pill.halfWidth
                rect = box(of: pill, at: placement.center)
                steps += 1
            }
            if steps > 0, let start = placement.leaderStart {
                placement.leaderEnd = CGPoint(
                    x: min(max(start.x, rect.minX), rect.maxX),
                    y: rect.minY - leaderClearance
                )
            }
            resolved[pill.id] = placement
            occupied.insert(rect)
        }
        return resolved
    }

    private static func box(of pill: PagePill, at center: CGPoint) -> CGRect {
        CGRect(x: center.x - pill.halfWidth, y: center.y - pill.halfHeight,
               width: pill.halfWidth * 2, height: pill.halfHeight * 2)
    }

    /// The boxes laid out so far, bucketed so a page of a few thousand pills is not a quadratic
    /// scan on every zoom.
    private struct PillGrid {
        static let cell: CGFloat = 128
        private var boxes: [CGRect] = []
        private var buckets: [Int64: [Int]] = [:]

        mutating func insert(_ rect: CGRect) {
            let index = boxes.count
            boxes.append(rect)
            for key in Self.keys(rect) { buckets[key, default: []].append(index) }
        }

        /// The earliest-laid-out box closer to `rect` than `clearance`, if any.
        func firstHit(_ rect: CGRect, clearance: CGFloat) -> CGRect? {
            let probe = rect.insetBy(dx: -clearance / 2, dy: -clearance / 2)
            var best: Int?
            for key in Self.keys(probe) {
                for index in buckets[key] ?? [] where index < (best ?? .max) {
                    if boxes[index].insetBy(dx: -clearance / 2, dy: -clearance / 2).intersects(probe) { best = index }
                }
            }
            return best.map { boxes[$0] }
        }

        private static func keys(_ rect: CGRect) -> [Int64] {
            guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return [] }
            let x0 = Int64((rect.minX / cell).rounded(.down)), x1 = Int64((rect.maxX / cell).rounded(.down))
            let y0 = Int64((rect.minY / cell).rounded(.down)), y1 = Int64((rect.maxY / cell).rounded(.down))
            guard x1 - x0 < 64, y1 - y0 < 64 else { return [x0 << 32 | (y0 & 0xFFFF_FFFF)] }
            var keys: [Int64] = []
            for x in x0...x1 { for y in y0...y1 { keys.append(x << 32 | (y & 0xFFFF_FFFF)) } }
            return keys
        }
    }

    /// The area-weighted centroid (shoelace), falling back to the vertex mean for a
    /// zero-area outline.
    public static func centroid(of polygon: [CGPoint]) -> CGPoint? {
        guard polygon.count >= 3 else { return nil }
        var twiceArea: CGFloat = 0
        var cx: CGFloat = 0
        var cy: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let cross = a.x * b.y - b.x * a.y
            twiceArea += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        if abs(twiceArea) > 1e-9 {
            let centroid = CGPoint(x: cx / (3 * twiceArea), y: cy / (3 * twiceArea))
            return centroid.x.isFinite && centroid.y.isFinite ? centroid : nil
        }
        let mean = CGPoint(
            x: polygon.reduce(0) { $0 + $1.x } / CGFloat(polygon.count),
            y: polygon.reduce(0) { $0 + $1.y } / CGFloat(polygon.count)
        )
        return mean.x.isFinite && mean.y.isFinite ? mean : nil
    }

    /// Whether the segment `a`–`b` meets the closed box (Liang–Barsky); a touch counts. The
    /// renderer's `AreaPillPlacement.segmentMeetsBox` is the page-space twin.
    static func segmentMeetsBox(_ a: CGPoint, _ b: CGPoint,
                                minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat) -> Bool {
        var enter: CGFloat = 0, leave: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - minX), (dx, maxX - a.x), (-dy, a.y - minY), (dy, maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let r = q / p
                if p < 0 {
                    if r > leave { return false }
                    enter = max(enter, r)
                } else {
                    if r < enter { return false }
                    leave = min(leave, r)
                }
            }
        }
        return true
    }

    /// Ray-crossing parity, the same rule the fill itself obeys (even-odd). The one
    /// implementation: page-space hit testing converts and calls this (IM-239).
    public static func contains(_ polygon: [CGPoint], point: CGPoint) -> Bool {
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
