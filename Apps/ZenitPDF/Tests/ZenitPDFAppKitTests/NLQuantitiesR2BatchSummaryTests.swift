import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFExport
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-QTY-15 phase 2 in the app: the Whole Project panel's "Summarise Closed Projects…" runs the
/// open panel through the modal presenter (answered here, never shown), and the batch exports as
/// one workbook with numbers in the display unit.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct NLQuantitiesR2BatchSummaryTests {

    @Test("The window's hooks run the batch through the open panel, and a non-project is named")
    func hooksRunTheBatch() async throws {
        let harness = try await Fix2Harness.make("Batch Host.pdf", calibrate: false)
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bogus-\(UUID().uuidString).zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bogus, withIntermediateDirectories: true)
        defer {
            ZenitModalPresenter.reset()
            harness.tearDown()
            try? FileManager.default.removeItem(at: bogus)
        }
        BatchProjectSummaryFlow.wire(harness.document)
        let shell = try #require(harness.document.shell)
        let run = try #require(shell.onBatchProjectSummary)
        #expect(shell.onExportBatchSummary != nil)

        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in
            request.identifier == BatchProjectSummaryFlow.openPanelIdentifier ? .urls([bogus]) : .dismissed
        }
        let batch = try #require(await run())
        #expect(ZenitModalPresenter.didRequest(BatchProjectSummaryFlow.openPanelIdentifier))
        #expect(batch.drawings.isEmpty)
        #expect(batch.refused.map(\.name) == [bogus.deletingPathExtension().lastPathComponent])
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)

        // A dismissed panel is no batch at all — the last one stays.
        ZenitModalPresenter.handler = { _ in .dismissed }
        #expect(await run() == nil)
    }

    @Test("The workbook form: 12 m² and 2 m² as numbers in square metres, the unit its own column")
    func workbookForm() throws {
        let slab = LedgerSubjectTotal(subject: "Slab", quantity: DecimalQuantity(value: 14, dimension: .area), rowCount: 2)
        let north = LedgerSubjectTotal(subject: "Slab", quantity: DecimalQuantity(value: 12, dimension: .area), rowCount: 1)
        let batch = LedgerBatchSummary(
            drawings: [.init(documentID: UUID(), title: "North", totals: [north])],
            combined: [slab],
            refused: [.init(name: "Bogus", reason: "not a project")]
        )
        let workbook = BatchProjectSummaryFlow.workbook(batch, units: .metric, title: "Batch")
        #expect(workbook.combined.map(\.value) == [14])
        #expect(workbook.combined.map(\.unit) == ["m²"])
        #expect(workbook.combined.map(\.decimalPlaces) == [2])
        #expect(workbook.projects.map(\.name) == ["North"])
        #expect(workbook.notIncluded == [["Bogus", "not a project"]])
        // In square feet the same 14 m² is 14 / 0.09290304 = 150.6947… ft², converted exactly.
        let imperial = BatchProjectSummaryFlow.workbook(batch, units: .imperial, title: "Batch")
        #expect(imperial.combined[0].unit == "ft²")
        #expect(imperial.combined[0].value == Decimal(14) / Decimal(string: "0.09290304")!)
    }
}
