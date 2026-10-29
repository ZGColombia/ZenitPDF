import CoreGraphics
import Foundation
import Testing
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// End-to-end Revision Compare over real PDFs: render, align, diff, classify.
///
/// The pairs are built from the `geo-l-shape` fixture's manifest — the fixture's own
/// page and its own six ring edges — with one edge moved, one added and one deleted.
/// Because every coordinate and every stroke width is an even integer, the ink lands on
/// whole pixels at every scale used here and the expected region bounds are exact rather
/// than approximate. `regionTolerance` is therefore zero-ish: it exists only to absorb
/// the last bit of `Double` arithmetic in the pixel-to-page conversion.
struct RevisionCompareTests {

    static let regionTolerance = 1e-9

    // MARK: - The test that catches most diff bugs

    @Test("A page compared with itself yields zero differences at three render scales")
    func selfComparisonHasNoDifferences() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        for scale in [1.0, 2.0, 3.0] {
            let result = try await harness.compare(scale: scale)
            #expect(result.rasterRegions.isEmpty, "scale \(scale)")
            #expect(result.rasterStatistics.differingPixelCount == 0, "scale \(scale)")
            #expect(result.rasterStatistics.isIdentical, "scale \(scale)")
            let vector = try #require(result.vector, "scale \(scale)")
            #expect(vector.isMeaningful)
            #expect(vector.differences.isEmpty, "scale \(scale)")
            #expect(vector.unchangedCount == 6, "scale \(scale)")
            #expect(result.differenceCount == 0, "scale \(scale)")
            #expect(result.isIdentical, "scale \(scale)")
        }
    }

    @Test("A fixture sheet compared with itself is identical, not merely nearly identical")
    func fixtureSelfComparisonIsExactlyEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-self-\(UUID().uuidString)", isDirectory: true)
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
        let result = try await comparator.compare(
            RevisionCompareRequest(
                baseline: reference,
                revised: reference,
                renderScale: 2,
                alignment: .automatic(.standard),
                raster: RasterDiffOptions(tolerance: .strict)
            )
        )
        #expect(result.rasterRegions.isEmpty)
        #expect(result.rasterStatistics.differingPixelCount == 0)
        #expect(result.alignment.transform.isIdentity())
        #expect(result.alignment.provenance == .pageBox)
        let vector = try #require(result.vector)
        #expect(vector.differences.isEmpty)
        #expect(vector.unchangedCount == vector.baselinePrimitiveCount)
    }

    // MARK: - Constructed mutations

    @Test("A moved edge is reported as one removal at the old place and one addition at the new")
    func movedEdgeIsClassifiedAndBounded() async throws {
        let pair = try RevisionCorpus.make(.movedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 2)
        #expect(result.rasterRegions.count == 2)

        let original = try #require(pair.edge(RevisionCorpus.movedEdgeIdentifier)).inkRect
        let moved = original.offsetBy(
            dx: RevisionCorpus.moveDelta.dx, dy: RevisionCorpus.moveDelta.dy
        )
        let removed = try #require(result.rasterRegions.first { $0.classification == .removed })
        let added = try #require(result.rasterRegions.first { $0.classification == .added })
        #expect(
            rectsAreEqual(removed.pageBounds, original, tolerance: Self.regionTolerance),
            "removed \(describe(removed.pageBounds)) expected \(describe(original))"
        )
        #expect(
            rectsAreEqual(added.pageBounds, moved, tolerance: Self.regionTolerance),
            "added \(describe(added.pageBounds)) expected \(describe(moved))"
        )
        // Solid black on white across the whole region: nothing marginal about it.
        #expect(removed.confidence == 1)
        #expect(added.confidence == 1)
        // 118 x 4 pt of ink at 2 px per point.
        #expect(removed.changedPixelCount == 236 * 8)
        #expect(added.changedPixelCount == 236 * 8)
    }

    @Test("An added edge is reported as exactly one added region with the ink's exact bounds")
    func addedEdgeIsClassifiedAndBounded() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 2)
        #expect(result.rasterRegions.count == 1)
        let region = try #require(result.rasterRegions.first)
        #expect(region.classification == .added)
        #expect(region.removedPixelCount == 0)
        #expect(
            rectsAreEqual(
                region.pageBounds, RevisionCorpus.addedEdge.inkRect, tolerance: Self.regionTolerance
            ),
            "added \(describe(region.pageBounds))"
        )
        #expect(region.signal == .raster)
    }

    @Test("A deleted edge is reported as exactly one removed region with the ink's exact bounds")
    func deletedEdgeIsClassifiedAndBounded() async throws {
        let pair = try RevisionCorpus.make(.deletedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 2)
        #expect(result.rasterRegions.count == 1)
        let region = try #require(result.rasterRegions.first)
        #expect(region.classification == .removed)
        #expect(region.addedPixelCount == 0)
        let expected = try #require(pair.edge(RevisionCorpus.deletedEdgeIdentifier)).inkRect
        #expect(
            rectsAreEqual(region.pageBounds, expected, tolerance: Self.regionTolerance),
            "removed \(describe(region.pageBounds)) expected \(describe(expected))"
        )
    }

    @Test("All three mutations at once give exactly four regions, in page scan order")
    func allMutationsTogether() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 2)
        #expect(result.rasterRegions.count == 4)
        #expect(result.rasterRegions.filter { $0.classification == .added }.count == 2)
        #expect(result.rasterRegions.filter { $0.classification == .removed }.count == 2)
        // Ids are handed out in raster scan order — top of the sheet first — so a
        // "next difference" button walks the page rather than a hash table.
        #expect(result.rasterRegions.map(\.id) == [0, 1, 2, 3])
        let pixelTops = result.rasterRegions.compactMap { $0.pixelBounds?.minY }
        #expect(pixelTops == pixelTops.sorted())

        let expected: Set<String> = [
            describe(RevisionCorpus.addedEdge.inkRect),
            describe(try #require(pair.edge(RevisionCorpus.deletedEdgeIdentifier)).inkRect),
            describe(try #require(pair.edge(RevisionCorpus.movedEdgeIdentifier)).inkRect),
            describe(
                try #require(pair.edge(RevisionCorpus.movedEdgeIdentifier)).inkRect
                    .offsetBy(dx: RevisionCorpus.moveDelta.dx, dy: RevisionCorpus.moveDelta.dy)
            )
        ]
        #expect(Set(result.rasterRegions.map { describe($0.pageBounds) }) == expected)
    }

    // MARK: - Scale independence and tolerance

    @Test("The same difference is found at two render scales with the same page bounds")
    func regionsAgreeAcrossRenderScales() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let coarse = try await harness.compare(scale: 1)
        let fine = try await harness.compare(scale: 3)
        #expect(coarse.rasterRegions.count == 4)
        #expect(fine.rasterRegions.count == 4)
        for (a, b) in zip(coarse.rasterRegions, fine.rasterRegions) {
            #expect(a.classification == b.classification)
            #expect(
                rectsAreEqual(a.pageBounds, b.pageBounds, tolerance: Self.regionTolerance),
                "\(describe(a.pageBounds)) vs \(describe(b.pageBounds))"
            )
        }
        // Nine times the pixels at three times the scale, and the same nine-times ratio
        // in the differing-pixel count: the tolerance did not quietly change behaviour.
        #expect(fine.rasterStatistics.differingPixelCount
            == coarse.rasterStatistics.differingPixelCount * 9)
    }

    @Test("The intensity tolerance absorbs a uniform paper shift at both render scales")
    func toleranceAbsorbsPaperShiftAtTwoScales() async throws {
        let pair = try RevisionCorpus.make(.none)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        for scale in [1.0, 2.0] {
            let rendered = try await harness.comparator.render(harness.baseline, scale: scale)
            // A uniform 20-level darkening: exactly what a different paper white or a
            // different plotter gamma does to a scan. Real, and not a design change.
            let shifted = try GrayImage(
                width: rendered.image.width,
                height: rendered.image.height,
                pixels: rendered.image.pixels.map { UInt8(max(0, Int($0) - 20)) }
            )

            let standard = try RasterDiffEngine.diff(
                baseline: rendered.image, revised: shifted, frame: rendered.frame,
                options: RasterDiffOptions(tolerance: .standard)
            )
            #expect(standard.regions.isEmpty, "scale \(scale)")
            #expect(standard.statistics.differingPixelCount == 0, "scale \(scale)")

            let strict = try RasterDiffEngine.diff(
                baseline: rendered.image, revised: shifted, frame: rendered.frame,
                options: RasterDiffOptions(tolerance: .strict)
            )
            // Every paper pixel moved, so the strict pass sees essentially the whole
            // sheet — the tolerance is doing the work, not the geometry.
            #expect(strict.statistics.differingPixelCount > 0, "scale \(scale)")
            #expect(
                strict.statistics.differingFraction > 0.9,
                "scale \(scale) saw \(strict.statistics.differingFraction)"
            )
            #expect(strict.statistics.addedPixelCount == strict.statistics.differingPixelCount)
        }
    }

    // MARK: - The two signals stay apart

    @Test("Raster findings and geometry findings are tagged and never merged")
    func signalsStaySeparate() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 2)
        let vector = try #require(result.vector)
        #expect(result.rasterRegions.allSatisfy { $0.signal == .raster })
        #expect(vector.regions.allSatisfy { $0.signal == .vector })
        // The pixel signal sees four separate clouds; the geometry signal sees three
        // edits, one of which it can name as a move. Neither number is wrong, and the
        // result reports both rather than picking one.
        #expect(result.rasterRegions.count == 4)
        #expect(vector.regions.count == 3)
        #expect(result.differenceCount == 7)

        let combined = result.allRegions
        #expect(combined.count == 7)
        #expect(combined.map(\.id) == Array(0..<7))
        #expect(combined.filter { $0.signal == .raster }.count == 4)
        #expect(combined.filter { $0.signal == .vector }.count == 3)
        // A raster region never carries geometry detail, and a vector region never
        // carries a pixel count.
        #expect(combined.filter { $0.signal == .raster }.allSatisfy { $0.vectorDetail == nil })
        #expect(combined.filter { $0.signal == .vector }.allSatisfy { $0.changedPixelCount == 0 })
    }

    @Test("Turning the vector signal off leaves the raster signal untouched")
    func vectorSignalIsOptional() async throws {
        let pair = try RevisionCorpus.make(.addedEdge)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let result = try await harness.compare(scale: 2, includesVectorSignal: false)
        #expect(result.vector == nil)
        #expect(result.rasterRegions.count == 1)
        #expect(result.differenceCount == 1)
    }

    // MARK: - Cancellation

    @Test("A cancelled comparison throws the typed cancellation fault")
    func cancellationIsTyped() async throws {
        let pair = try RevisionCorpus.make(.all)
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair)
        defer { Task { await harness.close() } }

        let task = Task { [harness] in
            try await harness.compare(scale: 2)
        }
        task.cancel()
        await #expect(throws: CompareFault.self) { try await task.value }
    }
}
