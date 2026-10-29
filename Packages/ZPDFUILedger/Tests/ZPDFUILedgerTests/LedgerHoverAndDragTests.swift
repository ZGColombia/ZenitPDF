import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// NL-UX-09 (hover cross-highlight) and NL-UX-15 (rows dragged out as a table), r2-layers. No
/// window is opened; the drag writes to a private pasteboard, never the general one.
@MainActor
@Suite("Ledger hover and drag out", .ledgerTierSerialised)
struct LedgerHoverAndDragTests {

    @Test("The pointer over a row reports its markup once; leaving the rows reports none")
    func hoverReportsTheMarkup() {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let host = LedgerTableHost(rowSource: source, mode: .flat, groupingColumns: [])
        host.controller.loadViewIfNeeded()
        var reported: [UUID?] = []
        host.controller.onHoverMarkup = { reported.append($0) }

        host.controller.hover(atVisualRow: 0)
        host.controller.hover(atVisualRow: 0)   // same row: nothing new
        host.controller.hover(atVisualRow: 1)
        host.controller.hover(atVisualRow: -1)  // left the rows
        let first = LedgerFixtures.rows[0].markupID
        let second = LedgerFixtures.rows[1].markupID
        #expect(reported == [first, second, nil])
        #expect(host.controller.hoveredRowID == nil)
    }

    @Test("A group heading names no markup")
    func hoverOnAHeading() {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let host = LedgerTableHost(rowSource: source, mode: .grouped, groupingColumns: [.projectZone])
        host.controller.loadViewIfNeeded()
        var reported: [UUID?] = []
        host.controller.onHoverMarkup = { reported.append($0) }
        // Row 0 of the grouped outline is the first zone's heading.
        guard case .group = host.controller.content(atVisualRow: 0) else {
            Issue.record("row 0 is not a heading")
            return
        }
        host.controller.hover(atVisualRow: 0)
        #expect(reported.isEmpty, "no markup under a heading, and nothing changed from none")
    }

    @Test("Rows dragged out carry the Copy table: header first, the whole selection when the drag starts on it")
    func dragOutWritesTheTable() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let host = LedgerTableHost(rowSource: source, mode: .flat, groupingColumns: [])
        host.controller.loadViewIfNeeded()
        let table = host.controller.mainTableViewForTesting
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("zenit.test.ledger-drag.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        // A drag that starts on a selected row carries the selection: header + two rows.
        #expect(host.controller.tableView(table, writeRowsWith: IndexSet(integer: 1), to: pasteboard))
        let text = try #require(pasteboard.string(forType: .tabularText))
        #expect(text == host.controller.copyText(), "the same table Copy writes")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        #expect(lines.first?.contains("Subject") == true)
        #expect(pasteboard.string(forType: .string) == text)

        // A drag that starts on an unselected row carries that row alone.
        #expect(host.controller.tableView(table, writeRowsWith: IndexSet(integer: 2), to: pasteboard))
        #expect(pasteboard.string(forType: .tabularText)?.split(separator: "\n").count == 2)

        // A vertical drag still selects rows; a drag out starts with a sideways move.
        #expect(table.verticalMotionCanBeginDrag == false)
    }
}
