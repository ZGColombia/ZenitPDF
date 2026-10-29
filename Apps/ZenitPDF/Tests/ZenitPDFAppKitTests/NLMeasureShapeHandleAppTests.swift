import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-06 on the canvas: a stored arc's end handle is dragged with the Select tool and the
/// arc length recomputes, one undo back.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureShapeHandleAppTests {

    /// 1:100 (72 pt = 2.54 m, so 1 pt = 2.54/72 m). An arc at (400, 400), r 72 pt, sweeping a
    /// quarter from 0: length 72 · π/2 pt = 2.54 · π/2 m. Dragging its end handle from (400, 472)
    /// to (328, 400) makes a half: 2.54 · π m (hand-derived).
    @Test("Dragging an arc's end handle recomputes its length; one undo restores it")
    func dragArcEnd() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        // Handles drag with snap since iteration 5 (V-001): with the default grid on, the release
        // at (328, 400) lands on the grid point (324, 396). Snapping off pins the raw release this
        // test's hand-derived half circle is measured from.
        var snap = await core.session.currentSnapSettings
        snap.enabledKinds = []
        try await core.session.setSnapSettings(snap)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let arc = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .arcLength, subject: "Curved wall", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, arcs: [
                ArcGeometry(center: PDFPoint(x: 400, y: 400), radius: 72, startAngle: 0, sweepAngle: .pi / 2)
            ]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(arc))
        await core.refresh()
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        harness.shell.perform(.selectTool)
        canvas.refresh()
        await canvas.settleScene()
        core.canvas.select(markupIDs: [arc.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        let quarter = 2.54 * Double.pi / 2
        let before = NSDecimalNumber(decimal: try #require(await core.session.markup(arc.id)?.measurement?[.arcLength]?.value)).doubleValue
        #expect(Swift.abs(before - quarter) <= quarter * 1e-12)

        let handle = try #require(canvas.vertexHandle(at: PDFPointValue(x: 400, y: 472)))
        #expect(handle.markupID == arc.id.rawValue)
        #expect(handle.index == 2, "the end handle: centre 0, start 1, end 2")
        canvas.handleDragBegan(at: PDFPointValue(x: 400, y: 472))
        canvas.handleDragMoved(to: PDFPointValue(x: 360, y: 460))
        canvas.handleDragEnded(at: PDFPointValue(x: 328, y: 400))
        var after = before
        for _ in 0..<150 {
            after = NSDecimalNumber(decimal: await core.session.markup(arc.id)?.measurement?[.arcLength]?.value ?? 0).doubleValue
            if after > before * 1.5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let half = 2.54 * Double.pi
        #expect(Swift.abs(after - half) <= half * 1e-9)
        await core.commands.undo()
        let undone = NSDecimalNumber(decimal: try #require(await core.session.markup(arc.id)?.measurement?[.arcLength]?.value)).doubleValue
        #expect(Swift.abs(undone - quarter) <= quarter * 1e-12)
    }
}
