import Foundation
import os

/// Money as a person reads it, in one place for every surface that prints an amount.
///
/// The ledger's money cells, its group headings, the summary chips and the Rate Library all
/// print the same `Decimal`. They used to round it three ways: the cell half away from zero
/// (S-079), the Rate Library with ICU's half-even default, so a rate of 45.125 SEK read
/// "45,12 kr" there and "45,13 kr" in the Unit Cost cell (T-052), and a group heading at the
/// session's length precision, so 767.125 printed "767.125" or "767" against "767,13 kr" in the
/// cells (T-048). Every one of them now asks here.
///
/// The rule is the product's display rule (`LedgerDisplayRounding`, `.plain`): round the exact
/// value once, half away from zero, at the currency's own minor digits — two for SEK, none for
/// JPY, three for KWD.
public enum LedgerMoneyFormatting {

    private static let digitsCache = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    /// The currency's minor digits (ISO 4217, as the system's currency data states them).
    ///
    /// Read once per code and cached, so a heading drawn per row never allocates a formatter.
    public static func fractionDigits(currencyCode code: String) -> Int {
        if let cached = digitsCache.withLock({ $0[code] }) { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.currencyCode = code
        let digits = max(0, formatter.maximumFractionDigits)
        digitsCache.withLock { $0[code] = digits }
        return digits
    }

    /// An amount with its currency symbol in `locale`, at the currency's minor digits, rounded
    /// half away from zero: 767.125 SEK in sv_SE is "767,13 kr", 767.125 JPY is "767 JPY".
    public static func text(_ amount: Decimal, currencyCode code: String, locale: Locale) -> String {
        amount.formatted(
            Decimal.FormatStyle.Currency(code: code, locale: locale)
                .rounded(rule: .toNearestOrAwayFromZero)
        )
    }
}
