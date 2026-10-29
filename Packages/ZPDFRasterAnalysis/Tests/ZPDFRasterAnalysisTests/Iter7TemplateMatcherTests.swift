import CoreGraphics
import Foundation
import Testing
@testable import ZPDFRasterAnalysis

/// X-050: the coarse pass scores the page a tile at a time. An example under 32 pixels on its
/// long side has coarse factor 1, and the old pass then built one picture of the whole page at full
/// resolution (20 bytes a pixel, about 600 MB at 30 MP) and a score grid of 8 bytes a pixel.
@Suite("X-050 — template matcher coarse tiles")
struct Iter7TemplateMatcherTests {

    /// A box with a centred plus, the same under every quarter turn and mirror, so the matcher
    /// scores one orientation.
    static func symmetricSymbol(side: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let edge = x < 2 || y < 2 || x >= side - 2 || y >= side - 2
                let plus = abs(2 * x - (side - 1)) <= 2 || abs(2 * y - (side - 1)) <= 2
                if edge || plus { pixels[y * side + x] = 0 }
            }
        }
        return pixels
    }

    static func stamp(_ symbol: [UInt8], side: Int, at origins: [(Int, Int)], into pixels: inout [UInt8], width: Int) {
        for (ox, oy) in origins {
            for y in 0..<side { for x in 0..<side { pixels[(oy + y) * width + ox + x] = symbol[y * side + x] } }
        }
    }

    /// Every template's tiled peaks are exactly the peaks one picture of the whole page finds —
    /// same origins, same scores to the bit, same order — with tiles small enough that peaks sit
    /// on tile edges and corners, and windows run off the page.
    @Test("Tiled coarse peaks equal the whole picture's, origin for origin and score for score")
    func tiledPeaksEqualWholePicture() throws {
        let image = Iter6TemplateMatcherTests.page(width: 220, height: 160)
        let templates = try [(36, 26, 23, 17), (148, 18, 10, 30), (0, 0, 12, 12), (118, 88, 31, 9)].map {
            FloatPicture(try #require(image.crop(x: $0.0, y: $0.1, width: $0.2, height: $0.3)))
        }
        let whole = FloatPicture(image)
        let expected = templates.map { whole.peaks(of: $0, minimumScore: 0.1, inkTolerance: 0.6) }
        #expect(expected.allSatisfy { !$0.isEmpty }, "the fixture must have peaks to compare")
        for tileSide in [3, 7, 37, 64, 219, 1_024] {
            var statistics = TemplateMatcher.CoarsePassStatistics()
            let tiled = TemplateMatcher.coarsePeaks(
                in: image, of: templates, minimumScore: 0.1, inkTolerance: 0.6, tileSide: tileSide, statistics: &statistics
            )
            for (index, peaks) in tiled.enumerated() {
                #expect(peaks.map(\.x) == expected[index].map(\.x), "tile \(tileSide), template \(index)")
                #expect(peaks.map(\.y) == expected[index].map(\.y), "tile \(tileSide), template \(index)")
                #expect(peaks.map(\.score) == expected[index].map(\.score), "tile \(tileSide), template \(index)")
            }
        }
    }

    /// The whole matcher answers the same whether the coarse page is one tile or many.
    @Test("Matches over small tiles equal matches over one tile")
    func matchesDoNotDependOnTheTileSide() throws {
        let width = 300, height = 200, side = 20
        var pixels = [UInt8](repeating: 255, count: width * height)
        Self.stamp(Self.symmetricSymbol(side: side), side: side, at: [(10, 10), (63, 41), (150, 150), (279, 179), (199, 99)],
                   into: &pixels, width: width)
        let image = GrayRaster(width: width, height: height, pixels: pixels, pageRegion: CGRect(x: 0, y: 0, width: width, height: height))
        let example = try #require(image.crop(x: 63, y: 41, width: side, height: side))
        var one = TemplateMatcher.CoarsePassStatistics(), many = TemplateMatcher.CoarsePassStatistics()
        let reference = TemplateMatcher.matches(of: example, in: image, options: .standard, tileSide: 10_000, statistics: &one)
        let tiled = TemplateMatcher.matches(of: example, in: image, options: .standard, tileSide: 41, statistics: &many)
        #expect(one.factor == 1 && one.tiles == 1 && many.tiles == 8 * 5)
        #expect(tiled == reference)
        #expect(reference.count == 5, "\(reference)")
    }

    /// A 24 px symbol on a 30 MP scan, the largest raster `ScanTrace` makes: factor
    /// max(1, min(24 / 16, 24 / 2)) = 1, so the coarse page is the page. Each tile's picture is at
    /// most (1 024 + 1 + 24)² = 1 100 401 pixels (about 22 MB as floats and tables) and its scores
    /// (1 024 + 2)² = 1 052 676, where the old pass held one 6 000 × 5 000 picture (about 600 MB)
    /// and 5 977 × 4 977 scores (about 240 MB). Measured once with the process's peak footprint
    /// (`ledger_phys_footprint_peak`) on this page, filtered single-test runs, debug build: 800 MiB
    /// of growth for the old coarse pass (one `FloatPicture` of the page and `peaks` over it), 46 MiB
    /// for `matches` with tiles.
    @Test("A 24 px symbol on a 30 MP scan is found with tiles under a twenty-seventh of the page")
    func smallSymbolOnThirtyMegapixelPage() throws {
        let width = 6_000, height = 5_000, side = 24
        var pixels = [UInt8](repeating: 255, count: width * height)
        let symbol = Self.symmetricSymbol(side: side)
        // One copy inside a tile, one across a tile corner (origins 1 024 and 2 048 are tile edges).
        Self.stamp(symbol, side: side, at: [(300, 400), (2_040, 1_020), (5_960, 4_970)], into: &pixels, width: width)
        let image = GrayRaster(width: width, height: height, pixels: pixels, pageRegion: CGRect(x: 0, y: 0, width: width, height: height))
        let example = try #require(image.crop(x: 300, y: 400, width: side, height: side))

        var statistics = TemplateMatcher.CoarsePassStatistics()
        let matches = TemplateMatcher.matches(of: example, in: image, options: .standard, statistics: &statistics)
        #expect(statistics.factor == 1)
        #expect(statistics.tiles == 6 * 5)
        #expect(statistics.largestPicturePixels <= 1_049 * 1_049, "\(statistics.largestPicturePixels)")
        #expect(statistics.largestScoreCount <= 1_026 * 1_026, "\(statistics.largestScoreCount)")
        #expect(statistics.largestPicturePixels * 27 < width * height)

        // Centres by hand, page space (origin bottom-left): x = ox + 12, y = 5 000 − (oy + 12).
        for (x, y) in [(312.0, 4_588.0), (2_052.0, 3_968.0), (5_972.0, 18.0)] {
            let match = try #require(matches.first { hypot($0.center.x - x, $0.center.y - y) < 1 }, "(\(x), \(y)): \(matches)")
            #expect(match.score > 0.999)
        }
        #expect(matches.count == 3, "\(matches)")
    }
}
