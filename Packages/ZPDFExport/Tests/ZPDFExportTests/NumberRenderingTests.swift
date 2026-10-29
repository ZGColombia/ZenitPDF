import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFExport

@Suite("Number rendering", .sharedHeap)
struct NumberRenderingTests {

    @Test("Fixed decimal places pad and cut without rounding")
    func fixedPlaces() {
        let locale = ExportNumberLocale.invariant
        #expect(locale.string(Decimal(string: "1.5")!, decimalPlaces: 3) == "1.500")
        #expect(locale.string(Decimal(0), decimalPlaces: 2) == "0.00")
        #expect(locale.string(Decimal(string: "-12.5")!, decimalPlaces: 1) == "-12.5")
        #expect(locale.string(Decimal(string: "42")!, decimalPlaces: 0) == "42")
        #expect(locale.string(Decimal(string: "0.125")!, decimalPlaces: nil) == "0.125")
    }

    @Test("A value that rounded to zero is not written as negative zero")
    func negativeZero() {
        let rounded = PrecisionMode.decimalPlaces(2).apply(to: Decimal(string: "-0.004")!)
        #expect(ExportNumberLocale.invariant.string(rounded, decimalPlaces: 2) == "0.00")
    }

    @Test("Grouping inserts the separator every three digits")
    func grouping() {
        let locale = ExportNumberLocale.enUS
        #expect(locale.string(Decimal(string: "1234567.891")!, decimalPlaces: 2) == "1,234,567.89")
        #expect(locale.string(Decimal(string: "999")!, decimalPlaces: 0) == "999")
        #expect(locale.string(Decimal(string: "1000")!, decimalPlaces: 0) == "1,000")
    }

    @Test("The Swedish locale writes a comma decimal separator")
    func swedish() {
        let locale = ExportNumberLocale.svSE.withGrouping(nil)
        #expect(locale.string(Decimal(string: "1234567.89")!, decimalPlaces: 2) == "1234567,89")
        #expect(locale.string(Decimal(string: "-2.5")!, decimalPlaces: 2) == "\u{2212}2,50")
    }

    @Test("A non-Latin-digit locale renders its own digits (QUALITY_BAR A33)")
    func arabicIndic() {
        let locale = ExportNumberLocale.arEG.withGrouping(nil)
        #expect(locale.string(Decimal(string: "1234.5")!, decimalPlaces: 2) == "\u{0661}\u{0662}\u{0663}\u{0664}\u{066B}\u{0665}\u{0660}")
    }

    /// The double-rounding detector QUALITY_BAR A31 makes mandatory, at the level of the
    /// rounding primitive itself: rounding once and rounding twice must not be the same code
    /// path, and only the single-rounded answer may be produced.
    @Test("Rounding once is not rounding twice", arguments: [
        ("0.4449", 2, "0.44"),
        ("0.4449", 3, "0.445"),
        ("1.005", 2, "1.01"),
        ("2.675", 2, "2.68"),
        ("8.125", 2, "8.13"),
        ("0.5", 0, "1")
    ])
    func singleRounding(source: String, places: Int, expected: String) throws {
        let value = try #require(Decimal(string: source))
        let once = PrecisionMode.decimalPlaces(places).apply(to: value)
        #expect(ExportNumberLocale.invariant.string(once, decimalPlaces: places) == expected)
    }

    /// The exact case the QUALITY_BAR calls out: what a `Double` formatter would have said.
    @Test("Double formatting differs from the exported value in the last digit")
    func doubleWouldDiffer() {
        // `1.005` as a Double is 1.00499999999999989, so "%.2f" prints 1.00. The export prints
        // 1.01, because it never went near a Double.
        #expect(String(format: "%.2f", 1.005) == "1.00")
        let exact = PrecisionMode.decimalPlaces(2).apply(to: Decimal(string: "1.005")!)
        #expect(ExportNumberLocale.invariant.string(exact, decimalPlaces: 2) == "1.01")

        #expect(String(format: "%.2f", 2.675) == "2.67")
        let other = PrecisionMode.decimalPlaces(2).apply(to: Decimal(string: "2.675")!)
        #expect(ExportNumberLocale.invariant.string(other, decimalPlaces: 2) == "2.68")
    }
}
