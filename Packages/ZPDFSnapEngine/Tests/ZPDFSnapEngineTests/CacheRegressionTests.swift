import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFVectorExtraction

/// Regressions in index building (BH-665, BH-666).
///
/// The vector layer cache these tests also covered (BH-666's cache half, IM-093) had no
/// production caller and was deleted with its tests (iteration 3, T-076); the primitive cap is
/// now asserted on ``SnapIndexBuilder``, the one path that builds an index.
@Suite("Index build and cache regressions")
struct CacheRegressionTests {

    typealias Fixtures = SnapIndexTests

    // MARK: - BH-665

    @Test("A page whose drawing is all on hidden layers says so, not 'no vector content' (BH-665)")
    func hiddenLayersAreNotAScannedPage() throws {
        let extraction = Fixtures.extraction(primitives: [
            Fixtures.layered(1, x: 100, layerID: "Walls"),
            Fixtures.layered(2, x: 200, layerID: "Walls"),
            Fixtures.layered(3, x: 300, layerID: "Grid")
        ])
        let index = try SnapIndexBuilder().build(
            page: try SnapScene.letterPage(), extraction: extraction, hiddenLayerIDs: ["Walls", "Grid"]
        )
        // Old output: .unavailable(.noVectorContent), message key
        // snap.vector.unavailable.noVectorContent — a scanned page, for a vector drawing whose
        // three primitives were filtered by the user's layer visibility.
        #expect(index.availability == .unavailable(.onlyFilteredGeometry(filteredCount: 3)))
        #expect(index.availability.messageKey == "snap.vector.unavailable.onlyFilteredGeometry")
        #expect(index.vectorPrimitiveCount == 0)
        #expect(!index.availability.allowsVectorCandidates)

        // A page that really has nothing keeps its reason.
        let empty = try SnapIndexBuilder().build(page: try SnapScene.letterPage(), extraction: Fixtures.extraction())
        #expect(empty.availability == .unavailable(.noVectorContent))
    }

    // MARK: - BH-666

    @Test("The builder honours the caller's primitive cap, markups counted (BH-666)")
    func builderHonoursLimits() throws {
        let page = try SnapScene.letterPage()
        let extraction = Fixtures.extraction(primitives: (0..<10).map { Fixtures.lineSegment($0) })
        let loose = try SnapIndexBuilder().build(page: page, extraction: extraction)
        #expect(loose.vectorPrimitiveCount == 10)

        // A cap of 5 on a 10-primitive page.
        let tight = SnapIndexLimits(maximumPrimitives: 5)
        #expect(throws: SnapEngineError.indexTooLarge(count: 10, limit: 5)) {
            _ = try SnapIndexBuilder(limits: tight).build(page: page, extraction: extraction)
        }

        // The vector layer fits a cap of 12, but with three markups the index holds 13.
        let twelve = SnapIndexLimits(maximumPrimitives: 12)
        let markups = (0..<3).map { i in
            SnapMarkupGeometry(
                id: MarkupID(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", i + 1)) ?? UUID()),
                geometry: [.point(PDFPoint(x: 400, y: 100 + Double(i)))],
                layerID: nil
            )
        }
        #expect(throws: SnapEngineError.indexTooLarge(count: 13, limit: 12)) {
            _ = try SnapIndexBuilder(limits: twelve).build(page: page, extraction: extraction, markups: markups)
        }
        let fits = try SnapIndexBuilder(limits: twelve).build(page: page, extraction: extraction, markups: Array(markups.prefix(2)))
        #expect(fits.primitiveCount == 12)
    }
}
