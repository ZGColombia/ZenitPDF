import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-AUTO-19 / NL-MEASURE-16: a drawing ratio for one part of a sheet, installed as a Scale
/// Region with its own preset scale, never replacing the sheet's own scale.
@Suite("Region preset scale (NL-AUTO-19)")
struct NLMeasureRegionScaleTests {

    static let documentID = NLMeasureScaleEntryTests.documentID

    static let detail: [PDFPoint] = [
        PDFPoint(x: 100, y: 100), PDFPoint(x: 400, y: 100), PDFPoint(x: 400, y: 300), PDFPoint(x: 100, y: 300)
    ]

    /// A 1:100 sheet with a 1:20 detail. The region's scale is `ScaleTransform.preset(1, 20)`,
    /// the page keeps its 1:100 scale (same id, same version), and a 72 pt line measured under the
    /// region scale is 72 × 0.0254 × 20 / 72 = 0.508 m (hand-derived: one inch of paper at 1:20).
    @Test("Adds a region and its scale; the page scale is untouched")
    func regionScaleLeavesThePageScale() async throws {
        let pages = NLMeasureScaleEntryTests.pages(count: 1)
        let page = pages[0].id
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        _ = try await session.setPresetScale(page: page, ratioDenominator: 100, label: "1:100")
        let before = try #require(await session.pageScale(page))

        let result = try await session.addRegionPresetScale(
            page: page, ratioDenominator: 20, label: "1:20", boundary: Self.detail, name: "Detail 3"
        )
        let after = try #require(await session.pageScale(page))
        #expect(after == before, "the sheet's own scale is neither replaced nor re-versioned")
        let regions = await session.scaleRegionDefinitions
        #expect(regions.count == 1)
        let region = try #require(regions.first)
        #expect(region.name == "Detail 3")
        #expect(region.scaleID == result.scaleID)
        #expect(region.boundary == Self.detail)
        #expect(region.priority == 1)

        let regionScale = try #require(await session.scale(onPage: page, scaleID: result.scaleID))
        #expect(regionScale.source == .preset)
        #expect(regionScale.matrix == (try ScaleTransform.preset(
            id: result.scaleID, page: pages[0], version: 1, ratioDenominator: 20, units: .metric
        )).matrix)
        #expect(await session.evidence(for: result.scaleID) == nil)

        var line = NLMeasureScaleEntryTests.length(on: page, from: (150, 150), to: (222, 150))
        line.scaleID = result.scaleID
        line.scaleRegionID = region.id
        _ = try await session.apply(.addMarkup(line))
        let measured = try #require(await session.markup(line.id)?.measurement?[.planLength]?.value)
        let expected = Decimal(string: "0.508")!
        #expect(Swift.abs(NSDecimalNumber(decimal: (measured - expected) / expected).doubleValue) <= 1e-12)
    }

    /// One ⌘Z takes the region and its scale back together; redo brings both.
    @Test("One undo removes region and scale")
    func oneUndo() async throws {
        let pages = NLMeasureScaleEntryTests.pages(count: 1)
        let page = pages[0].id
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        _ = try await session.setPresetScale(page: page, ratioDenominator: 100)
        let result = try await session.addRegionPresetScale(
            page: page, ratioDenominator: 20, boundary: Self.detail, name: ""
        )
        #expect(await session.scaleRegionDefinitions.first?.name == "1:20", "an empty name falls back to the ratio")
        let redo = try await session.revert(result.outcome.inverse)
        #expect(await session.scaleRegionDefinitions.isEmpty)
        #expect(await session.scale(onPage: page, scaleID: result.scaleID)?.id != result.scaleID)
        #expect(await session.pageScale(page) != nil)
        _ = try await session.revert(redo)
        #expect(await session.scaleRegionDefinitions.count == 1)
        #expect(await session.scale(onPage: page, scaleID: result.scaleID)?.id == result.scaleID)
    }

    /// A sheet with no scale refuses: the region scale would become the whole sheet's scale
    /// (BH-432). Nothing changes.
    @Test("Refused on a sheet with no scale")
    func refusedWithoutPageScale() async throws {
        let pages = NLMeasureScaleEntryTests.pages(count: 1)
        let page = pages[0].id
        let session = try TakeoffSession(documentID: Self.documentID, pages: pages, units: .metric)
        await #expect(throws: DocumentCommandError.noScale(page)) {
            _ = try await session.addRegionPresetScale(page: page, ratioDenominator: 20, boundary: Self.detail, name: "D")
        }
        #expect(await session.pageScale(page) == nil)
        #expect(await session.scaleRegionDefinitions.isEmpty)
        _ = try await session.setPresetScale(page: page, ratioDenominator: 100)
        await #expect(throws: DocumentCommandError.self) {
            _ = try await session.addRegionPresetScale(
                page: page, ratioDenominator: 20, boundary: Array(Self.detail.prefix(2)), name: "D"
            )
        }
        #expect(await session.scaleRegionDefinitions.isEmpty)
    }
}
