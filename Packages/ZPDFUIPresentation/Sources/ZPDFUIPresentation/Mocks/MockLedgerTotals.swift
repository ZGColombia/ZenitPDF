// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation

extension LedgerTotals {

    /// Builds the **mock** totals for a set of rows over a set of columns.
    ///
    /// Sample data and mock presenters only. The totals the product shows come from the core
    /// aggregator through `LedgerBridge.totals` in ZPDFAppCore; this was a second, public
    /// totals rule beside it until R-138 moved it here, where nothing shipping can pick it up.
    ///
    /// - Parameters:
    ///   - rows: The rows to aggregate.
    ///   - columns: The columns to total. Only columns that carry a dimension *and*
    ///     declare ``LedgerAggregate/sum`` produce a total here; every other aggregate is
    ///     computed by the presenter, because it needs more than the running sum.
    ///   - format: Renders a summed quantity into display text for its column.
    static func mockSumming(
        rows: [LedgerRow],
        columns: [LedgerColumn],
        format: (LedgerColumn, DecimalQuantity) -> String
    ) -> LedgerTotals {
        var quantities: [LedgerColumnID: DecimalQuantity] = [:]
        var incompatible: Set<LedgerColumnID> = []
        // S-043: rows that carried a value into each totalled column, as the core counts them.
        var valueCounts: [LedgerColumnID: Int] = [:]

        for column in columns where column.isQuantityColumn && column.aggregate == .sum {
            guard let dimension = column.dimension else { continue }
            var running = DecimalQuantity.zero(dimension)
            var contributed = false
            valueCounts[column.id] = 0
            for row in rows {
                if !row.value(column.id).isEmpty { valueCounts[column.id, default: 0] += 1 }
                // The column's declared dimension resolves a free-typed number: a `12` typed
                // into a Count column is twelve things, and into a Waste column a factor of
                // twelve. Before ADR-0014 every untyped number was minted `.ratio`, which was
                // the same value as `.count` and so summed with anything dimensionless; now it
                // would be refused, so the column has to say (ADR-0014 §3).
                guard let quantity = row.quantity(column.id, declaring: dimension) else {
                    // BH-766: a numeric column never stores text; a text cell in one is the
                    // rendering of a core error ("Formula error"). Totalling the other rows
                    // would head the column with a number the export refuses, so the column
                    // fails instead (CR-54).
                    if case .text = row.values[column.id] ?? .empty {
                        incompatible.insert(column.id)
                        contributed = false
                        break
                    }
                    continue
                }
                guard let sum = try? running.adding(quantity) else {
                    incompatible.insert(column.id)
                    contributed = false
                    break
                }
                running = sum
                contributed = true
            }
            if contributed, !incompatible.contains(column.id) {
                quantities[column.id] = running
            }
        }

        var displayValues: [LedgerColumnID: String] = [:]
        for column in columns {
            guard let quantity = quantities[column.id] else { continue }
            displayValues[column.id] = format(column, quantity)
        }

        return LedgerTotals(
            rowCount: rows.count,
            quantities: quantities,
            displayValues: displayValues,
            incompatibleColumns: incompatible,
            valueCounts: valueCounts
        )
    }
}
#endif
