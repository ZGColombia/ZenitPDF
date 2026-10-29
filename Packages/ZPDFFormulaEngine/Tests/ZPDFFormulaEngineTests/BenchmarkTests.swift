import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// The reason ``FormulaCompiler`` exists: a ledger the size of a real project must not re-parse a
/// formula per row.
@Suite("Compiled evaluation at ledger scale")
struct BenchmarkTests {

    private static let rowCount = 100_000

    private func buildRows(_ count: Int) -> [FormulaRow] {
        var rows: [FormulaRow] = []
        rows.reserveCapacity(count)
        let depth = Decimal(sign: .plus, exponent: -1, significand: 2)
        for index in 0..<count {
            let area = Decimal(index % 40) + Decimal(sign: .plus, exponent: -1, significand: 5)
            rows.append(
                FormulaRow(fields: [
                    .netArea: .area(area),
                    .perimeter: .length(Decimal(index % 17) + 1),
                    .depth: .length(depth)
                ])
            )
        }
        return rows
    }

    @Test("100 000 rows evaluate from one compiled program")
    func hundredThousandRows() throws {
        let source = "IF(Area > 10, Area * 2.5, Area * 1.5) + Perimeter * Depth"
        let rows = buildRows(Self.rowCount)
        let clock = ContinuousClock()

        let compileStart = clock.now
        let program = try FormulaEngine.compile(source)
        let compileTime = clock.now - compileStart

        var total = Decimal.zero
        let start = clock.now
        for row in rows {
            guard case .number(let quantity) = try program.evaluate(row: row) else {
                Issue.record("expected a number")
                return
            }
            total += quantity.value
        }
        let elapsed = clock.now - start

        let seconds = Double(elapsed.components.attoseconds) / 1e18
            + Double(elapsed.components.seconds)
        let perRowMicroseconds = seconds * 1e6 / Double(Self.rowCount)
        print("""
        [ZPDFFormulaEngine benchmark]
          formula            : \(program.canonicalText)
          rows               : \(Self.rowCount)
          compile (once)     : \(compileTime)
          evaluate all rows  : \(elapsed)
          per row            : \(String(format: "%.3f", perRowMicroseconds)) us
          checksum           : \(total)
        """)

        #expect(total > 0)
        #expect(program.resultType == .number(.area))
        // A generous ceiling: the point is that it is linear and parse-free, not a lower bound.
        #expect(seconds < 30)
    }

    @Test("Re-parsing per row is what the compiler avoids")
    func compilingOncePaysForItself() throws {
        let source = "Area * 2.5 + Perimeter * Depth"
        let rows = buildRows(2_000)
        let clock = ContinuousClock()

        let program = try FormulaEngine.compile(source)
        let compiledStart = clock.now
        for row in rows { _ = try program.evaluate(row: row) }
        let compiledElapsed = clock.now - compiledStart

        let naiveStart = clock.now
        for row in rows { _ = try FormulaEngine.compile(source).evaluate(row: row) }
        let naiveElapsed = clock.now - naiveStart

        print("""
        [ZPDFFormulaEngine benchmark] 2 000 rows
          compiled once      : \(compiledElapsed)
          re-parsed per row  : \(naiveElapsed)
        """)
        #expect(compiledElapsed < naiveElapsed)
    }

    @Test("A whole ledger of dependent formula columns evaluates over 100 000 rows")
    func ledgerAtScale() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(
                id: makeColumnID(1),
                name: "Waste area",
                type: .dynamicNumber,
                formula: FormulaExpression(source: "ROUND(Area * 1.07, 3)")
            ),
            FormulaColumnDescriptor(
                id: makeColumnID(2),
                name: "Cost",
                type: .dynamicNumber,
                formula: FormulaExpression(source: "[Waste area] * 450 + Perimeter * Depth * 120")
            )
        ])
        let ledger = try FormulaEngine.compileLedger(catalog: catalog)
        let rows = buildRows(Self.rowCount)
        let clock = ContinuousClock()
        let start = clock.now
        var filledCount = 0
        for row in rows {
            let filled = try ledger.filledRow(row)
            if filled.columns[makeColumnID(2)] != nil { filledCount += 1 }
        }
        let elapsed = clock.now - start
        print("""
        [ZPDFFormulaEngine benchmark] two dependent formula columns
          rows               : \(Self.rowCount)
          evaluate all rows  : \(elapsed)
        """)
        #expect(filledCount == Self.rowCount)
    }
}
