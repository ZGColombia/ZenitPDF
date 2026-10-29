import AppKit
import Foundation

/// NL-UX-09 and NL-UX-15 (r2-layers): the pointer over a row names its markup to the host, which
/// outlines it on the canvas; and rows dragged out of the ledger arrive in a spreadsheet or a text
/// editor as the same tab-separated table Copy writes.
extension LedgerTableController {

    // MARK: Hover (NL-UX-09)

    /// The row under the pointer changed. Reports the markup only when it changes, so a pointer
    /// moving along one row does not wake the canvas on every event.
    func hover(atVisualRow row: Int) {
        var id: UUID?
        if row >= 0, case let .row(position) = content(atVisualRow: row),
           let sourceIndex = plan.sourceIndex(displayPosition: position) {
            id = rowSource.ledgerRowID(at: sourceIndex)
        }
        guard id != hoveredRowID else { return }
        hoveredRowID = id
        onHoverMarkup?(id)
    }

    // MARK: Drag out (NL-UX-15)

    /// The rows a drag starting on `rows` carries: the whole selection when the drag starts on a
    /// selected row, else that row alone — the Finder's rule.
    func draggedVisualRows(_ rows: IndexSet, selection: IndexSet) -> IndexSet {
        rows.isSubset(of: selection) && !selection.isEmpty ? selection : rows
    }

    /// Writes `rows` of the active table to `pasteboard` as tab-separated text and plain text.
    /// Returns whether anything was written.
    @discardableResult
    func writeDraggedRows(_ rows: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        guard let text = tabularText(visualRows: rows) else { return false }
        pasteboard.declareTypes([.tabularText, .string], owner: nil)
        pasteboard.setString(text, forType: .tabularText)
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// NSTableView's drag of rows: one pasteboard entry for all of them, header first, so a
    /// spreadsheet receives one table rather than one cell per row.
    ///
    /// `nonisolated` because the SDK declares this (deprecated) requirement without the main
    /// actor; AppKit calls it on the main thread, which `assumeIsolated` checks.
    @objc(tableView:writeRowsWithIndexes:toPasteboard:)
    nonisolated public func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        nonisolated(unsafe) let table = tableView
        nonisolated(unsafe) let board = pboard
        return MainActor.assumeIsolated {
            writeDraggedRows(draggedVisualRows(rowIndexes, selection: table.selectedRowIndexes), to: board)
        }
    }

    /// NSOutlineView's drag of items: rows and group headings, in display order.
    @objc(outlineView:writeItems:toPasteboard:)
    nonisolated public func outlineView(_ outlineView: NSOutlineView, writeItems items: [Any], to pasteboard: NSPasteboard) -> Bool {
        nonisolated(unsafe) let items = items
        nonisolated(unsafe) let outline = outlineView
        nonisolated(unsafe) let board = pasteboard
        return MainActor.assumeIsolated {
            var rows = IndexSet()
            for item in items {
                let row = outline.row(forItem: item)
                if row >= 0 { rows.insert(row) }
            }
            return writeDraggedRows(draggedVisualRows(rows, selection: outline.selectedRowIndexes), to: board)
        }
    }

    /// Lets rows leave the application as a copy, and keeps a vertical drag for selecting rows:
    /// a drag out begins with a sideways move.
    static func configureDragOut(_ table: NSTableView) {
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        table.verticalMotionCanBeginDrag = false
    }
}

/// One tracking area per ledger table view, kept current with its visible rect, so the pointer's
/// row is known without a click (NL-UX-09).
@MainActor
enum LedgerRowHoverTracking {
    static func install(on view: NSView) {
        for area in view.trackingAreas where area.owner === view && area.userInfo?["zenit.ledgerHover"] != nil {
            view.removeTrackingArea(area)
        }
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: view,
            userInfo: ["zenit.ledgerHover": true]
        ))
    }
}
