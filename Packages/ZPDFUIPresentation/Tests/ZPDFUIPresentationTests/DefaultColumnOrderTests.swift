import Foundation
import Testing
@testable import ZPDFUIPresentation

/// R-148. `LedgerDefaultColumns.arranged(_:)` builds its lead from `defaultOrder`, so the
/// default column order is declared once.
@Suite("Ledger default column order")
struct DefaultColumnOrderTests {

    private func column(_ id: LedgerColumnID, visible: Bool = false, pinned: Bool = true) -> LedgerColumn {
        var column = LedgerColumn(id: id, title: id.rawValue, kind: .text, width: 10)
        column.visible = visible
        column.pinned = pinned
        return column
    }

    @Test("The arranged lead is exactly defaultOrder, whatever order the projection used")
    func leadFollowsDefaultOrder() {
        let projection = [
            column(.perimeter), column(.comment), column(.costCode), column(.subject),
            column(.label), column(.icon), column(.pageLabel)
        ]
        let arranged = LedgerDefaultColumns.arranged(projection)
        let order = LedgerDefaultColumns.defaultOrder
        #expect(Array(arranged.prefix(order.count).map(\.id)) == order)
        // The lead is visible, unpinned and at its default width; Perimeter is right-aligned.
        for lead in arranged.prefix(order.count) {
            #expect(lead.visible, "\(lead.id)")
            #expect(!lead.pinned, "\(lead.id)")
            #expect(lead.width == LedgerDefaultColumns.defaultWidth(for: lead.id), "\(lead.id)")
        }
        #expect(arranged.first { $0.id == .perimeter }?.alignment == .trailing)
        // Everything else trails, hidden until shown.
        #expect(arranged.last?.id == .costCode)
        #expect(arranged.last?.visible == false)
    }

    @Test("A default column the projection lacks is skipped; the display columns are always there")
    func missingColumnsAreSkipped() {
        let arranged = LedgerDefaultColumns.arranged([column(.label), column(.pageLabel)])
        #expect(arranged.map(\.id) == [
            .pageLabel, .label, LedgerDefaultColumns.valueColumnID, LedgerDefaultColumns.unitColumnID
        ])
    }
}
