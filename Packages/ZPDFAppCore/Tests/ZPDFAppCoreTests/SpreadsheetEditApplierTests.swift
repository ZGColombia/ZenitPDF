import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger

/// NL-PLAT-07, the apply half: reviewed spreadsheet edits land as ONE undoable step through the
/// ordinary commands, and a measured quantity cannot be written from a cell.
@MainActor
@Suite("Spreadsheet edits applied — NL-PLAT-07")
struct SpreadsheetEditApplierTests {

    private func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, PageID, DocumentID) {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, page.id, documentID)
    }

    private func addMarkup(_ environment: AppCoreEnvironment, page: PageID, document: DocumentID, subject: String) async throws -> MarkupID {
        let record = MarkupRecord(
            id: MarkupID(UUID()), documentID: document, pageID: page, kind: .measurement, tool: .length,
            subject: subject,
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)]),
            createdAt: Date(), modifiedAt: Date()
        )
        _ = try await environment.commands.perform(.addMarkup(record))
        return record.id
    }

    @Test("Three unit costs and one cost code land in one undo step; undo restores all four")
    func fourEditsOneUndo() async throws {
        let (environment, session, page, document) = try await makeEnvironment()
        let a = try await addMarkup(environment, page: page, document: document, subject: "Slab")
        let b = try await addMarkup(environment, page: page, document: document, subject: "Slab")
        let c = try await addMarkup(environment, page: page, document: document, subject: "Wall")
        let columns = await session.ledgerColumns
        let unitCost = try #require(columns.columnID(standard: .unitCost))
        let costCode = try #require(columns.columnID(standard: .costCode))

        let receipt = try await environment.applySpreadsheetEdits([
            SpreadsheetCellEdit(markupID: a.rawValue, columnKey: "unitCost", text: "112.5"),
            SpreadsheetCellEdit(markupID: b.rawValue, columnKey: "unitCost", text: "0.1"),
            SpreadsheetCellEdit(markupID: c.rawValue, columnKey: "unitCost", text: "85.25"),
            SpreadsheetCellEdit(markupID: b.rawValue, columnKey: "costCode", text: "21.9"),
        ])
        #expect(receipt.applied == 4)
        #expect(receipt.refused.isEmpty)
        // Exact decimals, never through a Double: 0.1 is 0.1.
        guard case let .currency(amountB, _)? = await session.markup(b)?.customValues[unitCost] else {
            Issue.record("no unit cost on b"); return
        }
        #expect(amountB == Decimal(string: "0.1"))
        guard case let .currency(amountA, _)? = await session.markup(a)?.customValues[unitCost] else {
            Issue.record("no unit cost on a"); return
        }
        #expect(amountA == Decimal(string: "112.5"))
        #expect(await session.markup(b)?.customValues[costCode] == .text("21.9"))

        await environment.commands.undo()
        #expect(await session.markup(a)?.customValues[unitCost] == nil)
        #expect(await session.markup(b)?.customValues[costCode] == nil)
        #expect(await session.markup(c)?.customValues[unitCost] == nil)
    }

    @Test("A measured column, text in a money column and a vanished markup are refused and named; nothing else changes")
    func refusals() async throws {
        let (environment, session, page, document) = try await makeEnvironment()
        let a = try await addMarkup(environment, page: page, document: document, subject: "Slab")
        let before = await session.markup(a)?.measurement
        let receipt = try await environment.applySpreadsheetEdits([
            SpreadsheetCellEdit(markupID: a.rawValue, columnKey: "planLength", text: "999"),
            SpreadsheetCellEdit(markupID: a.rawValue, columnKey: "unitCost", text: "about 90"),
            SpreadsheetCellEdit(markupID: UUID(), columnKey: "subject", text: "Ghost"),
        ])
        #expect(receipt.applied == 0)
        #expect(receipt.refused.count == 3)
        #expect(receipt.refused[0].reason.contains("measured"))
        #expect(await session.markup(a)?.measurement == before)
    }

    @Test("Subject, label and comment go through their own commands")
    func standardTextColumns() async throws {
        let (environment, session, page, document) = try await makeEnvironment()
        let a = try await addMarkup(environment, page: page, document: document, subject: "Slab")
        let receipt = try await environment.applySpreadsheetEdits([
            SpreadsheetCellEdit(markupID: a.rawValue, columnKey: "subject", text: "Slab on grade"),
            SpreadsheetCellEdit(markupID: a.rawValue, columnKey: "label", text: "S-1"),
            SpreadsheetCellEdit(markupID: a.rawValue, columnKey: "comment", text: "Checked on site"),
        ])
        #expect(receipt.applied == 3)
        let record = try #require(await session.markup(a))
        #expect(record.subject == "Slab on grade")
        #expect(record.label == "S-1")
        #expect(record.comment == "Checked on site")
    }
}
