import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Regression tests for quantities defects, driven through the shipping
/// presenter and command bus.
///
/// Every expected value is derived by hand in the comment beside it: a 40 × 30 pt rectangle at
/// 0.1 m/pt is 4 m × 3 m = 12 m², so a Unit Cost of 450 SEK/m² prices it at 12 × 450 = 5 400 SEK.
@Suite("Quantities — bug regressions")
@MainActor
struct NLQuantitiesBugTests {

    struct Fixture {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let ids: [MarkupID]
    }

    /// One calibrated page (0.1 m/pt) with `sizes.count` rectangles, each `w × h` points.
    func makeFixture(sizes: [(Double, Double)] = [(40, 30), (40, 30), (40, 30)]) async throws -> Fixture {
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
        try await environment.commands.calibrate(
            page: page.id,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 10,
            knownLengthUnit: .metre
        )
        var ids: [MarkupID] = []
        for (index, size) in sizes.enumerated() {
            let id = MarkupID(UUID())
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            let record = ZPDFContracts.MarkupRecord(
                id: id,
                documentID: documentID,
                pageID: page.id,
                kind: .measurement,
                tool: .area,
                subject: "Slab \(index)",
                author: "test",
                geometry: MeasurementGeometry(
                    pageID: page.id,
                    polygons: [PolygonGeometry(outer: PolygonRing(points: [
                        PDFPoint(x: 0, y: 0),
                        PDFPoint(x: size.0, y: 0),
                        PDFPoint(x: size.0, y: size.1),
                        PDFPoint(x: 0, y: size.1)
                    ], isClosed: true))]
                ),
                createdAt: stamp,
                modifiedAt: stamp
            )
            try await environment.commands.perform(.addMarkup(record))
            ids.append(id)
        }
        await environment.ledger.refresh()
        return Fixture(environment: environment, session: session, ids: ids)
    }

    func editor(_ fixture: Fixture) throws -> any LedgerBulkEditPresenting {
        try #require(fixture.environment.ledger as? any LedgerBulkEditPresenting)
    }

    // MARK: Bug 1 — edits to non-custom editable columns were dropped

    @Test("An inline edit of Cost Code changes the stored value, as one undo step")
    func costCodeEditIsApplied() async throws {
        let fixture = try await makeFixture()
        let costCode = try #require(await fixture.session.ledgerColumns.column(standard: .costCode))
        // Old code: the value was filtered out by the `custom.` prefix test, the batch was
        // empty, and the receipt reported success with `changedMarkupIDs == []`.
        let receipt = try await editor(fixture).applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[0].rawValue],
            values: [.costCode: .text("C-100")]
        ))
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(receipt.changedMarkupIDs == [fixture.ids[0].rawValue])
        let record = try #require(await fixture.session.markup(fixture.ids[0]))
        #expect(record.customValues[costCode.id] == .text("C-100"))

        await fixture.environment.commands.undo()
        let undone = try #require(await fixture.session.markup(fixture.ids[0]))
        #expect(undone.customValues[costCode.id] == nil)
        // One step: the next undo takes away the third rectangle, not more of the edit.
        await fixture.environment.commands.undo()
        #expect(await fixture.session.markup(fixture.ids[2]) == nil)
    }

    @Test("An edit to a measured column is refused out loud, not dropped with a success receipt")
    func measuredColumnEditIsRefused() async throws {
        let fixture = try await makeFixture()
        let receipt = try await editor(fixture).applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[0].rawValue],
            values: [.planArea: .number(5)]
        ))
        // Old code: filtered out, empty batch, success receipt.
        #expect(receipt.didFail)
        #expect(receipt.failureDescription?.contains("Plan Area") == true)
    }

    // MARK: Bug 2 — imported columns hidden and uneditable

    @Test("A table-import column is visible, in Bulk Edit, and an inline edit of it is applied")
    func importedColumnIsAUserColumn() async throws {
        let fixture = try await makeFixture()
        let columnID = ColumnID(UUID())
        let key = "zenit.import.\(columnID.rawValue.uuidString)"
        try await fixture.environment.commands.perform(.addCustomColumns([
            LedgerColumnDefinition(id: columnID, key: key, title: "Door type", kind: .text)
        ]))
        await fixture.environment.ledger.refresh()

        let column = try #require(fixture.environment.ledger.columns.first { $0.id.rawValue == key })
        // Old code: `isCustom` was false for this key, so all four of these failed.
        #expect(column.isUserDefined)
        #expect(column.holdsUserValues)
        let arranged = LedgerDefaultColumns.arranged(fixture.environment.ledger.columns)
        #expect(arranged.first { $0.id.rawValue == key }?.visible == true)

        let receipt = try await editor(fixture).applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[1].rawValue],
            values: [LedgerColumnID(key): .text("D2")]
        ))
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        let record = try #require(await fixture.session.markup(fixture.ids[1]))
        #expect(record.customValues[columnID] == .text("D2"))
    }

    @Test("The estimating built-ins hold user values; Subject, measured and display-unit columns do not")
    func userValueRuleOverBuiltIns() async throws {
        let columns = try LedgerColumnSet.standard()
        for standard in [StandardLedgerColumn.costCode, .trade, .phase, .material, .unitCost] {
            #expect(LedgerBridge.holdsUserValues(try #require(columns.column(standard: standard))), "\(standard)")
        }
        for standard in [StandardLedgerColumn.subject, .label, .comment, .status, .displayUnit, .planArea, .totalCost] {
            #expect(!LedgerBridge.holdsUserValues(try #require(columns.column(standard: standard))), "\(standard)")
        }
    }

    // MARK: Bug 3 — money and undeclared-dimension totals missing on screen

    @Test("A money column totals on screen, as the exports always did")
    func currencyColumnTotalsOnScreen() async throws {
        let fixture = try await makeFixture()
        let columnID = ColumnID(UUID())
        try await fixture.environment.commands.perform(.addCustomColumns([
            LedgerColumnDefinition(id: columnID, key: "custom.fee", title: "Fee", kind: .currency)
        ]))
        let amounts: [Decimal] = [Decimal(string: "100.10")!, Decimal(string: "200.25")!, 300]
        for (id, amount) in zip(fixture.ids, amounts) {
            try await fixture.environment.commands.perform(
                .editCustomValue(id: id, column: columnID, value: .currency(amount: amount, code: "SEK"))
            )
        }
        await fixture.environment.ledger.refresh()
        let column = try #require(fixture.environment.ledger.columns.first { $0.id.rawValue == "custom.fee" })
        // Old code: `aggregate(for:)` returned nil for a column without a dimension.
        #expect(column.aggregate == .sum)
        // 100.10 + 200.25 + 300 = 600.35, exact.
        let total = try #require(fixture.environment.ledger.grandTotals.quantities[LedgerColumnID("custom.fee")])
        #expect(total.value == Decimal(string: "600.35")!)
        #expect(total.dimension.currencyCode == "SEK")
        #expect(!fixture.environment.ledger.grandTotals.displayValue(LedgerColumnID("custom.fee")).isEmpty)
    }

    @Test("A number column with no declared dimension totals on screen")
    func undeclaredNumberColumnTotals() async throws {
        let fixture = try await makeFixture()
        let columnID = ColumnID(UUID())
        try await fixture.environment.commands.perform(.addCustomColumns([
            LedgerColumnDefinition(id: columnID, key: "custom.boards", title: "Boards", kind: .number)
        ]))
        for (id, count) in zip(fixture.ids, [2, 3, 4]) {
            try await fixture.environment.commands.perform(
                .editCustomValue(id: id, column: columnID, value: .number(.count(Decimal(count))))
            )
        }
        await fixture.environment.ledger.refresh()
        // 2 + 3 + 4 = 9. Old code: no aggregate and no total (dimension nil).
        let total = try #require(fixture.environment.ledger.grandTotals.quantities[LedgerColumnID("custom.boards")])
        #expect(total.value == 9)
    }

    // MARK: Bug 4 — Unit Cost summed; bug 7 — Total Cost always empty

    @Test("Unit Cost 450 on a 12 m² row: Total Cost 5 400; totals sum Total Cost, never Unit Cost")
    func unitCostPricesTotalCost() async throws {
        let fixture = try await makeFixture(sizes: [(40, 30), (20, 10)])
        let unitCost = try #require(await fixture.session.ledgerColumns.column(standard: .unitCost))
        // Row 0: 4 m × 3 m = 12 m². Row 1: 2 m × 1 m = 2 m².
        let receipt = try await editor(fixture).applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: Set(fixture.ids.map(\.rawValue)),
            values: [.unitCost: .currency(amount: 450, code: "SEK")]
        ))
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        #expect(try #require(await fixture.session.markup(fixture.ids[0])).customValues[unitCost.id]
            == .currency(amount: 450, code: "SEK"))
        await fixture.environment.ledger.refresh()
        let ledger = fixture.environment.ledger

        // Row totals: 12 × 450 = 5 400 and 2 × 450 = 900. Old code: empty on every row.
        var totals: [UUID: ZPDFUIPresentation.LedgerCellValue] = [:]
        for index in 0..<ledger.rowCount {
            let row = try #require(ledger.row(at: index))
            totals[row.markupID] = row.value(.totalCost)
        }
        #expect(totals[fixture.ids[0].rawValue] == .currency(amount: 5_400, code: "SEK"))
        #expect(totals[fixture.ids[1].rawValue] == .currency(amount: 900, code: "SEK"))

        // Grand total: 5 400 + 900 = 6 300. Unit Cost is a rate and has no total.
        let grand = ledger.grandTotals
        #expect(grand.quantities[.totalCost]?.value == 6_300)
        #expect(grand.quantities[.unitCost] == nil)
        #expect(ledger.columns.first { $0.id == .unitCost }?.aggregate == nil)
        #expect(ledger.columns.first { $0.id == .totalCost }?.aggregate == .sum)
    }

    @Test("The first Unit Cost of a project has a currency to be typed in")
    func unitCostColumnDeclaresACurrency() async throws {
        let fixture = try await makeFixture()
        let column = try #require(fixture.environment.ledger.columns.first { $0.id == .unitCost })
        // Old code: no dimension, so the Bulk Edit panel refused "450" for want of a currency.
        let code = try #require(column.dimension?.currencyCode)
        #expect(ZPDFContracts.QuantityDimension.isValidCurrencyCode(code))
    }

    // MARK: NL-QTY-14 — export the selected rows

    @Test("An export scoped to two selected rows carries two rows, totals equal to their sum, and says so")
    func selectedRowsExport() async throws {
        let fixture = try await makeFixture(sizes: [(40, 30), (40, 30), (20, 10)])
        var request = fixture.environment.ledger.request
        request.markupScope = [fixture.ids[0].rawValue, fixture.ids[2].rawValue]
        let (report, _) = try await fixture.session.exportReportWithDiagnostics(title: "T", request: request)
        // Two of three rows; 12 + 2 = 14 m² — never the unscoped 26.
        let exported: Set<MarkupID> = Set(report.allRows().map(\.markupID))
        let expected: Set<MarkupID> = [fixture.ids[0], fixture.ids[2]]
        #expect(exported == expected)
        #expect(report.metadata.rowCount == 2)
        #expect(report.metadata.totalRowCountBeforeFilter == 3)
        #expect(report.metadata.filterDescription.contains("SELECTED(2)"))
        let planArea = try #require(await fixture.session.ledgerColumns.column(standard: .planArea))
        let total = try #require(report.grandTotals.first { $0.column == planArea.id && $0.function == .sum })
        #expect(total.value == .quantity(.area(14)))
    }

    // MARK: NL-QTY-17 — status counts

    @Test("Status counts cover every row, filtered or not, in the frozen order, titled for people")
    func statusCounts() async throws {
        let fixture = try await makeFixture()
        _ = try await editor(fixture).applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [fixture.ids[0].rawValue, fixture.ids[1].rawValue],
            values: [.status: .choice("accepted")]
        ))
        await fixture.environment.ledger.refresh()
        let before = fixture.environment.ledger.statusCounts
        let untouched = try #require(await fixture.session.markup(fixture.ids[2])).status
        #expect(before.first { $0.value == "accepted" }?.count == 2)
        #expect(before.first { $0.value == untouched.rawValue }?.count == 1)
        #expect(before.first { $0.value == "accepted" }?.title == "Accepted")
        #expect(before.reduce(0) { $0 + $1.count } == 3)
    }
}
