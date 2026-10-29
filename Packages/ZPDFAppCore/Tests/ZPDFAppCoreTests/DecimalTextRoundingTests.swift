import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation

/// CR-53: the screen rounds the way the exporters round.
///
/// `QuantityFormatter.decimalText` used to hand the unrounded `Decimal` to `NumberFormatter`
/// with `roundingMode = .halfEven`, while `ExportProjector` pre-rounds with
/// `NSDecimalRound(.plain)` — half away from zero. The same quantity therefore read one way in
/// the ledger and the app's CSV and another in XLSX, JSON and PDF. Each test names the string
/// the old code produced.
@Suite("Screen rounding equals export rounding")
struct DecimalTextRoundingTests {

    private func area(_ text: String) -> ZPDFUIPresentation.DecimalQuantity {
        ZPDFUIPresentation.DecimalQuantity(value: Decimal(string: text)!, dimension: .area)
    }

    @Test("A half rounds away from zero, like NSDecimalRound(.plain): 0.125 → 0.13")
    func halfRoundsAwayFromZero() {
        let formatter = QuantityFormatter(units: .metric)
        // Old output: "0.12" (half-even).
        #expect(formatter.text(area("0.125")) == "0.13")
        // Old output: "1.00" (half-even).
        #expect(formatter.text(area("1.005")) == "1.01")
        // Old output: "0.62" (half-even); the exporters say "0.63".
        #expect(formatter.text(area("0.625")) == "0.63")
    }

    @Test("A negative value that rounds to zero reads 0.00, not -0.00")
    func negativeZeroIsZero() {
        let formatter = QuantityFormatter(units: .metric)
        // Old output: "-0.00".
        #expect(formatter.text(area("-0.004")) == "0.00")
    }

    @Test("The locale only changes the separators, never the rounding: 0.125 → 0,13")
    func localeKeepsTheRounding() {
        let swedish = QuantityFormatter(units: .metric, localeIdentifier: "sv_SE")
        // Old output: "0,12".
        #expect(swedish.text(area("0.125")) == "0,13")
        #expect(swedish.text(area("1.005")) == "1,01")
    }

    /// The export package's golden values and the text its projector renders for them
    /// (`ZPDFExportTests/ExportFixture.goldenValues` / `expectedGoldenText`, copied here because
    /// a test target cannot import another package's tests). The screen renders the same
    /// digits: rounding is one rule on both sides. Grouping separators are presentation —
    /// a ledger cell reads "1,234,567.89", a CSV cell "1234567.89" — and are stripped before
    /// the comparison; nothing else is.
    @Test("The screen renders the export fixture's golden values digit for digit")
    func screenMatchesExportGoldenText() {
        let goldenValues = ["0.4449", "1.005", "2.675", "-0.004", "1234567.891", "8.125"]
        let expectedGoldenText = ["0.44", "1.01", "2.68", "0.00", "1234567.89", "8.13"]
        let formatter = QuantityFormatter(units: .metric)
        let rendered = goldenValues.map { formatter.text(area($0)).replacingOccurrences(of: ",", with: "") }
        // Old output: ["0.44", "1.00", "2.67", "-0.00", "1234567.89", "8.12"] — three of six
        // disagreed with the export.
        #expect(rendered == expectedGoldenText)
    }

    @Test("Values that need no rounding are untouched, grouping included")
    func exactValuesAreUnchanged() {
        let formatter = QuantityFormatter(units: .metric)
        #expect(formatter.text(area("498.4")) == "498.40")
        #expect(formatter.text(area("12345.678")) == "12,345.68")
    }
}
