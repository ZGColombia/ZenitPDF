import CoreGraphics
import Foundation
import Testing
import ZPDFPDFKitBridge
@testable import ZPDFCompare

/// T-069: the overlay plan fits its scale with the bridge's helper, the one OCR uses, so a sheet
/// the old 0.1 %-step loop could not fit is planned instead of refused.
@Suite("Iter3 overlay plan fit")
struct Iter3OverlayPlanTests {

    @Test("T-069: a strip sheet whose exact-area scale is ten times over is planned within budget")
    func stripSheetIsPlanned() throws {
        // 10 000 × 0.01 pt at 10 000 pixels, wanted at scale 10. Old output: 64 steps of 0.999
        // reached scale 9.38 (93 798 × 1 pixels) and threw `pixelBudgetExceeded`, and
        // `RevisionComparator.inBudgetScale` then rendered at the unfitted scale 10.
        let plan = try OverlayCompositePlan.fit(
            pageBox: CGRect(x: 0, y: 0, width: 10_000, height: 0.01),
            requestedScale: 10, layerCount: 2, maximumPixels: 10_000
        )
        #expect(plan.pixelWidth == 9_901 && plan.pixelHeight == 1, "\(plan)")
        #expect(plan.pixelCount <= 10_000)
        #expect(plan.isReduced)
        #expect(plan.scale == RenderPixelSize.fittedScale(width: 10_000, height: 0.01, requested: 10, pixelBudget: 10_000))
    }

    @Test("T-069: the plan's scale and bitmap are the bridge's, on a letter sheet over its budget")
    func planMatchesTheBridge() throws {
        let plan = try OverlayCompositePlan.fit(
            pageBox: CGRect(x: 0, y: 0, width: 612, height: 792),
            requestedScale: 1, layerCount: 1, maximumPixels: 100_000
        )
        // The bridge's fit: 278 × 359 = 99 802 pixels (the exact-area scale would be 100 080).
        #expect(plan.scale == RenderPixelSize.fittedScale(width: 612, height: 792, requested: 1, pixelBudget: 100_000))
        #expect(plan.pixelWidth == 278 && plan.pixelHeight == 359)
        // A request that fits is not touched.
        let fits = try OverlayCompositePlan.fit(
            pageBox: CGRect(x: 0, y: 0, width: 612, height: 792),
            requestedScale: 0.25, layerCount: 1, maximumPixels: 100_000
        )
        #expect(fits.scale == 0.25 && !fits.isReduced)
    }
}
