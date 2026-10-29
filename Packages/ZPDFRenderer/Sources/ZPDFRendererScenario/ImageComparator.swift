import Foundation
import ImageIO
import ZPDFRenderer

// Golden-test infrastructure: it lives in this non-product target, next to the scenes it judges,
// so a shipping app that links `ZPDFRenderer` never links the comparator (X-041).

/// The verdict of a golden comparison, with every number it was based on.
public struct ImageComparison: Sendable, Hashable {
    public var matches: Bool
    /// Largest single-channel difference anywhere, `0...1`.
    public var maximumChannelDifference: Double
    /// Largest single-channel difference after a 3x3 box blur, `0...1`. This is the perceptual
    /// term: it forgives a one-pixel antialiasing phase shift and forgives nothing wider.
    public var maximumBlurredDifference: Double
    /// Mean absolute channel difference over the whole image, `0...1`.
    public var meanChannelDifference: Double
    /// Fraction of pixels whose blurred difference exceeds ``ImageComparator/perceptualChannelTolerance``.
    public var differingPixelFraction: Double
    /// Largest difference in mean alpha coverage over any 16x16 tile, `0...1`. This is the
    /// structural term: a missing shape, an inverted fill rule or a mis-scaled dash all move a
    /// tile's mean coverage far more than antialiasing ever can.
    public var maximumTileCoverageDifference: Double
    /// The tile where ``maximumTileCoverageDifference`` occurred, in tile coordinates.
    public var worstTile: (x: Int, y: Int)
    /// Total ink (summed alpha) in each image, and their ratio.
    public var inkRatio: Double
    /// Why the comparison failed, empty when it passed.
    public var failureReasons: [String]

    public static func == (lhs: ImageComparison, rhs: ImageComparison) -> Bool {
        lhs.matches == rhs.matches
            && lhs.maximumChannelDifference == rhs.maximumChannelDifference
            && lhs.maximumBlurredDifference == rhs.maximumBlurredDifference
            && lhs.meanChannelDifference == rhs.meanChannelDifference
            && lhs.differingPixelFraction == rhs.differingPixelFraction
            && lhs.maximumTileCoverageDifference == rhs.maximumTileCoverageDifference
            && lhs.worstTile == rhs.worstTile
            && lhs.inkRatio == rhs.inkRatio
            && lhs.failureReasons == rhs.failureReasons
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(matches)
        hasher.combine(maximumBlurredDifference)
        hasher.combine(maximumTileCoverageDifference)
    }

    /// A one-line summary for a test failure message.
    public var summary: String {
        String(
            format:
                "maxΔ %.4f, blurredΔ %.4f, meanΔ %.5f, differing %.4f%%, worst tile (%d,%d) Δcov %.4f, ink ratio %.5f",
            maximumChannelDifference,
            maximumBlurredDifference,
            meanChannelDifference,
            differingPixelFraction * 100,
            worstTile.x,
            worstTile.y,
            maximumTileCoverageDifference,
            inkRatio
        ) + (failureReasons.isEmpty ? "" : " — " + failureReasons.joined(separator: "; "))
    }
}

/// Compares two rasters the way a golden test needs them compared.
///
/// # Why not a plain pixel diff
///
/// A GPU rasteriser and Core Graphics will never produce byte-identical antialiasing. Their
/// coverage estimators differ, their blend arithmetic rounds differently, and Metal's vertex
/// pipeline works in `Float` where Core Graphics works in `Double`. A strict pixel diff therefore
/// fails on every scene, which means it would be disabled, which means it would test nothing.
///
/// # Why not a plain tolerance either
///
/// A loose per-pixel tolerance passes a scene that is missing an entire small shape, because the
/// shape occupies few pixels and each of those pixels is only "somewhat" wrong. That is exactly
/// the class of defect this suite exists to catch.
///
/// # The three terms
///
/// 1. **Perceptual, as a population rather than a maximum.** Both images get a 3x3 box blur, and
///    the *fraction* of pixels whose blurred channel difference exceeds
///    ``perceptualChannelTolerance`` must stay under ``differingPixelFractionTolerance``.
///
///    The maximum is computed and reported but deliberately **not** asserted. A GPU antialiases
///    by counting multisamples and Core Graphics computes exact edge area, so a single pixel
///    where a dash boundary lands on the other side of a sample position can differ by a third of
///    a level while the picture is right everywhere. Gating on the maximum makes the suite fail
///    on one pixel out of half a million; gating on the population makes it fail when a region
///    is wrong, which is the thing worth failing on.
/// 2. **Structural.** Mean alpha coverage per 16x16 tile must agree within
///    ``tileCoverageTolerance``. A missing shape, a hole filled in by a wrong fill rule, or a
///    dash pattern at the wrong scale changes tile coverage by whole percent — far outside the
///    tolerance — while antialiasing changes it by a fraction of a percent.
/// 3. **Global ink.** Total alpha must agree within ``inkRatioTolerance``, which catches a
///    uniform, everywhere-slightly-wrong difference that both other terms would pass.
///
/// All three must pass. `ImageComparatorTests` asserts both halves of the bargain: the terms pass
/// a legitimate backend difference, and they fail a missing shape, an ignored fill rule, a
/// mis-scaled dash and a three-point translation.
public enum ImageComparator {

    /// A pixel counts as perceptibly different above this blurred per-channel difference,
    /// `0...1`. About 20/255, which is a little over three eight-sample multisample levels: the
    /// quantisation a GPU edge carries against an exact-area one.
    public static let perceptualChannelTolerance = 0.08
    /// Largest per-tile mean-coverage difference allowed, `0...1`.
    public static let tileCoverageTolerance = 0.025
    /// Largest fraction of pixels allowed to exceed ``perceptualChannelTolerance``.
    public static let differingPixelFractionTolerance = 0.005
    /// Total-ink ratio must lie inside `1 ± this`.
    public static let inkRatioTolerance = 0.02
    /// Tile edge in pixels for the structural term.
    public static let tileSize = 16

    public static func compare(_ lhs: RasterImage, _ rhs: RasterImage) -> ImageComparison {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return ImageComparison(
                matches: false,
                maximumChannelDifference: 1,
                maximumBlurredDifference: 1,
                meanChannelDifference: 1,
                differingPixelFraction: 1,
                maximumTileCoverageDifference: 1,
                worstTile: (0, 0),
                inkRatio: 0,
                failureReasons: [
                    "size mismatch: \(lhs.width)x\(lhs.height) vs \(rhs.width)x\(rhs.height)"
                ]
            )
        }

        let width = lhs.width
        let height = lhs.height
        let pixelCount = width * height

        var maximumChannel = 0
        var sumChannel = 0
        var inkLeft = 0.0
        var inkRight = 0.0
        for offset in 0..<(pixelCount * 4) {
            let a = Int(lhs.pixels[offset])
            let b = Int(rhs.pixels[offset])
            let difference = a > b ? a - b : b - a
            if difference > maximumChannel { maximumChannel = difference }
            sumChannel += difference
        }
        for index in 0..<pixelCount {
            inkLeft += Double(lhs.pixels[index * 4 + 3])
            inkRight += Double(rhs.pixels[index * 4 + 3])
        }

        let blurredLeft = boxBlur(lhs)
        let blurredRight = boxBlur(rhs)
        var maximumBlurred = 0.0
        var differingPixels = 0
        let perceptual = Float(perceptualChannelTolerance)
        for index in 0..<pixelCount {
            var worst: Float = 0
            for channel in 0..<4 {
                let offset = index * 4 + channel
                worst = Swift.max(worst, Swift.abs(blurredLeft[offset] - blurredRight[offset]))
            }
            maximumBlurred = Swift.max(maximumBlurred, Double(worst))
            if worst > perceptual { differingPixels += 1 }
        }

        let tilesX = (width + tileSize - 1) / tileSize
        let tilesY = (height + tileSize - 1) / tileSize
        var maximumTile = 0.0
        var worstTile = (x: 0, y: 0)
        for tileY in 0..<tilesY {
            for tileX in 0..<tilesX {
                var sumLeft = 0.0
                var sumRight = 0.0
                var samples = 0
                for y in (tileY * tileSize)..<Swift.min(height, (tileY + 1) * tileSize) {
                    for x in (tileX * tileSize)..<Swift.min(width, (tileX + 1) * tileSize) {
                        let offset = (y * width + x) * 4 + 3
                        sumLeft += Double(lhs.pixels[offset])
                        sumRight += Double(rhs.pixels[offset])
                        samples += 1
                    }
                }
                guard samples > 0 else { continue }
                let difference = Swift.abs(sumLeft - sumRight) / (Double(samples) * 255)
                if difference > maximumTile {
                    maximumTile = difference
                    worstTile = (tileX, tileY)
                }
            }
        }

        let inkRatio = inkRight > 0 ? inkLeft / inkRight : (inkLeft > 0 ? .infinity : 1)
        let differingFraction = Double(differingPixels) / Double(pixelCount)

        var reasons: [String] = []
        if maximumTile > tileCoverageTolerance {
            reasons.append(String(
                format: "tile (%d,%d) coverage difference %.4f exceeds %.4f — a structural difference",
                worstTile.x, worstTile.y, maximumTile, tileCoverageTolerance
            ))
        }
        if differingFraction > differingPixelFractionTolerance {
            reasons.append(String(
                format: "%.4f%% of pixels differ perceptibly, over the %.4f%% budget",
                differingFraction * 100, differingPixelFractionTolerance * 100
            ))
        }
        if !(Swift.abs(inkRatio - 1) <= inkRatioTolerance) {
            reasons.append(String(format: "total ink ratio %.5f is outside 1 ± %.3f", inkRatio, inkRatioTolerance))
        }

        return ImageComparison(
            matches: reasons.isEmpty,
            maximumChannelDifference: Double(maximumChannel) / 255,
            maximumBlurredDifference: maximumBlurred,
            meanChannelDifference: Double(sumChannel) / Double(pixelCount * 4) / 255,
            differingPixelFraction: differingFraction,
            maximumTileCoverageDifference: maximumTile,
            worstTile: worstTile,
            inkRatio: inkRatio,
            failureReasons: reasons
        )
    }

    /// A separable 3x3 box blur over all four channels, returning normalised `0...1` values.
    ///
    /// Separable — a horizontal pass then a vertical one — because the naive nine-tap version is
    /// the single most expensive thing in the golden suite and this is the same answer for a
    /// third of the work. `Float` rather than `Double` for the same reason: the values are
    /// eight-bit samples and the tolerance is 8/255, so double precision buys nothing here.
    private static func boxBlur(_ image: RasterImage) -> [Float] {
        let width = image.width
        let height = image.height
        let count = width * height * 4
        var horizontal = [Float](repeating: 0, count: count)
        image.pixels.withUnsafeBufferPointer { source in
            horizontal.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    let row = y * width * 4
                    for x in 0..<width {
                        let left = x > 0 ? row + (x - 1) * 4 : -1
                        let right = x < width - 1 ? row + (x + 1) * 4 : -1
                        let here = row + x * 4
                        for channel in 0..<4 {
                            var sum = Float(source[here + channel])
                            var taps: Float = 1
                            if left >= 0 { sum += Float(source[left + channel]); taps += 1 }
                            if right >= 0 { sum += Float(source[right + channel]); taps += 1 }
                            destination[here + channel] = sum / taps
                        }
                    }
                }
            }
        }
        var output = [Float](repeating: 0, count: count)
        horizontal.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    let above = y > 0 ? (y - 1) * width * 4 : -1
                    let below = y < height - 1 ? (y + 1) * width * 4 : -1
                    let row = y * width * 4
                    for x in 0..<width {
                        let offset = x * 4
                        for channel in 0..<4 {
                            var sum = source[row + offset + channel]
                            var taps: Float = 1
                            if above >= 0 { sum += source[above + offset + channel]; taps += 1 }
                            if below >= 0 { sum += source[below + offset + channel]; taps += 1 }
                            destination[row + offset + channel] = sum / taps / 255
                        }
                    }
                }
            }
        }
        return output
    }
}

extension RasterImage {
    /// Decodes a PNG into premultiplied RGBA8 by redrawing it into a known context, so the result
    /// is byte-comparable with a freshly rendered image regardless of how the file was written.
    /// Only the golden files are ever read back; the shipping renderer only writes PNGs.
    public static func fromPNG(_ data: Data) -> RasterImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return fromCGImage(image)
    }
}
