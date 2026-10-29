import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// U-072 (iteration 4, ui-presentation-measure): a clouded ellipse whose box is huge but finite
/// used to trap in `Int(_:)` before its facet count was clamped. Pure geometry; no view, no window.
@Suite("Clouded ellipse stays bounded — U-072", .appTierSerialised)
struct Iter4CloudBoundAppTests {

    /// Old output: `Int((perimeter / (radius * 2)).rounded())` on a perimeter of about 4.4e30
    /// trapped, crashing the scene build on every draw of the page.
    @Test("A 1e30 pt box does not trap and falls back to the minimum facet count")
    func hugeBoxDoesNotTrap() {
        let box = PDFRectValue(x: 0, y: 0, width: 1e30, height: 4e29)
        let outline = CanvasSceneBuilder.cloudedEllipse(in: box, radius: 8)
        // 360 facets (the clamp); every facet touches a vertex past the 1e7 pt coordinate bound,
        // so each is drawn straight: one point per facet.
        #expect(outline.count == 360)
    }

    @Test("An infinite perimeter (box past 1e308) does not trap")
    func infinitePerimeterDoesNotTrap() {
        let box = PDFRectValue(x: 0, y: 0, width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let outline = CanvasSceneBuilder.cloudedEllipse(in: box, radius: 8)
        #expect(outline.count <= 360)
    }

    @Test("An ordinary clouded ellipse keeps its facet rule")
    func ordinaryEllipseUnchanged() {
        // A 200 x 200 circle at radius 10: perimeter 200π ≈ 628.3, / 20 ≈ 31.4 → 31 facets; each
        // facet (≈ 20.2 pt) gets one scallop of 12 points: 372 points.
        let outline = CanvasSceneBuilder.cloudedEllipse(in: PDFRectValue(x: 0, y: 0, width: 200, height: 200), radius: 10)
        #expect(outline.count == 372)
    }
}
