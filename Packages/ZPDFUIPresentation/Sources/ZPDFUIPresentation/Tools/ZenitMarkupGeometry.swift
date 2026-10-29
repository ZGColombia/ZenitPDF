import Foundation

/// How each markup tool stores what it drew, and the pure maths that both the commit path
/// and the canvas renderer read it back with.
///
/// A markup is not a measurement, so it does not go through the measurement engine's
/// geometry builders. It still uses the contract's `MeasurementGeometry` as its container —
/// that is what the archive, the undo stack and the hydration path already round-trip — so
/// the *convention* below is the whole schema. Both sides of the seam call these functions
/// rather than re-deriving the shape, which is what keeps the committed markup and the drawn
/// markup the same object.
///
/// | Kind | Stored as |
/// |---|---|
/// | `text` | `points` = the two opposite corners of the box; the string is the record's `caption` (NL-COLLAB-18; `comment` is its review note) |
/// | `callout` | `points` = `[target, boxCornerA, boxCornerB]`; the string is the record's `caption` |
/// | `line`, `arrow` | `points` = the two endpoints |
/// | `polyline` | `points` = every vertex, open |
/// | `ellipse` | `points` = the two opposite corners of the bounding box |
/// | `rectangle`, `polygon`, `cloud` | one closed `polygons` ring |
public enum ZenitMarkupGeometry {

    /// The axis-aligned rectangle spanned by two opposite corners, standardized.
    public static func boundingRect(_ first: PDFPointValue, _ second: PDFPointValue) -> PDFRectValue {
        PDFRectValue(
            x: Swift.min(first.x, second.x),
            y: Swift.min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

    /// The four corners of an axis-aligned rectangle from two opposite corners, in drawing
    /// order. Shared by the drag preview and the commit so they cannot disagree.
    public static func rectangleCorners(
        _ first: PDFPointValue,
        _ second: PDFPointValue
    ) -> [PDFPointValue] {
        [
            first,
            PDFPointValue(x: second.x, y: first.y),
            second,
            PDFPointValue(x: first.x, y: second.y)
        ]
    }

    /// An ellipse inscribed in a rectangle, as a closed polyline.
    ///
    /// 72 facets: 5° segments are below one device pixel at every zoom the product
    /// supports, and the canvas draws outlines rather than curves everywhere else too.
    public static func ellipseOutline(in rect: PDFRectValue, segments: Int = 72) -> [PDFPointValue] {
        let steps = Swift.max(8, segments)
        let cx = rect.minX + rect.size.width / 2
        let cy = rect.minY + rect.size.height / 2
        let rx = rect.size.width / 2
        let ry = rect.size.height / 2
        return (0..<steps).map { step in
            let angle = Double(step) / Double(steps) * 2 * Double.pi
            return PDFPointValue(x: cx + rx * cos(angle), y: cy + ry * sin(angle))
        }
    }

    /// A revision-cloud outline: the polygon's edges replaced by outward semicircular
    /// scallops of roughly `radius` page points, meeting in cusps.
    ///
    /// Returned as a dense point list rather than as arcs, because the canvas, the export
    /// renderer and the hit test all consume outlines and none of them wants a second
    /// curve representation to keep in step.
    ///
    /// The outline is always a closed ring. An open-path mode (`closed: false`) had no caller and
    /// dropped the path's end point, because each scallop leaves its far cusp to the next edge
    /// (V-077); it is gone.
    public static func cloudOutline(
        _ polygon: [PDFPointValue],
        radius: Double
    ) -> [PDFPointValue] {
        guard polygon.count >= 2, radius > 0, radius.isFinite else { return polygon }
        var outline: [PDFPointValue] = []
        let edgeCount = polygon.count
        // BH-282: the ring is stored as drawn, and half of all people click a cloud's corners
        // clockwise. The right-hand normal is outward only for a counter-clockwise ring (page
        // space is y-up), so a clockwise ring flips it — otherwise every scallop bulged inward.
        let orientation: Double = signedArea(polygon) < 0 ? -1 : 1
        let scallopCounts = cloudScallopCounts(polygon, edgeCount: edgeCount, radius: radius)
        for index in 0..<edgeCount {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-9 else { continue }
            guard let scallops = scallopCounts[index] else {
                // U-072: an edge past the coordinate bound is drawn straight; the next edge's
                // first point finishes it (the last edge's is the ring's first point).
                outline.append(start)
                continue
            }
            let step = length / Double(scallops)
            let ux = dx / length
            let uy = dy / length
            // The outward normal, whichever way the ring was drawn.
            let nx = uy * orientation
            let ny = -ux * orientation
            for scallop in 0..<scallops {
                // A true semicircle on the chord, centred on its midpoint: it leaves and meets
                // the edge at right angles, so neighbouring bumps meet in a cusp. The old
                // half-sine left the edge at a shallow slope and a cloud read as a wavy line
                // (design round d7, final QA).
                let arcRadius = step / 2
                let centre = Double(scallop) * step + arcRadius
                // Twelve samples per bump: a curve at 100 % without exploding the point count
                // on a fifty-edge cloud. The bump's far cusp is the next bump's first point.
                for sample in 0..<12 {
                    let theta = Double(sample) / 12 * Double.pi
                    let along = centre - cos(theta) * arcRadius
                    let out = sin(theta) * arcRadius
                    outline.append(PDFPointValue(
                        x: start.x + ux * along + nx * out,
                        y: start.y + uy * along + ny * out
                    ))
                }
            }
        }
        return outline
    }

    /// The most scallops one cloud edge is drawn with. 4 096 bumps of the smallest arc size
    /// (2 pt) span 16 384 pt, longer than any PDF page's edge (14 400 pt).
    static let maximumScallopsPerEdge = 4_096

    /// The most scallops a whole cloud outline is drawn with (twelve points each). A cloud
    /// around the largest PDF page at the smallest arc size needs 14 400; past this budget every
    /// edge is scaled down in proportion, so the outline stays a cloud with larger bumps.
    static let maximumScallopsPerOutline = 16_384

    /// The coordinate bound of the frozen measurement contract
    /// (`MeasurementGeometry.coordinateMagnitudeBound`, 1e7 PDF points, ADR-0035). This package
    /// has no dependencies, so the value is restated; `Fix2ToolGeometryTests` pins it.
    static let coordinateMagnitudeBound: Double = 1e7

    /// How many scallops each edge gets, or `nil` for an edge drawn straight.
    ///
    /// U-072: the count used to be `Int((length / (radius * 2)).rounded())` with nothing bounding
    /// `length`. An imported cloud with one vertex at 1e30 pt asked for ~1e29 scallops — past
    /// `Int.max`, so the conversion trapped and the page crashed every time it was drawn — and
    /// a vertex near 1e7 pt built millions of points on every scene build. The count is now
    /// clamped in `Double` before any conversion, an edge with an endpoint or a length past the
    /// coordinate bound (or not finite) is drawn straight, and the total is held to
    /// ``maximumScallopsPerOutline``.
    static func cloudScallopCounts(
        _ polygon: [PDFPointValue],
        edgeCount: Int,
        radius: Double
    ) -> [Int?] {
        let bound = coordinateMagnitudeBound
        func inBound(_ point: PDFPointValue) -> Bool {
            point.x.isFinite && point.y.isFinite && abs(point.x) <= bound && abs(point.y) <= bound
        }
        var wanted: [Double?] = []
        wanted.reserveCapacity(edgeCount)
        var total = 0.0
        for index in 0..<edgeCount {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard inBound(start), inBound(end), length.isFinite, length <= bound else {
                wanted.append(nil)
                continue
            }
            // At least one scallop per edge, and never one longer than 2·radius — up to the cap.
            let count = Swift.min(Double(maximumScallopsPerEdge), Swift.max(1, (length / (radius * 2)).rounded()))
            wanted.append(count)
            total += count
        }
        let budget = Double(maximumScallopsPerOutline)
        let scale = total > budget ? budget / total : 1
        return wanted.map { count in
            count.map { Swift.max(1, Int(($0 * scale).rounded(.down))) }
        }
    }

    /// Twice the signed area of a ring (shoelace): positive for counter-clockwise in y-up
    /// page space, negative for clockwise.
    static func signedArea(_ ring: [PDFPointValue]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }

    /// The default text box a single click places: a caret-height box wide enough to see,
    /// anchored with the click at its top-left in page space.
    ///
    /// Page space is y-up and a rect's origin is its lower-left corner, so "top-left at the
    /// click" is an origin one box-height *below* the click. The old origin was the click
    /// itself, which opened the whole box above the point clicked (BH-797).
    ///
    /// The Text tool's contract: a click places an insertion point, or a drag defines a
    /// box. A click still has to produce a box — the caret has to live somewhere — so it
    /// produces this one, and typing grows it.
    public static func defaultTextBox(at point: PDFPointValue, fontSize: Double) -> PDFRectValue {
        let height = Swift.max(12, fontSize * 1.6)
        return PDFRectValue(x: point.x, y: point.y - height, width: Swift.max(80, fontSize * 10), height: height)
    }

    /// Where a callout's leader line meets its box: the point on the box's outline closest
    /// to the target, clamped to the box's edges.
    public static func leaderAttachment(target: PDFPointValue, box: PDFRectValue) -> PDFPointValue {
        let clampedX = Swift.min(Swift.max(target.x, box.minX), box.minX + box.size.width)
        let clampedY = Swift.min(Swift.max(target.y, box.minY), box.minY + box.size.height)
        // Inside the box: attach to the nearest edge rather than to an interior point,
        // which would draw a leader that disappears under the text.
        let insideX = target.x > box.minX && target.x < box.minX + box.size.width
        let insideY = target.y > box.minY && target.y < box.minY + box.size.height
        guard insideX && insideY else { return PDFPointValue(x: clampedX, y: clampedY) }
        let toLeft = target.x - box.minX
        let toRight = box.minX + box.size.width - target.x
        let toBottom = target.y - box.minY
        let toTop = box.minY + box.size.height - target.y
        let smallest = Swift.min(Swift.min(toLeft, toRight), Swift.min(toBottom, toTop))
        if smallest == toLeft { return PDFPointValue(x: box.minX, y: target.y) }
        if smallest == toRight { return PDFPointValue(x: box.minX + box.size.width, y: target.y) }
        if smallest == toBottom { return PDFPointValue(x: target.x, y: box.minY) }
        return PDFPointValue(x: target.x, y: box.minY + box.size.height)
    }
}
