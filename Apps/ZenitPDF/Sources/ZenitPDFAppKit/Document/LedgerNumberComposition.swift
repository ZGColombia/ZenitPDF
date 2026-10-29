import Foundation
import ZPDFQuantityLedger
import ZPDFUILedger

/// Installs the one number formatter the ledger screen, the app's CSV and every exporter share
/// (IM-012's composition half): the screen's
/// renderer seam is pointed at the aggregation layer's `LedgerNumberLocale`, so a value reads
/// the same on the ledger, in the workbook and on the PDF report.
@MainActor
enum LedgerNumberComposition {

    /// Idempotent; called before the first ledger of a process renders.
    static func install() {
        guard !installed else { return }
        installed = true
        LedgerNumberFormatting.setRenderer { value, digits, locale, grouping in
            LedgerNumberLocale.forLocale(locale, grouping: grouping).string(value, decimalPlaces: digits)
        }
    }

    private static var installed = false
}
