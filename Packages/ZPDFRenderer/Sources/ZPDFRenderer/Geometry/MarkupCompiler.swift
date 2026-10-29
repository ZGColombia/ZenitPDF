import Foundation
import ZPDFContracts

/// Turns one ``RenderableMarkup`` into instances. Pure, deterministic, and shared by both
/// backends and by the hit tester — which is the mechanism, not the aspiration, behind
/// "hit testing matches what is drawn".
public struct MarkupCompiler {

    /// Glyph atlases, needed only for text labels.
    private let glyphAtlases: GlyphAtlasCache
    /// Device pixels per page point, needed only to pick the glyph size bucket.
    private let pixelsPerPagePoint: Double
    /// Page points per view point at the current zoom — what turns the measurement grammar's
    /// view-sized decorations (arrowheads, ticks, pills) into page-space instances. `1` is the
    /// zoom-1 identity, kept as the default so callers that never compile those shapes are
    /// untouched.
    private let pagePointsPerViewPoint: Double
    /// The linear part of the pixel-to-page map — how a device-pixel offset (x right, y down)
    /// turns into a page-space offset. Only a text label's selection bounds need it, because
    /// that is the one place a pixel-sized extent has to become a page-space box (BH-625).
    private let pixelToPage: RenderTransform.Affine

    /// - Parameter pixelToPage: the frame's pixel-to-page map; only its linear part is read.
    ///   `nil` assumes an unrotated page in a flipped view — `(1/ppp, 0, 0, -1/ppp)`.
    public init(
        glyphAtlases: GlyphAtlasCache,
        pixelsPerPagePoint: Double,
        pagePointsPerViewPoint: Double = 1,
        pixelToPage: RenderTransform.Affine? = nil
    ) {
        self.glyphAtlases = glyphAtlases
        self.pixelsPerPagePoint = pixelsPerPagePoint
        self.pagePointsPerViewPoint =
            pagePointsPerViewPoint.isFinite && pagePointsPerViewPoint > 0
                ? pagePointsPerViewPoint
                : 1
        let inverse = pixelsPerPagePoint.isFinite && pixelsPerPagePoint > 0 ? 1 / pixelsPerPagePoint : 1
        self.pixelToPage = pixelToPage
            ?? RenderTransform.Affine(a: inverse, b: 0, c: 0, d: -inverse, tx: 0, ty: 0)
    }

    /// Compiles `markup`, or returns `nil` when its geometry is unusable.
    ///
    /// Unusable means: non-finite coordinates, coordinates past
    /// ``RenderLimits/coordinateMagnitudeBound``, contours past
    /// ``RenderLimits/maximumContourVertices``, or nothing visible after style resolution. The
    /// markup is then dropped and counted; it is never partially drawn and never fatal.
    public func compile(_ markup: RenderableMarkup) -> CompiledMarkup? {
        guard !markup.isHidden else { return nil }
        var compiled = CompiledMarkup(
            id: markup.id,
            revision: markup.revision,
            zIndex: markup.zIndex
        )
        compiled.multiplies = markup.style.blendMode == .multiply
        // The measurement-grammar shapes paint view-sized ink well outside their measured
        // geometry, so they report the full ink box here; every other shape keeps reporting
        // `geometryBounds`.
        var inkBounds: PDFRect?

        switch markup.shape {
        case let .polyline(polyline):
            guard let points = validated(polyline.points), points.count >= 2 else { return nil }
            compiled.segments = strokeSegments(
                points: points,
                isClosed: polyline.isClosed,
                style: markup.style
            )
            // The curve form rides along for a vector painter (ADR-0030 §5.6).
            if let curve = polyline.curve, curve.isFinite, !compiled.segments.isEmpty {
                compiled.vectorStroke = [curve]
            }

        case let .filledPolygon(polygon):
            guard let outer = validated(polygon.outer), outer.count >= 3 else { return nil }
            var holes: [[PDFPoint]] = []
            holes.reserveCapacity(polygon.holes.count)
            for hole in polygon.holes {
                // A hole with an unusable vertex is the same defect that rejects an outer
                // contour, and it is rejected the same way: dropping just the hole filled the
                // cutout in and drew a region the measurement does not describe, uncounted
                // (BH-198). A hole that is merely degenerate — under three distinct vertices —
                // encloses nothing, so skipping it changes no pixel.
                guard let cleaned = validated(hole) else { return nil }
                guard cleaned.count >= 3 else { continue }
                holes.append(cleaned)
            }
            if let fill = markup.style.effectiveFill {
                let sanitized = RenderPolygon(outer: outer, holes: holes)
                if let triangles = try? PolygonTriangulator.triangulate(sanitized), !triangles.isEmpty {
                    compiled.triangles = triangles.map {
                        CompiledTriangle(a: $0.a, b: $0.b, c: $0.c, color: fill)
                    }
                } else {
                    // The fill was requested but could not be triangulated (threw, or produced no
                    // triangles for a degenerate outline). The outline may still stroke below, but
                    // the dropped fill is recorded so it is counted, not lost silently (CR-80).
                    compiled.fillRejected = true
                }
            }
            if markup.style.effectiveStroke != nil, markup.style.sanitizedLineWidth > 0 {
                compiled.segments = strokeSegments(
                    points: outer,
                    isClosed: true,
                    style: markup.style
                )
                for hole in holes {
                    compiled.segments.append(contentsOf: strokeSegments(
                        points: hole,
                        isClosed: true,
                        style: markup.style
                    ))
                }
            }
            // The curve form rides along for a vector painter (ADR-0030 §5.6) — only when it
            // describes every contour, so a curve never stands in for a contour it lacks.
            if let curves = polygon.curves, curves.count == 1 + polygon.holes.count, curves.allSatisfy(\.isFinite) {
                if !compiled.triangles.isEmpty { compiled.vectorFill = curves }
                if !compiled.segments.isEmpty { compiled.vectorStroke = curves }
            }

        case let .countSymbol(symbol):
            guard symbol.center.isFinite, inRange(symbol.center) else { return nil }
            guard symbol.size.isFinite, symbol.size > 0 else { return nil }
            guard let color = markup.style.effectiveStroke ?? markup.style.effectiveFill else {
                return nil
            }
            let rotation = symbol.rotationDegrees.isFinite ? symbol.rotationDegrees : 0
            compiled.symbols = [CompiledSymbol(
                center: symbol.center,
                symbol: symbol.symbol,
                sizePagePoints: symbol.size,
                color: color,
                rotationDegrees: rotation
            )]
            if rotation.truncatingRemainder(dividingBy: 90) != 0 {
                // A turned square reaches past its unturned box by up to √2; the bounds are what
                // the culler and the hit tester trust, so they must cover the turned corners.
                let radians = rotation * .pi / 180
                let half = symbol.size / 2 * (abs(cos(radians)) + abs(sin(radians)))
                inkBounds = PDFRect(
                    x: symbol.center.x - half,
                    y: symbol.center.y - half,
                    width: 2 * half,
                    height: 2 * half
                )
            }

        case let .textLabel(label):
            guard label.anchorPoint.isFinite, inRange(label.anchorPoint) else { return nil }
            guard label.fontSize.isFinite, label.fontSize > 0 else { return nil }
            guard let color = markup.style.effectiveStroke ?? markup.style.effectiveFill else {
                return nil
            }
            let deviceSize = label.fontSize * pixelsPerPagePoint
            let bucket = GlyphAtlas.bucket(forDeviceSize: deviceSize)
            let atlas = glyphAtlases.atlas(fontName: label.fontName, deviceSize: deviceSize)
            let run = atlas.layout(label.text)
            guard !run.glyphs.isEmpty else { return nil }
            let dx = -run.width * label.anchor.horizontalFraction
            let dy = -run.height * label.anchor.verticalFraction
            // A label that turns with its object (a stamp's field text, T-065) is laid out
            // upright and turned about its anchor, in pixel space, by the angle its page
            // direction comes out at on screen. Every other label keeps step 0 and the exact
            // upright arithmetic below.
            let steps = label.rotationDegrees.map(pixelRotationSteps(pageDegrees:)) ?? 0
            let turn = Double(steps) * 2 * .pi / CompiledGlyph.rotationStepsPerTurn
            let cosine = Foundation.cos(turn), sine = Foundation.sin(turn)
            func turned(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
                steps == 0 ? (x, y) : (x * cosine - y * sine, x * sine + y * cosine)
            }
            compiled.glyphs = run.glyphs.map { glyph in
                let offset = turned(dx + glyph.x, dy + glyph.y)
                return CompiledGlyph(
                    anchor: label.anchorPoint,
                    offsetX: offset.x,
                    offsetY: offset.y,
                    widthPixels: Double(glyph.tile.width),
                    heightPixels: Double(glyph.tile.height),
                    tile: glyph.tile,
                    glyph: glyph.glyph,
                    color: color,
                    rotationSteps: steps
                )
            }
            compiled.glyphBucket = bucket
            compiled.glyphFontName = label.fontName
            // The label's real extent, so the selection ring and handles surround the text
            // instead of collapsing onto the anchor point (BH-625). The run is pixel-sized;
            // its (turned) corners go through the frame's own pixel-to-page map.
            inkBounds = pixelCornerBounds(
                anchor: label.anchorPoint,
                corners: [turned(dx, dy), turned(dx + run.width, dy),
                          turned(dx + run.width, dy + run.height), turned(dx, dy + run.height)]
            )

        case let .dimensionLine(dimension):
            guard let expanded = compileDimensionLine(dimension, style: markup.style) else {
                return nil
            }
            compiled.segments = expanded.segments
            compiled.triangles = expanded.triangles
            compiled.glyphs = expanded.glyphs
            compiled.glyphBucket = expanded.glyphBucket
            compiled.glyphFontName = expanded.glyphFontName
            inkBounds = expanded.inkBounds

        case let .labelPill(pill):
            guard pill.anchorPoint.isFinite, inRange(pill.anchorPoint) else { return nil }
            guard let textColor = markup.style.effectiveStroke ?? markup.style.effectiveFill else {
                return nil
            }
            guard let built = pillInstances(
                center: pill.anchorPoint,
                text: pill.text,
                fontName: pill.fontName,
                fontSizeViewPoints: pill.fontSizeViewPoints,
                pillFill: pill.pillFill,
                textColor: textColor,
                opacity: markup.style.opacity
            ) else { return nil }
            compiled.triangles = built.triangles
            compiled.glyphs = built.glyphs
            compiled.glyphBucket = built.glyphBucket
            compiled.glyphFontName = built.glyphFontName
            inkBounds = built.rect

        case let .image(image):
            // ADR-0043: the picture from its own pixels. Its three defining corners must be
            // usable and span an area; a degenerate box paints nothing and is rejected.
            let corners = image.corners
            guard corners.allSatisfy({ $0.isFinite && inRange($0) }) else { return nil }
            let ux = (image.xEnd.x - image.origin.x, image.xEnd.y - image.origin.y)
            let uy = (image.yEnd.x - image.origin.x, image.yEnd.y - image.origin.y)
            let area = ux.0 * uy.1 - ux.1 * uy.0
            guard area.isFinite, area != 0 else { return nil }
            if let pixels = RenderImagePixels.decode(image.source) {
                compiled.images = [CompiledImage(
                    origin: image.origin,
                    xEnd: image.xEnd,
                    yEnd: image.yEnd,
                    pixels: pixels,
                    opacity: image.opacity * (markup.style.opacity.isFinite ? markup.style.opacity : 1)
                )]
            } else {
                // Bytes that do not decode, or declare more than the import's bound: the frame,
                // so the placement is visibly there, and the missing picture is counted as a
                // rejected fill rather than lost silently (CR-80).
                compiled.fillRejected = true
                if markup.style.effectiveStroke != nil, markup.style.sanitizedLineWidth > 0 {
                    compiled.segments = strokeSegments(points: corners, isClosed: true, style: markup.style)
                }
            }
        }

        guard !compiled.isEmpty else { return nil }
        compiled.bounds = inkBounds ?? markup.geometryBounds
        compiled.dashTruncated = compiled.segments.contains { $0.dash.isTruncated }
        Self.applyInkPadding(to: &compiled)
        return compiled
    }

    /// The page-space bounding box of pixel-space points given as offsets from `anchor`.
    private func pixelCornerBounds(anchor: PDFPoint, corners: [(x: Double, y: Double)]) -> PDFRect? {
        var box = BoundsAccumulator()
        for corner in corners {
            box.add(PDFPoint(
                x: anchor.x + pixelToPage.a * corner.x + pixelToPage.c * corner.y,
                y: anchor.y + pixelToPage.b * corner.x + pixelToPage.d * corner.y
            ))
        }
        return box.rect
    }

    /// The pixel-space turn, in ``CompiledGlyph/rotationSteps``, of text whose baseline runs
    /// `pageDegrees` counter-clockwise from the page's +x axis: the angle that page direction
    /// comes out at through this frame's page-to-pixel map, measured rather than assumed — the
    /// map is y-flipped and may carry the page's `/Rotate` and the view's turn, and each changes
    /// the sign or adds a quarter turn. The canvas reads the angle off the stamp's transformed
    /// x axis the same way.
    func pixelRotationSteps(pageDegrees: Double) -> UInt16 {
        guard pageDegrees.isFinite else { return 0 }
        let determinant = pixelToPage.a * pixelToPage.d - pixelToPage.b * pixelToPage.c
        guard determinant.isFinite, determinant != 0 else { return 0 }
        let radians = pageDegrees * .pi / 180
        let (ux, uy) = (Foundation.cos(radians), Foundation.sin(radians))
        // The page-to-pixel linear map is the inverse of the pixel-to-page one.
        let px = (pixelToPage.d * ux - pixelToPage.c * uy) / determinant
        let py = (-pixelToPage.b * ux + pixelToPage.a * uy) / determinant
        return CompiledGlyph.rotationSteps(forPixelRadians: Foundation.atan2(py, px))
    }

    /// Records how far the painted ink can reach beyond the geometry bounds, so the culler can
    /// treat "outside the viewport" as a statement about pixels rather than centrelines.
    ///
    /// Every constant here is an upper bound, deliberately generous by a pixel or two: padding
    /// that is too large only shrinks the culling win at the margin, while padding that is too
    /// small would change rendered pixels, which culling must never do.
    private static func applyInkPadding(to compiled: inout CompiledMarkup) {
        var pagePoints = 0.0
        var devicePixels = 0.0
        if !compiled.segments.isEmpty {
            // The full nominal width covers half of it on each side of the centreline plus a
            // square cap's diagonal reach past an endpoint. The one-pixel stroke floor and the
            // analytic feather are pixel quantities.
            for segment in compiled.segments {
                pagePoints = Swift.max(pagePoints, segment.widthPagePoints)
            }
            devicePixels = Swift.max(devicePixels, 2.5)
        }
        if !compiled.triangles.isEmpty || !compiled.images.isEmpty {
            // Triangles never paint outside their vertices; MSAA resolve stays within a pixel.
            // A picture fills its parallelogram, which the bounds hold, plus its edge feather.
            devicePixels = Swift.max(devicePixels, 1.5)
        }
        var symbolReach = 0.0
        if !compiled.symbols.isEmpty {
            // The quad is `size` page points centred on `center`, which the geometry bounds
            // already contain; only edge antialiasing remains.
            devicePixels = Swift.max(devicePixels, 2.0)
            for symbol in compiled.symbols where symbol.sizePagePoints > 0 {
                let radians = symbol.rotationDegrees * .pi / 180
                let turn = Swift.abs(Foundation.cos(radians)) + Swift.abs(Foundation.sin(radians))
                symbolReach = Swift.max(symbolReach, symbol.sizePagePoints / 2 * turn)
            }
        }
        var glyphReach = 0.0
        for glyph in compiled.glyphs {
            // Glyph quads are pixel-sized offsets from an anchor whose bounds are a point. A
            // turned quad (a stamp's text, T-065) reaches as far as its farthest turned corner.
            let reach = glyph.rotationSteps == 0
                ? Swift.max(
                    Swift.max(Swift.abs(glyph.offsetX), Swift.abs(glyph.offsetX + glyph.widthPixels)),
                    Swift.max(Swift.abs(glyph.offsetY), Swift.abs(glyph.offsetY + glyph.heightPixels))
                )
                : glyph.cornerOffsets.reduce(0.0) { Swift.max($0, Swift.abs($1.x), Swift.abs($1.y)) }
            glyphReach = Swift.max(glyphReach, reach)
            // +1 for the whole-pixel anchor quantisation, +1.5 slack.
            devicePixels = Swift.max(devicePixels, reach + 2.5)
        }
        compiled.paddingPagePoints = pagePoints
        compiled.paddingDevicePixels = devicePixels
        // Precomputed here so a hit test's cheap reject is two reads, not a pass over every
        // instance of every markup (IM-083).
        compiled.symbolReachPagePoints = symbolReach
        compiled.glyphReachPixels = glyphReach
    }

    // MARK: - Stroking

    /// Expands a point run into segments, giving every interior joint a round cap.
    ///
    /// Round joints are a choice, and it is the choice both backends make identically: a segment
    /// is one quad, and a round cap at each shared endpoint fills the wedge a miter would. A
    /// miter join would need a per-vertex bevel computation on the CPU and a per-instance miter
    /// limit on the GPU, and the two would round differently. This way the Core Graphics oracle
    /// strokes each segment as its own path with the same two caps, and the outputs coincide.
    private func strokeSegments(
        points: [PDFPoint],
        isClosed: Bool,
        style: RenderStyle
    ) -> [CompiledSegment] {
        guard let color = style.effectiveStroke else { return [] }
        let width = style.sanitizedLineWidth
        guard width > 0 else { return [] }
        let count = points.count
        guard count >= 2 else { return [] }
        let segmentCount = isClosed ? count : count - 1
        guard segmentCount >= 1 else { return [] }

        let dash = DashPattern(style.dash)
        var segments: [CompiledSegment] = []
        segments.reserveCapacity(segmentCount)
        var travelled = 0.0
        for index in 0..<segmentCount {
            let start = points[index]
            let end = points[(index + 1) % count]
            let isFirst = index == 0
            let isLast = index == segmentCount - 1
            let startCap: RenderCap = (isFirst && !isClosed) ? style.startCap : .round
            let endCap: RenderCap = (isLast && !isClosed) ? style.endCap : .round
            segments.append(CompiledSegment(
                start: start,
                end: end,
                widthPagePoints: width,
                color: color,
                startCap: startCap,
                endCap: endCap,
                dash: dash,
                dashOffsetPagePoints: travelled
            ))
            travelled += start.distance(to: end)
        }
        return segments
    }

    // MARK: - The measurement grammar

    /// Metrics of the dimension grammar that are not per-markup knobs, in view points.
    /// Public so the test suite can assert against the same numbers it draws with.
    public enum DimensionGrammar {
        /// Horizontal padding between the pill text and the pill edge.
        public static let pillPaddingXViewPoints: Double = 6
        /// Vertical padding between the pill text and the pill edge.
        public static let pillPaddingYViewPoints: Double = 3
        /// Clear space kept between the shaft and the pill edge.
        public static let pillClearanceViewPoints: Double = 2
        /// Steps per quarter arc of the pill corner. 6 gives facets under half a view point
        /// at every corner radius the grammar produces.
        public static let cornerSteps = 6
        /// An arrowhead never takes more than this fraction of the measured span, so a short
        /// dimension keeps a visible shaft and the two arrows never cross each other.
        public static let maximumArrowFractionOfSpan = 1.0 / 3.0
    }

    private struct CompiledDimension {
        var segments: [CompiledSegment] = []
        var triangles: [CompiledTriangle] = []
        var glyphs: [CompiledGlyph] = []
        var glyphBucket: Int?
        var glyphFontName: String?
        var inkBounds: PDFRect?
    }

    private struct CompiledPill {
        var triangles: [CompiledTriangle]
        var glyphs: [CompiledGlyph]
        var glyphBucket: Int
        var glyphFontName: String
        /// The pill's page-space box: the bounding box of its contour, which is screen-upright
        /// and so turned in page space on a `/Rotate` sheet (U-077).
        var rect: PDFRect
        /// Half extents of ``rect``, for the shaft gap computation.
        var halfWidth: Double
        var halfHeight: Double
    }

    /// Expands one committed length into the visual reference's dimension grammar. The measured endpoints
    /// are the arrow **tips**; every decoration size is view points times
    /// ``pagePointsPerViewPoint``, so the grammar stays legible at every zoom without ever
    /// moving the measured points.
    private func compileDimensionLine(
        _ dimension: RenderDimensionLine,
        style: RenderStyle
    ) -> CompiledDimension? {
        guard dimension.start.isFinite, dimension.end.isFinite,
              inRange(dimension.start), inRange(dimension.end)
        else { return nil }
        guard let color = style.effectiveStroke else { return nil }
        let width = style.sanitizedLineWidth
        guard width > 0 else { return nil }

        let dx = dimension.end.x - dimension.start.x
        let dy = dimension.end.y - dimension.start.y
        let span = (dx * dx + dy * dy).squareRoot()
        guard span.isFinite, span > 1e-9 else { return nil }
        let ux = dx / span, uy = dy / span
        let nx = -uy, ny = ux

        let vp = pagePointsPerViewPoint
        let arrowLength = Swift.min(
            Swift.max(dimension.arrowLengthViewPoints, 0) * vp,
            span * DimensionGrammar.maximumArrowFractionOfSpan
        )
        let arrowHalfWidth = Swift.max(dimension.arrowHalfWidthViewPoints, 0) * vp
        let tickHalf = Swift.max(dimension.tickLengthViewPoints, 0) * vp / 2

        var out = CompiledDimension()
        var bounds = BoundsAccumulator()
        bounds.add(dimension.start)
        bounds.add(dimension.end)

        func segment(_ from: PDFPoint, _ to: PDFPoint) -> CompiledSegment {
            bounds.add(from); bounds.add(to)
            return CompiledSegment(
                start: from,
                end: to,
                widthPagePoints: width,
                color: color,
                // Butt caps: a round cap would push ink past the measured point by half a
                // stroke width, and the tips are a statement about geometry.
                startCap: .butt,
                endCap: .butt,
                dash: DashPattern(.solid),
                dashOffsetPagePoints: 0
            )
        }

        // Arrowheads, tips exactly on the measured points, bases toward the middle.
        if arrowLength > 0, arrowHalfWidth > 0 {
            let heads: [(tip: PDFPoint, inward: (Double, Double))] = [
                (dimension.start, (ux, uy)),
                (dimension.end, (-ux, -uy))
            ]
            for head in heads {
                let baseX = head.tip.x + head.inward.0 * arrowLength
                let baseY = head.tip.y + head.inward.1 * arrowLength
                let left = PDFPoint(x: baseX + nx * arrowHalfWidth, y: baseY + ny * arrowHalfWidth)
                let right = PDFPoint(x: baseX - nx * arrowHalfWidth, y: baseY - ny * arrowHalfWidth)
                bounds.add(left); bounds.add(right)
                out.triangles.append(CompiledTriangle(a: head.tip, b: left, c: right, color: color))
            }
        }

        // Extension ticks: one perpendicular stroke through each measured point.
        if tickHalf > 0 {
            for point in [dimension.start, dimension.end] {
                out.segments.append(segment(
                    PDFPoint(x: point.x - nx * tickHalf, y: point.y - ny * tickHalf),
                    PDFPoint(x: point.x + nx * tickHalf, y: point.y + ny * tickHalf)
                ))
            }
        }

        // The pill, on the line at its midpoint.
        let mid = PDFPoint(
            x: (dimension.start.x + dimension.end.x) / 2,
            y: (dimension.start.y + dimension.end.y) / 2
        )
        var pill: CompiledPill?
        if let textColor = style.effectiveStroke {
            pill = pillInstances(
                center: mid,
                text: dimension.label,
                fontName: dimension.fontName,
                fontSizeViewPoints: dimension.fontSizeViewPoints,
                pillFill: dimension.pillFill,
                textColor: textColor,
                opacity: style.opacity
            )
        }

        // The shaft. When the pill sits on the line, the shaft stops at the pill's edge on
        // both sides — the value is part of the line, not struck through by it.
        if let pill {
            out.triangles.append(contentsOf: pill.triangles)
            out.glyphs = pill.glyphs
            out.glyphBucket = pill.glyphBucket
            out.glyphFontName = pill.glyphFontName
            bounds.add(PDFPoint(x: pill.rect.minX, y: pill.rect.minY))
            bounds.add(PDFPoint(x: pill.rect.maxX, y: pill.rect.maxY))

            // Where a ray from the midpoint along the shaft leaves the pill's box.
            let epsilon = 1e-12
            var exit = Double.infinity
            if Swift.abs(ux) > epsilon { exit = Swift.min(exit, pill.halfWidth / Swift.abs(ux)) }
            if Swift.abs(uy) > epsilon { exit = Swift.min(exit, pill.halfHeight / Swift.abs(uy)) }
            let gap = exit.isFinite
                ? exit + DimensionGrammar.pillClearanceViewPoints * vp
                : 0
            let half = span / 2
            if gap > 0, half > gap {
                out.segments.append(segment(
                    dimension.start,
                    PDFPoint(x: mid.x - ux * gap, y: mid.y - uy * gap)
                ))
                out.segments.append(segment(
                    PDFPoint(x: mid.x + ux * gap, y: mid.y + uy * gap),
                    dimension.end
                ))
            }
            // A pill wider than the whole span swallows the shaft; the tips are still marked
            // by the arrowheads and ticks, which is the honest rendering of a dimension too
            // short for its own label.
        } else {
            out.segments.append(segment(dimension.start, dimension.end))
        }

        out.inkBounds = bounds.rect
        return out
    }

    /// Builds one rounded dark pill with its text, centred on `center`. Returns `nil` for an
    /// empty run — a pill with nothing to say is not drawn.
    private func pillInstances(
        center: PDFPoint,
        text: String,
        fontName: String,
        fontSizeViewPoints: Double,
        pillFill: RGBAColor?,
        textColor: RGBAColor,
        opacity: Double
    ) -> CompiledPill? {
        guard fontSizeViewPoints.isFinite, fontSizeViewPoints > 0 else { return nil }
        let vp = pagePointsPerViewPoint
        // View points to device pixels: the backing scale, recovered from the two ratios the
        // compiler carries. Constant across zoom, so the glyph bucket is stable while panning
        // and zooming and only the page-space pill is recompiled.
        let pixelsPerViewPoint = pixelsPerPagePoint * vp
        let deviceSize = fontSizeViewPoints * pixelsPerViewPoint
        guard deviceSize.isFinite, deviceSize > 0 else { return nil }

        let bucket = GlyphAtlas.bucket(forDeviceSize: deviceSize)
        let atlas = glyphAtlases.atlas(fontName: fontName, deviceSize: deviceSize)
        let run = atlas.layout(text)
        guard !run.glyphs.isEmpty, pixelsPerPagePoint > 0 else { return nil }

        // The pill is measured where its text is laid out: in device pixels, screen-upright
        // (U-077). Its glyphs are pixel offsets from the anchor, so on a `/Rotate 90` or `270`
        // sheet the text runs across the page's y axis; a contour measured along page x came out
        // tall and narrow under text running across it.
        let halfWidthPixels = run.width / 2 + DimensionGrammar.pillPaddingXViewPoints * pixelsPerViewPoint
        let halfHeightPixels = run.height / 2 + DimensionGrammar.pillPaddingYViewPoints * pixelsPerViewPoint
        guard halfWidthPixels.isFinite, halfHeightPixels.isFinite, halfWidthPixels > 0, halfHeightPixels > 0 else {
            return nil
        }

        var fill = pillFill ?? RenderShape.defaultPillFill
        let clampedOpacity = opacity.isFinite ? Swift.min(1, Swift.max(0, opacity)) : 0
        fill = fill.clampedToUnitRange()
        fill.alpha *= clampedOpacity

        // The rounded-rect contour, fanned into triangles from its first vertex. The contour
        // is convex, so the fan is exact; both backends draw the same triangle list, so there
        // is nothing for them to disagree about. It is built in screen axes — x right, y up,
        // in pixels — and each vertex goes to page space through the frame's own pixel-to-page
        // map, as a text label's selection box does: screen right is that map's x column and
        // screen up its negated y column. On an upright page that is the page-axis rectangle
        // it always was.
        let local = Self.roundedRectContour(
            center: PDFPoint(x: 0, y: 0),
            halfWidth: halfWidthPixels,
            halfHeight: halfHeightPixels,
            radius: Swift.min(halfHeightPixels, halfWidthPixels)
        )
        let contour = local.map { vertex in
            PDFPoint(
                x: center.x + pixelToPage.a * vertex.x - pixelToPage.c * vertex.y,
                y: center.y + pixelToPage.b * vertex.x - pixelToPage.d * vertex.y
            )
        }
        var box = BoundsAccumulator()
        for vertex in contour { box.add(vertex) }
        guard let rect = box.rect, rect.width > 0, rect.height > 0 else { return nil }
        var triangles: [CompiledTriangle] = []
        if fill.alpha > 0 {
            triangles.reserveCapacity(contour.count - 2)
            for index in 1..<(contour.count - 1) {
                triangles.append(CompiledTriangle(
                    a: contour[0],
                    b: contour[index],
                    c: contour[index + 1],
                    color: fill
                ))
            }
        }

        let dx = -run.width / 2
        let dy = -run.height / 2
        let glyphs = run.glyphs.map { glyph in
            CompiledGlyph(
                anchor: center,
                offsetX: dx + glyph.x,
                offsetY: dy + glyph.y,
                widthPixels: Double(glyph.tile.width),
                heightPixels: Double(glyph.tile.height),
                tile: glyph.tile,
                glyph: glyph.glyph,
                color: textColor
            )
        }

        return CompiledPill(
            triangles: triangles,
            glyphs: glyphs,
            glyphBucket: bucket,
            glyphFontName: fontName,
            rect: rect,
            halfWidth: Swift.max(center.x - rect.minX, rect.maxX - center.x),
            halfHeight: Swift.max(center.y - rect.minY, rect.maxY - center.y)
        )
    }

    /// The contour of a rounded rectangle, counter-clockwise in page space, starting at the
    /// right end of the bottom edge.
    public static func roundedRectContour(
        center: PDFPoint,
        halfWidth: Double,
        halfHeight: Double,
        radius: Double
    ) -> [PDFPoint] {
        let r = Swift.max(0, Swift.min(radius, Swift.min(halfWidth, halfHeight)))
        let steps = DimensionGrammar.cornerSteps
        // Corner centres, in counter-clockwise order starting bottom-right, with the angle
        // each quarter arc starts at.
        let corners: [(cx: Double, cy: Double, startAngle: Double)] = [
            (center.x + halfWidth - r, center.y - halfHeight + r, -Double.pi / 2),
            (center.x + halfWidth - r, center.y + halfHeight - r, 0),
            (center.x - halfWidth + r, center.y + halfHeight - r, Double.pi / 2),
            (center.x - halfWidth + r, center.y - halfHeight + r, Double.pi)
        ]
        var points: [PDFPoint] = []
        points.reserveCapacity(corners.count * (steps + 1))
        for corner in corners {
            for step in 0...steps {
                let angle = corner.startAngle + Double.pi / 2 * Double(step) / Double(steps)
                points.append(PDFPoint(
                    x: corner.cx + r * Foundation.cos(angle),
                    y: corner.cy + r * Foundation.sin(angle)
                ))
            }
        }
        return points
    }

    /// Running min/max box over page points.
    private struct BoundsAccumulator {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var seen = false

        mutating func add(_ point: PDFPoint) {
            guard point.isFinite else { return }
            seen = true
            minX = Swift.min(minX, point.x); maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y); maxY = Swift.max(maxY, point.y)
        }

        var rect: PDFRect? {
            guard seen else { return nil }
            return PDFRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    // MARK: - Validation

    private func inRange(_ point: PDFPoint) -> Bool {
        Swift.abs(point.x) <= RenderLimits.coordinateMagnitudeBound
            && Swift.abs(point.y) <= RenderLimits.coordinateMagnitudeBound
    }

    /// Rejects the whole contour when any vertex is unusable — a partially drawn markup is a lie
    /// about geometry, so the renderer would rather draw nothing and say so.
    private func validated(_ points: [PDFPoint]) -> [PDFPoint]? {
        guard points.count <= RenderLimits.maximumContourVertices else { return nil }
        var out: [PDFPoint] = []
        out.reserveCapacity(points.count)
        for point in points {
            guard point.isFinite, inRange(point) else { return nil }
            if let last = out.last, last == point { continue }
            out.append(point)
        }
        return out
    }
}
