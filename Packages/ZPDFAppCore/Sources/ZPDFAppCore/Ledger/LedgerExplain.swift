import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// "Explain any number": for the selected rows, each
/// row's value, how it was made — measured on which sheet at which scale (the trace resolver's
/// answer, never today's scale for yesterday's row), or derived by which formula — and the exact
/// sum per unit.
extension AppCoreEnvironment {

    public func explain(_ markupIDs: Set<UUID>) async -> LedgerExplanation {
        guard let projection = try? await session.ledgerProjection(.flat) else {
            return LedgerExplanation(rows: [], totals: [])
        }
        let facts = await measurementTraceFacts()
        // The ledger's own additivity rule, as the snapshots use it (S-031): the column a row's
        // `Value` came from decides. The dimension test added a Rise/Drop row's rise — a length —
        // into the metres total the ledger refuses to make (T-026, BH-240).
        let reader = LedgerBridge.PrimaryQuantityReader(view: projection.view, formatter: projection.formatter)
        var rows: [LedgerExplanation.Row] = []
        var sums: [ZPDFUIPresentation.QuantityDimension: Decimal] = [:]
        var order: [ZPDFUIPresentation.QuantityDimension] = []
        for index in 0..<projection.rowCount {
            guard let row = projection.row(at: index), markupIDs.contains(row.markupID) else { continue }
            let quantity = LedgerDefaultColumns.primaryQuantity(for: row)
            let provenance: String
            if row.displayValue(.icon).hasPrefix("ƒ") {
                provenance = row.displayValue(.comment)
            } else if row.isRead {
                // S-090: a row read from a schedule table names its source, never a sheet and a
                // scale it was not measured at.
                provenance = NSLocalizedString(
                    "Read from a table on the drawing, not measured",
                    comment: "Explain: the provenance of a row whose quantity was read from a schedule table"
                )
            } else if let fact = facts[MarkupID(row.markupID)] {
                provenance = String(format: NSLocalizedString(
                    "Measured on %1$@ at %2$@ by %3$@",
                    comment: "Explain: a measured row's provenance; sheet, scale at measure time, author"
                ), fact.sheetLabel, fact.scaleText, fact.author.isEmpty ? "—" : fact.author)
            } else {
                provenance = ""
            }
            rows.append(.init(
                markupID: row.markupID, subject: row.displayValue(.subject), label: row.displayValue(.label),
                valueText: [LedgerDefaultColumns.valueText(for: row), LedgerDefaultColumns.unitText(for: row)]
                    .filter { !$0.isEmpty }.joined(separator: " "),
                value: quantity, provenance: provenance
            ))
            let adds = reader.contribution(atStoreIndex: projection.view.tree.orderedRowIndices[index])?.isAdditive ?? false
            if let quantity, adds, !quantity.dimension.ratio, !quantity.dimension.angle {
                if sums[quantity.dimension] == nil { order.append(quantity.dimension) }
                sums[quantity.dimension, default: 0] += quantity.value
            }
        }
        let formatter = ledger.projectionFormatter
        let totals = order.map { dimension in
            // With its unit: one line per unit, and a line that says which (round 2).
            formatter.textWithUnit(ZPDFUIPresentation.DecimalQuantity(value: sums[dimension] ?? 0, dimension: dimension))
        }
        return LedgerExplanation(rows: rows, totals: totals)
    }
}

extension AppLedgerPresenter: LedgerExplaining {
    public func explain(_ markupIDs: Set<UUID>) async -> LedgerExplanation {
        await explainSeam?(markupIDs) ?? LedgerExplanation(rows: [], totals: [])
    }
}
