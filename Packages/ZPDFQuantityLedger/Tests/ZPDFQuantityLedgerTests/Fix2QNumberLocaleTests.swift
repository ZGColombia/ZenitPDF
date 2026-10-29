import Foundation
import Testing
@testable import ZPDFQuantityLedger

/// IM-012: the one hermetic number formatter now lives in the aggregation layer. The presets
/// render exactly what the export layer's goldens pin, and the Locale factory follows the same
/// rules as the screen (ZPDFUILedger `LedgerNumberStyle.forLocale`), so the goldens below are
/// the same strings the screen test asserts.
@Suite("Fix2 Q: shared number locale (IM-012)")
struct Fix2QNumberLocaleTests {

    private let value = Decimal(string: "-1234567.5")!

    @Test("Presets keep their export goldens")
    func presets() {
        #expect(LedgerNumberLocale.enUS.string(value, decimalPlaces: 2) == "-1,234,567.50")
        #expect(LedgerNumberLocale.svSE.string(value, decimalPlaces: 2) == "\u{2212}1\u{00A0}234\u{00A0}567,50")
        #expect(LedgerNumberLocale.invariant.string(value, decimalPlaces: nil) == "-1234567.5")
        #expect(LedgerNumberLocale.arEG.string(12, decimalPlaces: 0) == "\u{0661}\u{0662}")
        // "-0.00" is never written.
        #expect(LedgerNumberLocale.enUS.string(Decimal(string: "-0.00")!, decimalPlaces: 2) == "0.00")
    }

    @Test("A Locale is pinned the way the screen pins it")
    func fromLocale() {
        // Before IM-012 there was no factory: the screen used ICU (U+202F grouping, U+002D minus
        // for sv-SE) and the export used the hand-written svSE preset (U+00A0, U+2212).
        let swedish = LedgerNumberLocale.forLocale(Locale(identifier: "sv_SE"))
        #expect(swedish.string(value, decimalPlaces: 2) == LedgerNumberLocale.svSE.string(value, decimalPlaces: 2))
        let english = LedgerNumberLocale.forLocale(Locale(identifier: "en_US"))
        #expect(english.string(value, decimalPlaces: 2) == "-1,234,567.50")
        #expect(LedgerNumberLocale.forLocale(Locale(identifier: "en_US"), grouping: false)
            .string(value, decimalPlaces: 2) == "-1234567.50")
        #expect(LedgerNumberLocale.forLocale(Locale(identifier: "ar_EG")).digits.first == "\u{0660}")
    }
}
