import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Bug (`AppLedgerBulkEdit.swift:26,167`) and NL-UX-12: every Inspector edit
/// went on the Edit menu as "Undo Bulk Edit", one colour on one markup included.
@MainActor
@Suite("Undo action names for Inspector edits")
struct NLUXUndoNameTests {

    private let one: Set<UUID> = [UUID()]
    private let twelve: Set<UUID> = Set((0..<12).map { _ in UUID() })

    @Test("One field names the step; a count is added above one markup")
    func singleFieldNames() {
        let red = ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1)
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: one, style: MarkupStyleEdit(color: red)), markupCount: 1
        ) == "Change Colour")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: twelve, color: red), markupCount: 12
        ) == "Change Colour (12 Markups)")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: one, style: MarkupStyleEdit(lineWidth: 2)), markupCount: 1
        ) == "Change Line Width")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: one, style: MarkupStyleEdit(opacity: 0.5)), markupCount: 1
        ) == "Change Opacity")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: one, values: [.status: .choice("accepted")]), markupCount: 1
        ) == "Change Status")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: one, values: [.label: .text("W1")]), markupCount: 1
        ) == "Edit Label")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: one, values: [.comment: .empty]), markupCount: 1
        ) == "Edit Notes")
    }

    @Test("Several appearance fields read Change Appearance; a wider step stays Bulk Edit")
    func combinedNames() {
        let red = ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1)
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: one, style: MarkupStyleEdit(color: red, lineWidth: 3)),
            markupCount: 1
        ) == "Change Appearance")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(
                markupIDs: twelve,
                values: [.subject: .text("Slab"), .status: .choice("accepted")],
                color: red
            ),
            markupCount: 12
        ) == AppCoreEnvironment.bulkEditUndoActionName)
    }

    /// End to end through the shipping bus. Old output: `undoManager.undoActionName == "Bulk Edit"`.
    @Test("Recolouring one markup through the bulk-edit path reads Undo Change Colour")
    @MainActor
    func recolourOneMarkupEndToEnd() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let id = MarkupID(UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await environment.commands.perform(.addMarkup(ZPDFContracts.MarkupRecord(
            id: id,
            documentID: documentID,
            pageID: page.id,
            kind: .rectangle,
            subject: "Cloud",
            author: "test",
            status: .open,
            geometry: MeasurementGeometry(
                pageID: page.id,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
                    PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)
                ], isClosed: true))]
            ),
            createdAt: stamp,
            modifiedAt: stamp
        )))
        await environment.ledger.refresh()

        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [id.rawValue],
            style: MarkupStyleEdit(color: ColorRGBA(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ))

        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(receipt.undoActionName == "Change Colour")
        #expect(environment.commands.undoManager.undoActionName == "Change Colour")
    }
}
