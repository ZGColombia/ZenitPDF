import CoreGraphics
import Foundation
import Testing
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// Independent audit of the two properties Revision Compare is worthless without:
/// comparing a page with itself finds nothing, and antialiasing is not a change.
///
/// `RevisionCompareTests` already covers self-comparison at scales 1, 2 and 3 — all of
/// them whole numbers, where a fixture drawn on even integer coordinates lands on exact
/// pixel boundaries and the renderer produces no antialiased fringe at all. That is the
/// easy half of the property. This suite adds the fractional scales, where every stroke
/// edge falls between pixel centres and the whole page is fringe, and asserts the result
/// is still exactly zero.
struct CompareAuditTests {

    // MARK: - Self-comparison

    /// Scales chosen so that a 4-point stroke lands on a half pixel (1.5, 2.5), on a
    /// third (1.0 / 3 steps via 2.75), and at a size where the raster is large enough
    /// that a single stray pixel anywhere would be found.
    static let auditScales: [Double] = [0.75, 1.0, 1.5, 2.0, 2.5, 2.75, 3.0, 4.0]

    @Test("A page compared with itself is exactly zero at eight scales, fractional ones included")
    func selfComparisonIsZeroAtEveryScale() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        for scale in Self.auditScales {
            let result = try await harness.compare(scale: scale, tolerance: .strict)
            #expect(
                result.rasterStatistics.differingPixelCount == 0,
                "scale \(scale): \(result.rasterStatistics.differingPixelCount) differing pixels" as Comment
            )
            #expect(result.rasterStatistics.addedPixelCount == 0, "scale \(scale)")
            #expect(result.rasterStatistics.removedPixelCount == 0, "scale \(scale)")
            #expect(result.rasterRegions.isEmpty, "scale \(scale)")
            #expect(result.rasterStatistics.isIdentical, "scale \(scale)")
            #expect(result.isIdentical, "scale \(scale)")
            #expect(result.differenceCount == 0, "scale \(scale)")
            // The comparison must actually have looked at pixels.
            #expect(
                result.rasterStatistics.comparedPixelCount > 10_000,
                "scale \(scale): only \(result.rasterStatistics.comparedPixelCount) pixels compared" as Comment
            )
        }
    }

    /// Self-comparison must also hold on a real fixture sheet with text, hatching and a
    /// title block, not only on the six-edge synthetic ring.
    @Test("A dense fixture sheet compared with itself is zero at three scales")
    func fixtureSelfComparisonIsZero() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ZPDFFixtures.make(.titleBlockSheet, in: directory)

        let provider = PDFKitDocumentProvider()
        defer { Task { await provider.closeAll() } }
        let document = try await provider.open(fileAt: fixture.url)
        let comparator = RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider))
        let reference = RevisionPageReference(
            document: document.handle, pageIndex: 0, box: .crop,
            fileURL: fixture.url, label: "self"
        )

        for scale in [1.0, 1.5, 2.0] {
            let result = try await comparator.compare(
                RevisionCompareRequest(
                    baseline: reference,
                    revised: reference,
                    renderScale: scale,
                    alignment: .automatic(.standard),
                    raster: RasterDiffOptions(tolerance: .strict)
                )
            )
            #expect(result.rasterStatistics.differingPixelCount == 0, "scale \(scale)")
            #expect(result.rasterRegions.isEmpty, "scale \(scale)")
            #expect(result.alignment.transform.isIdentity(), "scale \(scale)")
        }
    }

    // MARK: - Antialiasing

    static func frame(_ width: Int, _ height: Int) -> RasterFrame {
        RasterFrame(
            boxRect: CGRect(x: 0, y: 0, width: Double(width), height: Double(height)),
            renderedRegion: CGRect(x: 0, y: 0, width: Double(width), height: Double(height)),
            rotation: 0,
            scale: 1,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    /// A page with a diagonal stroke, antialiased: the fringe pixels carry intermediate
    /// gray values, which is what makes them sensitive to a sub-pixel change in the
    /// transform.
    static func antialiasedDiagonal(
        width: Int,
        height: Int,
        offset: Double,
        fringeBias: Int
    ) throws -> GrayImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            let centre = Double(y) * 0.7 + 40 + offset
            for x in 0..<width {
                let distance = abs(Double(x) - centre)
                guard distance < 3 else { continue }
                // A linear coverage ramp: solid in the middle, a fringe on both sides.
                let coverage = max(0, min(1, (2.0 - distance) / 1.0))
                var value = Int((1 - coverage) * 255)
                // Only fringe pixels — the partially covered ones — take the bias.
                if coverage > 0, coverage < 1 { value += fringeBias }
                pixels[y * width + x] = UInt8(max(0, min(255, value)))
            }
        }
        return try GrayImage(width: width, height: height, pixels: pixels)
    }

    @Test("One antialiasing pixel is never a reported change, at any level up to the tolerance")
    func oneAntialiasedPixelIsNotAChange() throws {
        let width = 200
        let height = 200
        let base = try Self.antialiasedDiagonal(width: width, height: height, offset: 0, fringeBias: 0)

        // One pixel, differing by 1 level, then by the whole tolerance, then past it.
        // Below the tolerance nothing differs at all; above it one pixel differs but is
        // far under `minimumRegionPixelCount`, so it is discarded and no region is
        // reported. Either way the reviewer is shown nothing, which is the property.
        for delta in [1, 8, 16, 24, 25, 40, 120, 255] {
            var pixels = base.pixels
            // (180, 20) is clear white paper: the diagonal's centre at y = 20 is x = 54, so
            // this pixel is 255 and a darkening of `delta` is a real change of `delta`.
            let index = 20 * width + 180
            #expect(base.pixels[index] == 255)
            pixels[index] = UInt8(max(0, min(255, Int(base.pixels[index]) - delta)))
            let changed = try GrayImage(width: width, height: height, pixels: pixels)

            let outcome = try RasterDiffEngine.diff(
                baseline: base,
                revised: changed,
                frame: Self.frame(width, height),
                options: RasterDiffOptions(tolerance: .standard)
            )
            #expect(
                outcome.regions.isEmpty,
                "delta \(delta): \(outcome.regions.count) regions reported for a single pixel" as Comment
            )
            #expect(outcome.statistics.differingPixelCount <= 1, "delta \(delta)")
            if delta > 24 {
                // It was seen and then deliberately discarded, not missed.
                #expect(outcome.statistics.differingPixelCount == 1, "delta \(delta)")
                #expect(outcome.statistics.discardedRegionCount == 1, "delta \(delta)")
            } else {
                #expect(outcome.statistics.differingPixelCount == 0, "delta \(delta)")
            }
        }
    }

    @Test("A whole antialiasing fringe shifted by a gray level or two is not a change")
    func antialiasFringeDriftIsNotAChange() throws {
        // The realistic case: the same geometry rasterised by two runs whose transforms
        // differ in the last bits, so every fringe pixel along a diagonal moves by one or
        // two gray levels while the solid core is untouched. Under `.standard` that is
        // thousands of pixels of drift, and none of them may become a finding.
        let width = 300
        let height = 300
        let base = try Self.antialiasedDiagonal(width: width, height: height, offset: 0, fringeBias: 0)

        for bias in [-2, -1, 1, 2] {
            let drifted = try Self.antialiasedDiagonal(
                width: width, height: height, offset: 0, fringeBias: bias
            )
            // The fringe really did move — otherwise this test proves nothing.
            var movedPixels = 0
            for i in 0..<base.pixels.count where base.pixels[i] != drifted.pixels[i] {
                movedPixels += 1
            }
            #expect(movedPixels > 200, "bias \(bias): only \(movedPixels) fringe pixels moved" as Comment)

            let outcome = try RasterDiffEngine.diff(
                baseline: base,
                revised: drifted,
                frame: Self.frame(width, height),
                options: RasterDiffOptions(tolerance: .standard)
            )
            #expect(
                outcome.statistics.differingPixelCount == 0,
                "bias \(bias): \(outcome.statistics.differingPixelCount) pixels over the tolerance" as Comment
            )
            #expect(outcome.regions.isEmpty, "bias \(bias)")
        }
    }

    @Test("Real ink is still found next to the antialiasing the tolerance absorbs")
    func realInkIsStillFound() throws {
        // The counterweight: a tolerance that hides a one-pixel fringe must not also hide
        // a genuine mark. A 6 x 6 black square is 36 pixels of full-swing ink, three times
        // `minimumRegionPixelCount`, and must come back as exactly one region even while a
        // two-level fringe drift is happening everywhere else on the page.
        let width = 300
        let height = 300
        let base = try Self.antialiasedDiagonal(width: width, height: height, offset: 0, fringeBias: 0)
        var pixels = try Self.antialiasedDiagonal(
            width: width, height: height, offset: 0, fringeBias: 2
        ).pixels
        for y in 200..<206 {
            for x in 200..<206 { pixels[y * width + x] = 0 }
        }
        let revised = try GrayImage(width: width, height: height, pixels: pixels)

        let outcome = try RasterDiffEngine.diff(
            baseline: base,
            revised: revised,
            frame: Self.frame(width, height),
            options: RasterDiffOptions(tolerance: .standard)
        )
        #expect(outcome.regions.count == 1, "got \(outcome.regions.count) regions" as Comment)
        #expect(outcome.statistics.differingPixelCount == 36)
        #expect(outcome.statistics.addedPixelCount == 36)
        #expect(outcome.statistics.removedPixelCount == 0)
    }
}
