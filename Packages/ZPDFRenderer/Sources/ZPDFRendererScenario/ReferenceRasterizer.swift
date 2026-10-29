import Foundation
import ZPDFContracts
import ZPDFRenderer

/// An independent, deliberately slow coverage rasteriser, written to answer one question:
/// **was the first generation of the golden PNGs correct?**
///
/// # Why it exists
///
/// A golden suite that was seeded from the renderer's own output proves only that the renderer
/// still does what it did on the day the goldens were written — including whatever it did wrong.
/// `QUALITY_BAR` 2.6 states the rule for measurement fixtures: an expected value may never be
/// produced by the code under test. The same rule applies to a picture.
///
/// So this type re-derives, from the specification rather than from the code:
///
/// - the page-to-pixel transform, written out from the coordinate specification's crop
///   translation, the clockwise `/Rotate` quarter turn, the zoom and the flipped-view placement,
///   with no call into `PageCoordinateConverter` or `RenderTransform`;
/// - the even-odd fill rule, as a ray-crossing parity test over the **original contours**, with
///   no triangulation anywhere — which is what makes it a real check on the triangulator;
/// - the stroke as a distance field around the centreline with the documented cap shapes, and the
///   documented width floor `max(w · zoom · backingScale, 1)`;
/// - the dash scaling rule as stated in ``DashPattern``'s documentation, re-implemented from the
///   prose.
///
/// Coverage is estimated by 4x4 supersampling, so its own antialiasing is a box filter rather
/// than Core Graphics' exact-area filter. That is why the comparison is made on **mean coverage
/// per 16x16 tile** rather than per pixel: a box filter and an exact-area filter agree on the
/// integral over a tile to a fraction of a percent, and disagree on individual edge pixels by a
/// lot. A missing shape, a hole that is filled, a stroke at the wrong width, a dash at the wrong
/// scale, or a page rotated the wrong way all move the tile integral far outside that.
///
/// # What it does not cover
///
/// Count symbols and text glyphs. Both backends take those from the *same* ``AlphaBitmap`` atlas,
/// so an independent rasteriser of them would be an independent rasteriser of Core Text, which is
/// not the thing under test. Scenes containing them are verified by the closed-form ink checks in
/// `GoldenProvenanceTests` instead, and `verifiableScenes` lists exactly which scenes this type
/// is competent to judge.
public enum ReferenceRasterizer {

    /// Names of the golden scenes this rasteriser is competent to verify: those whose ink is
    /// entirely strokes and even-odd fills.
    public static let verifiableScenes: Set<String> = [
        "polygon-holes-1",
        "polygon-holes-2",
        "polygon-holes-3",
        "self-touching",
        "dashes-and-caps-zoom-005",
        "dashes-and-caps-zoom-100",
        "dashes-and-caps-zoom-800",
        "rotated-90",
        "rotated-180",
        "rotated-270",
        "cropped-offset-origin",
        "retina-hairlines",
        "stroke-angles",
        "dash-angles",
        "round-caps-and-corners",
        "translucent-overlap",
        // Imported artwork is strokes and even-odd fills and nothing else — that is the whole
        // point of compiling it rather than sampling it — so the independent oracle is
        // competent to judge all six zoom scenes.
        "artwork-vector-zoom-025",
        "artwork-vector-zoom-100",
        "artwork-vector-zoom-400",
        "artwork-raster-zoom-025",
        "artwork-raster-zoom-100",
        "artwork-raster-zoom-400"
    ]

    /// Subsamples per axis.
    public static let supersample = 4

    /// A coverage image: one `0...1` alpha per pixel.
    public struct Coverage: Sendable {
        public let width: Int
        public let height: Int
        public var alpha: [Double]

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
            self.alpha = [Double](repeating: 0, count: Swift.max(0, width * height))
        }

        /// Mean alpha over each `tile x tile` block, row major.
        public func tileMeans(tile: Int) -> (values: [Double], columns: Int, rows: Int) {
            let columns = (width + tile - 1) / tile
            let rows = (height + tile - 1) / tile
            var values = [Double](repeating: 0, count: columns * rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    var sum = 0.0
                    var samples = 0
                    for y in (row * tile)..<Swift.min(height, (row + 1) * tile) {
                        for x in (column * tile)..<Swift.min(width, (column + 1) * tile) {
                            sum += alpha[y * width + x]
                            samples += 1
                        }
                    }
                    values[row * columns + column] = samples > 0 ? sum / Double(samples) : 0
                }
            }
            return (values, columns, rows)
        }
    }

    /// The independent page-to-pixel map, re-derived from the specification.
    struct Transform {
        let cropMinX: Double, cropMinY: Double, cropWidth: Double, cropHeight: Double
        let rotation: PageRotation
        let zoom: Double, backingScale: Double
        let displayedHeightViewPoints: Double
        /// The viewport's anchor in view points: the top-left corner of the displayed page, which
        /// is negative once the canvas is scrolled past the page's own origin.
        let anchorX: Double, anchorY: Double

        init(page: PageDescriptor, zoom: Double, backingScale: Double, anchorX: Double, anchorY: Double) {
            let box = page.visibleBox
            cropMinX = box.minX
            cropMinY = box.minY
            cropWidth = box.width
            cropHeight = box.height
            rotation = page.rotation
            self.zoom = zoom
            self.backingScale = backingScale
            self.anchorX = anchorX
            self.anchorY = anchorY
            let rotated = page.rotatedVisibleSize
            displayedHeightViewPoints = rotated.height * zoom
        }

        func pixel(_ point: PDFPoint) -> (Double, Double) {
            let u0 = point.x - cropMinX
            let v0 = point.y - cropMinY
            let u: Double, v: Double
            switch rotation {
            case .degrees0: u = u0; v = v0
            case .degrees90: u = v0; v = cropWidth - u0
            case .degrees180: u = cropWidth - u0; v = cropHeight - v0
            case .degrees270: u = cropHeight - v0; v = u0
            }
            let sx = u * zoom
            let sy = v * zoom
            let viewY = displayedHeightViewPoints - sy
            return ((anchorX + sx) * backingScale, (anchorY + viewY) * backingScale)
        }

        var pixelsPerPagePoint: Double { zoom * backingScale }
    }

    /// Rasterises `scene`'s strokes and fills into a coverage image.
    public static func rasterize(_ scene: RenderScene) -> Coverage {
        let size = scene.viewport.pixelSize
        var coverage = Coverage(width: size.width, height: size.height)
        guard size.width > 0, size.height > 0 else { return coverage }
        let transform = Transform(
            page: scene.page,
            zoom: scene.viewport.zoom,
            backingScale: scene.viewport.backingScale,
            anchorX: Double(scene.viewport.layout.anchor.x),
            anchorY: Double(scene.viewport.layout.anchor.y)
        )

        let ordered = scene.markups
            .filter { !$0.isHidden }
            .compactMap(usable)
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
                return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            }

        // Category order, exactly as both backends draw: fills, then strokes.
        for markup in ordered {
            guard case let .filledPolygon(polygon) = markup.shape,
                  let fill = markup.style.effectiveFill
            else { continue }
            composeFill(polygon, alpha: fill.alpha, transform: transform, into: &coverage)
        }
        for markup in ordered {
            guard let stroke = markup.style.effectiveStroke, markup.style.sanitizedLineWidth > 0
            else { continue }
            switch markup.shape {
            case let .polyline(polyline):
                composeStroke(
                    points: polyline.points,
                    closed: polyline.isClosed,
                    style: markup.style,
                    alpha: stroke.alpha,
                    transform: transform,
                    into: &coverage
                )
            case let .filledPolygon(polygon):
                composeStroke(
                    points: polygon.outer,
                    closed: true,
                    style: markup.style,
                    alpha: stroke.alpha,
                    transform: transform,
                    into: &coverage
                )
                for hole in polygon.holes {
                    composeStroke(
                        points: hole,
                        closed: true,
                        style: markup.style,
                        alpha: stroke.alpha,
                        transform: transform,
                        into: &coverage
                    )
                }
            case .countSymbol, .textLabel, .dimensionLine, .labelPill, .image:
                // Atlas ink, composites carrying atlas ink, or a raster picture (ADR-0043). Scenes containing these are
                // outside `verifiableScenes` and are held by the closed-form ink checks and
                // the cross-backend equality instead.
                continue
            }
        }
        return coverage
    }

    // MARK: - Admission

    /// The markup as the renderer's documented admission rules leave it, or `nil` when they
    /// reject it — re-stated here from `RenderLimits` and `MarkupCompiler`'s contract, not called:
    ///
    /// - a contour with a non-finite vertex, a vertex past the coordinate bound, or more than
    ///   the vertex limit is unusable; consecutive duplicate vertices are one vertex;
    /// - a polyline needs two vertices and a polygon's outer contour three, or the markup is
    ///   rejected whole;
    /// - an unusable hole rejects the markup (BH-198); a hole of fewer than three vertices
    ///   encloses nothing and is skipped.
    ///
    /// Without this the oracle stroked a two-point polygon the renderer rejects (BH-638), put
    /// caps on a zero-length segment the renderer never emits (BH-639), and trapped on an
    /// infinite fill vertex (BH-641) — ink or crashes in the reference that a correct render
    /// cannot match.
    static func usable(_ markup: RenderableMarkup) -> RenderableMarkup? {
        func contour(_ points: [PDFPoint]) -> [PDFPoint]? {
            guard points.count <= RenderLimits.maximumContourVertices else { return nil }
            var out: [PDFPoint] = []
            for point in points {
                guard point.x.isFinite, point.y.isFinite,
                      abs(point.x) <= RenderLimits.coordinateMagnitudeBound,
                      abs(point.y) <= RenderLimits.coordinateMagnitudeBound
                else { return nil }
                if let last = out.last, last == point { continue }
                out.append(point)
            }
            return out
        }
        var copy = markup
        switch markup.shape {
        case let .polyline(line):
            guard let points = contour(line.points), points.count >= 2 else { return nil }
            copy.shape = .polyline(RenderPolyline(points: points, isClosed: line.isClosed))
        case let .filledPolygon(polygon):
            guard let outer = contour(polygon.outer), outer.count >= 3 else { return nil }
            var holes: [[PDFPoint]] = []
            for hole in polygon.holes {
                guard let cleaned = contour(hole) else { return nil }
                if cleaned.count >= 3 { holes.append(cleaned) }
            }
            copy.shape = .filledPolygon(RenderPolygon(outer: outer, holes: holes))
        case .countSymbol, .textLabel, .dimensionLine, .labelPill, .image:
            break
        }
        return copy
    }

    // MARK: - Fills

    private static func composeFill(
        _ polygon: RenderPolygon,
        alpha: Double,
        transform: Transform,
        into coverage: inout Coverage
    ) {
        var contours: [[(Double, Double)]] = []
        contours.append(polygon.outer.map(transform.pixel))
        for hole in polygon.holes { contours.append(hole.map(transform.pixel)) }
        guard let box = boundingBox(of: contours.flatMap { $0 }) else { return }
        forEachSubsample(box, coverage) { x, y, sampleX, sampleY, hits in
            var crossings = 0
            for contour in contours {
                crossings += rayCrossings(contour, sampleX, sampleY)
            }
            if crossings % 2 == 1 { hits += 1 }
            _ = x; _ = y
        } commit: { index, fraction in
            let contribution = alpha * fraction
            coverage.alpha[index] += contribution * (1 - coverage.alpha[index])
        }
    }

    /// Ray-crossing count for one contour, casting in +x. Even-odd parity over all contours is
    /// what makes a hole a hole, with no winding and no triangulation involved.
    private static func rayCrossings(_ contour: [(Double, Double)], _ x: Double, _ y: Double) -> Int {
        guard contour.count >= 3 else { return 0 }
        var crossings = 0
        for index in contour.indices {
            let a = contour[index]
            let b = contour[(index + 1) % contour.count]
            guard (a.1 > y) != (b.1 > y) else { continue }
            let t = (y - a.1) / (b.1 - a.1)
            let crossX = a.0 + t * (b.0 - a.0)
            if crossX > x { crossings += 1 }
        }
        return crossings
    }

    // MARK: - Strokes

    private static func composeStroke(
        points: [PDFPoint],
        closed: Bool,
        style: RenderStyle,
        alpha: Double,
        transform: Transform,
        into coverage: inout Coverage
    ) {
        let clean = points.filter(\.isFinite)
        guard clean.count >= 2 else { return }
        let pixels = clean.map(transform.pixel)
        let count = pixels.count
        let segmentCount = closed ? count : count - 1
        guard segmentCount >= 1 else { return }

        // The documented width policy, re-derived: nominal width in device pixels, floored at one
        // pixel so a hairline stays legible, ceiling at 4096.
        let width = Swift.min(
            4096.0,
            Swift.max(1.0, style.sanitizedLineWidth * transform.pixelsPerPagePoint)
        )
        let half = width / 2

        var runsPixels: [Double] = []
        var phasePixels = 0.0
        var scale = transform.pixelsPerPagePoint
        if let rule = dashRule(style: style, pixelsPerPagePoint: transform.pixelsPerPagePoint) {
            runsPixels = rule.runs.map { $0 * rule.scale }
            phasePixels = rule.phase * rule.scale
            scale = rule.scale
        }
        let period = runsPixels.reduce(0, +)

        var travelled = 0.0
        for index in 0..<segmentCount {
            let a = pixels[index]
            let b = pixels[(index + 1) % count]
            let isFirst = index == 0
            let isLast = index == segmentCount - 1
            // Core Graphics draws no cap on a stroke of one device pixel or less; the renderer
            // adopts that rule (see `RenderTransform.effectiveCap`) and so does the oracle.
            let thin = width <= 1.0
            let startCap: RenderCap = thin ? .butt : ((isFirst && !closed) ? style.startCap : .round)
            let endCap: RenderCap = thin ? .butt : ((isLast && !closed) ? style.endCap : .round)
            let dx = b.0 - a.0, dy = b.1 - a.1
            let length = (dx * dx + dy * dy).squareRoot()
            let segmentTravelled = travelled
            travelled += length / Swift.max(transform.pixelsPerPagePoint, 1e-12)

            guard length > 0 || startCap != .butt else { continue }
            let pad = half + 2
            let box = (
                minX: Swift.min(a.0, b.0) - pad,
                minY: Swift.min(a.1, b.1) - pad,
                maxX: Swift.max(a.0, b.0) + pad,
                maxY: Swift.max(a.1, b.1) + pad
            )
            let ux = length > 0 ? dx / length : 1
            let uy = length > 0 ? dy / length : 0
            // `segmentTravelled` is arc length in page points from the start of the polyline;
            // the dash rule scales it into pixels with the same single factor as the runs.
            // Scaled by the same factor as the runs: one rule, computed once (BH-640).
            let offsetPixels = period > 0 ? phasePixels + segmentTravelled * scale : 0

            forEachSubsample(box, coverage) { _, _, sampleX, sampleY, hits in
                let px = sampleX - a.0
                let py = sampleY - a.1
                let along = px * ux + py * uy
                let across = Swift.abs(-px * uy + py * ux)

                // The specification, re-derived: the ink is a band of half-width `half` about the
                // centreline; past each end the cap decides how far it reaches; a dash is the
                // same band restricted to the pattern's on-runs, and Core Graphics caps every
                // dash with the path's line cap, so each on-run's ends are capped too.
                var segmentOvershoot = 0.0
                var segmentCap = endCap
                if along < 0 {
                    segmentOvershoot = -along
                    segmentCap = startCap
                } else if along > length {
                    segmentOvershoot = along - length
                    segmentCap = endCap
                }

                let onPath = Swift.min(Swift.max(along, 0), length)
                var dashOvershoot = 0.0
                let dashCap: RenderCap = onPath < length / 2 ? startCap : endCap
                if period > 0 {
                    var position = (onPath + offsetPixels).truncatingRemainder(dividingBy: period)
                    if position < 0 { position += period }
                    var accumulated = 0.0
                    for (runIndex, run) in runsPixels.enumerated() {
                        if position < accumulated + run {
                            if runIndex % 2 == 1 {
                                let behind = position - accumulated
                                let ahead = (accumulated + run) - position
                                dashOvershoot = Swift.min(behind, ahead)
                            }
                            break
                        }
                        accumulated += run
                    }
                }

                let overshoot = segmentOvershoot + dashOvershoot
                let cap = segmentOvershoot > 0 ? segmentCap : dashCap
                let distance = overshoot <= 0
                    ? Swift.abs(across)
                    : capDistance(overshoot, across, half, cap)
                if distance <= half { hits += 1 }
            } commit: { index, fraction in
                let contribution = alpha * fraction
                coverage.alpha[index] += contribution * (1 - coverage.alpha[index])
            }
        }
    }

    /// The documented dash rule, re-derived from `DashPattern`'s prose:
    ///
    /// - at most four runs are kept, an even number of them;
    /// - one scale factor for the whole pattern, `max(ppp, 1.5 / smallest)`, where `smallest` is
    ///   the smallest positive run that is not a **dot run** — an on-run shorter than 5 % of the
    ///   kept period, drawn by its caps (BH-624).
    ///
    /// The per-segment dash offset uses this same factor. It used to be recomputed from the whole
    /// run list, so a five-run pattern scaled its offsets by a different factor from its runs
    /// (BH-640).
    static func dashRule(
        style: RenderStyle,
        pixelsPerPagePoint ppp: Double
    ) -> (runs: [Double], phase: Double, scale: Double)? {
        guard case let .pattern(rawRuns, rawPhase) = style.dash.sanitized, rawRuns.count >= 2
        else { return nil }
        let runs = Array(rawRuns.prefix(rawRuns.count >= 4 ? 4 : 2))
        let period = runs.reduce(0, +)
        guard period > 0 else { return nil }
        var smallest = Double.infinity
        for (index, run) in runs.enumerated() where run > 0 {
            if index % 2 == 0, run < 0.05 * period { continue }
            smallest = Swift.min(smallest, run)
        }
        let scale = smallest.isFinite ? Swift.max(ppp, 1.5 / smallest) : ppp
        return (runs, rawPhase, scale)
    }

    private static func capDistance(
        _ overshoot: Double,
        _ across: Double,
        _ half: Double,
        _ cap: RenderCap
    ) -> Double {
        guard overshoot > 0 else { return Swift.abs(across) }
        switch cap {
        case .round: return (overshoot * overshoot + across * across).squareRoot()
        case .square: return Swift.max(Swift.abs(across), overshoot)
        case .butt: return Swift.max(Swift.abs(across), half + overshoot)
        }
    }

    // MARK: - Sampling

    private static func boundingBox(
        of points: [(Double, Double)]
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard !points.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = Swift.min(minX, point.0); maxX = Swift.max(maxX, point.0)
            minY = Swift.min(minY, point.1); maxY = Swift.max(maxY, point.1)
        }
        return (minX - 2, minY - 2, maxX + 2, maxY + 2)
    }

    private static func forEachSubsample(
        _ box: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        _ coverage: Coverage,
        _ test: (Int, Int, Double, Double, inout Int) -> Void,
        commit: (Int, Double) -> Void
    ) {
        let step = 1.0 / Double(supersample)
        // Clamped in `Double` before any `Int` conversion, so no box can trap (BH-641).
        guard !box.minX.isNaN, !box.maxX.isNaN, !box.minY.isNaN, !box.maxY.isNaN else { return }
        let width = Double(coverage.width), height = Double(coverage.height)
        let x0 = Int(Swift.min(width, Swift.max(0, box.minX.rounded(.down))))
        let y0 = Int(Swift.min(height, Swift.max(0, box.minY.rounded(.down))))
        let x1 = Int(Swift.min(width - 1, Swift.max(-1, box.maxX.rounded(.up))))
        let y1 = Int(Swift.min(height - 1, Swift.max(-1, box.maxY.rounded(.up))))
        guard x0 <= x1, y0 <= y1 else { return }
        let total = Double(supersample * supersample)
        for y in y0...y1 {
            for x in x0...x1 {
                var hits = 0
                for subY in 0..<supersample {
                    let sampleY = Double(y) + (Double(subY) + 0.5) * step
                    for subX in 0..<supersample {
                        let sampleX = Double(x) + (Double(subX) + 0.5) * step
                        test(x, y, sampleX, sampleY, &hits)
                    }
                }
                guard hits > 0 else { continue }
                commit(y * coverage.width + x, Double(hits) / total)
            }
        }
    }
}
