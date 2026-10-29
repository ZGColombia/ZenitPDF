import Foundation
import ZPDFContracts

/// NL-QTY-07 (round 2): a derived row has no markup of its own on the canvas — it is
/// materialised from its source (ADR-0024 §2.2) — so selecting it in the ledger selects the
/// measured row it came from. Before, the canvas was handed an identity it did not know and
/// selected nothing.
extension AppLedgerPresenter {

    /// `rowIDs` with every derived row replaced by its source markup.
    public func canvasSelection(for rowIDs: Set<UUID>) -> Set<UUID> {
        var output: Set<UUID> = []
        for id in rowIDs {
            if let position = projection.positionByMarkupID[id],
               let source = projection.view.row(displayRow: position).record.derivation?.sourceMarkupID {
                output.insert(source.rawValue)
            } else {
                output.insert(id)
            }
        }
        return output
    }
}
