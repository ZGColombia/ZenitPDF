import Foundation

/// A presenter that can say how many markups in the document carry no quantity.
///
/// The Quantity Ledger bar's Markups chip shows the number of non-measurement markups:
/// text boxes, callouts, notes, images, shapes, stamps. Most of them
/// have no ledger row — a markup earns one only by producing a quantity or by being given a
/// subject — so the ledger's own row count cannot answer it. The chip used to show that row
/// count, and four text boxes on a sheet read "Markups 0" (L-50).
@MainActor
public protocol LedgerMarkupCounting: AnyObject {
    /// Markups in the document whose kind carries no quantity, ledger row or not.
    var nonMeasurementMarkupCount: Int { get }
}

#if DEBUG || ZPDF_MOCKS
/// The mock's sample holds every markup as a row, so the rows without a measurement kind are
/// its non-measurement markups. Debug and test builds only, like the mock itself (R-142).
extension MockLedgerPresenter: LedgerMarkupCounting {
    public var nonMeasurementMarkupCount: Int {
        allRowsForAudit.reduce(0) { $1.measurementKind == nil ? $0 + 1 : $0 }
    }
}
#endif
