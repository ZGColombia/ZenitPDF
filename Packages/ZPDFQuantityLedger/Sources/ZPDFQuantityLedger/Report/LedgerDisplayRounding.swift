import Foundation
import ZPDFContracts

/// The product's one rounding rule for a number a person reads, stated where both the screen
/// and the exports can cite it.
///
/// # Code-review finding CR-53
///
/// Every export — CSV, XLSX, JSON and the printed report — rounds through
/// ``LedgerValueFormatting/displayDecimal(_:)``, which is `PrecisionMode.apply(to:)`, which is
/// `NSDecimalRound(.plain)`: **round half away from zero**, applied once, to the exact
/// `Decimal`. The on-screen ledger and the application's own CSV rendered through a
/// `NumberFormatter` set to `.halfEven` on the *unrounded* value, so one cell read `0.12` on
/// screen and `0.13` in the workbook, `1.00` against `1.01`, and `-0.00` against `0.00`. Two
/// rounding rules is one too many (QUALITY_BAR A25, A29–A31).
///
/// The rule, in one place:
///
/// 1. Round the exact `Decimal` **once**, with ``round(_:places:)`` — half away from zero.
/// 2. Only then hand it to a formatter, which then has nothing left to round. A formatter's own
///    rounding mode is irrelevant once step 1 has happened and must never stand in for it:
///    `NumberFormatter` rounds a `Decimal` through its own arithmetic and settles ties
///    differently.
/// 3. A value that rounds to zero is zero — never `-0.00`. ``round(_:places:)`` returns the
///    unsigned zero, and the export layer's number locale drops the sign the same way.
///
/// The application's `QuantityBridge.decimalText` is the screen's half of this rule: it
/// pre-rounds with ``round(_:places:)`` before it formats.
public enum LedgerDisplayRounding: Sendable {

    /// The rounding mode the whole product uses at the display boundary.
    public static let mode: NSDecimalNumber.RoundingMode = .plain

    /// Rounds an exact value to `places` decimals, once, half away from zero.
    ///
    /// The same call ``LedgerValueFormatting/displayDecimal(_:)`` makes for a column with a
    /// `.decimalPlaces` precision, so a screen that calls this and an export that calls that
    /// print the same digits by construction.
    public static func round(_ value: Decimal, places: Int) -> Decimal {
        // IM-079: one rounding entry point. A negative value that rounds to zero does not keep
        // its sign — `-0.00` reads as a negative quantity on a printed page — and that rule
        // now lives in `displayDecimal`, so the screen and every export share it by
        // construction rather than by two copies agreeing.
        LedgerValueFormatting(precision: .decimalPlaces(max(0, min(12, places)))).displayDecimal(value)
    }
}
