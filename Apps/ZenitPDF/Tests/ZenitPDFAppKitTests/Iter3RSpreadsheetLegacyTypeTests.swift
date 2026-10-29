import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFQuantityLedger
import ZPDFSpreadsheet
@testable import ZenitPDFAppKit

/// Loop iteration 3, re-fix of T-046: the ledger's Type cell now holds the measurement tool
/// (`length`) where it held the markup kind (`measurement`), and an XLSX workbook carries that
/// cell as text. A workbook exported before the change says `measurement`; compared as it was,
/// File ▸ Import Spreadsheet Changes… refused the read-only Type column on every measured row.
@MainActor
@Suite("Loop iteration 3 re-fix — older workbooks and the Type cell", .appTierSerialised)
struct Iter3RSpreadsheetLegacyTypeTests {

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

    @Test("An older workbook's \"measurement\" Type cells compare as unchanged; its real edit applies; any other Type edit is still refused")
    func olderWorkbookTypeCells() async throws {
        let harness = try await Fix2Harness.make("Older workbook.pdf")
        defer { harness.tearDown() }
        var ids: [MarkupID] = []
        for (index, length) in [250.0, 410.0].enumerated() {
            let record = try await harness.addMarkup(tool: .length, geometry: { page in
                MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10 + Double(index) * 50), PDFPoint(x: 10 + length, y: 10 + Double(index) * 50)])
            }, subject: "Wall")
            ids.append(record.id)
        }
        let slab = try await harness.addMarkup(tool: .area, geometry: { page in
            MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 10, y: 300), PDFPoint(x: 110, y: 300), PDFPoint(x: 110, y: 400), PDFPoint(x: 10, y: 400)
            ], isClosed: true))])
        }, subject: "Slab")
        ids.append(slab.id)
        let seeded = try await harness.core.applySpreadsheetEdits(ids.enumerated().map { index, id in
            SpreadsheetCellEdit(markupID: id.rawValue, columnKey: "costCode", text: "CC-\(index)")
        })
        #expect(seeded.applied == 3)
        await harness.settle()

        // The shipping export, with row identity.
        let projection = try await ProjectWindowController.projection(
            core: harness.core, documentName: "Older workbook", scaleDescription: nil, request: harness.core.ledger.request)
        let type = StandardLedgerColumn.icon.rawValue
        #expect(projection.table.columns.contains { $0.key == type }, "the export must carry the Type column")
        let identity = await SpreadsheetRoundTrip.identity(of: harness.document)
        let options = SpreadsheetRoundTrip.withRowIdentity(XLSXExportOptions(), projection: projection, identity: identity)
        let workbookURL = harness.directory.appendingPathComponent("Ledger.xlsx")
        try XLSXExporter().export(projection, to: workbookURL, options: options)

        // Make it the workbook an older build wrote: both walls' Type cells say "measurement"
        // (the kind), the slab's says "cloud" (a real edit to a read-only cell), and one cost
        // code is edited, CC-1 → CC-9.
        let unpacked = harness.directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", workbookURL.path, "-d", unpacked.path], in: harness.directory)
        let strings = unpacked.appendingPathComponent("xl/sharedStrings.xml")
        var stringsXML = try String(contentsOf: strings, encoding: .utf8)
        // The new export writes the tool's name, as the ledger's Type column shows it (L-46).
        #expect(stringsXML.contains(">Length<"), "the new export writes the tool's name")
        #expect(stringsXML.contains(">Area<"))
        #expect(stringsXML.contains(">CC-1<"))
        stringsXML = stringsXML
            .replacingOccurrences(of: ">Length<", with: ">measurement<")
            .replacingOccurrences(of: ">Area<", with: ">cloud<")
            .replacingOccurrences(of: ">CC-1<", with: ">CC-9<")
        try stringsXML.write(to: strings, atomically: true, encoding: .utf8)
        let older = harness.directory.appendingPathComponent("Ledger older.xlsx")
        try run("/usr/bin/zip", ["-q", "-X", "-r", older.path, "."], in: unpacked)

        let workbook = try LedgerRoundTripWorkbook(data: Data(contentsOf: older))
        #expect(workbook.rows.filter { $0.values[type] == "measurement" }.count == 2)
        // The walls' Type reads as the file spells it; the slab's stays what the ledger says.
        let (current, _) = SpreadsheetRoundTrip.currentValues(of: projection)
        let tokens = SpreadsheetRoundTrip.typeTokens(of: await harness.records())
        let reconciled = SpreadsheetRoundTrip.acceptingOlderSpellings(current, in: workbook, typeTokens: tokens)
        #expect(reconciled[ids[0].rawValue.uuidString]?[type] == .text("measurement"))
        #expect(reconciled[ids[1].rawValue.uuidString]?[type] == .text("measurement"))
        #expect(reconciled[slab.id.rawValue.uuidString]?[type] == .text("Area"))

        // The review the command shows, against the whole ledger.
        let comparison = try await ProjectWindowController.projection(
            core: harness.core, documentName: "Older workbook", scaleDescription: nil,
            request: SpreadsheetRoundTrip.comparisonRequest(for: workbook))
        let review = SpreadsheetRoundTrip.review(workbook, against: comparison, projectID: identity, typeTokens: tokens)
        // Old output: three refusals — Type "length" → "measurement" on both walls, and the slab.
        #expect(review.refusals.count == 1, "\(review.refusals)")
        #expect(review.refusals.first?.before == "Area")
        #expect(review.refusals.first?.after == "cloud")
        #expect(review.refusals.first?.reason == .readOnlyColumn)
        #expect(review.changes.map(\.after) == ["CC-9"])

        // The same through the command, its review answered Apply by injection.
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { request in request.identifier == SpreadsheetRoundTrip.reviewIdentifier ? .button(0) : .dismissed }
        defer { ZenitModalPresenter.handler = nil }
        let receipt = try #require(await SpreadsheetRoundTrip.importChanges(from: older, into: harness.document))
        let shown = try #require(ZenitModalPresenter.recorded.first { $0.identifier == SpreadsheetRoundTrip.reviewIdentifier })
        // L-48: one cell is "1 cell" (it read "changes 1 cells").
        #expect(shown.title.contains("changes 1 cell"), "\(shown.title)")
        #expect(!shown.title.contains("cells"), "\(shown.title)")
        #expect(shown.buttons.first == "Apply 1 Change", "\(shown.buttons)")
        #expect(!shown.detail.contains("“measurement”"), "\(shown.detail)")
        #expect(shown.detail.contains("“Area” → “cloud”"), "\(shown.detail)")
        #expect(receipt.applied == 1)
        await harness.settle()
        let costCode = LedgerIdentifiers.columnID(for: .costCode)
        #expect(await harness.core.session.markup(ids[1])?.customValues[costCode] == .text("CC-9"))
        #expect(await harness.core.session.markup(ids[0])?.tool == .length, "the Type cell is never applied")
    }
}
