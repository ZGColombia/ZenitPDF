import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The Select tool's hit rule, stated once and asserted without a window.
///
/// The rule the canvas used to apply was `shape.bounds` padded by six screen points, which
/// is why a click in the notch of an L-shaped area selected it and why a click in the empty
/// middle of an outlined rectangle selected the rectangle. Both are here.
@Suite(.appTierSerialised)
struct CanvasHitTestingTests {

    private func shape(
        points: [PDFPointValue],
        closed: Bool,
        filled: Bool,
        counts: [PDFPointValue] = [],
        textBox: PDFRectValue? = nil
    ) -> CanvasMarkupShape {
        CanvasMarkupShape(
            id: UUID(),
            pageID: UUID(),
            color: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1),
            strokes: points.isEmpty
                ? []
                : [CanvasStroke(points: points, closed: closed, filled: filled)],
            counts: counts,
            bounds: PDFRectValue(x: 0, y: 0, width: 100, height: 100),
            hidden: false,
            textBox: textBox
        )
    }

    /// An L whose bounding box is 0…100 square; the notch is the top-right quadrant.
    private var lShape: CanvasMarkupShape {
        shape(
            points: [
                PDFPointValue(x: 0, y: 0),
                PDFPointValue(x: 100, y: 0),
                PDFPointValue(x: 100, y: 40),
                PDFPointValue(x: 40, y: 40),
                PDFPointValue(x: 40, y: 100),
                PDFPointValue(x: 0, y: 100)
            ],
            closed: true,
            filled: true
        )
    }

    @Test("A filled area is selected by its interior, and not by the empty part of its box")
    func fillIsTheHitAreaAndTheBoxIsNot() {
        #expect(CanvasHitTesting.shape(lShape, contains: PDFPointValue(x: 20, y: 20), tolerance: 6))
        #expect(!CanvasHitTesting.shape(lShape, contains: PDFPointValue(x: 80, y: 80), tolerance: 6),
                "the notch is inside the bounding box and outside the shape")
        #expect(!CanvasHitTesting.shape(lShape, contains: PDFPointValue(x: 130, y: 50), tolerance: 6))
    }

    @Test("An unfilled closed outline is a frame: only its edge selects it")
    func anOutlineIsGrabbedByItsEdge() {
        let frame = shape(
            points: [
                PDFPointValue(x: 0, y: 0),
                PDFPointValue(x: 100, y: 0),
                PDFPointValue(x: 100, y: 100),
                PDFPointValue(x: 0, y: 100)
            ],
            closed: true,
            filled: false
        )
        #expect(!CanvasHitTesting.shape(frame, contains: PDFPointValue(x: 50, y: 50), tolerance: 6),
                "a rectangle drawn to ring a detail must leave the detail clickable")
        #expect(CanvasHitTesting.shape(frame, contains: PDFPointValue(x: 50, y: 2), tolerance: 6))
        #expect(CanvasHitTesting.shape(frame, contains: PDFPointValue(x: 0, y: 50), tolerance: 6),
                "the closing edge is an edge like any other")
    }

    @Test("An open path is selected near the line, and the tolerance is exactly the tolerance")
    func anOpenPathIsGrabbedNearTheLine() {
        let line = shape(
            points: [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0)],
            closed: false,
            filled: false
        )
        #expect(CanvasHitTesting.shape(line, contains: PDFPointValue(x: 50, y: 5), tolerance: 6))
        #expect(!CanvasHitTesting.shape(line, contains: PDFPointValue(x: 50, y: 7), tolerance: 6))
        #expect(!CanvasHitTesting.shape(line, contains: PDFPointValue(x: 110, y: 0), tolerance: 6),
                "past the end of the segment is past the end of the segment")
    }

    @Test("Count marks and text boxes are their own hit areas")
    func countsAndTextAreSelectable() {
        let marks = shape(
            points: [],
            closed: false,
            filled: false,
            counts: [PDFPointValue(x: 200, y: 200)]
        )
        #expect(CanvasHitTesting.shape(marks, contains: PDFPointValue(x: 203, y: 200), tolerance: 6))
        #expect(!CanvasHitTesting.shape(marks, contains: PDFPointValue(x: 240, y: 200), tolerance: 6))

        let text = shape(
            points: [],
            closed: false,
            filled: false,
            textBox: PDFRectValue(x: 10, y: 10, width: 80, height: 20)
        )
        #expect(CanvasHitTesting.shape(text, contains: PDFPointValue(x: 50, y: 20), tolerance: 6),
                "a text markup has no outline and must still be selectable")
    }

    @Test("A marquee catches what it crosses, not only what it encloses")
    func marqueeIntersects() {
        let markup = lShape
        #expect(CanvasHitTesting.shape(markup, intersects: PDFRectValue(x: 90, y: 90, width: 40, height: 40)),
                "an estimator dragging over a wall run expects to catch the run it crosses")
        #expect(CanvasHitTesting.shape(markup, intersects: PDFRectValue(x: -10, y: -10, width: 200, height: 200)))
        #expect(!CanvasHitTesting.shape(markup, intersects: PDFRectValue(x: 200, y: 200, width: 10, height: 10)))
    }
}
