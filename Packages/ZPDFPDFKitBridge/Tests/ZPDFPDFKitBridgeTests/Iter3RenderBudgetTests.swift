import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// T-069: the render's ceil-per-axis sizing rule and the scale fitted to it live in one place,
/// beside the render, for Revision Compare's overlay plan and OCR alike.
@Suite("Iter3 render pixel budget")
struct Iter3RenderBudgetTests {

    @Test("T-069: a strip sheet ten times over at the exact-area scale still gets a fitting scale")
    func stripSheetFits() {
        // 10 000 × 0.01 pt at a 10 000-pixel budget: the exact-area scale is 10, which renders
        // 100 000 × 1 pixels. The root of (10 000·s + 1)(0.01·s + 1) = 10 000 is 0.990 096…,
        // which renders 9 901 × 1. The overlay's old loop reached 10 × 0.999⁶⁴ = 9.38 at most
        // (93 798 × 1 pixels) and threw.
        let scale = RenderPixelSize.fittedScale(width: 10_000, height: 0.01, requested: 10, pixelBudget: 10_000)
        #expect(abs(scale - 0.990_096_106_895) < 1e-9, "\(scale)")
        #expect(RenderPixelSize.renderedDimension(10_000, scale: scale) == 9_901)
        #expect(RenderPixelSize.renderedDimension(0.01, scale: scale) == 1)
    }

    @Test("T-069: unusable arguments give 0; a request that fits is returned untouched")
    func edges() {
        #expect(RenderPixelSize.fittedScale(width: 0, height: 10, requested: 1, pixelBudget: 100) == 0)
        #expect(RenderPixelSize.fittedScale(width: 10, height: 10, requested: .nan, pixelBudget: 100) == 0)
        #expect(RenderPixelSize.fittedScale(width: 10, height: 10, requested: 1, pixelBudget: 0) == 0)
        #expect(RenderPixelSize.fittedScale(width: 612, height: 792, requested: 0.5, pixelBudget: 64_000_000) == 0.5)
    }

    @Test("T-069: the fitted scale renders, through the real provider, exactly the bitmap the rule predicts, within budget")
    func providerAgreesWithTheRule() async throws {
        // A letter page at a 100 000-pixel budget: the exact-area scale 0.454 215… renders
        // ⌈278.0⌉ × ⌈359.7⌉ = 278 × 360 = 100 080, over; the root 0.452 766… renders 278 × 359
        // = 99 802.
        let budget = 100_000
        let exactArea = (Double(budget) / (612.0 * 792.0)).squareRoot()
        #expect(RenderPixelSize.renderedDimension(612, scale: exactArea) * RenderPixelSize.renderedDimension(792, scale: exactArea) == 100_080)
        let scale = RenderPixelSize.fittedScale(width: 612, height: 792, requested: 1, pixelBudget: budget)
        #expect(abs(scale - 0.452_766_967_585) < 1e-9, "\(scale)")

        let provider = PDFKitDocumentProvider()
        var limits = DocumentLimits.standard
        limits.maximumRenderPixels = budget
        let opened = try await provider.open(.url(Corpus.url(.rectangle)), password: nil, limits: limits)
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(document: opened.handle, pageIndex: 0, box: .media, scale: CGFloat(scale))
        )
        #expect(rendered.pixelWidth == 278 && rendered.pixelHeight == 359)
        #expect(Double(rendered.pixelWidth) == RenderPixelSize.renderedDimension(612, scale: scale))
        #expect(Double(rendered.pixelHeight) == RenderPixelSize.renderedDimension(792, scale: scale))
        // And the exact-area scale is refused by the same provider: the rule is the render's.
        await #expect(throws: PDFBridgeError.pixelBudgetExceeded(requestedPixels: 100_080, limit: budget)) {
            _ = try await provider.renderPageRegion(
                PageRenderRequest(document: opened.handle, pageIndex: 0, box: .media, scale: CGFloat(exactArea))
            )
        }
        await provider.closeAll()
    }
}
