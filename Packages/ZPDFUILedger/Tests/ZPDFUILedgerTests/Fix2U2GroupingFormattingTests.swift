import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Bug hunt 2 regressions and improvements on aggregate display and the shared number
/// formatter. Every test names what the old code answered. (BH-729 was a fix to
/// LedgerGroupingBar, removed as dead code in R-124; the shipping pane offers its grouping
/// levels through ZPDFUIShell's `LedgerPaneModel.groupableColumns`, which skips display columns.
/// IM-079's raw-string case went with the export writer's raw columns. BH-239, BH-728, BH-730
/// and BH-240 were rules of the table's in-memory fold, deleted in C-04 (R-129); the preview
/// mock's outline keeps them and `Iter2MockLedgerOutlineTests` in ZPDFUIPresentation asserts
/// them there.)
@Suite("Fix2 U2: grouping, subtotals and number formatting", .ledgerTierSerialised, .serialized)
struct Fix2U2GroupingFormattingTests {

    // MARK: Aggregate display

    @Test("IM-098: an aggregate hands out its number and unit separately")
    func aggregateDisplayParts() {
        let result = LedgerAggregateResult(
            column: .planArea, aggregate: .sum,
            value: .quantity(DecimalQuantity(value: Decimal(string: "1234.5")!, dimension: .area))
        )
        // T-053: through `LedgerValueParts.parts`, the one parts formatter the table's headings
        // use; `LedgerAggregateResult.displayParts` was an uncalled duplicate of it.
        let parts = LedgerValueParts.parts(
            of: result, policy: .metric, rounding: .twoDigits, locale: Locale(identifier: "sv_SE")
        )
        #expect(parts?.number == "1\u{00A0}234,50")
        #expect(parts?.unit == "m²")
        let refused = LedgerAggregateResult(column: .planArea, aggregate: .sum, value: .mixedUnits)
        #expect(LedgerValueParts.parts(of: refused, policy: .metric, rounding: .exact, locale: Locale(identifier: "sv_SE")) == nil)
    }

    // MARK: Number formatting

    @Test("BH-241: .exact never rounds, and rounding is half away from zero everywhere")
    func exactAndHalfAwayRounding() {
        let locale = Locale(identifier: "en_US_POSIX")
        let area = DecimalQuantity(value: Decimal(string: "12.125")!, dimension: .area)
        // Old: "12.12 m²" (.exact fell back to 2 digits, ICU half-even) while .twoDigits said 12.13.
        #expect(LedgerNumberFormatting.display(area, rounding: .exact, locale: locale) == "12.125 m²")
        #expect(LedgerNumberFormatting.display(area, rounding: .twoDigits, locale: locale) == "12.13 m²")
        #expect(LedgerNumberFormatting.string(Decimal(string: "2.5")!, fractionDigits: 0, locale: locale) == "3")
        #expect(LedgerNumberFormatting.string(Decimal(string: "-2.5")!, fractionDigits: 0, locale: locale) == "-3")
    }

    @Test("IM-079: rounding to zero never renders a signed zero")
    func negativeZeroIsNormalised() {
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(LedgerNumberFormatting.rounded(Decimal(string: "-0.001")!, fractionDigits: 2) == 0)
        #expect(LedgerNumberFormatting.string(Decimal(string: "-0.001")!, fractionDigits: 2, locale: locale) == "0.00")
    }

    @Test("IM-012: the screen formatter is hermetic and matches the export's locale rules")
    func hermeticLocaleRendering() {
        let value = Decimal(string: "-1234567.5")!
        // The export golden strings (ExportNumberLocale.enUS / .svSE / .arEG) for the same value.
        #expect(LedgerNumberFormatting.string(value, fractionDigits: 2, locale: Locale(identifier: "en_US")) == "-1,234,567.50")
        #expect(LedgerNumberFormatting.string(value, fractionDigits: 2, locale: Locale(identifier: "sv_SE"))
                == "\u{2212}1\u{00A0}234\u{00A0}567,50")
        let arabic = LedgerNumberStyle.forLocale(Locale(identifier: "ar_EG"))
        #expect(arabic.digits.first == "\u{0660}")
        #expect(LedgerNumberFormatting.string(1000, fractionDigits: 0, locale: Locale(identifier: "en_US"), grouping: false) == "1000")
        // Values >= 1 000, zero after rounding and negative values in one locale.
        #expect(LedgerNumberFormatting.string(Decimal(string: "0.004")!, fractionDigits: 2, locale: Locale(identifier: "sv_SE")) == "0,00")
    }

    @Test("IM-012: an installed renderer is what every ledger string goes through")
    func rendererInjection() {
        // The renderer is process-wide and other suites format concurrently, so this one only
        // answers differently for a sentinel value and defers to the built-in renderer otherwise.
        let sentinel = Decimal(string: "987654.321")!
        LedgerNumberFormatting.setRenderer { value, digits, locale, grouping in
            value == LedgerNumberFormatting.rounded(sentinel, fractionDigits: digits ?? 3)
                ? "CORE"
                : LedgerNumberFormatting.builtInRenderer(value, digits, locale, grouping)
        }
        defer { LedgerNumberFormatting.setRenderer(nil) }
        #expect(LedgerNumberFormatting.string(sentinel, fractionDigits: 3) == "CORE")
        let quantity = DecimalQuantity(value: sentinel, dimension: .length)
        #expect(LedgerNumberFormatting.display(quantity, rounding: .threeDigits) == "CORE m")
    }

    @Test("IM-096: no formatter allocation per cell — hermetic rendering beats NumberFormatter")
    func formattingIsFasterThanNumberFormatter() {
        let values = (0..<20_000).map { Decimal($0) + Decimal(string: "0.125")! }
        let locale = Locale(identifier: "sv_SE")
        let clock = ContinuousClock()
        let old = clock.measure {
            for value in values {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
                _ = formatter.string(from: value as NSDecimalNumber)
            }
        }
        let new = clock.measure {
            for value in values { _ = LedgerNumberFormatting.string(value, fractionDigits: 2, locale: locale) }
        }
        print("IM-096 20k cells: NumberFormatter per call \(old), hermetic \(new)")
        #expect(new < old)
    }
}
