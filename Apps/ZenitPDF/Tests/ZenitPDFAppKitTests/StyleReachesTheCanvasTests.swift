import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// A style the Inspector writes has to reach the ink on the page.
///
/// The Inspector could read **#0433FF, 9 pt, 100 %, Dotted** over an arrow drawn thin, solid
/// and cyan-thin: colour changed the canvas and no other style did.
///
/// The reason is exact: `CanvasPageView.draw(_ shape:)` read `shape.color` and
/// **nothing else**. Every stroke was `path.lineWidth = ZPDFStroke.measurement`, a constant.
/// `shape.lineWidth` had been carried from the record into the scene all along and was never
/// used; `opacity`, `lineStyle` and `fontSize` were not carried at all. Colour worked because
/// colour was the one field the drawing code looked at.
///
/// So these assert the two halves separately, because they failed separately:
///
///   1. the record's style reaches the **scene** — `CanvasSceneBuilder` output;
///   2. the scene's style reaches the **stroke** — the dash table, which is pure.
@MainActor
@Suite(.appTierSerialised)
struct StyleReachesTheCanvasTests {

    private func record(
        style: MarkupStyle,
        pageID: PageID,
        documentID: DocumentID
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .line,
            tool: nil,
            subject: "Arrow",
            label: "A",
            author: "test",
            style: style,
            geometry: MeasurementGeometry(
                pageID: pageID,
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 200)]
            ),
            createdAt: Date(timeIntervalSince1970: 1_787_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    }

    @Test("Every style field the Inspector edits reaches the drawable scene")
    func styleReachesTheScene() throws {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        var style = MarkupStyle.default
        style.color = RGBAColor(red: 0.016, green: 0.2, blue: 1, alpha: 1)
        style.lineWidth = 9
        style.opacity = 0.4
        style.lineStyle = .dotted
        style.fontSize = 21

        let shapes = CanvasSceneBuilder.build(
            records: [record(style: style, pageID: pageID, documentID: documentID)],
            summaries: [],
            pageID: pageID.rawValue,
            captionOverrides: [:],
            artwork: [:]
        )
        let shape = try #require(shapes.first, "the record produced no drawable shape")

        #expect(shape.lineWidth == 9, "the stroke width never left the record")
        #expect(shape.opacity == 0.4, "the opacity never left the record")
        #expect(shape.lineStyle == .dotted, "the line style never left the record")
        #expect(shape.fontSize == 21, "the text size never left the record")
        #expect(abs(shape.color.blue - 1) < 0.001)
    }

    @Test("A dotted line is drawn dotted, and a solid one is not")
    func theDashTableIsRealised() {
        let path = NSBezierPath()

        CanvasPageView.applyDash(.solid, to: path, strokeWidth: 9)
        #expect(dashCount(of: path) == 0, "a solid line was given a dash pattern")

        CanvasPageView.applyDash(.dotted, to: path, strokeWidth: 9)
        #expect(dashCount(of: path) == 2, "a dotted line was drawn solid")
        #expect(path.lineCapStyle == .round, "a dot needs a round cap or it is a stub")

        CanvasPageView.applyDash(.dashed, to: path, strokeWidth: 9)
        #expect(dashCount(of: path) == 2)

        CanvasPageView.applyDash(.dashDot, to: path, strokeWidth: 9)
        #expect(dashCount(of: path) == 4)
    }

    @Test("The dash pattern scales with the stroke, so a 9 pt dotted line still reads as dotted")
    func theDashScalesWithTheStroke() {
        let thin = NSBezierPath()
        let thick = NSBezierPath()
        CanvasPageView.applyDash(.dotted, to: thin, strokeWidth: 1)
        CanvasPageView.applyDash(.dotted, to: thick, strokeWidth: 9)
        #expect(
            gapLength(of: thick) > gapLength(of: thin),
            """
            A fixed dash pattern makes a thick dotted line look solid: the dots grow with the \
            stroke and the gaps do not.
            """
        )
    }

    private func dashCount(of path: NSBezierPath) -> Int {
        var count = 0
        var phase: CGFloat = 0
        path.getLineDash(nil, count: &count, phase: &phase)
        return count
    }

    private func gapLength(of path: NSBezierPath) -> CGFloat {
        var count = 0
        var phase: CGFloat = 0
        path.getLineDash(nil, count: &count, phase: &phase)
        guard count >= 2 else { return 0 }
        var pattern = [CGFloat](repeating: 0, count: count)
        path.getLineDash(&pattern, count: &count, phase: &phase)
        return pattern[1]
    }
}

/// Found live, 2026-08-29: widening an Arrow's line made the head disappear —
/// it was a fixed 9 pt triangle drawn inside a stroke that had grown past it.
@MainActor
@Suite(.appTierSerialised)
struct ArrowheadScalingTests {

    @Test("The head grows with the stroke and always clears the line's own width")
    func headScalesWithStroke() {
        // Hairline: the floors keep the classic 9 × 3.5 head.
        let thin = CanvasPageView.arrowheadDimensions(strokeWidth: 1)
        #expect(thin.length == 9)
        #expect(thin.halfWidth == 3.5)

        // The reported case: a 9 pt line. The head must be wider than the line, or the
        // line swallows it — half the stroke is 4.5, so halfWidth must exceed that.
        let thick = CanvasPageView.arrowheadDimensions(strokeWidth: 9)
        #expect(thick.length > 9, "a 9 pt line needs a head longer than its own width")
        #expect(thick.halfWidth > 9 / 2,
                "the head must stick out past the stroke's edge on both sides")

        // Monotonic: a wider line never gets a smaller head.
        let wider = CanvasPageView.arrowheadDimensions(strokeWidth: 24)
        #expect(wider.length > thick.length)
        #expect(wider.halfWidth > thick.halfWidth)
    }
}
