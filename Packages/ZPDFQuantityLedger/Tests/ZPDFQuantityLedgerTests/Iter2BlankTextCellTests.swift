import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// S-077: a blank Subject, Label, Comment or Author
/// is no value, the rule BH-196 set for an unassigned zone, layer, scale region, scale or page.
@Suite("Iteration 2 — blank text cells are empty")
struct Iter2BlankTextCellTests {

    private static func record(_ index: Int, text: String) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(index)),
            documentID: DocumentID(SyntheticLedger.deterministicUUID(-1)),
            pageID: PageID(SyntheticLedger.deterministicUUID(-2)),
            kind: .measurement,
            subject: text,
            label: text,
            comment: text,
            author: text,
            createdAt: SyntheticLedger.epoch,
            modifiedAt: SyntheticLedger.epoch
        )
    }

    @Test("S-077: a blank Subject, Label, Comment or Author is empty, filters as empty and sorts with the empties")
    func blankTextIsEmpty() throws {
        // Old output: `.text("")` for all four — "is empty" matched no row, "is not empty"
        // matched both rows, and an ascending sort put the blank row first ([0, 1]) while
        // grouping filed it under "(none)", which the BH-196 columns already did right.
        let columns = try LedgerColumnSet.standard()
        let store = try LedgerStore(
            markups: [Self.record(0, text: ""), Self.record(1, text: "Wall W1")],
            columns: columns,
            names: LedgerNameCatalog()
        )
        func column(_ standard: StandardLedgerColumn) throws -> ColumnID {
            try #require(columns.columnID(standard: standard))
        }
        let evaluator = LedgerFilterEvaluator(store: store)
        for standard in [StandardLedgerColumn.subject, .label, .comment, .author] {
            let id = try column(standard)
            #expect(store.value(at: 0, column: id) == .value(.empty), "\(standard)")
            #expect(store.value(at: 1, column: id) == .value(.text("Wall W1")), "\(standard)")
            #expect(evaluator.filter([0, 1], with: .rule(LedgerFilterRule(column: id, op: .isEmpty))) == [0], "\(standard)")
            #expect(evaluator.filter([0, 1], with: .rule(LedgerFilterRule(column: id, op: .isNotEmpty))) == [1], "\(standard)")
            // Nulls last, as the grouping puts "(none)" last.
            #expect(LedgerSorter(store: store, descriptors: [LedgerSortDescriptor(column: id)]).sorted([0, 1]) == [1, 0], "\(standard)")
        }
    }
}
