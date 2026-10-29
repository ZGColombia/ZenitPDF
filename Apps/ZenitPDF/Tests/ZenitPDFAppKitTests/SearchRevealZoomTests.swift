import CoreGraphics
import Testing
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Revealing a search hit must not change the zoom.
///
/// Found 2026-08-26: searching a drawing for *"Takplan"* found two hits, and clicking one
/// magnified the canvas to roughly 500 %. That was `ZoomMath.fit` doing exactly what it is for —
/// a word is a few points across, and fitting a few points to a viewport is an enormous zoom.
/// Right for `⌘*` on a selected markup; wrong for "show me where this word is", because the
/// reader loses the drawing around the word they were looking for.
@Suite(.appTierSerialised)
struct SearchRevealZoomTests {

    private let viewport = CGSize(width: 1200, height: 800)

    /// A word-sized run of text, the shape that produced the 500 %.
    private let word = PDFRectValue(x: 400, y: 620, width: 46, height: 9)

    @Test("A word-sized hit fits at ordinary zooms, so revealing it only scrolls")
    func wordFitsSoItScrolls() {
        for zoom in [0.25, 0.5, 1.0, 2.0, 4.0] {
            #expect(
                ZoomMath.fits(target: word, in: viewport, zoom: zoom),
                "a 46 × 9 pt word does not fit a 1200 × 800 viewport at \(zoom)× — it plainly does"
            )
        }
    }

    @Test("Centring keeps the zoom and puts the hit in the middle")
    func centringKeepsZoom() throws {
        let visible = try #require(ZoomMath.centred(target: word, in: viewport, zoom: 1.0))
        // The viewport in page space is the view size divided by the zoom.
        #expect(visible.size.width == 1200)
        #expect(visible.size.height == 800)
        // The hit's centre is the viewport's centre.
        let hitCentreX = word.origin.x + word.size.width / 2
        let hitCentreY = word.origin.y + word.size.height / 2
        #expect(abs((visible.minX + visible.size.width / 2) - hitCentreX) < 1e-9)
        #expect(abs((visible.minY + visible.size.height / 2) - hitCentreY) < 1e-9)
    }

    @Test("At 4× the visible page rect is a quarter as wide, still centred on the hit")
    func centringAtHigherZoom() throws {
        let visible = try #require(ZoomMath.centred(target: word, in: viewport, zoom: 4.0))
        #expect(visible.size.width == 300)
        #expect(visible.size.height == 200)
        let hitCentreX = word.origin.x + word.size.width / 2
        #expect(abs((visible.minX + visible.size.width / 2) - hitCentreX) < 1e-9)
    }

    @Test("Fitting the same word is the enormous zoom that was reported, which is why it is not used")
    func fitIsTheBug() throws {
        // Pinned so the difference between the two paths cannot quietly disappear: if `fit` ever
        // stops magnifying a word, this test says so and the reveal path can be simplified.
        let fit = try #require(ZoomMath.fit(target: word, in: viewport))
        #expect(fit.zoom > 20, "fit produced \(fit.zoom)×; the reported symptom was ~5× to 20×+")
    }

    @Test("A hit larger than the viewport cannot be scrolled into view, so it zooms out")
    func oversizedHitZoomsOut() {
        // A title block spanning most of an A1 sheet, viewed at 4×.
        let large = PDFRectValue(x: 0, y: 0, width: 2000, height: 1400)
        #expect(ZoomMath.fits(target: large, in: viewport, zoom: 4.0) == false)
        // …and at a zoom where it does fit, it scrolls like anything else.
        #expect(ZoomMath.fits(target: large, in: viewport, zoom: 0.4) == true)
    }

    @Test("Degenerate viewports and zooms resolve to nothing rather than dividing by zero")
    func degenerateInputs() {
        #expect(ZoomMath.centred(target: word, in: .zero, zoom: 1) == nil)
        #expect(ZoomMath.centred(target: word, in: viewport, zoom: 0) == nil)
        #expect(ZoomMath.centred(target: word, in: viewport, zoom: -1) == nil)
        #expect(ZoomMath.fits(target: word, in: .zero, zoom: 1) == false)
        #expect(ZoomMath.fits(target: word, in: viewport, zoom: 0) == false)
    }
}
