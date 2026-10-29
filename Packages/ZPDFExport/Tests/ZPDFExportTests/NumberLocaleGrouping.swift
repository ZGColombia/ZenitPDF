import ZPDFExport

extension ExportNumberLocale {

    /// This locale with its digit grouping replaced: `nil` turns grouping off.
    ///
    /// A test helper (X-036): nothing in the shipping code changes a pinned locale's grouping
    /// after the fact — `LedgerNumberLocale.forLocale(_:grouping:)` decides it once.
    func withGrouping(_ separator: String?) -> ExportNumberLocale {
        ExportNumberLocale(
            identifier: identifier,
            decimalSeparator: decimalSeparator,
            groupingSeparator: separator,
            groupingSize: groupingSize,
            minusSign: minusSign,
            digits: digits
        )
    }
}
