import CoreGraphics
import Foundation
import Testing
@testable import ZPDFRasterAnalysis

/// W-096: the full-resolution refinement reads a picture of the few windows around each coarse
/// peak, not a full-resolution picture of the whole page. The old matcher built that picture —
/// four bytes of value and sixteen of summed-area tables per pixel, about 600 MB for a 30 MP scan
/// — on every page, before the coarse pass had found anything.
@Suite("W-096 — template matcher refinement window")
struct Iter6TemplateMatcherTests {

    /// A deterministic page: paper, speckle and a few strokes, so windows have structure and
    /// no window anywhere is flat.
    static func page(width: Int, height: Int) -> GrayRaster {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state: UInt32 = 0x2545_F491
        for index in pixels.indices {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            pixels[index] = 200 + UInt8(state % 56)
        }
        for (x0, y0, w, h) in [(10, 12, 60, 3), (40, 30, 4, 50), (120, 90, 70, 5), (150, 20, 6, 120), (0, 0, 9, 9)] {
            for y in y0..<min(height, y0 + h) { for x in x0..<min(width, x0 + w) { pixels[y * width + x] = 10 } }
        }
        return GrayRaster(width: width, height: height, pixels: pixels,
                          pageRegion: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test("Every offset the refinement reads scores on the window as it does on the whole page")
    func windowScoresEqualWholePageScores() throws {
        let image = Self.page(width: 220, height: 160)
        let whole = FloatPicture(image)
        let template = FloatPicture(try #require(image.crop(x: 36, y: 26, width: 23, height: 17)))
        let statistics = template.statistics
        let reach = 4
        // Interior, every edge and every corner, including peaks whose windows run off the page.
        let peaks = [(36, 26), (0, 0), (219, 159), (0, 100), (100, 0), (205, 80), (90, 150), (199, 145), (3, 157)]
        var compared = 0, refused = 0
        for peak in peaks {
            let window = try #require(FloatPicture.refinementWindow(of: image, around: peak, reach: reach, template: template))
            #expect(window.picture.width <= template.width + 2 * reach)
            #expect(window.picture.height <= template.height + 2 * reach)
            for y in (peak.1 - reach)...(peak.1 + reach) {
                for x in (peak.0 - reach)...(peak.0 + reach) {
                    let expected = whole.ncc(of: template, atX: x, y: y)
                    let actual = window.picture.ncc(of: template, atX: x - window.originX, y: y - window.originY,
                                                    templateStatistics: statistics)
                    switch (expected, actual) {
                    case (nil, nil):
                        refused += 1
                    case let (expected?, actual?):
                        compared += 1
                        #expect(abs(expected - actual) <= 1e-12, "(\(x), \(y)): \(expected) on the page, \(actual) on the window")
                    default:
                        Issue.record("(\(x), \(y)): \(String(describing: expected)) on the page, \(String(describing: actual)) on the window")
                    }
                }
            }
        }
        // Both kinds occur: windows inside the page, and windows that run past an edge.
        #expect(compared > 200 && refused > 100, "compared \(compared), refused \(refused)")
        // The example's own place scores 1.
        let own = try #require(FloatPicture.refinementWindow(of: image, around: (36, 26), reach: reach, template: template))
        let score = try #require(own.picture.ncc(of: template, atX: 36 - own.originX, y: 26 - own.originY))
        #expect(abs(score - 1) < 1e-9)
    }

    /// A 30 MP scan, the largest raster `ScanTrace` makes, with one boxed symbol near the bottom
    /// right. The only full-resolution picture the refinement builds is the window: (64 + 2·4) ×
    /// (48 + 2·4) pixels where the old one was 6 000 × 5 000. Measured once with the process's
    /// peak footprint around `matches` on this page: 624 MiB of growth with the old whole-page
    /// picture, 51 MiB without it.
    ///
    /// The matcher itself runs on the page's bottom-right 400 × 300 pixels, which hold the symbol
    /// near the page's corner: the coarse pass over all 30 MP takes over half a minute in a debug
    /// build and proves nothing more.
    @Test("On a 30 MP scan the refinement builds a window of the template plus its reach, and still finds the symbol")
    func thirtyMegapixelPageRefinesOnAWindow() throws {
        let width = 6_000, height = 5_000
        var pixels = [UInt8](repeating: 255, count: width * height)
        // A 64 × 48 box with a cross, its top-left at (5 800, 4 900).
        let symbolX = 5_800, symbolY = 4_900, symbolWidth = 64, symbolHeight = 48
        for y in 0..<symbolHeight {
            for x in 0..<symbolWidth {
                let edge = x < 3 || y < 3 || x >= symbolWidth - 3 || y >= symbolHeight - 3
                let cross = abs(x * symbolHeight - y * symbolWidth) < 2 * symbolWidth
                if edge || cross { pixels[(symbolY + y) * width + symbolX + x] = 0 }
            }
        }
        let image = GrayRaster(width: width, height: height, pixels: pixels,
                               pageRegion: CGRect(x: 0, y: 0, width: width, height: height))
        let example = try #require(image.crop(x: symbolX, y: symbolY, width: symbolWidth, height: symbolHeight))
        // The matcher's factor for this example: max(1, min(64 / 16, 48 / 2)) = 4.
        let template = FloatPicture(example)
        let window = try #require(FloatPicture.refinementWindow(of: image, around: (symbolX, symbolY), reach: 4, template: template))
        #expect(window.picture.width == symbolWidth + 8 && window.picture.height == symbolHeight + 8)
        #expect(window.picture.values.count == 72 * 56, "a window, not the page's 30 000 000 pixels")

        let corner = try #require(image.crop(x: width - 400, y: height - 300, width: 400, height: 300))
        let matches = TemplateMatcher.matches(of: example, in: corner)
        // Centre by hand, in page space (the crop keeps it): x 5 800 + 32 = 5 832; y from the top
        // 4 900 + 24 = 4 924, page y 5 000 − 4 924 = 76.
        let match = try #require(matches.first { hypot($0.center.x - 5_832, $0.center.y - 76) < 1 }, "\(matches)")
        #expect(match.score > 0.999)
    }
}
