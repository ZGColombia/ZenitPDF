import Foundation
import ZPDFRenderer

/// Compares a rendered raster against the independent coverage oracle.
///
/// The comparison is on **mean alpha per 16x16 tile**, for the reason spelled out on
/// ``ReferenceRasterizer``: a box-filtered supersampler and Core Graphics' exact-area filter
/// agree on the integral of coverage over a tile and disagree on individual edge pixels. The
/// tolerance below is therefore a tolerance on an integral, not on a pixel, and it is tight
/// enough that a missing shape, a filled-in hole, a stroke at the wrong width, a dash drawn solid
/// or a page turned the wrong way all fail it by an order of magnitude.
///
/// # What it cannot see
///
/// A dash **scale** error that keeps the pattern's on/off ratio. The one-factor rule preserves
/// every ratio, so a renderer that dropped `DashPattern.minimumRunPixels` altogether — 0.9/0.5 px
/// runs instead of 2.7/1.5 px at 5 % zoom — lays down the same total ink and tile means within
/// about one partial run, far under the tolerance. This comment used to claim the opposite
/// (BH-636). That property is held where it can be measured: `DashAndAtlasTests.scalingRule`
/// asserts the floored run lengths directly, and the shader implements the same two lines.
public enum GoldenProvenance {

    /// Largest allowed difference in mean tile coverage.
    public static let tileTolerance = 0.035
    /// Largest allowed difference in total ink, as a fraction of the reference's total.
    public static let inkTolerance = 0.04
    public static let tile = 16

    public struct Result: Sendable {
        public var matches: Bool
        public var worstTileDifference: Double
        public var worstTile: (x: Int, y: Int)
        public var inkRatio: Double
        public var tilesOverTolerance: Int
        /// Set when the render and the reference are not the same size, in which case nothing
        /// else here was measured.
        public var sizeMismatch: (rendered: PixelSize, reference: PixelSize)? = nil

        public var summary: String {
            // A size mismatch used to fall through to the tile format with `Int.max` tiles,
            // which `%d` printed as "-1 tiles over", and never said the sizes differed (BH-637).
            if let sizeMismatch {
                return "size mismatch: rendered \(sizeMismatch.rendered.width)x\(sizeMismatch.rendered.height), "
                    + "reference \(sizeMismatch.reference.width)x\(sizeMismatch.reference.height) — "
                    + "regenerate the golden or fix the scene's viewport"
            }
            return "worst tile (\(worstTile.x),\(worstTile.y)) Δ "
                + String(format: "%.4f (limit %.3f), ink ratio %.4f", worstTileDifference, tileTolerance, inkRatio)
                + ", \(tilesOverTolerance) tiles over"
        }
    }

    public static func compare(image: RasterImage, reference: ReferenceRasterizer.Coverage) -> Result {
        guard image.width == reference.width, image.height == reference.height else {
            return Result(
                matches: false,
                worstTileDifference: 1,
                worstTile: (0, 0),
                inkRatio: 0,
                tilesOverTolerance: 0,
                sizeMismatch: (
                    PixelSize(width: image.width, height: image.height),
                    PixelSize(width: reference.width, height: reference.height)
                )
            )
        }
        var rendered = ReferenceRasterizer.Coverage(width: image.width, height: image.height)
        for index in 0..<(image.width * image.height) {
            rendered.alpha[index] = Double(image.pixels[index * 4 + 3]) / 255
        }
        let left = rendered.tileMeans(tile: tile)
        let right = reference.tileMeans(tile: tile)
        var worst = 0.0
        var worstTile = (x: 0, y: 0)
        var over = 0
        for row in 0..<right.rows {
            for column in 0..<right.columns {
                let index = row * right.columns + column
                let difference = abs(left.values[index] - right.values[index])
                if difference > worst {
                    worst = difference
                    worstTile = (column, row)
                }
                if difference > tileTolerance { over += 1 }
            }
        }
        let inkLeft = rendered.alpha.reduce(0, +)
        let inkRight = reference.alpha.reduce(0, +)
        let ratio = inkRight > 0 ? inkLeft / inkRight : (inkLeft > 0 ? .infinity : 1)
        let inkOK = abs(ratio - 1) <= inkTolerance
        return Result(
            matches: over == 0 && inkOK,
            worstTileDifference: worst,
            worstTile: worstTile,
            inkRatio: ratio,
            tilesOverTolerance: over
        )
    }
}
