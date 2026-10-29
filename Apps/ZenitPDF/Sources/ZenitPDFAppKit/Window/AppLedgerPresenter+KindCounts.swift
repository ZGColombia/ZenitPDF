import ZPDFAppCore
import ZPDFUIShell

/// The Quantity Ledger bar's summary chips (Areas 2, Lengths 7, …) read per-kind row counts
/// through ``LedgerKindRowCounting``. The app's presenter already keeps them, filter-aware, in
/// `rowCountsByMeasurementKind`; this conformance is what lets the chips show them instead of
/// leaving the count out.
extension AppLedgerPresenter: LedgerKindRowCounting {}
