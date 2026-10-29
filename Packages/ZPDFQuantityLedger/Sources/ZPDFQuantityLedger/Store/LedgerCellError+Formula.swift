import Foundation
import ZPDFFormulaEngine

extension LedgerCellError {

    /// The error a formula cell carries when its formula failed on this row (T-057).
    ///
    /// The kind follows the engine's code, so the cell reads "Divide by zero" or "Mixed units"
    /// where that is what happened; every failure used to be recorded as `formulaEvaluation`,
    /// which the table shows as a bare "Formula error", leaving the bridge's more specific texts
    /// unreachable. The detail is the engine's message, which names the failing sub-expression —
    /// `Division by zero in `100 / [Divisor]`.` — without the source offset the ledger has no
    /// use for; the table shows it as the cell's help tag.
    init(formulaFailure error: FormulaEngineError) {
        let kind: Kind
        switch error.code {
        case .divisionByZero, .moduloByZero:
            kind = .divisionByZero
        case .dimensionMismatch, .dimensionRejected:
            kind = .dimensionMismatch
        case .blankValue, .blankCondition:
            // Nothing to compute from on this row (V-058): a Length row's `Area`, a row with
            // no Pack size. A total leaves the cell out instead of refusing.
            kind = .missingInput
        default:
            kind = .formulaEvaluation
        }
        self.init(kind: kind, detail: error.message)
    }
}
