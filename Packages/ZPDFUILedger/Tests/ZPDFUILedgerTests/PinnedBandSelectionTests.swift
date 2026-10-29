import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// LT-40 from the live test, 2026-08-29: clicking a ledger row on the PINNED column band
/// (Type/Subject — the leading ~230 pt of every row) highlighted the row and told nobody.
/// `tableViewSelectionDidChange` explicitly ignored the pinned table, sync was one-way
/// main→pinned, so the presenter's selection stayed empty and Export/Copy Snippet stayed
/// disabled however deliberately the row was chosen.
@MainActor
@Suite(.ledgerTierSerialised)
struct PinnedBandSelectionTests {

    private final class SelectionSpy: LedgerTableControllerDelegate {
        var received: [Set<UUID>] = []
        func ledgerTable(_ controller: LedgerTableController, didChangeSelection rowIDs: Set<UUID>) {
            received.append(rowIDs)
        }
        func ledgerTable(_ controller: LedgerTableController, didActivate rowID: UUID) {}
        func ledgerTable(_ controller: LedgerTableController, didChangeColumns columns: [LedgerColumn]) {}
        func ledgerTable(_ controller: LedgerTableController, didRequestSort columnID: LedgerColumnID, ascending: Bool) {}
        func ledgerTable(_ controller: LedgerTableController, didSetExpanded expanded: Bool, groupPath: String) {}
    }

    @Test("A selection made on the pinned band reaches the delegate and the row IDs")
    func pinnedBandSelectionReachesTheDelegate() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        controller.rebuildPlan()
        let spy = SelectionSpy()
        controller.delegate = spy

        let pinned = controller.pinnedTableViewForTesting
        // AppKit posts selectionDidChange for this exactly as it does for a click;
        // the controller is the pinned table's delegate, so no manual notification.
        pinned.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let expected = try #require(source.ledgerRowID(at: 0))
        #expect(controller.selectedRowIDs == [expected],
                "LT-40: the pinned-band click never reached selectedRowIDs")
        #expect(spy.received.last == [expected],
                "LT-40: the delegate never heard about the pinned-band click")
    }

    @Test("The pinned mirror does not echo: one click, one delegate report")
    func pinnedMirrorDoesNotEcho() throws {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        controller.rebuildPlan()
        let spy = SelectionSpy()
        controller.delegate = spy

        let pinned = controller.pinnedTableViewForTesting
        pinned.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(spy.received.count == 1, "the pinned→main mirror echoed back into a second report")
    }

    @Test("A click on the main table reports once: the main→pinned mirror does not echo")
    func mainMirrorDoesNotEcho() throws {
        // Old output: `spy.received.count == 2` (CR-63). The main handler reported, then
        // mirrored the selection into the pinned band unguarded; the pinned band's own
        // `selectionDidChange` mirrored it back and reported a second time, so one click ran
        // `presenter.select` and the bulk-edit adoption twice.
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        controller.rebuildPlan()
        let spy = SelectionSpy()
        controller.delegate = spy

        let main = controller.mainTableViewForTesting
        main.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        let expected = try #require(source.ledgerRowID(at: 2))
        #expect(spy.received == [[expected]], "one click, one report, the right row")
        #expect(controller.selectedRowIDs == [expected])
        // The pinned band followed, so both bands highlight the same row.
        #expect(controller.pinnedTableViewForTesting.selectedRowIndexes == IndexSet(integer: 2))
    }

    @Test("A click on the grouped outline reports once as well")
    func groupedMirrorDoesNotEcho() throws {
        // Old output: two delegate reports for one click, for the same reason as the flat
        // table (CR-63, `outlineViewSelectionDidChange`).
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(
            rowSource: source, mode: .grouped, groupingColumns: [.projectZone]
        )
        controller.loadViewIfNeeded()
        controller.rebuildPlan()
        controller.expandAllGroups()
        let spy = SelectionSpy()
        controller.delegate = spy

        let outline = controller.outlineViewForTesting
        // Row 0 is the "Zone A" heading; row 1 is its first row.
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        #expect(spy.received.count == 1, "the main→pinned mirror echoed back into a second report")
        #expect(spy.received.first?.count == 1, "the click landed on a row, not a heading")
        #expect(controller.pinnedTableViewForTesting.selectedRowIndexes == IndexSet(integer: 1))
    }
}
