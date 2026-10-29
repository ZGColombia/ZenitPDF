import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The status quick filters' counts (NL-QTY-17), in the frozen status order, titled the way
/// the Status column titles its options.
extension AppLedgerPresenter: LedgerStatusCounting {

    public var statusCounts: [LedgerStatusCount] {
        ZPDFContracts.MarkupStatus.allCases.compactMap { status in
            guard let count = rowCountsByStatus[status], count > 0 else { return nil }
            return LedgerStatusCount(value: status.rawValue, title: LedgerBridge.statusTitle(status), count: count)
        }
    }
}
