import Foundation
import Testing
import ZPDFQuantityLedger
@testable import ZPDFAppCore

/// S-079: a money cell rounds half away from zero,
/// the product-wide display rule its group header and the exports already use.
@Suite("Iteration 2 — money cell rounding")
struct Iter2LedgerMoneyRoundingTests {

    private static func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    @Test("S-079: a .xx5 amount reads the same last digit in the cell as in the header and the export")
    func moneyCellRoundsLikeTheExport() {
        // Hand-derived: Total Cost is an exact multiplication, 17 × 45.125 = 767.125. Half away
        // from zero at the currency's two minor digits is 767.13. Old output: "767,12 kr" — the
        // currency style's default half-even — while the group header
        // (LedgerNumberFormatting.displayParts, `.plain`) and the workbook
        // (LedgerValueFormatting.displayDecimal through LedgerDisplayRounding) said 767.13.
        let total = Decimal(17) * Self.decimal("45.125")
        #expect(total == Self.decimal("767.125"))
        #expect(LedgerBridge.currencyText(total, code: "SEK", localeIdentifier: "sv_SE") == "767,13\u{00A0}kr")
        #expect(LedgerDisplayRounding.round(total, places: 2) == Self.decimal("767.13"))

        // 30.625 → 30.63 (old "30,62 kr"); −30.625 → −30.63: away from zero, not up.
        #expect(LedgerBridge.currencyText(Self.decimal("30.625"), code: "SEK", localeIdentifier: "sv_SE") == "30,63\u{00A0}kr")
        #expect(LedgerBridge.currencyText(Self.decimal("-30.625"), code: "SEK", localeIdentifier: "sv_SE") == "\u{2212}30,63\u{00A0}kr")
        #expect(LedgerDisplayRounding.round(Self.decimal("-30.625"), places: 2) == Self.decimal("-30.63"))

        // Another currency and locale follow the same rule; an amount with no tie is unchanged.
        #expect(LedgerBridge.currencyText(Self.decimal("45.125"), code: "USD", localeIdentifier: "en_US") == "$45.13")
        #expect(LedgerBridge.currencyText(Self.decimal("45.5"), code: "SEK", localeIdentifier: "sv_SE") == "45,50\u{00A0}kr")
        #expect(LedgerBridge.currencyText(Self.decimal("5091.1"), code: "SEK", localeIdentifier: "sv_SE") == "5\u{00A0}091,10\u{00A0}kr")
    }
}
