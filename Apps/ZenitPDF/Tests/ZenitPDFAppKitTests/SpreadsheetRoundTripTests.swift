import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFQuantityLedger
import ZPDFSpreadsheet
@testable import ZenitPDFAppKit

/// NL-PLAT-07 end to end, on the shipping paths: the real XLSX writer with row identity, an edit
/// made to the workbook's own XML the way a spreadsheet saves it, the real reader, the review the
/// person answers (injected), and one undoable apply.
@MainActor
@Suite("Spreadsheet round trip — NL-PLAT-07", .appTierSerialised)
struct SpreadsheetRoundTripTests {

    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
    }

    @Test("Export, edit 1 unit cost, 1 cost code and 1 measured length in the workbook, import: 2 applied in one undo, the length refused")
    func roundTrip() async throws {
        let harness = try await Fix2Harness.make("Round trip.pdf")
        defer { harness.tearDown() }
        var ids: [MarkupID] = []
        for (index, length) in [250.0, 410.0, 530.0].enumerated() {
            let record = try await harness.addMarkup(tool: .length, geometry: { page in
                MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10 + Double(index) * 50), PDFPoint(x: 10 + length, y: 10 + Double(index) * 50)])
            }, subject: "Wall")
            ids.append(record.id)
        }
        let seeded = try await harness.core.applySpreadsheetEdits(ids.enumerated().flatMap { index, id in [
            SpreadsheetCellEdit(markupID: id.rawValue, columnKey: "costCode", text: "CC-\(index)"),
            SpreadsheetCellEdit(markupID: id.rawValue, columnKey: "unitCost", text: "100"),
        ] })
        #expect(seeded.applied == 6)
        await harness.settle()

        // The shipping export: the projection on screen, written with row identity.
        let projection = try await ProjectWindowController.projection(
            core: harness.core, documentName: "Round trip", scaleDescription: nil, request: harness.core.ledger.request)
        #expect(projection.table.columns.contains { $0.key == "unitCost" }, "the fixture ledger must show Unit Cost")
        let options = SpreadsheetRoundTrip.withRowIdentity(XLSXExportOptions(), projection: projection,
                                                            identity: await SpreadsheetRoundTrip.identity(of: harness.document))
        let workbookURL = harness.directory.appendingPathComponent("Ledger.xlsx")
        try XLSXExporter().export(projection, to: workbookURL, options: options)

        // Untouched, it comes back with nothing to do: no false changes from number formatting.
        let untouched = try LedgerRoundTripWorkbook(data: Data(contentsOf: workbookURL))
        let (current, numeric) = SpreadsheetRoundTrip.currentValues(of: projection)
        let identity = await SpreadsheetRoundTrip.identity(of: harness.document)
        let clean = LedgerRoundTrip.review(untouched, current: current, numericKeys: numeric, projectID: identity)
        #expect(clean.changes.isEmpty, "\(clean.changes)")
        #expect(clean.refusals.isEmpty, "\(clean.refusals)")
        #expect(untouched.rows.count == 3)

        // Edit the saved XML, as a spreadsheet would: CC-1 → CC-9, the first 100 → 112.5, and the
        // 2.5 m length typed over as 9.
        let unpacked = harness.directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", workbookURL.path, "-d", unpacked.path], in: harness.directory)
        let strings = unpacked.appendingPathComponent("xl/sharedStrings.xml")
        let sheet = unpacked.appendingPathComponent("xl/worksheets/sheet1.xml")
        var stringsXML = try String(contentsOf: strings, encoding: .utf8)
        var sheetXML = try String(contentsOf: sheet, encoding: .utf8)
        #expect(stringsXML.contains(">CC-1<"))
        stringsXML = stringsXML.replacingOccurrences(of: ">CC-1<", with: ">CC-9<")
        let hundred = try #require(sheetXML.range(of: "<v>100</v>"))
        sheetXML.replaceSubrange(hundred, with: "<v>112.5</v>")
        let length = try #require(sheetXML.range(of: "<v>2.5</v>"), "the 2.5 m length cell")
        sheetXML.replaceSubrange(length, with: "<v>9</v>")
        try stringsXML.write(to: strings, atomically: true, encoding: .utf8)
        try sheetXML.write(to: sheet, atomically: true, encoding: .utf8)
        let edited = harness.directory.appendingPathComponent("Ledger edited.xlsx")
        try run("/usr/bin/zip", ["-q", "-X", "-r", edited.path, "."], in: unpacked)

        // Import through the command, the review answered Apply by injection.
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in request.identifier == SpreadsheetRoundTrip.reviewIdentifier ? .button(0) : .dismissed }
        defer { ZenitModalPresenter.handler = nil }
        let receipt = try #require(await SpreadsheetRoundTrip.importChanges(from: edited, into: harness.document))
        let review = try #require(ZenitModalPresenter.recorded.first { $0.identifier == SpreadsheetRoundTrip.reviewIdentifier })
        #expect(review.title.contains("changes 2 cells"), "\(review.title)")
        #expect(review.detail.contains("“CC-1” → “CC-9”"))
        #expect(review.detail.contains("→ “112.5”"))
        #expect(review.detail.contains("→ “9”"), "the refused length is named: \(review.detail)")
        #expect(receipt.applied == 2)

        await harness.settle()
        let unitCost = LedgerIdentifiers.columnID(for: .unitCost)
        let costCode = LedgerIdentifiers.columnID(for: .costCode)
        let first = try #require(await harness.core.session.markup(ids[0]))
        guard case let .currency(amount, _)? = first.customValues[unitCost] else { Issue.record("no unit cost"); return }
        #expect(amount == Decimal(string: "112.5"))
        #expect(await harness.core.session.markup(ids[1])?.customValues[costCode] == .text("CC-9"))
        // The measured length is untouched: 250 pt at 100 pt/m is 2.5 m, from the geometry.
        #expect(first.geometry?.points.last?.x == 260)

        // One undo takes both back.
        await harness.core.commands.undo()
        guard case let .currency(restored, _)? = await harness.core.session.markup(ids[0])?.customValues[unitCost] else {
            Issue.record("no unit cost after undo"); return
        }
        #expect(restored == 100)
        #expect(await harness.core.session.markup(ids[1])?.customValues[costCode] == .text("CC-1"))
    }

    @Test("A workbook without row identity is refused with a sentence, and nothing changes")
    func plainWorkbookRefused() async throws {
        let harness = try await Fix2Harness.make("Plain.pdf")
        defer { harness.tearDown() }
        let projection = try await ProjectWindowController.projection(
            core: harness.core, documentName: "Plain", scaleDescription: nil, request: harness.core.ledger.request)
        let url = harness.directory.appendingPathComponent("Plain.xlsx")
        try XLSXExporter().export(projection, to: url)   // no row identity: the old workbook
        ZenitModalPresenter.reset()
        let receipt = await SpreadsheetRoundTrip.importChanges(from: url, into: harness.document)
        #expect(receipt == nil)
        let refusal = try #require(ZenitModalPresenter.lastRecorded)
        #expect(refusal.identifier == SpreadsheetRoundTrip.refusalIdentifier)
        #expect(refusal.detail.contains("row identity"))
    }
}
