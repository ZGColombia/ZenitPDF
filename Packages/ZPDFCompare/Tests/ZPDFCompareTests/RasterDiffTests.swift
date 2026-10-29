import CoreGraphics
import Foundation
import Testing
import ZPDFCompare

/// The pixel signal: thresholding, morphology, connected components, and the frame
/// arithmetic that turns a pixel rectangle back into a page rectangle.
struct RasterDiffTests {

    /// A frame over a Letter page at scale 1, unrotated, so pixel and page coordinates
    /// differ only by the y flip.
    static func letterFrame(scale: Double = 1) -> RasterFrame {
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        return RasterFrame(
            boxRect: box,
            renderedRegion: box,
            rotation: 0,
            scale: scale,
            pixelWidth: Int(612 * scale),
            pixelHeight: Int(792 * scale)
        )
    }

    static func canvas(
        width: Int,
        height: Int,
        marks: [(CGRect, UInt8)] = []
    ) throws -> GrayImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for (rect, value) in marks {
            for y in Int(rect.minY)..<Int(rect.maxY) where y >= 0 && y < height {
                for x in Int(rect.minX)..<Int(rect.maxX) where x >= 0 && x < width {
                    pixels[y * width + x] = value
                }
            }
        }
        return try GrayImage(width: width, height: height, pixels: pixels)
    }

    // MARK: - Frame arithmetic

    @Test("Pixel and page space round-trip exactly at every page rotation")
    func frameRoundTripsAtEveryRotation() throws {
        let box = CGRect(x: -20, y: -10, width: 612, height: 792)
        for rotation in [0, 90, 180, 270] {
            let displaySize = rotation == 90 || rotation == 270
                ? CGSize(width: box.height, height: box.width)
                : box.size
            let frame = RasterFrame(
                boxRect: box,
                renderedRegion: box,
                rotation: rotation,
                scale: 2,
                pixelWidth: Int(displaySize.width * 2),
                pixelHeight: Int(displaySize.height * 2)
            )
            let pageToPixel = frame.pageToPixel
            let pixelToPage = try frame.pixelToPage()
            for point in [
                CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY),
                CGPoint(x: 100, y: 250)
            ] {
                let round = pixelToPage.apply(to: pageToPixel.apply(to: point))
                #expect(abs(round.x - point.x) < 1e-9, "rotation \(rotation)")
                #expect(abs(round.y - point.y) < 1e-9, "rotation \(rotation)")
            }
            // The whole box must land inside the bitmap, whatever the rotation.
            let mapped = pageToPixel.transformedBounds(of: box)
            #expect(abs(mapped.minX) < 1e-9, "rotation \(rotation)")
            #expect(abs(mapped.minY) < 1e-9, "rotation \(rotation)")
            #expect(abs(mapped.width - Double(frame.pixelWidth)) < 1e-9, "rotation \(rotation)")
            #expect(abs(mapped.height - Double(frame.pixelHeight)) < 1e-9, "rotation \(rotation)")
        }
    }

    // MARK: - Self comparison

    @Test("An image compared with itself yields zero differences at the strictest tolerance")
    func selfComparisonIsEmpty() throws {
        let image = try Self.canvas(
            width: 200,
            height: 120,
            marks: [(CGRect(x: 20, y: 20, width: 60, height: 8), 0),
                    (CGRect(x: 120, y: 70, width: 40, height: 40), 64)]
        )
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 200, height: 120),
            renderedRegion: CGRect(x: 0, y: 0, width: 200, height: 120),
            rotation: 0,
            scale: 1,
            pixelWidth: 200,
            pixelHeight: 120
        )
        let outcome = try RasterDiffEngine.diff(
            baseline: image,
            revised: image,
            frame: frame,
            options: RasterDiffOptions(tolerance: .strict)
        )
        #expect(outcome.regions.isEmpty)
        #expect(outcome.statistics.differingPixelCount == 0)
        #expect(outcome.statistics.isIdentical)
        #expect(!outcome.wasTruncated)
    }

    // MARK: - Classification

    @Test("Added, removed and changed are classified from the direction of the ink")
    func classificationFollowsInkDirection() throws {
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            renderedRegion: CGRect(x: 0, y: 0, width: 300, height: 200),
            rotation: 0,
            scale: 1,
            pixelWidth: 300,
            pixelHeight: 200
        )
        let baseline = try Self.canvas(
            width: 300, height: 200,
            marks: [
                (CGRect(x: 10, y: 10, width: 20, height: 20), 0),    // disappears
                (CGRect(x: 150, y: 10, width: 20, height: 20), 0)    // becomes lighter
            ]
        )
        let revised = try Self.canvas(
            width: 300, height: 200,
            marks: [
                (CGRect(x: 150, y: 10, width: 20, height: 20), 128), // lighter: removed ink
                (CGRect(x: 10, y: 150, width: 20, height: 20), 0)    // appears
            ]
        )
        let outcome = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame,
            options: RasterDiffOptions(tolerance: .strict)
        )
        #expect(outcome.regions.count == 3)
        let byClassification = Dictionary(grouping: outcome.regions, by: \.classification)
        #expect(byClassification[.removed]?.count == 2)
        #expect(byClassification[.added]?.count == 1)
        #expect(outcome.statistics.addedPixelCount == 400)
        #expect(outcome.statistics.removedPixelCount == 800)
    }

    @Test("A region that both gains and loses ink is classified as changed")
    func overlappingGainAndLossIsChanged() throws {
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            renderedRegion: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotation: 0, scale: 1, pixelWidth: 100, pixelHeight: 100
        )
        // A 6 x 6 block shifted right by 4 px. The two differing strips are 2 px
        // apart, so the standard 3 px grouping dilation joins them into one region —
        // which is the point: a moved line is one finding, not two.
        let baseline = try Self.canvas(
            width: 100, height: 100, marks: [(CGRect(x: 20, y: 20, width: 6, height: 6), 0)]
        )
        let revised = try Self.canvas(
            width: 100, height: 100, marks: [(CGRect(x: 24, y: 20, width: 6, height: 6), 0)]
        )
        let outcome = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame,
            options: RasterDiffOptions(
                tolerance: RasterDiffTolerance(
                    intensityTolerance: 0, minimumRegionPixelCount: 1, groupingRadiusPixels: 3
                )
            )
        )
        #expect(outcome.regions.count == 1)
        #expect(outcome.regions.first?.classification == .changed)
        #expect((outcome.regions.first?.addedPixelCount ?? 0) > 0)
        #expect((outcome.regions.first?.removedPixelCount ?? 0) > 0)
    }

    // MARK: - Grouping

    @Test("Grouping joins differing pixels within the dilation radius and no further")
    func groupingRadiusDecidesRegionCount() throws {
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 200, height: 60),
            renderedRegion: CGRect(x: 0, y: 0, width: 200, height: 60),
            rotation: 0, scale: 1, pixelWidth: 200, pixelHeight: 60
        )
        let baseline = try Self.canvas(width: 200, height: 60)
        // Two 6 x 6 blobs with a 6 px gap between them.
        let revised = try Self.canvas(
            width: 200, height: 60,
            marks: [(CGRect(x: 20, y: 20, width: 6, height: 6), 0),
                    (CGRect(x: 32, y: 20, width: 6, height: 6), 0)]
        )

        let separate = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame,
            options: RasterDiffOptions(
                tolerance: RasterDiffTolerance(
                    intensityTolerance: 0, minimumRegionPixelCount: 1, groupingRadiusPixels: 2
                )
            )
        )
        #expect(separate.regions.count == 2)

        let merged = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame,
            options: RasterDiffOptions(
                tolerance: RasterDiffTolerance(
                    intensityTolerance: 0, minimumRegionPixelCount: 1, groupingRadiusPixels: 4
                )
            )
        )
        #expect(merged.regions.count == 1)
        // The reported bounds come from the differing pixels, never from the dilation.
        let bounds = try #require(merged.regions.first?.pixelBounds)
        #expect(bounds == CGRect(x: 20, y: 20, width: 18, height: 6))
    }

    @Test("Groups below the minimum pixel count are discarded and counted as discarded")
    func minimumRegionSizeDropsSpecks() throws {
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            renderedRegion: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotation: 0, scale: 1, pixelWidth: 100, pixelHeight: 100
        )
        let baseline = try Self.canvas(width: 100, height: 100)
        let revised = try Self.canvas(
            width: 100, height: 100,
            marks: [(CGRect(x: 10, y: 10, width: 2, height: 2), 0),
                    (CGRect(x: 60, y: 60, width: 10, height: 10), 0)]
        )
        let outcome = try RasterDiffEngine.diff(
            baseline: baseline, revised: revised, frame: frame,
            options: RasterDiffOptions(
                tolerance: RasterDiffTolerance(
                    intensityTolerance: 0, minimumRegionPixelCount: 12, groupingRadiusPixels: 0
                )
            )
        )
        #expect(outcome.regions.count == 1)
        #expect(outcome.statistics.groupedRegionCount == 2)
        #expect(outcome.statistics.discardedRegionCount == 1)
        #expect(outcome.regions.first?.changedPixelCount == 100)
    }

    // MARK: - Tolerance

    @Test("Confidence separates a solid change from a marginal smudge")
    func confidenceRule() {
        // 100 differing pixels, every one of them strong.
        let solid = RasterDifferenceConfidence.value(
            strongPixelCount: 100, changedPixelCount: 100, minimumRegionPixelCount: 12
        )
        #expect(abs(solid - 1) < 1e-12)
        // 12 differing pixels, none of them strong: the smallest region that survives
        // the filter, made entirely of marginal pixels.
        let smudge = RasterDifferenceConfidence.value(
            strongPixelCount: 0, changedPixelCount: 12, minimumRegionPixelCount: 12
        )
        #expect(abs(smudge - 0.125) < 1e-12)
        #expect(RasterDifferenceConfidence.value(
            strongPixelCount: 0, changedPixelCount: 0, minimumRegionPixelCount: 12
        ) == 0)
    }

    @Test("Mismatched raster sizes are refused with a typed error, not silently cropped")
    func mismatchedSizesThrow() throws {
        let frame = Self.letterFrame()
        let a = try Self.canvas(width: 612, height: 792)
        let b = try Self.canvas(width: 611, height: 792)
        #expect(throws: CompareFault.self) {
            try RasterDiffEngine.diff(baseline: a, revised: b, frame: frame)
        }
    }

    @Test("A raster above the pixel budget is refused before any allocation")
    func pixelBudgetIsEnforced() throws {
        let frame = RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            renderedRegion: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotation: 0, scale: 1, pixelWidth: 100, pixelHeight: 100
        )
        let image = try Self.canvas(width: 100, height: 100)
        #expect(throws: CompareFault.self) {
            try RasterDiffEngine.diff(
                baseline: image, revised: image, frame: frame,
                options: RasterDiffOptions(maximumPixels: 999)
            )
        }
    }

    // MARK: - Resampling

    @Test("Resampling by the identity returns the same buffer, not a softened copy")
    func identityResampleIsExact() throws {
        let image = try Self.canvas(
            width: 40, height: 40, marks: [(CGRect(x: 10, y: 10, width: 5, height: 5), 0)]
        )
        let resampled = try image.resampled(
            using: .identity, width: 40, height: 40, maximumPixels: 10_000
        )
        #expect(resampled == image)
    }

    @Test("Resampling by a whole-pixel translation moves the ink exactly that far")
    func integerTranslationResample() throws {
        let image = try Self.canvas(
            width: 40, height: 40, marks: [(CGRect(x: 10, y: 10, width: 5, height: 5), 0)]
        )
        // Destination pixel (x, y) reads source pixel (x - 7, y - 3): the mark moves
        // right by 7 and down by 3.
        let inverse = AlignmentTransform.translation(dx: -7, dy: -3)
        let moved = try image.resampled(
            using: inverse, width: 40, height: 40, maximumPixels: 10_000
        )
        #expect(moved[17, 13] == 0)
        #expect(moved[10, 10] == 255)
        #expect(moved[21, 17] == 0)
        #expect(moved[22, 18] == 255)
    }
}
