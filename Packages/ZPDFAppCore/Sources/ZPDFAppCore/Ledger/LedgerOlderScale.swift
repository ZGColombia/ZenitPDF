import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// A value kept under an older scale (NL-MEASURE-03, ADR-0030 §2: Keep Existing Values) as the
/// Quantity Ledger shows it.
///
/// A kept measurement stays in every total, as the person chose; what it may never do is pass
/// unnoticed. So its row carries a badge in words, and the ledger can be narrowed to exactly those
/// rows (``LedgerRequest/onlyOlderScaleValues``). One predicate decides all three — badge, count and
/// filter — so they cannot disagree.
public enum LedgerOlderScale {

    /// Whether a record's value was kept under an older version of its scale: the session flags
    /// such a value ``MeasurementWarning/Code/staleScaleVersion`` when it keeps it.
    public static func isKept(_ record: MarkupRecord) -> Bool {
        record.measurement?.warnings.contains { $0.code == .staleScaleVersion } ?? false
    }

    /// The badge's words, with a glyph — never colour alone.
    public static var badge: String {
        "⚠ " + NSLocalizedString("Older scale", comment: "Ledger badge: this value was kept under an older version of its scale")
    }
}

extension AppLedgerPresenter: LedgerOlderScaleFiltering {}
