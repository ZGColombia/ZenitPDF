import Foundation
import Testing
@testable import ZPDFSpreadsheet

/// R-193: a spreadsheet literal is a decimal only if the whole string is one.
@Suite("Strict decimal literals (R-193)")
struct StrictDecimalTests {

    @Test("Malformed literals are refused instead of read as their prefix")
    func prefixesAreRefused() {
        // Old output: 1.25, 12, 1000 and 5 — `Decimal(string:)` read the prefix and the
        // character filter in front of it let every one of these through.
        for text in ["1.250.00", "12-5", "1e3e3", "5e", "--5", "1+", ".", "e5", "1 000", "1,5", "0x10", "+"] {
            #expect(LedgerRoundTrip.decimal(text) == nil, "\(text) must be refused")
            #expect(StrictDecimal.parse(text) == nil, "\(text) must be refused")
        }
    }

    @Test("Well-formed literals parse exactly, surrounding spaces trimmed")
    func wellFormedLiterals() {
        #expect(LedgerRoundTrip.decimal("85.25") == Decimal(string: "85.25"))
        #expect(LedgerRoundTrip.decimal(" 112.5 ") == Decimal(string: "112.5"))
        #expect(LedgerRoundTrip.decimal("-0.25") == Decimal(string: "-0.25"))
        #expect(LedgerRoundTrip.decimal("1E-3") == Decimal(string: "0.001"))
        #expect(LedgerRoundTrip.decimal("+7") == 7)
        #expect(LedgerRoundTrip.decimal(".5") == Decimal(string: "0.5"))
        #expect(LedgerRoundTrip.decimal("0.1") == Decimal(string: "0.1"), "exactly one tenth, never through a Double")
    }

    @Test("A mistyped money cell in a reviewed workbook is a refusal, not a change")
    func reviewRefusesMalformedMoney() throws {
        // The review's not-a-number check reads through `decimal(_:)`.
        #expect(LedgerRoundTrip.decimal("1.250.00") == nil)
        #expect(LedgerRoundTrip.decimal("1250.00") == Decimal(string: "1250"))
    }
}
