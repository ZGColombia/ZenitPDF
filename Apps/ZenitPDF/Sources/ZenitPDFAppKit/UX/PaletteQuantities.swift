import AppKit
import ZPDFAppCore
import ZPDFUIPresentation
import ZPDFUIShell

/// A command palette that knows the quantities.
///
/// Typing "floor tile" finds the subject's total — "Floor tile · 42.6 m² in 12 markups" — and
/// Return selects every one of those markups across the drawing. The number is the Quantity
/// Ledger's own subtotal, read from the engine's grouped projection (exact `Decimal`, the
/// aggregation QUALITY_BAR holds), never a sum re-done here. Local, no server, no model.
enum PaletteQuantities {

    /// One subject's line: its name, the ledger's subtotal text and how many markups it holds.
    struct SubjectTotal: Equatable {
        let subject: String
        let totalText: String?
        let markupCount: Int
    }

    /// The subject subtotals of the takeoff, from the engine.
    @MainActor
    static func subjectTotals(core: AppCoreEnvironment) async -> [SubjectTotal] {
        guard let projection = try? await core.session.ledgerProjection(LedgerRequest(grouping: [.subject])) else {
            return []
        }
        return projection.rootGroups.compactMap { group in
            // The title is the subject as the ledger prints it; the grouping token is a
            // normalised key, not something to show or to match markups by.
            let subject = group.title
            guard !subject.isEmpty else { return nil }
            let text = group.totals.displayValues[LedgerDefaultColumns.valueColumnID]
            return SubjectTotal(subject: subject, totalText: text, markupCount: group.totals.rowCount)
        }
    }

    /// The palette rows for those totals.
    @MainActor
    static func rows(_ totals: [SubjectTotal], core: AppCoreEnvironment) -> [CommandPaletteItem] {
        totals.map { total in
            let detail: String
            if let text = total.totalText, !text.isEmpty {
                detail = String(
                    format: NSLocalizedString("%1$@ in %2$ld markups", comment: "Command palette quantity row: subtotal and markup count"),
                    text, total.markupCount
                )
            } else {
                detail = String(format: NSLocalizedString("%ld markups", comment: "Command palette row detail: how many markups a selection row selects"), total.markupCount)
            }
            return CommandPaletteItem(
                id: "quantity:\(total.subject)",
                title: total.subject,
                detail: detail,
                category: .selection,
                keywords: [NSLocalizedString("total", comment: "Command palette keyword for a subject's quantity row")],
                perform: { [weak core] in
                    guard let core else { return }
                    let ids = Set(core.snapshot.markups.filter { $0.subject == total.subject && !$0.hidden }.map(\.id))
                    core.canvas.select(markupIDs: ids, additive: false)
                }
            )
        }
    }
}
