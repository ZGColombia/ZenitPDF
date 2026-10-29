import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFMeasureDictionary
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-AUTO-19 / NL-MEASURE-16: Scale Regions proposed from the drawing file's viewports and from
/// printed viewport titles, added with their own ratio as one undo, the sheet's scale untouched.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureRegionOfferTests {

    /// Two viewports: the whole sheet at 1:100 (no box) and a detail box at 1:20.
    /// 1:100 → one point is 0.0254/72 × 100 m = 35.2777… mm; 1:20 → 7.05555… mm.
    static let viewports = "/VP [<< /Type /Viewport /Name (PLAN) /Measure << /Subtype /RL /R (1:100) /X [<< /U (mm) /C 35.2777777778 >>] >> >> "
        + "<< /Type /Viewport /Name (DETAIL 3) /BBox [1000 200 1500 700] /Measure << /Subtype /RL /R (1:20) /X [<< /U (mm) /C 7.05555555556 >>] >> >>]"

    @Test("The menu proposes the detail viewport; Add Scale Region installs it; the sheet keeps 1:100")
    func viewportBecomesRegion() async throws {
        let harness = try await NLMeasureR2Harness.make("Viewports.pdf", pageExtras: Self.viewports)
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        // Without a sheet scale the command asks for one first.
        harness.controller.beginFindScaleRegions(for: harness.document)
        #expect(await AppTestSupport.wait { ScaleSheetCoordinator.active(for: harness.document) != nil })
        ScaleSheetCoordinator.active(for: harness.document)?.cancel()

        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100, label: "1:100")
        let pageScale = try #require(await core.session.pageScale(harness.page))
        harness.controller.beginFindScaleRegions(for: harness.document)
        #expect(await AppTestSupport.wait {
            core.document.warnings.contains { $0.actionTitle == NSLocalizedString("Add Scale Region", comment: "") }
        })
        let offers = core.document.warnings.filter { ScaleRegionOffers.pending[$0.id] != nil }
        #expect(offers.count == 1, "the whole-page 1:100 viewport is the sheet's own scale, not a region")
        let offer = try #require(offers.first)
        #expect(offer.title.contains("1:20"))
        #expect(offer.message.contains("DETAIL 3"))

        #expect(harness.document.handleScaleRegionOffer(offer.id))
        #expect(await AppTestSupport.wait { !harness.core.document.warnings.contains { $0.id == offer.id } })
        let regions = await core.session.scaleRegionDefinitions
        #expect(regions.count == 1)
        let region = try #require(regions.first)
        #expect(region.name == "DETAIL 3")
        #expect(region.boundary == [PDFPoint(x: 1000, y: 200), PDFPoint(x: 1500, y: 200), PDFPoint(x: 1500, y: 700), PDFPoint(x: 1000, y: 700)])
        let regionScale = try #require(await core.session.scale(onPage: harness.page, scaleID: region.scaleID))
        #expect(regionScale.source == .preset)
        // 1:20 exactly: 0.0254 × 20 / 72 metres per point.
        #expect(regionScale.matrix.a == Decimal(string: "0.0254")! * 20 / 72)
        #expect(await core.session.pageScale(harness.page) == pageScale, "the sheet's scale is not replaced")

        // One undo takes the region and its scale back.
        await core.commands.undo()
        #expect(await core.session.scaleRegionDefinitions.isEmpty)
        #expect(await core.session.pageScale(harness.page) == pageScale)
    }

    /// A printed title at 1:20 under a drawing, on a 1:100 sheet, is offered; one at 1:100 is
    /// not (it is the sheet's own scale); a title whose drawing is already a file viewport is
    /// not said twice.
    @Test("Printed titles become candidates unless they repeat the sheet or a viewport")
    func titleCandidates() throws {
        func title(_ ratio: Int, _ region: (Double, Double, Double, Double), _ text: String) -> ViewportScaleProposal {
            let candidate = ScaleCandidate(
                ratio: ScaleRatio(numerator: 1, denominator: ratio)!,
                matchedText: "1:\(ratio)", sourceText: text,
                boundsInPageSpace: PDFRectValue(x: region.0, y: region.1 - 20, width: 100, height: 10),
                paperSizeHint: nil, hasExplicitPrefix: true, confidence: 1
            )
            return ViewportScaleProposal(ratio: candidate.ratio, evidence: candidate, region: PDFRectValue(x: region.0, y: region.1, width: region.2, height: region.3))
        }
        let detail = title(20, (100, 100, 300, 200), "DETAIL 3 SCALE 1:20")
        let plan = title(100, (600, 100, 800, 800), "PLAN 1:100")
        let found = ScaleRegionOffers.candidates(viewports: [], titles: [detail, plan], pageDenominator: 100, userUnit: 1)
        #expect(found.count == 1)
        #expect(found.first?.ratioDenominator == 20)
        #expect(found.first?.name == "DETAIL 3 SCALE 1:20")
        #expect(found.first?.boundary.first == PDFPoint(x: 100, y: 100))

        let url = try NLMeasureR2Harness.writeFixture(
            named: "D3.pdf",
            pageExtras: "/VP [<< /Name (D3) /BBox [90 90 410 310] /Measure << /Subtype /RL /R (1:20) /X [<< /U (mm) /C 7.05555555556 >>] >> >>]"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try #require(CGPDFDocument(url as CFURL))
        let viewport = try #require(PDFMeasureReader.viewports(in: pdf).first)
        #expect(viewport.ratioDenominator == 20)
        let both = ScaleRegionOffers.candidates(viewports: [viewport], titles: [detail], pageDenominator: 100, userUnit: 1)
        #expect(both.count == 1, "the title's drawing lies inside the file viewport: one region, said once")
        #expect(both.first?.name == "D3")
    }
}
