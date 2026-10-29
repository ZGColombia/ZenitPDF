import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// R-172: the ledger's exact addition and the
/// formula engine's `DecimalQuantity` addition share one primitive, `NumericPolicy.add`.
@Suite("Iteration 1 — quantities core, ledger summation")
struct Iter1QuantitiesCoreSummationTests {

    static let thirtyEightNines = Decimal(string: "99999999999999999999999999999999999999")!

    /// 38 nines − 7.7 = …91.3 exactly, which needs 39 digits. Old output: …92 with no error —
    /// `NSDecimalSubtract` rounds and reports `.noError` on this toolchain, so a running total
    /// that had a value removed could drift silently. Now it is refused like an inexact add.
    @Test("R-172: an inexact subtraction in the ledger is refused, as an inexact addition is")
    func inexactSubtractionRefused() throws {
        #expect(throws: LedgerAggregationError(code: .inexactAddition(.lossOfPrecision))) {
            try DecimalSummation.subtract(Self.thirtyEightNines, Decimal(string: "7.7")!)
        }
        #expect(throws: LedgerAggregationError(code: .inexactAddition(.lossOfPrecision))) {
            try DecimalSummation.add(Self.thirtyEightNines, Decimal(string: "0.5")!)
        }
        // Exact cases are unchanged: 12.5 − 0.25 = 12.25; 0.1 + 0.2 = 0.3.
        #expect(try DecimalSummation.subtract(Decimal(string: "12.5")!, Decimal(string: "0.25")!) == Decimal(string: "12.25")!)
        #expect(try DecimalSummation.add(Decimal(string: "0.1")!, Decimal(string: "0.2")!) == Decimal(string: "0.3")!)
    }

    /// The same pair of numbers is refused by the formula path (`DecimalQuantity.adding`) and by
    /// the ledger path (`DecimalSummation.add`) — one exact-or-refuse rule.
    @Test("R-172: the formula path and the ledger path refuse the same addition")
    func bothPathsAgree() {
        let half = Decimal(string: "0.5")!
        #expect(throws: (any Error).self) { try DecimalSummation.add(Self.thirtyEightNines, half) }
        #expect(throws: NumericError.decimalOverflow(operation: "add")) {
            try DecimalQuantity.area(Self.thirtyEightNines).adding(.area(half))
        }
    }
}
