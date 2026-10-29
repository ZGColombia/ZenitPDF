import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-MEASURE-09 through the shipping window: the Inspector's Caption row, segment lengths on the
/// canvas, and a dragged label that keeps its offset in page points.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureCaptionAppTests {

    /// 1:100: a 72 × 72 pt square is 2.54 m a side — area 6.4516 m², perimeter 10.16 m.
    @Test("Caption fields, segment lengths and a dragged label")
    func caption() async throws {
        let harness = try await NLMeasureR2Harness.make("Caption.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let area = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .area, subject: "Floor", label: "Area C", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 300, y: 300), PDFPoint(x: 372, y: 300), PDFPoint(x: 372, y: 372), PDFPoint(x: 300, y: 372)
            ]))]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(area))
        await core.refresh()
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        harness.shell.perform(.selectTool)
        core.canvas.select(markupIDs: [area.id.rawValue], additive: false)
        canvas.refresh()
        await canvas.settleScene()
        let editing = harness.shell.inspectorEditing
        #expect(await AppTestSupport.wait { editing.captionState?.selection == [area.id.rawValue] })
        let state = try #require(editing.captionState)
        #expect(state.availableFields.contains(.perimeter))
        #expect(state.chosenFields == [])
        // An area's headline is its Plan Area field (the tool's primary field).
        let headline = try #require(state.headline)
        #expect(state.shownFields == [headline])

        // Caption: area and perimeter, in the ledger formatter's words.
        editing.onSetCaptionFields?([area.id.rawValue], state.toggling(.perimeter))
        let formatter = core.snapshot.ledger.formatter
        let areaText = formatter.textWithUnit(Shown.Quantity.squareMetres(Decimal(string: "6.4516")!))
        let perimeterText = formatter.textWithUnit(Shown.Quantity.metres(Decimal(string: "10.16")!))
        let expected = "Area C: \(areaText) · P \(perimeterText)"
        #expect(await AppTestSupport.wait {
            canvas.refresh()
            return canvas.pageViewForTesting.shapes.first { $0.id == area.id.rawValue }?.caption == expected
        }, "expected \(expected)")

        // Segment lengths: four edges of 2.54 m.
        editing.onSetSegmentLengths?([area.id.rawValue], true)
        let edge = formatter.textWithUnit(Shown.Quantity.metres(Decimal(string: "2.54")!))
        #expect(await AppTestSupport.wait {
            canvas.refresh()
            return canvas.pageViewForTesting.shapes.first { $0.id == area.id.rawValue }?.segmentLabels.map(\.text) == [edge, edge, edge, edge]
        })

        // Drag the label 50 pt right and 20 pt up: the offset is stored in page points.
        let page = canvas.pageViewForTesting
        page.frame = NSRect(origin: .zero, size: page.frame.size == .zero ? NSSize(width: 1200, height: 900) : page.frame.size)
        let rep = try #require(page.bitmapImageRepForCachingDisplay(in: page.bounds))
        page.cacheDisplay(in: page.bounds, to: rep)   // a draw pass records the pill's frame
        let frame = try #require(page.captionFrames[area.id.rawValue])
        let transform = try #require(page.transform)
        let grab = transform.pagePoint(from: CGPoint(x: frame.midX, y: frame.midY))
        canvas.handleDragBegan(at: grab)
        canvas.handleDragMoved(to: PDFPointValue(x: grab.x + 25, y: grab.y + 10))
        canvas.handleDragEnded(at: PDFPointValue(x: grab.x + 50, y: grab.y + 20))
        var offset: PDFPoint?
        for _ in 0..<150 {
            offset = await core.session.markup(area.id)?.style.measurementCaption?.labelOffset
            if offset != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stored = try #require(offset)
        #expect(Swift.abs(stored.x - 50) < 1e-6 && Swift.abs(stored.y - 20) < 1e-6)
        #expect(await core.session.markup(area.id)?.geometry == area.geometry, "the drag moved the label, not the area")
        #expect(await AppTestSupport.wait { editing.captionState?.hasLabelOffset == true })
        editing.onResetLabelPosition?([area.id.rawValue])
        #expect(await AppTestSupport.wait { editing.captionState?.hasLabelOffset == false })
    }
}
