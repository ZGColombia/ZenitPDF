import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// R-136. A measured operand is a ``DecimalQuantity`` whose magnitude is in the SI base unit, so
/// `CONVERT` may only read it from that base unit. Before the fix the compiler checked the
/// operand's *dimension* only and then converted the raw base magnitude as if it were in `from`.
@Suite("CONVERT reads a measured quantity from its base unit")
struct ConvertSourceUnitTests {

    private let dynamicColumn = makeColumnID(1)

    private func dynamicCatalog() throws -> FormulaColumnCatalog {
        try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: dynamicColumn, name: "Any", type: .dynamicNumber)
        ])
    }

    /// Area = 10 m². Old output: `0.9290304` (10 read as ft², times 0.09290304), no error.
    @Test("CONVERT(Area, ft2, m2) on a measured area is refused, not misread")
    func areaFromNonBaseUnitIsRefused() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("CONVERT(Area, ft2, m2)") }
        #expect(error.code == .convertSourceNotBaseUnit(from: "ft2", base: "m2"))
        #expect(error.subexpression == "CONVERT(Area, ft2, m2)")
        #expect(error.message.contains("m2"))
    }

    /// Length = 3.048 m. Old output: `0.9290304` (3.048 read as ft, times 0.3048), no error.
    @Test("CONVERT(Length, ft, m) on a measured length is refused, not misread")
    func lengthFromNonBaseUnitIsRefused() throws {
        let error = try captureFormulaError { try FormulaEngine.compile("CONVERT(Length, ft, m)") }
        #expect(error.code == .convertSourceNotBaseUnit(from: "ft", base: "m"))
    }

    /// The correct spelling still works, with hand-derived results:
    /// 3.048 m / 0.3048 m per ft = 10 ft exactly; 10 m² / 0.09290304 m² per ft² = 107.639104…
    @Test("Reading a measured quantity from its base unit converts exactly")
    func baseUnitSourceConverts() throws {
        let length = try evaluate("CONVERT(Length, m, ft)", row: try sampleRow(length: "3.048"))
        #expect(try length.decimal() == 10)
        #expect(try length.dimension().isDimensionless)

        let area = try evaluate("ROUND(CONVERT(Area, m2, ft2), 6)", row: try sampleRow(area: "10"))
        #expect(try area.decimal() == (try dec("107.639104")))

        // Base to base is the identity: 10 m² is 10 m².
        let same = try evaluate("CONVERT(Area, m2, m2)", row: try sampleRow(area: "10"))
        #expect(try same.decimal() == 10)
    }

    /// A bare magnitude is the caller's assertion that the number is already in `from`, so the
    /// base-unit rule does not apply to it: 10 ft² × 0.09290304 = 0.9290304 m².
    @Test("A dimensionless operand may still name any source unit")
    func dimensionlessOperandKeepsAnySource() throws {
        #expect(try number("CONVERT(10, ft2, m2)") == (try dec("0.9290304")))
        #expect(try number("CONVERT(CONVERT(3.048, m, ft), ft, m)") == (try dec("3.048")))
    }

    /// The per-row branch had the same gap. Old output: `0.9290304` for a column holding 10 m².
    @Test("A column whose dimension is known only per row gets the same check at run time")
    func dynamicOperandIsCheckedAtRunTime() throws {
        let program = try FormulaEngine.compile("CONVERT([Any], ft2, m2)", catalog: dynamicCatalog())
        var row = FormulaRow()
        row.columns[dynamicColumn] = .number(.area(10))
        do {
            _ = try program.evaluate(row: row)
            Issue.record("expected convertSourceNotBaseUnit")
        } catch let error as FormulaEngineError {
            #expect(error.code == .convertSourceNotBaseUnit(from: "ft2", base: "m2"))
        }

        // The same column holding a bare count is a magnitude in `from`: 10 ft² = 0.9290304 m².
        row.columns[dynamicColumn] = .number(.count(10))
        #expect(try program.evaluate(row: row).decimal() == (try dec("0.9290304")))

        // And holding an area read from its base unit: 10 m² = 10 m².
        let base = try FormulaEngine.compile("CONVERT([Any], m2, m2)", catalog: dynamicCatalog())
        row.columns[dynamicColumn] = .number(.area(10))
        #expect(try base.evaluate(row: row).decimal() == 10)
    }
}
