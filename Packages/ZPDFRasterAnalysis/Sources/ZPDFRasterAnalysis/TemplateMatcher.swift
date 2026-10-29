import Accelerate
import CoreGraphics
import Foundation

/// A boxed symbol found again on a scanned sheet (NL-AUTO-14, track b): normalised
/// cross-correlation of the example over the page picture, at the four right angles and their
/// mirrors.
///
/// # How
///
/// 1. **Coarse.** Both pictures are shrunk so the example is about 16 pixels on its longer side.
///    Only windows whose amount of ink is within a third of the example's are scored (most of a
///    plan is paper), and each is scored by normalised cross-correlation — which is blind to
///    brightness and contrast, so a lighter scan still matches. The page is scored a tile at a
///    time (X-050), so an example too small to shrink never puts the whole page in memory as
///    floats and summed-area tables.
/// 2. **Fine.** Around every coarse peak the score is recomputed at full resolution, a few pixels
///    either way, and a match is kept only at or above the threshold.
/// 3. **One per place.** Matches closer than half the example's size are one match (the best).
///
/// Every match carries its score, so the review can show how sure it is; the caller marks each
/// "from the scan" (`CaptureMethod.fromScan`, ADR-0031) and commits only what a person accepts.
public enum TemplateMatcher {

    public struct Match: Sendable, Hashable {
        /// The match's centre, in page space.
        public let center: CGPoint
        /// Normalised cross-correlation, `−1…1`; `1` is the example itself.
        public let score: Double
        /// Clockwise quarter turns of the example that matched.
        public let quarterTurns: Int
        public let mirrored: Bool
    }

    public struct Options: Sendable, Hashable {
        public var threshold: Double
        public var coarseTemplateSide: Int
        public var maximumMatches: Int
        public var inkTolerance: Double

        public init(threshold: Double = 0.7, coarseTemplateSide: Int = 16, maximumMatches: Int = 1_000, inkTolerance: Double = 0.35) {
            self.threshold = threshold
            self.coarseTemplateSide = coarseTemplateSide
            self.maximumMatches = maximumMatches
            self.inkTolerance = inkTolerance
        }

        public static let standard = Options()
    }

    /// Every place `example` appears in `image`.
    public static func matches(of example: GrayRaster, in image: GrayRaster, options: Options = .standard) -> [Match] {
        var statistics = CoarsePassStatistics()
        return matches(of: example, in: image, options: options, statistics: &statistics)
    }

    /// What the coarse pass built, for tests (X-050).
    struct CoarsePassStatistics: Sendable, Equatable {
        var factor = 0
        var tiles = 0
        /// The most pixels one coarse picture held.
        var largestPicturePixels = 0
        /// The most window scores one coarse tile held for one orientation.
        var largestScoreCount = 0
    }

    /// Window origins one coarse tile owns along each side (X-050).
    static let coarseTileSide = 1_024

    /// ``matches(of:in:options:)``, reporting what its coarse pass built.
    static func matches(
        of example: GrayRaster, in image: GrayRaster, options: Options, tileSide: Int = coarseTileSide,
        statistics: inout CoarsePassStatistics
    ) -> [Match] {
        let longSide = max(example.width, example.height)
        // Keep at least two coarse pixels across the short side (S-114). An elongated symbol
        // (above about 8:1) shrunk by the long side alone collapses to one coarse row; a thin
        // stroke on the page that straddles a block boundary then splits its ink over two coarse
        // rows, no one-row window holds enough of it to pass the ink filter, and the match is
        // lost — the example's own stroke included.
        let shortSide = min(example.width, example.height)
        let factor = max(1, min(longSide / max(4, options.coarseTemplateSide), shortSide / 2))
        statistics.factor = factor
        var orientations: [(picture: GrayRaster, turns: Int, mirrored: Bool)] = []
        for mirrored in [false, true] {
            var picture = mirrored ? example.mirrored() : example
            for turns in 0..<4 {
                if !orientations.contains(where: { $0.picture.pixels == picture.pixels && $0.picture.width == picture.width }) {
                    orientations.append((picture, turns, mirrored))
                }
                picture = picture.rotatedClockwise()
            }
        }
        // X-050: the coarse page is scored over tiles. It used to be one picture of the whole page,
        // and an example under 32 pixels on its long side (a 3.5 mm symbol on a 30 MP scan) has
        // factor 1, so that picture was the page at full resolution — 20 bytes a pixel, about
        // 600 MB at 30 MP — with a score grid of 8 bytes a pixel on top, the allocation W-096
        // took out of the refinement. A tile is at most (1 024 + 1 + the example's side)² pixels.
        let coarsePeaks = coarsePeaks(
            in: image.downsampled(by: factor),
            of: orientations.map { FloatPicture($0.picture.downsampled(by: factor)) },
            minimumScore: options.threshold - 0.2, inkTolerance: options.inkTolerance,
            tileSide: tileSide, statistics: &statistics
        )
        var found: [Match] = []
        for (index, orientation) in orientations.enumerated() {
            let fullTemplate = FloatPicture(orientation.picture)
            let templateStatistics = fullTemplate.statistics
            for peak in coarsePeaks[index] {
                // Refine at full resolution around the coarse peak, on a picture of only the
                // pixels the refinement can read (W-096). The whole page used to be built at full
                // resolution, about 20 bytes a pixel (600 MB for a 30 MP scan), on every page
                // and before the coarse pass had found anything, for these few windows.
                let cx = peak.x * factor, cy = peak.y * factor
                guard let window = FloatPicture.refinementWindow(
                    of: image, around: (cx, cy), reach: factor, template: fullTemplate
                ) else { continue }
                var best: (score: Double, x: Int, y: Int)?
                for y in (cy - factor)...(cy + factor) {
                    for x in (cx - factor)...(cx + factor) {
                        guard let score = window.picture.ncc(
                            of: fullTemplate, atX: x - window.originX, y: y - window.originY,
                            templateStatistics: templateStatistics
                        ), score > (best?.score ?? -2) else { continue }
                        best = (score, x, y)
                    }
                }
                guard let best, best.score >= options.threshold else { continue }
                let center = image.pagePoint(x: Double(best.x) + Double(fullTemplate.width) / 2, y: Double(best.y) + Double(fullTemplate.height) / 2)
                found.append(Match(center: center, score: best.score, quarterTurns: orientation.turns, mirrored: orientation.mirrored))
            }
        }
        // One match per place: the best within half the example's size.
        let radius = Double(min(example.width, example.height)) * image.pointsPerPixel / 2
        var kept: [Match] = []
        for match in found.sorted(by: { $0.score > $1.score }) {
            guard !kept.contains(where: { hypot($0.center.x - match.center.x, $0.center.y - match.center.y) < radius }) else { continue }
            kept.append(match)
            if kept.count >= options.maximumMatches { break }
        }
        return kept.sorted { ($0.center.y, $0.center.x) > ($1.center.y, $1.center.x) }
    }

    /// Every template's coarse peaks on `image`, scored a tile at a time (X-050), in the order one
    /// pass over the whole picture finds them: row by row.
    ///
    /// A tile owns the window origins in its `tileSide`² square. Its picture holds the pixels the
    /// windows at those origins read, plus one origin more on every side for the neighbour test,
    /// so every score and every peak decision is the one the whole picture makes: a window's sum
    /// and sum of squares are the same whole numbers read from a smaller table, its dot products
    /// run over the same rows, and an origin that is off the page is off the tile's picture too.
    static func coarsePeaks(
        in image: GrayRaster, of templates: [FloatPicture], minimumScore: Double, inkTolerance: Double,
        tileSide: Int, statistics: inout CoarsePassStatistics
    ) -> [[(x: Int, y: Int, score: Double)]] {
        var result = [[(x: Int, y: Int, score: Double)]](repeating: [], count: templates.count)
        let reach = templates.map { max($0.width, $0.height) }.max() ?? 0
        let side = max(1, tileSide)
        for ty0 in stride(from: 0, to: image.height, by: side) {
            let ty1 = min(image.height, ty0 + side)
            for tx0 in stride(from: 0, to: image.width, by: side) {
                let tx1 = min(image.width, tx0 + side)
                let x0 = max(0, tx0 - 1), y0 = max(0, ty0 - 1)
                let picture = FloatPicture(
                    region: image, x0: x0, y0: y0, x1: min(image.width, tx1 + reach), y1: min(image.height, ty1 + reach)
                )
                statistics.tiles += 1
                statistics.largestPicturePixels = max(statistics.largestPicturePixels, picture.width * picture.height)
                for (index, template) in templates.enumerated() {
                    var scoreCount = 0
                    let peaks = picture.peaks(
                        of: template, minimumScore: minimumScore, inkTolerance: inkTolerance,
                        ownedX: (tx0 - x0)..<(tx1 - x0), ownedY: (ty0 - y0)..<(ty1 - y0), scoreCount: &scoreCount
                    )
                    statistics.largestScoreCount = max(statistics.largestScoreCount, scoreCount)
                    result[index].append(contentsOf: peaks.map { (x: $0.x + x0, y: $0.y + y0, score: $0.score) })
                }
            }
        }
        return result.map { peaks in peaks.sorted { ($0.y, $0.x) < ($1.y, $1.x) } }
    }
}

/// A picture as floats with its integral images, for scoring windows.
struct FloatPicture {
    let width: Int
    let height: Int
    let values: [Float]
    /// Summed-area tables of the values and their squares, (width + 1) × (height + 1).
    let sum: [Double]
    let squares: [Double]

    init(_ raster: GrayRaster) {
        self.init(width: raster.width, height: raster.height, values: raster.pixels.map { Float($0) })
    }

    /// The picture of the part of `image` that the full-resolution refinement around a coarse
    /// peak can read (W-096): every window whose top-left lies within `reach` pixels of `peak`,
    /// clamped to the image, so at most `(template.width + 2·reach) × (template.height + 2·reach)`
    /// pixels. `originX`/`originY` place it in the image.
    ///
    /// A window scores on it as it does on the whole image: its sum and sum of squares are the
    /// same whole numbers read from a smaller table, and its dot products run over the same rows.
    /// A window that runs past the image runs past this picture too, so it is refused exactly as
    /// before.
    static func refinementWindow(
        of image: GrayRaster, around peak: (x: Int, y: Int), reach: Int, template: FloatPicture
    ) -> (picture: FloatPicture, originX: Int, originY: Int)? {
        let x0 = max(0, peak.x - reach), y0 = max(0, peak.y - reach)
        let x1 = min(image.width, peak.x + reach + template.width)
        let y1 = min(image.height, peak.y + reach + template.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return (FloatPicture(region: image, x0: x0, y0: y0, x1: x1, y1: y1), x0, y0)
    }

    /// The picture of `image`'s pixels in `[x0, x1) × [y0, y1)`, which must lie inside it.
    init(region image: GrayRaster, x0: Int, y0: Int, x1: Int, y1: Int) {
        var values: [Float] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))
        for row in y0..<y1 {
            let start = row * image.width
            values.append(contentsOf: image.pixels[(start + x0)..<(start + x1)].lazy.map { Float($0) })
        }
        self.init(width: x1 - x0, height: y1 - y0, values: values)
    }

    private init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
        var sum = [Double](repeating: 0, count: (width + 1) * (height + 1))
        var squares = sum
        for y in 0..<height {
            var row = 0.0, rowSquares = 0.0
            for x in 0..<width {
                let v = Double(values[y * width + x])
                row += v
                rowSquares += v * v
                sum[(y + 1) * (width + 1) + x + 1] = sum[y * (width + 1) + x + 1] + row
                squares[(y + 1) * (width + 1) + x + 1] = squares[y * (width + 1) + x + 1] + rowSquares
            }
        }
        self.sum = sum
        self.squares = squares
    }

    func rect(_ table: [Double], x: Int, y: Int, w: Int, h: Int) -> Double {
        let stride = width + 1
        return table[(y + h) * stride + x + w] - table[y * stride + x + w] - table[(y + h) * stride + x] + table[y * stride + x]
    }

    /// The template's mean and the root of its sum of squared deviations.
    var statistics: (mean: Double, norm: Double) {
        let n = Double(width * height)
        let total = rect(sum, x: 0, y: 0, w: width, h: height)
        let totalSquares = rect(squares, x: 0, y: 0, w: width, h: height)
        return (total / n, max(0, totalSquares - total * total / n).squareRoot())
    }

    /// Normalised cross-correlation of `template` placed with its top-left at (x, y), or `nil`
    /// outside the picture or on a flat window.
    func ncc(of template: FloatPicture, atX x: Int, y: Int, templateStatistics: (mean: Double, norm: Double)? = nil) -> Double? {
        guard x >= 0, y >= 0, x + template.width <= width, y + template.height <= height else { return nil }
        let n = Double(template.width * template.height)
        let windowSum = rect(sum, x: x, y: y, w: template.width, h: template.height)
        let windowSquares = rect(squares, x: x, y: y, w: template.width, h: template.height)
        let windowNorm = max(0, windowSquares - windowSum * windowSum / n).squareRoot()
        let stats = templateStatistics ?? template.statistics
        guard windowNorm > 1e-6, stats.norm > 1e-6 else { return nil }
        var cross = 0.0
        values.withUnsafeBufferPointer { image in
            template.values.withUnsafeBufferPointer { tpl in
                for row in 0..<template.height {
                    var dot: Float = 0
                    vDSP_dotpr(image.baseAddress! + (y + row) * width + x, 1, tpl.baseAddress! + row * template.width, 1, &dot, vDSP_Length(template.width))
                    cross += Double(dot)
                }
            }
        }
        // Σ(T−t̄)(I−ī) = ΣTI − n·t̄·ī
        let numerator = cross - n * stats.mean * (windowSum / n)
        return numerator / (stats.norm * windowNorm)
    }

    /// Local maxima of the score over the picture, above `minimumScore`, scoring only windows
    /// whose ink is near the template's.
    func peaks(of template: FloatPicture, minimumScore: Double, inkTolerance: Double) -> [(x: Int, y: Int, score: Double)] {
        var scoreCount = 0
        return peaks(of: template, minimumScore: minimumScore, inkTolerance: inkTolerance,
                     ownedX: 0..<width, ownedY: 0..<height, scoreCount: &scoreCount)
    }

    /// ``peaks(of:minimumScore:inkTolerance:)`` among the window origins in `ownedX` × `ownedY`
    /// only (X-050). Scores are kept for those origins and the ring of neighbours around them,
    /// `scoreCount` of them, not for every origin of the picture.
    func peaks(
        of template: FloatPicture, minimumScore: Double, inkTolerance: Double,
        ownedX: Range<Int>, ownedY: Range<Int>, scoreCount: inout Int
    ) -> [(x: Int, y: Int, score: Double)] {
        guard template.width <= width, template.height <= height else { return [] }
        let stats = template.statistics
        let n = Double(template.width * template.height)
        let templateInk = n * 255 - template.rect(template.sum, x: 0, y: 0, w: template.width, h: template.height)
        let columns = width - template.width + 1, rows = height - template.height + 1
        let xs = max(0, ownedX.lowerBound)..<max(0, min(columns, ownedX.upperBound))
        let ys = max(0, ownedY.lowerBound)..<max(0, min(rows, ownedY.upperBound))
        guard !xs.isEmpty, !ys.isEmpty else { return [] }
        // The scored block: the owned origins and every neighbour the peak test reads.
        let sx = max(0, xs.lowerBound - 1), ex = min(columns, xs.upperBound + 1)
        let sy = max(0, ys.lowerBound - 1), ey = min(rows, ys.upperBound + 1)
        let stride = ex - sx
        var scores = [Double](repeating: -2, count: stride * (ey - sy))
        scoreCount = scores.count
        for y in sy..<ey {
            for x in sx..<ex {
                let ink = n * 255 - rect(sum, x: x, y: y, w: template.width, h: template.height)
                guard abs(ink - templateInk) <= inkTolerance * max(templateInk, 1) else { continue }
                if let score = ncc(of: template, atX: x, y: y, templateStatistics: stats) { scores[(y - sy) * stride + x - sx] = score }
            }
        }
        var result: [(Int, Int, Double)] = []
        for y in ys {
            for x in xs {
                let score = scores[(y - sy) * stride + x - sx]
                guard score >= minimumScore else { continue }
                var isPeak = true
                neighbours: for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                        if scores[(ny - sy) * stride + nx - sx] > score { isPeak = false; break neighbours }
                    }
                }
                if isPeak { result.append((x, y, score)) }
            }
        }
        return result
    }
}
