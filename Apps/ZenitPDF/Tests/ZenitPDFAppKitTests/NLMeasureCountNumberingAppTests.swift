import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-12: Measure ▸ Number Count Marks numbers the selected count on the canvas, and a
/// continued numbered count keeps counting.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureCountNumberingAppTests {

    @Test("The menu numbers the selected count 1…3 on the canvas; one undo removes it")
    func numbersOnCanvas() async throws {
        let harness = try await NLMeasureR2Harness.make("Counts.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.setPresetScale(page: harness.page, ratioDenominator: 100)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: harness.page, kind: .measurement, tool: .count,
            subject: "Doors", author: "t",
            geometry: MeasurementGeometry(pageID: harness.page, countPoints: [(300.0, 200.0), (200, 200), (100, 200)].map {
                CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: $0.0, y: $0.1))
            }),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(record))
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        canvas.refresh()
        #expect(await AppTestSupport.wait { canvas.pageViewForTesting.shapes.contains { $0.id == record.id.rawValue } })
        core.canvas.select(markupIDs: [record.id.rawValue], additive: false)
        #expect(core.canvas.selectedMarkupIDs == [record.id.rawValue])
        harness.controller.toggleCountNumbering(for: harness.document)
        var numbered = false
        for _ in 0..<150 {
            numbered = CountNumbering.isNumbered(await core.session.markup(record.id)?.geometry)
            if numbered { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(numbered)
        canvas.refresh()
        #expect(await AppTestSupport.wait {
            canvas.pageViewForTesting.shapes.first { $0.id == record.id.rawValue }?.countNumbers == [1, 2, 3]
        })
        #expect(await core.session.markup(record.id)?.measurement?[.count]?.value == 3)
        await core.commands.undo()
        canvas.refresh()
        #expect(await AppTestSupport.wait {
            canvas.pageViewForTesting.shapes.first { $0.id == record.id.rawValue }?.countNumbers == []
        })
    }
}
