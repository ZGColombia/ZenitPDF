import Foundation
import ZPDFContracts

/// Hit testing against the compiled scene — the same instances the backends paint.
///
/// # The contract this type exists to keep
///
/// A user aims at ink. So every distance here is measured to the **drawn** extent of the ink, not
/// to the nominal geometry:
///
/// - A stroke is a rounded, butted or squared-off rectangle of width
///   ``RenderTransform/deviceWidth(forPageWidth:)`` — the width that was actually painted, floor
///   included. At 5 % zoom a 0.25 pt hairline is painted one device pixel wide, which is 10 page
///   points across, and it is hittable across all 10.
/// - A count symbol is its drawn square, which is sized in page points and therefore scales.
/// - A selection handle is its drawn square, which is sized in **view points** and therefore does
///   not scale — a handle is always about seven points of screen, at 5 % zoom and at 6400 %.
/// - A dash gap is not a hole. Dashes are decoration; the object is continuous, and a user who
///   clicks between two dashes has clicked the line.
///
/// Both backends call this same type, so they cannot disagree, and the golden suite plus
/// `HitTestAgreementTests` assert the two return identical results over a grid of query points.
public struct SceneHitTester {

    /// Distance from a point to the ink of one stroked segment, in page points. `0` inside.
    ///
    /// `halfWidth` is the **drawn** half width in page points, which is why the caller passes it
    /// rather than the segment's nominal width.
    public static func distanceToStroke(
        from point: PDFPoint,
        segment: CompiledSegment,
        halfWidth: Double
    ) -> Double {
        let dx = segment.end.x - segment.start.x
        let dy = segment.end.y - segment.start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else {
            // A zero-length segment is a dot: its ink is a disc for a round cap, a square for a
            // square cap, and nothing at all for a butt cap.
            let distance = point.distance(to: segment.start)
            switch segment.startCap {
            case .round: return Swift.max(0, distance - halfWidth)
            case .square:
                let ax = Swift.abs(point.x - segment.start.x) - halfWidth
                let ay = Swift.abs(point.y - segment.start.y) - halfWidth
                return Swift.max(0, Swift.max(ax, ay))
            case .butt: return distance
            }
        }
        let ux = dx / length
        let uy = dy / length
        let px = point.x - segment.start.x
        let py = point.y - segment.start.y
        let along = px * ux + py * uy
        let across = Swift.abs(-px * uy + py * ux)

        // Extension past each end, in the segment's own frame, according to its cap.
        func capExtension(_ cap: RenderCap) -> Double {
            switch cap {
            case .butt: 0
            case .square: halfWidth
            case .round: 0 // handled by the radial term below
            }
        }
        let startExtension = capExtension(segment.startCap)
        let endExtension = capExtension(segment.endCap)

        let beyondStart = -(along) - startExtension
        let beyondEnd = along - length - endExtension
        let outsideAlong = Swift.max(0, Swift.max(beyondStart, beyondEnd))
        let outsideAcross = Swift.max(0, across - halfWidth)

        if along < 0, segment.startCap == .round {
            return Swift.max(0, (along * along + across * across).squareRoot() - halfWidth)
        }
        if along > length, segment.endCap == .round {
            let overshoot = along - length
            return Swift.max(0, (overshoot * overshoot + across * across).squareRoot() - halfWidth)
        }
        guard outsideAlong > 0 || outsideAcross > 0 else { return 0 }
        return (outsideAlong * outsideAlong + outsideAcross * outsideAcross).squareRoot()
    }

    /// The closest point on a segment's centreline, used to report where the hit landed.
    public static func closestPointOnCentreline(
        from point: PDFPoint,
        segment: CompiledSegment
    ) -> PDFPoint {
        let dx = segment.end.x - segment.start.x
        let dy = segment.end.y - segment.start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return segment.start }
        var t = ((point.x - segment.start.x) * dx + (point.y - segment.start.y) * dy) / lengthSquared
        t = Swift.min(1, Swift.max(0, t))
        return PDFPoint(x: segment.start.x + t * dx, y: segment.start.y + t * dy)
    }

    /// `true` when the point is inside the triangle, boundary included.
    public static func contains(_ triangle: CompiledTriangle, _ point: PDFPoint) -> Bool {
        func cross(_ a: PDFPoint, _ b: PDFPoint, _ c: PDFPoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
        }
        let d1 = cross(triangle.a, triangle.b, point)
        let d2 = cross(triangle.b, triangle.c, point)
        let d3 = cross(triangle.c, triangle.a, point)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    /// Runs the query.
    ///
    /// - Parameters:
    ///   - markups: the compiled scene, **in painter order** — back to front. `ScenePreparer`
    ///     guarantees it; a caller that hands over an unordered array gets an unordered answer.
    ///   - overlay: the selection overlay, whose handles are tested first and win outright.
    ///   - point: the query point, in page space.
    ///   - tolerance: the caller's tolerance in page points, on top of the drawn ink.
    public static func hitTest(
        markups: [CompiledMarkup],
        overlay: OverlayBuilder.Overlay,
        transform: RenderTransform,
        point: PDFPoint,
        tolerance: Double
    ) -> HitTestResult? {
        hitTest(
            markups: markups,
            candidates: nil,
            overlay: overlay,
            transform: transform,
            point: point,
            tolerance: tolerance
        )
    }

    /// Runs the query over a candidate subset.
    ///
    /// - Parameter candidates: storage indices into `markups`, **topmost first** (descending),
    ///   that could possibly be hit — what ``ScenePreparer/hitCandidates(point:tolerance:transform:)``
    ///   returns from the culler's spatial index. `nil` scans every markup. Because the
    ///   candidates are a superset of what can be hit and are visited in the same top-down
    ///   order, the answer is identical to the full scan; only the work differs — a handful of
    ///   markups per query instead of every markup on the page (IM-083).
    public static func hitTest(
        markups: [CompiledMarkup],
        candidates: [Int]?,
        overlay: OverlayBuilder.Overlay,
        transform: RenderTransform,
        point: PDFPoint,
        tolerance: Double
    ) -> HitTestResult? {
        guard point.isFinite else { return nil }
        let slack = Swift.max(0, tolerance.isFinite ? tolerance : 0)

        // Handles first, unconditionally: they are drawn on top of everything and a user aiming
        // at a handle has never meant the shape underneath it.
        if !overlay.handles.isEmpty {
            let half = transform.pagePoints(fromViewPoints: overlay.handleSizeViewPoints) / 2
            var best: (distance: Double, handle: (markupID: MarkupID, index: Int, center: PDFPoint))?
            for handle in overlay.handles {
                let ax = Swift.abs(point.x - handle.center.x) - half
                let ay = Swift.abs(point.y - handle.center.y) - half
                let distance = Swift.max(0, Swift.max(ax, ay))
                guard distance <= slack else { continue }
                if best == nil || distance < best!.distance {
                    best = (distance, handle)
                }
            }
            if let best {
                return HitTestResult(
                    markupID: best.handle.markupID,
                    kind: .handle,
                    elementIndex: best.handle.index,
                    distanceInPagePoints: best.distance,
                    point: best.handle.center
                )
            }
        }

        // `markups` arrives in painter order — back to front, `(zIndex, id)` ascending, a total
        // order established once by `ScenePreparer` — so walking it backwards is walking it from
        // the topmost markup down. Sorting here instead, which is the obvious way to write it,
        // meant a hundred-thousand-element sort on every mouse move.
        if let candidates {
            for index in candidates where index >= 0 && index < markups.count {
                if let result = hitTest(markups[index], transform: transform, point: point, tolerance: slack) {
                    return result
                }
            }
            return nil
        }
        for markup in markups.reversed() {
            if let result = hitTest(markup, transform: transform, point: point, tolerance: slack) {
                return result
            }
        }
        return nil
    }

    /// The colour of a triangle built only to be tested, never painted.
    private static let noInk = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// The per-markup test, exposed so the agreement tests can drive it directly.
    public static func hitTest(
        _ markup: CompiledMarkup,
        transform: RenderTransform,
        point: PDFPoint,
        tolerance: Double
    ) -> HitTestResult? {
        // Cheap reject: the bounding box grown by the widest drawn stroke plus the tolerance.
        // The widest nominal width is `paddingPagePoints` and the drawn half width grows with
        // it, so this is a lookup; a hand-built markup without the precomputed figures falls
        // back to the reduce.
        let widestStroke: Double
        if markup.segments.isEmpty {
            widestStroke = 0
        } else if markup.paddingPagePoints > 0 {
            widestStroke = transform.drawnHalfWidthInPagePoints(forPageWidth: markup.paddingPagePoints)
        } else {
            widestStroke = markup.segments.reduce(0.0) {
                Swift.max($0, transform.drawnHalfWidthInPagePoints(forPageWidth: $1.widthPagePoints))
            }
        }
        if let box = markup.bounds {
            let grow = widestStroke + tolerance + symbolReach(markup, transform: transform)
            if point.x < box.minX - grow || point.x > box.maxX + grow
                || point.y < box.minY - grow || point.y > box.maxY + grow {
                return nil
            }
        }

        // Vertices beat strokes: grabbing a corner is a different gesture from grabbing an edge.
        //
        // A vertex's distance is measured the way a stroke's is — to the edge of its ink, the
        // drawn disc of the stroke's half width around it — so the two compare like with like.
        // Measuring the vertex to its centre and the stroke to its edge meant a click 1 pt from a
        // corner of a 6 pt line lost to the stroke (1 > 0), and `.vertex` was only ever reported
        // at the exact vertex or outside the ink past an end cap (BH-628).
        var vertexBest: (distance: Double, index: Int, point: PDFPoint)?
        func considerVertex(_ vertex: PDFPoint, index: Int, reach: Double) {
            let distance = Swift.max(0, point.distance(to: vertex) - reach)
            guard distance <= tolerance else { return }
            if vertexBest == nil || distance < vertexBest!.distance {
                vertexBest = (distance, index, vertex)
            }
        }
        for (index, segment) in markup.segments.enumerated() {
            let reach = transform.drawnHalfWidthInPagePoints(forPageWidth: segment.widthPagePoints)
            considerVertex(segment.start, index: index, reach: reach)
        }
        // An open run's last vertex is no segment's start; without this it could never be
        // reported as a vertex, unlike the first (BH-627). A closed run ends where it began.
        if let last = markup.segments.last, let first = markup.segments.first, last.end != first.start {
            let reach = transform.drawnHalfWidthInPagePoints(forPageWidth: last.widthPagePoints)
            considerVertex(last.end, index: markup.segments.count, reach: reach)
        }

        var strokeBest: (distance: Double, point: PDFPoint)?
        for rawSegment in markup.segments {
            var segment = rawSegment
            // Hit test the caps that were drawn, not the ones that were asked for.
            segment.startCap = transform.effectiveCap(
                rawSegment.startCap, forPageWidth: rawSegment.widthPagePoints
            )
            segment.endCap = transform.effectiveCap(
                rawSegment.endCap, forPageWidth: rawSegment.widthPagePoints
            )
            let half = transform.drawnHalfWidthInPagePoints(forPageWidth: segment.widthPagePoints)
            let distance = distanceToStroke(from: point, segment: segment, halfWidth: half)
            guard distance <= tolerance else { continue }
            if strokeBest == nil || distance < strokeBest!.distance {
                strokeBest = (distance, closestPointOnCentreline(from: point, segment: segment))
            }
        }

        for symbol in markup.symbols {
            let half = symbol.sizePagePoints > 0
                ? symbol.sizePagePoints / 2
                : transform.pagePoints(fromViewPoints: symbol.sizeViewPoints) / 2
            // A turned marker is tested in its own frame: the query point turned back by the
            // marker's angle about its centre (BH-634).
            var dx = point.x - symbol.center.x
            var dy = point.y - symbol.center.y
            if symbol.rotationDegrees != 0 {
                let radians = -symbol.rotationDegrees * .pi / 180
                let c = Foundation.cos(radians), s = Foundation.sin(radians)
                (dx, dy) = (dx * c - dy * s, dx * s + dy * c)
            }
            let ax = Swift.abs(dx) - half
            let ay = Swift.abs(dy) - half
            let distance = Swift.max(0, Swift.max(ax, ay))
            guard distance <= tolerance else { continue }
            if strokeBest == nil || distance < strokeBest!.distance {
                strokeBest = (distance, symbol.center)
            }
        }

        if let vertexBest, strokeBest == nil || vertexBest.distance <= strokeBest!.distance {
            return HitTestResult(
                markupID: markup.id,
                kind: .vertex,
                elementIndex: vertexBest.index,
                distanceInPagePoints: vertexBest.distance,
                point: vertexBest.point
            )
        }
        if let strokeBest {
            return HitTestResult(
                markupID: markup.id,
                kind: .stroke,
                distanceInPagePoints: strokeBest.distance,
                point: strokeBest.point
            )
        }

        for triangle in markup.triangles where contains(triangle, point) {
            return HitTestResult(
                markupID: markup.id,
                kind: .fill,
                distanceInPagePoints: 0,
                point: point
            )
        }

        // A placed picture is hit anywhere on the area it covers (ADR-0043): its parallelogram,
        // as the two triangles it splits into.
        for image in markup.images {
            let c = image.corners
            let halves = [
                CompiledTriangle(a: c[0], b: c[1], c: c[2], color: Self.noInk),
                CompiledTriangle(a: c[0], b: c[2], c: c[3], color: Self.noInk)
            ]
            if halves.contains(where: { contains($0, point) }) {
                return HitTestResult(markupID: markup.id, kind: .fill, distanceInPagePoints: 0, point: point)
            }
        }

        // A glyph is hit inside its drawn quad. The quad is a pixel-space rectangle hung off a
        // page-space anchor, so the test runs in pixels and the answer is reported in page space.
        if !markup.glyphs.isEmpty {
            let queryPixel = transform.pixel(from: point)
            let tolerancePixels = tolerance * transform.pixelsPerPagePoint
            for glyph in markup.glyphs {
                let anchor = transform.pixel(from: glyph.anchor)
                let minX = anchor.x + glyph.offsetX
                let minY = anchor.y + glyph.offsetY
                // The query in the quad's own frame: a turned quad (a stamp's field text, T-065)
                // is tested where it is drawn, not where its upright twin would be.
                var query = (x: queryPixel.x, y: queryPixel.y)
                if glyph.rotationSteps != 0 {
                    let turn = glyph.rotationRadians
                    let cosine = Foundation.cos(turn), sine = Foundation.sin(turn)
                    let (rx, ry) = (queryPixel.x - minX, queryPixel.y - minY)
                    query = (minX + rx * cosine + ry * sine, minY - rx * sine + ry * cosine)
                }
                let ax = Swift.max(minX - query.x, query.x - (minX + glyph.widthPixels))
                let ay = Swift.max(minY - query.y, query.y - (minY + glyph.heightPixels))
                let distance = Swift.max(0, Swift.max(ax, ay))
                guard distance <= tolerancePixels else { continue }
                return HitTestResult(
                    markupID: markup.id,
                    kind: .fill,
                    distanceInPagePoints: transform.pixelsPerPagePoint > 0
                        ? distance / transform.pixelsPerPagePoint
                        : 0,
                    point: point
                )
            }
        }

        return nil
    }

    /// How far a markup's symbols and glyph quads reach past its geometry bounds, in page
    /// points. Read from the figures the compiler precomputed; a hand-built markup without them
    /// is measured instead.
    private static func symbolReach(_ markup: CompiledMarkup, transform: RenderTransform) -> Double {
        let precomputedSymbols = markup.symbols.isEmpty || markup.symbolReachPagePoints > 0
        let precomputedGlyphs = markup.glyphs.isEmpty || markup.glyphReachPixels > 0
        if precomputedSymbols, precomputedGlyphs,
           !markup.symbols.contains(where: { $0.sizePagePoints <= 0 }) {
            let glyphs = transform.pixelsPerPagePoint > 0
                ? markup.glyphReachPixels / transform.pixelsPerPagePoint
                : 0
            return Swift.max(markup.symbolReachPagePoints, glyphs)
        }
        var reach = 0.0
        for symbol in markup.symbols {
            let half = symbol.sizePagePoints > 0
                ? symbol.sizePagePoints / 2
                : transform.pagePoints(fromViewPoints: symbol.sizeViewPoints) / 2
            reach = Swift.max(reach, half)
        }
        if !markup.glyphs.isEmpty, transform.pixelsPerPagePoint > 0 {
            for glyph in markup.glyphs {
                let extentPixels = glyph.rotationSteps == 0
                    ? Swift.max(
                        Swift.abs(glyph.offsetX) + glyph.widthPixels,
                        Swift.abs(glyph.offsetY) + glyph.heightPixels
                    )
                    : glyph.cornerOffsets.reduce(0.0) { Swift.max($0, Swift.abs($1.x), Swift.abs($1.y)) }
                reach = Swift.max(reach, extentPixels / transform.pixelsPerPagePoint)
            }
        }
        return reach
    }
}
