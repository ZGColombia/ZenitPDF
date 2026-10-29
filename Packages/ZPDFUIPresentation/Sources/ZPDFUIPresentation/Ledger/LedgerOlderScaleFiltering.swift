import Foundation

/// A ledger that knows which rows hold a value kept under an older scale (NL-MEASURE-03,
/// Keep Existing Values) and can be narrowed to them — so such a value never passes unnoticed into
/// a total. Optional: a presenter without kept values simply does not conform.
@MainActor
public protocol LedgerOlderScaleFiltering: AnyObject {
    /// Rows holding a kept value, over every row whether filtered out or not.
    var olderScaleRowCount: Int { get }
    /// Whether the ledger shows only those rows.
    var showsOnlyOlderScaleValues: Bool { get }
    /// Shows only those rows, or every row again.
    func setShowsOnlyOlderScaleValues(_ on: Bool)
}
