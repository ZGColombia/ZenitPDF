import Foundation

// LedgerMarkupJump and LedgerSelectionCoordinator lived here. Their only host was LedgerScreen,
// the package's own SwiftUI screen, which the application never used (it went too, later in the
// same iteration, with its export dialog and grouping bar): the shipping ledger is
// ZPDFUIShell's LedgerPaneModel over LedgerTableHost, which bridges selection through
// host.onSelectionChange and host.onActivate. Both types were removed as dead code in loop
// iteration 1 (R-124), together with the two hook-gate allow-list entries that excused
// the coordinator's unassigned onJump and onSelectionChanged.

/// Builds the ledger's spoken summary line.
public enum LedgerAccessibilitySummary {

    /// The summary a screen reader reads when focus enters the ledger.
    ///
    /// For example: "Ledger, 412 rows, 3 groups, total 1 240.5 m², 2 selected".
    public static func text(
        rowCount: Int,
        groupCount: Int,
        totalText: String?,
        selectionCount: Int = 0
    ) -> String {
        // "Ledger, 1 row", never "Ledger, 1 rows" (U-066): each count is its own plural piece.
        var summary = LedgerPlurals.ledgerSummary(rows: rowCount, groups: groupCount)
        if let totalText, !totalText.isEmpty {
            let format = NSLocalizedString(
                "%1$@, total %2$@",
                comment: "VoiceOver summary suffix: existing summary, grand total"
            )
            summary = String(format: format, summary, totalText)
        }
        if selectionCount > 0 {
            let format = NSLocalizedString(
                "%1$@, %2$d selected",
                comment: "VoiceOver summary suffix: existing summary, number of selected rows"
            )
            summary = String(format: format, summary, selectionCount)
        }
        return summary
    }
}
