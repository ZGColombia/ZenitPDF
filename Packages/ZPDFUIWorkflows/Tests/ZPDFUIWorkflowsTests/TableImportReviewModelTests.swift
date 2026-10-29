import Foundation
import Testing
@testable import ZPDFUIWorkflows

/// The table-import review panel's state, driven without a window (feature 31).
///
/// The claims here are the honesty ones: the grid shows exactly what was read, a refusal
/// is a refusal rather than an empty grid, a number column that cannot parse a cell flags
/// it and keeps the text — never a silent zero — and accepting produces exactly the shape
/// the app tier's acceptance path consumes.
@Suite("Table import review model", .workflowsTierSerialised)
struct TableImportReviewModelTests {

    /// A three-column, three-row schedule the way the app tier would map it: a printed
    /// header on two columns, one positional name, one unread cell, one unplaced line.
    static func doorSchedule() -> TableImportReviewTable {
        TableImportReviewTable(
            columns: [
                .init(index: 0, title: "Door", headerWasPrinted: true),
                .init(index: 1, title: "Width", headerWasPrinted: true),
                .init(index: 2, title: "Column 3", headerWasPrinted: false)
            ],
            rows: [
                .init(
                    cells: [.init(text: "D1"), .init(text: "910"), .init(text: "Oak")],
                    sourceText: "D1 910 Oak"
                ),
                .init(
                    cells: [.init(text: "D2"), .init(text: "12,5"), .init(text: "")],
                    sourceText: "D2 12,5"
                ),
                .init(
                    cells: [.init(text: "D3"), .init(text: "PLAN 2"), .init(text: "Steel")],
                    sourceText: "D3 PLAN 2 Steel"
                )
            ],
            columnOrigin: .ruleLines,
            unplacedTexts: ["SCHEDULE REV B"]
        )
    }

    @MainActor
    @Test("A proposal comes out as the grid it went in as")
    func proposalBecomesGrid() {
        let model = TableImportReviewModel(
            table: Self.doorSchedule(),
            onAccept: { _ in },
            onCancel: {}
        )
        #expect(model.refusal == nil)
        #expect(model.columns.count == 3)
        #expect(model.rows.count == 3)
        #expect(model.columns.map(\.title) == ["Door", "Width", "Column 3"])
        #expect(model.columnTitles == ["Door", "Width", "Column 3"])
        #expect(model.columnKinds == [.text, .text, .text], "text is the default everywhere")
        // The one unread cell is flagged as unread, not filled in.
        #expect(model.rows[1].cells[2].isUnread)
        #expect(model.table?.unreadCellCount == 1)
        // Text the OCR read but could not file is carried, never dropped.
        #expect(model.table?.unplacedTexts == ["SCHEDULE REV B"])
        #expect(model.canAccept)
    }

    @MainActor
    @Test("A refusal is a full-panel state: no grid, no acceptance, no accept call")
    func refusalHasNoGrid() {
        var cancelled = false
        let model = TableImportReviewModel(
            refusal: .noColumnStructure(interiorRuleCount: 1, alignmentClusterCount: 1),
            onCancel: { cancelled = true }
        )
        #expect(model.table == nil)
        #expect(model.columns.isEmpty)
        #expect(model.rows.isEmpty)
        #expect(!model.canAccept)
        #expect(
            model.refusal == .noColumnStructure(interiorRuleCount: 1, alignmentClusterCount: 1)
        )
        // The refusal explains itself in words; no case may render blank.
        #expect(model.refusal?.displayTitle.isEmpty == false)
        #expect(model.refusal?.displayMessage.isEmpty == false)
        // accept() on a refusal is a no-op — a refusal model is constructed without any
        // accept closure, and the guard refuses before the empty one is reached.
        model.accept()
        #expect(!model.canAccept)
        // cancel() remains the one way out.
        model.cancel()
        #expect(cancelled)
    }

    @MainActor
    @Test("Every refusal case carries non-empty plain words")
    func everyRefusalSpeaks() {
        let refusals: [TableImportReviewRefusal] = [
            .emptyRegion,
            .textWithoutPositions(lineCount: 4),
            .noColumnStructure(interiorRuleCount: 0, alignmentClusterCount: 1),
            .noRows
        ]
        for refusal in refusals {
            #expect(!refusal.displayTitle.isEmpty)
            #expect(!refusal.displayMessage.isEmpty)
        }
    }

    @MainActor
    @Test("A number column flags the cell it cannot parse and keeps its text — never zero")
    func numberColumnFlagsWithoutZeroing() {
        let model = TableImportReviewModel(
            table: Self.doorSchedule(),
            onAccept: { _ in },
            onCancel: {}
        )
        model.columnKinds[1] = .number

        // "910" parses, "12,5" parses (comma decimal), "PLAN 2" does not.
        #expect(model.unparsedRowIndexes(forColumn: 1) == [2])
        #expect(model.isCellFlagged(row: 2, column: 1))
        #expect(!model.isCellFlagged(row: 0, column: 1))
        #expect(!model.isCellFlagged(row: 1, column: 1))
        #expect(model.flaggedCellCount == 1)

        // The flagged cell's text is untouched — the exact OCR text, not "", not "0".
        #expect(model.rows[2].cells[1].text == "PLAN 2")
        // And the parse itself refuses rather than inventing a value.
        #expect(TableImportReviewModel.numberValue(of: "PLAN 2") == nil)
        #expect(TableImportReviewModel.numberValue(of: "PLAN 2") != Decimal(0))

        // A text column makes no number claim, so nothing is flagged there.
        #expect(model.unparsedRowIndexes(forColumn: 0).isEmpty)
        // The unread cell is never flagged: absent is a different fact than unparsable.
        // Column 2 holds "Oak", an unread cell, and "Steel" — under a number claim the two
        // read cells are flagged, and only those.
        model.columnKinds[2] = .number
        #expect(model.unparsedRowIndexes(forColumn: 2) == [0, 2])
        #expect(!model.unparsedRowIndexes(forColumn: 2).contains(1))
    }

    @MainActor
    @Test("The number parse reads plain, comma-decimal and grouped forms, and only those")
    func numberParseIsDeterministic() {
        #expect(TableImportReviewModel.numberValue(of: "910") == Decimal(910))
        #expect(TableImportReviewModel.numberValue(of: "12,5") == Decimal(string: "12.5"))
        #expect(TableImportReviewModel.numberValue(of: "12.5") == Decimal(string: "12.5"))
        #expect(TableImportReviewModel.numberValue(of: "-3.25") == Decimal(string: "-3.25"))
        #expect(TableImportReviewModel.numberValue(of: "1 200") == Decimal(1200))
        #expect(TableImportReviewModel.numberValue(of: "1\u{00A0}200") == Decimal(1200))
        #expect(TableImportReviewModel.numberValue(of: "") == nil)
        #expect(TableImportReviewModel.numberValue(of: "PLAN 2") == nil)
        #expect(TableImportReviewModel.numberValue(of: "910x2100") == nil)
        // Both separators present: refused outright rather than disambiguated by luck.
        #expect(TableImportReviewModel.numberValue(of: "1,200.50") == nil)
        // Two commas cannot be one decimal separator.
        #expect(TableImportReviewModel.numberValue(of: "1,200,300") == nil)
    }

    @MainActor
    @Test("Accepting hands the app tier exactly the acceptance's input shape")
    func acceptProducesTheAcceptedInputShape() throws {
        var received: TableImportReviewOutcome?
        let model = TableImportReviewModel(
            table: Self.doorSchedule(),
            onAccept: { received = $0 },
            onCancel: {}
        )
        model.columnTitles[0] = "  Door mark  "   // trimmed at acceptance
        model.columnTitles[2] = "   "             // blank: falls back to the proposal's title
        model.columnKinds[1] = .number

        model.accept()

        let outcome = try #require(received)
        // One reviewed column per proposal column, in proposal order — the correlation the
        // acceptance's minted bindings rely on.
        #expect(outcome.columns.map(\.index) == [0, 1, 2])
        #expect(outcome.columns.map(\.title) == ["Door mark", "Width", "Column 3"])
        #expect(outcome.columns.map(\.kind) == [.text, .number, .text])
        // The number column names the rows the app tier must keep as text.
        #expect(outcome.columns[1].unparsedRowIndexes == [2])
        #expect(outcome.columns[0].unparsedRowIndexes.isEmpty)
        #expect(outcome.columns[2].unparsedRowIndexes.isEmpty)
        // The subject key matches the acceptance's default: the leftmost column.
        #expect(outcome.subjectColumnIndex == 0)
    }

    @MainActor
    @Test("Cancel raises onCancel and accepts nothing")
    func cancelRaisesOnCancel() {
        var cancelled = false
        var accepted = false
        let model = TableImportReviewModel(
            table: Self.doorSchedule(),
            onAccept: { _ in accepted = true },
            onCancel: { cancelled = true }
        )
        model.cancel()
        #expect(cancelled)
        #expect(!accepted)
    }

    @MainActor
    @Test("The read-row marker is the ADR-0012 glyph and explains itself in words")
    func readRowMarkerIsTheADRGlyph() {
        #expect(TableImportReviewModel.readRowGlyph == "\u{2310}")  // ⌐, ADR-0012 rule 5
        #expect(!TableImportReviewModel.readRowAccessibilityText.isEmpty)
    }
}
