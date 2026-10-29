import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFQuantityLedger

/// R-131: the refusal token names the two quantity kinds that clashed.
@Suite("Refusal token names both kinds")
struct Iter1RefusalTokenTests {

    private func valueSumTotal(_ rows: [[ColumnID: LedgerCellValue]]) throws -> LedgerReportTotal {
        let store = try HandBuiltLedger.makeStore(rows: rows)
        let view = store.makeView(
            LedgerViewSpec(aggregation: HandBuiltLedger.plan([HandBuiltLedger.valueColumn]))
        )
        let report = LedgerReportBuilder(timestamps: FixedTimestampProvider(SyntheticLedger.epoch))
            .makeReport(view)
        return try #require(
            report.grandTotals.first {
                $0.column == HandBuiltLedger.valueColumn && $0.function == .sum
            }
        )
    }

    /// Old output: `#MIXED_UNITS[1|1]` — count and ratio both print their base unit symbol `1`.
    @Test("A count mixed with a ratio exports as 1 and 1:ratio, not 1 and 1")
    func countAndRatioAreNamed() throws {
        let total = try valueSumTotal([
            [HandBuiltLedger.valueColumn: .number(.count(5))],
            [HandBuiltLedger.valueColumn: .number(.ratio(5))]
        ])
        let token = try #require(total.refusalToken)
        #expect(token.hasPrefix(LedgerReport.mixedDimensionsToken + "["))
        #expect(token.hasSuffix("]"))
        let inner = token.dropFirst(LedgerReport.mixedDimensionsToken.count + 1).dropLast()
        #expect(Set(inner.split(separator: "|").map(String.init)) == ["1", "1:ratio"])
        #expect(token != "\(LedgerReport.mixedDimensionsToken)[1|1]")
    }

    @Test("Length mixed with area keeps its existing token")
    func lengthAndAreaUnchanged() throws {
        let total = try valueSumTotal([
            [HandBuiltLedger.valueColumn: .number(.length(3))],
            [HandBuiltLedger.valueColumn: .number(.area(4))]
        ])
        #expect(total.refusalToken == "\(LedgerReport.mixedDimensionsToken)[m|m^2]", "the base-unit symbols, as before R-131")
    }
}
