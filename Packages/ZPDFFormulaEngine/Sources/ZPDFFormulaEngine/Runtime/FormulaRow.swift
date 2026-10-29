import Foundation
import ZPDFContracts

/// The per-row input a compiled formula reads.
///
/// A plain value type: no references, no laziness, nothing to synchronise. Evaluating 100 000 of
/// these across a task group is safe because there is nothing shared to race on.
public struct FormulaRow: Hashable, Sendable {
    /// Measurement results for this row, keyed by field.
    public var fields: [MeasurementField: DecimalQuantity]
    /// Custom column cells, keyed by stable column id.
    public var columns: [ColumnID: FormulaValue]
    /// The row's unit cost, if it has one. `UnitCost` in a formula reads this.
    public var unitCost: DecimalQuantity?

    public init(
        fields: [MeasurementField: DecimalQuantity] = [:],
        columns: [ColumnID: FormulaValue] = [:],
        unitCost: DecimalQuantity? = nil
    ) {
        self.fields = fields
        self.columns = columns
        self.unitCost = unitCost
    }

    public func value(for field: MeasurementField) -> FormulaValue {
        fields[field].map(FormulaValue.number) ?? .blank
    }

    public func value(for column: ColumnID) -> FormulaValue {
        columns[column] ?? .blank
    }
}

// A compiled formula takes a ``FormulaRow`` and nothing else. There is no group: `SUM`, `AVG`
// and `COUNT` type-check but refuse to evaluate, because both callers (the ledger's formula
// columns and the assembly evaluator) refuse aggregate formulas before evaluating, and totals
// over rows are the Quantity Ledger's own summary layer (U-074). The one-field wrapper that
// carried the row, and the second `evaluate` entry point that took it, are gone (V-076).
