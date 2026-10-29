import CoreGraphics
import Foundation
import Testing
@testable import ZPDFRasterAnalysis

/// S-114: boxing a thin symbol on a scan crashed the app. `GrayRaster.downsampled(by:)` clamped
/// the output side to one pixel but still averaged a whole `factor × factor` block, so a picture
/// shorter than the factor read past the end of `pixels`.
///
/// The case from the finding: a 3 px × 177 px stroke, trimmed to its ink plus a 2 px margin as
/// `ScanSymbolCount.template` does, is a 181 × 7 example. The matcher's factor is 181 / 16 = 11,
/// so the old coarse template had h = 1 and read row 10 of a 7-row picture: the largest index was
/// 10·181 + 15·11 + 10 = 1985 of 1267 pixels, a trap (old: "Fatal error: Index out of range").
@Suite("S-114 — thin symbols on a scan")
struct Iter2ThinSymbolTests {

    /// A white picture, 1 px per page point, with black rectangles (x, y from the top, w, h).
    static func picture(width: Int, height: Int, ink: [(Int, Int, Int, Int)]) -> GrayRaster {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for (x0, y0, w, h) in ink {
            for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { pixels[y * width + x] = 0 } }
        }
        return GrayRaster(width: width, height: height, pixels: pixels, pageRegion: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test("A block that runs past a short side averages only the pixels that exist")
    func downsampleShortSide() {
        // 7 wide × 2 high, factor 4: one output row (h = max(1, 0)) whose block is rows 0–1 only.
        // Row 0 is black (0), row 1 white (255): columns 0–3 average (4·0 + 4·255) / 8 = 127.
        // Old: read rows 2 and 3 of a 2-row picture — out of range.
        let raster = Self.picture(width: 7, height: 2, ink: [(0, 0, 7, 1)])
        let small = raster.downsampled(by: 4)
        #expect(small.width == 1 && small.height == 1)
        #expect(small.pixels == [127])
        // The coarse picture covers the 4 × 2 source pixels it averaged, not 4 × 4.
        #expect(small.pageRegion == CGRect(x: 0, y: 0, width: 4, height: 2))
    }

    @Test("A side narrower than the factor never reads into the next row")
    func downsampleNarrowSide() {
        // 2 wide × 8 high, factor 4: w = max(1, 0) = 1, blocks are 2 columns × 4 rows.
        // Column 1 is black, column 0 white: each block is (4·255 + 4·0) / 8 = 127.
        // Old: dx ran to 3 and read columns 0–1 of the *next* row as columns 2–3 of this one;
        // the last block read past the end.
        let raster = Self.picture(width: 2, height: 8, ink: [(1, 0, 1, 8)])
        let small = raster.downsampled(by: 4)
        #expect(small.width == 1 && small.height == 2)
        #expect(small.pixels == [127, 127])
    }

    @Test("Whole blocks average exactly as before")
    func downsampleWholeBlocks() {
        // 4 × 4, factor 2, the top-left 2 × 2 black: [0, 255, 255, 255].
        let raster = Self.picture(width: 4, height: 4, ink: [(0, 0, 2, 2)])
        let small = raster.downsampled(by: 2)
        #expect(small.pixels == [0, 255, 255, 255])
        #expect(small.pageRegion == CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// Three 177 × 3 strokes; the example is the first one with a 2 px margin (181 × 7).
    static let strokes = [(20, 20), (240, 60), (60, 120)]

    @Test("A 181 × 7 example is found at every stroke, not a crash")
    func horizontalThinSymbol() throws {
        let image = Self.picture(width: 460, height: 160, ink: Self.strokes.map { ($0.0, $0.1, 177, 3) })
        let example = try #require(image.crop(x: 18, y: 18, width: 181, height: 7))
        #expect(example.width == 181 && example.height == 7)
        let matches = TemplateMatcher.matches(of: example, in: image)
        // Centres by hand: x0 + 177 / 2, and y from the top y0 + 1.5, as page y = 160 − that.
        let expected = Self.strokes.map { CGPoint(x: Double($0.0) + 88.5, y: 160 - (Double($0.1) + 1.5)) }
        #expect(matches.count == 3, "\(matches)")
        for centre in expected {
            #expect(matches.contains { hypot($0.center.x - centre.x, $0.center.y - centre.y) < 1 && $0.score > 0.99 }, "no match at \(centre): \(matches)")
        }
    }

    @Test("A 7 × 181 example is found at every stroke, not a crash")
    func verticalThinSymbol() throws {
        let image = Self.picture(width: 160, height: 460, ink: Self.strokes.map { ($0.1, $0.0, 3, 177) })
        let example = try #require(image.crop(x: 18, y: 18, width: 7, height: 181))
        #expect(example.width == 7 && example.height == 181)
        let matches = TemplateMatcher.matches(of: example, in: image)
        let expected = Self.strokes.map { CGPoint(x: Double($0.1) + 1.5, y: 460 - (Double($0.0) + 88.5)) }
        #expect(matches.count == 3, "\(matches)")
        for centre in expected {
            #expect(matches.contains { hypot($0.center.x - centre.x, $0.center.y - centre.y) < 1 && $0.score > 0.99 }, "no match at \(centre): \(matches)")
        }
    }
}
