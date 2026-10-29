import CoreGraphics
import Foundation
import Testing
import ZPDFCanvasCore

/// R-157: the dimension grammar's arrowheads never exceed a third of the path, as the
/// renderer's own dimension lines already did.
struct DimensionGrammarClampTests {

    private func headLength(_ decoration: DimensionGrammar.Decoration, _ index: Int) -> CGFloat {
        let head = decoration.arrowheads[index]
        let baseMid = CGPoint(x: (head[1].x + head[2].x) / 2, y: (head[1].y + head[2].y) / 2)
        return ((baseMid.x - head[0].x) * (baseMid.x - head[0].x) + (baseMid.y - head[0].y) * (baseMid.y - head[0].y)).squareRoot()
    }

    /// Old output: two 9-point heads on a 12-point span — bases at x = 9 and x = 3, crossed.
    @Test("R-157: a 12-point dimension gets two 4-point heads that do not cross")
    func shortSpanClampsArrows() {
        let decoration = DimensionGrammar.decoration(forViewPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 12, y: 0)])
        // By hand: 12 / 3 = 4 points each; first base at x = 4, last base at x = 8.
        #expect(abs(headLength(decoration, 0) - 4) < 1e-9)
        #expect(abs(headLength(decoration, 1) - 4) < 1e-9)
        #expect(decoration.arrowheads[0][1].x < decoration.arrowheads[1][1].x)
        // The tips are still the measured points, exactly.
        #expect(decoration.arrowheads[0][0] == CGPoint(x: 0, y: 0))
        #expect(decoration.arrowheads[1][0] == CGPoint(x: 12, y: 0))
    }

    @Test("R-157: from 27 points up the heads are full size; a polyline clamps by its whole length")
    func longSpansAreUnclamped() {
        let exact = DimensionGrammar.decoration(forViewPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 27, y: 0)])
        #expect(abs(headLength(exact, 0) - DimensionGrammar.arrowLength) < 1e-9)
        // Two legs of 6: 12 in all, so 4-point heads.
        let bent = DimensionGrammar.decoration(forViewPoints: [
            CGPoint(x: 0, y: 0), CGPoint(x: 6, y: 0), CGPoint(x: 6, y: 6)
        ])
        #expect(abs(headLength(bent, 0) - 4) < 1e-9)
        #expect(abs(headLength(bent, 1) - 4) < 1e-9)
    }
}
