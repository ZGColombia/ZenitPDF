import Foundation
import ZPDFUIPresentation

/// Whether a page point is *on* a markup, and which markups a marquee catches.
///
/// The canvas used to answer the first question with `shape.bounds` padded by six screen
/// points. A bounding box is not the shape: a click in the notch of an
/// L-shaped area, or in the empty middle of a rectangle drawn as an outline, selected a
/// markup the pointer was nowhere near — and on a busy drawing the wrong one, because the
/// topmost *box* wins even when the outline underneath is the one under the cursor.
///
/// Pure and view-free, so the rule is asserted in a test rather than by clicking.
enum CanvasHitTesting {

    /// Whether `point` selects `shape`, within `tolerance` page units of its outline.
    ///
    /// The rule, in the order a user would state it: inside a filled area, on any outline,
    /// on a count mark, or inside a text box. A closed outline that carries no fill is a
    /// frame — a rectangle drawn to ring a detail — and only its edge selects it, so the
    /// drawing inside stays reachable.
    static func shape(
        _ shape: CanvasMarkupShape,
        contains point: PDFPointValue,
        tolerance: Double,
        zoom: Double = 1
    ) -> Bool {
        // A Temporary Measure is never selectable ink: it exists only on the presenter, and
        // selecting it issued commands on an id the session does not hold (BH-339, BH-344).
        guard !shape.isTemporary else { return false }
        // The holes are found only once a filled ring has contained the point: finding them
        // filters and allocates, and most probes land in no filled ring at all (S-005).
        var holes: [[PDFPointValue]]?
        // The drawn stroke, not its centreline: a 9 pt line is clickable across its width
        // (IM-161).
        let strokeTolerance = tolerance + max(0, shape.lineWidth) / 2
        for stroke in shape.strokes {
            guard stroke.points.count >= 2 else { continue }
            if stroke.closed, stroke.filled, polygon(stroke.points, contains: point) {
                let rings = holes ?? Self.holes(of: shape)
                holes = rings
                if !rings.contains(where: { polygon($0, contains: point) }) { return true }
            }
            if isNear(point, path: stroke.points, closed: stroke.closed, tolerance: strokeTolerance) {
                return true
            }
        }
        // The drawn count symbol, not a 6-px dot at its centre (BH-878): the painter's drawn
        // size, floored on screen (L-15), in page units.
        let symbolRadius = symbolRadius(of: shape, zoom: zoom)
        for mark in shape.counts where mark.distance(to: point) <= max(tolerance, symbolRadius) {
            return true
        }
        if let box = shape.textBox {
            // A turned box (ADR-0029) is stored unturned: the point is turned back about the
            // same centre instead, so the hit area is the box as drawn.
            let probe = shape.rotationDegrees != 0 && shape.rotationCentre != nil
                ? CanvasSceneBuilder.turn(point, about: shape.rotationCentre!, degrees: -shape.rotationDegrees)
                : point
            if inset(box, by: tolerance).contains(probe) { return true }
        }
        // A markup with neither an outline nor a count is a bare text box whose string is
        // empty of geometry; its box is its only handle, and the clause above covers it.
        return false
    }

    /// The page-space rectangle holding every piece of ink ``shape(_:contains:tolerance:zoom:)``
    /// tests — the outlines (a callout's leader among them), the count marks, and the text box
    /// as drawn, turned when the markup is — before any tolerance. `nil` when there is none, and
    /// then nothing can hit the shape.
    ///
    /// Not `shape.bounds`: a callout's bounds are its text box alone, while its leader runs out
    /// to the target, so rejecting on the bounds would make every leader unclickable.
    static func inkBounds(of shape: CanvasMarkupShape) -> PDFRectValue? {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ point: PDFPointValue) {
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }
        for stroke in shape.strokes where stroke.points.count >= 2 {
            for point in stroke.points { add(point) }
        }
        for mark in shape.counts { add(mark) }
        for corner in shape.drawnTextBoxCorners { add(corner) }
        guard minX <= maxX, minY <= maxY else { return nil }
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether `point` can select `shape` at all, from its cached ``inkBounds(of:)``: the one
    /// rectangle comparison the canvas makes per shape on a pointer move before the exact test
    /// (S-005). Every mouse move with Select armed used to run the exact test — every segment's
    /// distance, and the hole and ring copies of each filled area — over every shape on the
    /// sheet. Conservative by construction: the ink is padded by the widest reach the exact test
    /// allows, so this never refuses a point the exact test would accept.
    static func mayContain(
        _ shape: CanvasMarkupShape,
        inkBounds: PDFRectValue?,
        point: PDFPointValue,
        tolerance: Double,
        zoom: Double = 1
    ) -> Bool {
        guard let ink = inkBounds else { return false }
        let strokeReach = tolerance + max(0, shape.lineWidth) / 2
        let countReach = shape.counts.isEmpty ? 0 : max(tolerance, symbolRadius(of: shape, zoom: zoom))
        // A turned box is tested with its tolerance margin turned too, and a turned margin
        // reaches up to √2 times further along an axis.
        let turned = shape.rotationDegrees != 0 && shape.rotationCentre != nil
        let boxReach = shape.textBox == nil ? 0 : (turned ? tolerance * 2.0.squareRoot() : tolerance)
        // A hair of slack so a probe exactly on the reach is never lost to rounding.
        let reach = max(strokeReach, countReach, boxReach) * (1 + 1e-9) + 1e-9
        return point.x >= ink.minX - reach && point.x <= ink.maxX + reach
            && point.y >= ink.minY - reach && point.y <= ink.maxY + reach
    }

    /// A count symbol's drawn radius in page units: half its drawn size in view points ÷ zoom
    /// (BH-878), with the painter's on-screen minimum (L-15), so a mark drawn larger than its
    /// sheet size at a far zoom is clicked where it is drawn. The painter's keyline is not a
    /// target: the tolerance already reaches past it.
    private static func symbolRadius(of shape: CanvasMarkupShape, zoom: Double) -> Double {
        let safeZoom = max(zoom, 1e-6)
        return Double(CanvasCountSymbolPainter.drawnSizeInView(for: shape.symbol, zoom: CGFloat(safeZoom))) / 2 / safeZoom
    }

    /// Whether a marquee catches `shape`.
    ///
    /// Intersect, not enclose: an estimator dragging over a wall run expects to catch the
    /// measurements it crosses, and requiring full containment means the one long dimension
    /// that runs off the marquee is silently left behind.
    static func shape(_ shape: CanvasMarkupShape, intersects marquee: PDFRectValue) -> Bool {
        guard !shape.isTemporary else { return false }
        let bounds = shape.bounds
        guard bounds.maxX >= marquee.minX, bounds.minX <= marquee.maxX,
              bounds.maxY >= marquee.minY, bounds.minY <= marquee.maxY
        else { return false }
        return true
    }

    /// The holes of a shape's filled area: the closed, unfilled rings inside its one filled
    /// outer ring (a cutout). Empty for any other shape.
    static func holes(of shape: CanvasMarkupShape) -> [[PDFPointValue]] {
        let filled = shape.strokes.filter { $0.closed && $0.filled }
        guard filled.count == 1, let outer = filled.first else { return [] }
        return shape.strokes
            .filter { $0.closed && !$0.filled && $0.points.count >= 3 }
            .map(\.points)
            .filter { ring in ring.first.map { polygon(outer.points, contains: $0) } ?? false }
    }

    /// Even-odd point-in-polygon in page space — ``AreaPillLayout/contains(_:point:)``, the
    /// one implementation (IM-239).
    static func polygon(_ ring: [PDFPointValue], contains point: PDFPointValue) -> Bool {
        AreaPillLayout.contains(ring.map { CGPoint(x: $0.x, y: $0.y) }, point: CGPoint(x: point.x, y: point.y))
    }

    /// Whether the point is within `tolerance` of any edge of the path.
    static func isNear(
        _ point: PDFPointValue,
        path: [PDFPointValue],
        closed: Bool,
        tolerance: Double
    ) -> Bool {
        guard path.count >= 2 else {
            return path.first.map { $0.distance(to: point) <= tolerance } ?? false
        }
        for index in 0..<(path.count - 1) {
            if distance(from: point, toSegment: path[index], path[index + 1]) <= tolerance {
                return true
            }
        }
        if closed, let first = path.first, let last = path.last {
            return distance(from: point, toSegment: last, first) <= tolerance
        }
        return false
    }

    /// Shortest distance from a point to a segment, in page units.
    static func distance(
        from point: PDFPointValue,
        toSegment a: PDFPointValue,
        _ b: PDFPointValue
    ) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return a.distance(to: point) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = Swift.min(1, Swift.max(0, t))
        let closest = PDFPointValue(x: a.x + t * dx, y: a.y + t * dy)
        return closest.distance(to: point)
    }

    private static func inset(_ rect: PDFRectValue, by amount: Double) -> PDFRectValue {
        PDFRectValue(
            x: rect.minX - amount,
            y: rect.minY - amount,
            width: rect.size.width + amount * 2,
            height: rect.size.height + amount * 2
        )
    }
}

extension CanvasMarkupShape {

    /// The four corners of the text box as its words are drawn, in page space: turned about
    /// ``rotationCentre`` when the markup is turned (ADR-0029 stores the box unturned and turns
    /// the text at draw time), as stored otherwise. Empty without a text box.
    var drawnTextBoxCorners: [PDFPointValue] {
        guard let box = textBox else { return [] }
        let corners = [
            PDFPointValue(x: box.minX, y: box.minY), PDFPointValue(x: box.maxX, y: box.minY),
            PDFPointValue(x: box.maxX, y: box.maxY), PDFPointValue(x: box.minX, y: box.maxY)
        ]
        guard rotationDegrees != 0, let centre = rotationCentre else { return corners }
        return corners.map { CanvasSceneBuilder.turn($0, about: centre, degrees: rotationDegrees) }
    }

    /// The axis-aligned page rectangle the markup's box occupies as drawn: its text box turned
    /// as the words are, or ``bounds`` when it has no text box.
    ///
    /// One rule for the draw cull, the Select hover, the ledger hover and the hit test's ink
    /// bounds. The first three used the stored, unturned text box, so a turned borderless text
    /// box was culled by a rectangle its words left (partial redraws clipped them) and both
    /// hover outlines crossed it instead of framing it (T-002).
    var drawnBox: PDFRectValue {
        let corners = drawnTextBoxCorners
        guard let first = corners.first else { return bounds }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for corner in corners.dropFirst() {
            minX = Swift.min(minX, corner.x); maxX = Swift.max(maxX, corner.x)
            minY = Swift.min(minY, corner.y); maxY = Swift.max(maxY, corner.y)
        }
        return PDFRectValue(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
