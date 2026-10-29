import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Bug hunt 2, batch placement geometry and display guards.
@Suite("Fix2 batch placement")
struct Fix2BatchAndGeometryTests {

    /// BH-051. Old output on the /Rotate 90 sheet: centre (30, 430) — the 100 × 40 stamp spanned
    /// x = -20…80, 20 pt off the sheet, and sat 50 pt from the visual right edge instead of 20.
    @Test("A stamp on a rotated page lands inside the sheet at the inset the estimator typed")
    func rotatedPlacementStaysOnTheSheet() {
        let box = PDFRectValue(x: 0, y: 0, width: 1000, height: 500)
        let size = PDFSizeValue(width: 100, height: 40)
        let anchor = BatchAnchor.corner(.topRight, insetX: 20, insetY: 10)

        let turned = BatchPlacementGeometry.anchorPoint(in: box, rotation: .degrees90, anchor: anchor, size: size)
        #expect(abs(turned.x - 60) < 1e-9)
        #expect(abs(turned.y - 460) < 1e-9)
        // Screen right edge is page-space maxY, screen top edge is page-space minX on a 90° page.
        #expect(abs((box.maxY - (turned.y + size.height / 2)) - 20) < 1e-9)
        #expect(abs(((turned.x - size.width / 2) - box.minX) - 10) < 1e-9)

        for rotation in PageRotation.allCases {
            for corner in [BatchAnchorCorner.topLeft, .topRight, .bottomLeft, .bottomRight] {
                let point = BatchPlacementGeometry.anchorPoint(
                    in: box, rotation: rotation,
                    anchor: .corner(corner, insetX: 20, insetY: 10), size: size
                )
                #expect(point.x - size.width / 2 >= box.minX - 1e-9, "\(rotation) \(corner)")
                #expect(point.x + size.width / 2 <= box.maxX + 1e-9, "\(rotation) \(corner)")
                #expect(point.y - size.height / 2 >= box.minY - 1e-9, "\(rotation) \(corner)")
                #expect(point.y + size.height / 2 <= box.maxY + 1e-9, "\(rotation) \(corner)")
            }
        }
    }

    /// BH-268 / BH-763. Old output: "Fatal error: Double value cannot be converted to Int because
    /// it is either infinite or NaN" (or "…because the result would be greater than Int.max").
    @Test("Size-scope and inset names never trap on pasted extremes")
    func displayNamesSurviveExtremes() {
        for bad in [1e22, -1e22, Double.infinity, -Double.infinity, Double.nan] {
            let scope = BatchPageScope.matchingSize(widthPoints: bad, heightPoints: 10, tolerancePoints: 1)
            #expect(!scope.displayName.isEmpty)
            let anchor = BatchAnchor.corner(.topLeft, insetX: bad, insetY: bad)
            #expect(!anchor.displayName.isEmpty)
        }
        #expect(BatchDisplayInteger.clamped(12.5) == 13)
        #expect(BatchDisplayInteger.clamped(.nan) == 0)
    }

    /// IM-021. The old single helper answered 3.5 pt for a 7-point tolerance on a 2× display
    /// and 7 pt on a 1× one; the view-point helper answers the same on both.
    @Test("A view-point tolerance does not depend on the backing scale")
    func viewPointToleranceIgnoresBackingScale() {
        let page = UUID()
        func viewport(zoom: Double, scale: Double) -> ViewportSnapshot {
            ViewportSnapshot(pageID: page, pageIndex: 0, zoom: zoom,
                             visiblePageRect: PDFRectValue(x: 0, y: 0, width: 100, height: 100),
                             backingScaleFactor: scale, displayMode: .continuous)
        }
        #expect(viewport(zoom: 2, scale: 2).pageDistance(forViewPoints: 7) == 3.5)
        #expect(viewport(zoom: 2, scale: 1).pageDistance(forViewPoints: 7) == 3.5)
        #expect(viewport(zoom: 0, scale: 2).pageDistance(forViewPoints: 7) == 0)
    }
}
