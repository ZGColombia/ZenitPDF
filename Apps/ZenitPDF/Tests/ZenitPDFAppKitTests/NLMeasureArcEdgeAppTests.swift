import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-05, first slice through the canvas: Measure ▸ Curve an Edge.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureArcEdgeAppTests {

    /// 100 pt = 1 m. A 1000 × 500 pt area is 10 × 5 m. Curving its right side through
    /// (1350, 350) makes the golden semicircle: area 50 + 3.125π m², perimeter 25 + 2.5π m.
    @Test("Curve an Edge bends the right side into the semicircle, measured exactly; one undo")
    func curveEdge() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Edge.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let bay = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .area, subject: "Bay", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 1100, y: 100), PDFPoint(x: 1100, y: 600), PDFPoint(x: 100, y: 600)
            ]))]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(bay))
        await core.refresh()
        core.canvas.select(markupIDs: [bay.id.rawValue], additive: false)
        harness.controller.beginCurveEdge(for: harness.document)
        #expect(CurveEdgePick.isArmed(harness.document))
        harness.controller.finishCalibration(points: [PDFPointValue(x: 1101, y: 350), PDFPointValue(x: 1350, y: 350)], for: harness.document)
        var area = 0.0
        for _ in 0..<150 {
            area = NSDecimalNumber(decimal: await core.session.markup(bay.id)?.measurement?[.netArea]?.value ?? 0).doubleValue
            if area > 51 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let expected = 50 + 3.125 * Double.pi
        #expect(Swift.abs(area - expected) <= expected * 1e-12)
        let perimeter = NSDecimalNumber(decimal: try #require(await core.session.markup(bay.id)?.measurement?[.perimeter]?.value)).doubleValue
        #expect(Swift.abs(perimeter - (25 + 2.5 * .pi)) <= (25 + 2.5 * .pi) * 1e-12)

        // The canvas draws the arc as an arc: the outline has far more than four points.
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        #expect(await AppTestSupport.wait {
            canvas.refresh()
            return (canvas.pageViewForTesting.shapes.first { $0.id == bay.id.rawValue }?.strokes.first?.points.count ?? 0) > 20
        })
        await core.commands.undo()
        let undone = NSDecimalNumber(decimal: try #require(await core.session.markup(bay.id)?.measurement?[.netArea]?.value)).doubleValue
        #expect(Swift.abs(undone - 50) <= 50 * 1e-12)
    }
}
