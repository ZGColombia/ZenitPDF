import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

/// Engine fixes: how the catalog treats column names and column kinds.
@Suite("Column catalog names and kinds")
struct ColumnCatalogTests {

    private func column(
        _ index: UInt8,
        key: String,
        title: String,
        kind: ColumnKind,
        dimension: QuantityDimension? = nil,
        formula: String? = nil
    ) -> LedgerColumnDefinition {
        LedgerColumnDefinition(
            id: makeColumnID(index),
            key: key,
            title: title,
            kind: kind,
            dimension: dimension,
            formula: formula.map { FormulaExpression(source: $0) }
        )
    }

    // MARK: BH-022

    /// BH-022. A table import mints `.text` columns titled with the header cell verbatim. The
    /// built-in `material` column already uses `material` as key and title, so a schedule with a
    /// `Material` header — or two `Qty` headers — made the catalog throw `duplicateColumnName`
    /// and the whole column set refused to build. Old output: `FormulaColumnCatalog.init` threw
    /// "Two columns are both named `Material`". Now the catalog builds and every formula that
    /// does not name the ambiguous spelling compiles and evaluates.
    @Test("A duplicate title no formula uses does not stop the catalog or the ledger")
    func duplicateTitlesAreHarmlessUntilUsed() throws {
        let columns = [
            column(1, key: "material", title: "material", kind: .text),
            column(2, key: "imported-material", title: "Material", kind: .text),
            column(3, key: "qty-a", title: "Qty", kind: .number),
            column(4, key: "qty-b", title: "Qty", kind: .number),
            column(5, key: "rate", title: "Rate", kind: .number),
            column(6, key: "cost", title: "Cost", kind: .formula, formula: "Area * [Rate]")
        ]
        let catalog = try FormulaColumnCatalog(ledgerColumns: columns)
        let ledger = try FormulaEngine.compileLedger(catalog: catalog)
        let row = FormulaRow(
            fields: [.netArea: .area(try dec("12.5"))],
            columns: [makeColumnID(5): .number(.count(4))]
        )
        let filled = try ledger.filledRow(row)
        // 12.5 m^2 x 4 = 50 m^2 (the rate is a bare count, so the product stays an area).
        #expect(filled.columns[makeColumnID(6)] == .number(.area(50)))
        #expect(catalog.isAmbiguous("QTY"))
        #expect(catalog.isAmbiguous(" material "))
        #expect(catalog.column(named: "Qty") == nil)
        #expect(catalog.column(named: "Rate")?.id == makeColumnID(5))
    }

    @Test("A formula that names an ambiguous column is refused with the name it wrote")
    func ambiguousReferenceIsRefused() throws {
        let catalog = try FormulaColumnCatalog(ledgerColumns: [
            column(3, key: "qty-a", title: "Qty", kind: .number),
            column(4, key: "qty-b", title: "qty", kind: .number)
        ])
        let error = try captureFormulaError { try FormulaEngine.compile("[Qty] * 2", catalog: catalog) }
        #expect(error.code == .duplicateColumnName("Qty"))
        #expect(error.subexpression == "[Qty]")
        #expect(error.message.contains("More than one column is named `Qty`"))

        // The ledger path (dependency graph) refuses it the same way.
        let withFormula = try FormulaColumnCatalog(ledgerColumns: [
            column(3, key: "qty-a", title: "Qty", kind: .number),
            column(4, key: "qty-b", title: "qty", kind: .number),
            column(5, key: "double", title: "Double", kind: .formula, formula: "[Qty] * 2")
        ])
        let graphError = try captureFormulaError { try FormulaEngine.compileLedger(catalog: withFormula) }
        guard case .duplicateColumnName = graphError.code else {
            Issue.record("got \(graphError.code)")
            return
        }
        // Either column stays reachable by its id.
        let byID = try FormulaEngine.compile(
            "[col:\(makeColumnID(4).rawValue.uuidString)] * 2", catalog: catalog
        )
        let value = try byID.evaluate(row: FormulaRow(columns: [makeColumnID(4): .number(.count(3))]))
        #expect(value == .number(.count(6)))
    }

    @Test("A key that collides with another column's title is ambiguous, not first-wins")
    func keyCollidingWithTitle() throws {
        let catalog = try FormulaColumnCatalog(columns: [
            FormulaColumnDescriptor(id: makeColumnID(1), name: "Waste", key: "w1", type: .number(.ratio)),
            FormulaColumnDescriptor(id: makeColumnID(2), name: "Other", key: "waste", type: .number(.ratio))
        ])
        #expect(catalog.isAmbiguous("Waste"))
        #expect(catalog.column(named: "w1")?.id == makeColumnID(1))
        #expect(catalog.column(named: "Other")?.id == makeColumnID(2))
    }

    @Test("Two columns with the same id are still refused")
    func duplicateIDStillRefused() throws {
        let error = try captureFormulaError {
            try FormulaColumnCatalog(columns: [
                FormulaColumnDescriptor(id: makeColumnID(1), name: "A", type: .dynamicNumber),
                FormulaColumnDescriptor(id: makeColumnID(1), name: "B", type: .dynamicNumber)
            ])
        }
        #expect(error.code == .duplicateColumnID(makeColumnID(1)))
    }

    // MARK: BH-545

    /// BH-545. A blank or whitespace-only title reached `guard !name.isEmpty` and was reported as
    /// "Two columns are both named ``" — there was one column and it had no name. Old output:
    /// `duplicateColumnName("   ")` thrown from the catalog. Now the column is kept, is not
    /// reachable by name, and stays reachable by key and id.
    @Test("A blank title is not a duplicate; the column is reachable by key and id")
    func blankTitle() throws {
        let catalog = try FormulaColumnCatalog(ledgerColumns: [
            column(1, key: "untitled-1", title: "   ", kind: .number),
            column(2, key: "untitled-2", title: "", kind: .number)
        ])
        #expect(catalog.columns.count == 2)
        #expect(!catalog.isAmbiguous(""))
        let program = try FormulaEngine.compile("[untitled-1] + [untitled-2]", catalog: catalog)
        let value = try program.evaluate(row: FormulaRow(columns: [
            makeColumnID(1): .number(.count(2)),
            makeColumnID(2): .number(.count(3))
        ]))
        // 2 + 3 = 5
        #expect(value == .number(.count(5)))
    }

    // MARK: BH-157

    /// BH-157. Text, date and choice columns typed as `dynamicNumber` and every filled cell read
    /// back as blank, so `COALESCE([Material], 0) * 10` on a row whose Material says "Concrete"
    /// evaluated to 0 with no error, and `COUNT([Notes])` over filled text cells returned 0.
    /// Old output: `.number(0 count)`. Now the reference is refused at compile time.
    @Test("A formula cannot read a text, date or choice column")
    func unreadableKindsAreRefused() throws {
        let catalog = try FormulaColumnCatalog(ledgerColumns: [
            column(1, key: "material", title: "Material", kind: .text),
            column(2, key: "due", title: "Due", kind: .date),
            column(3, key: "status", title: "Status", kind: .choice),
            column(4, key: "rate", title: "Rate", kind: .number)
        ])
        for (source, kind) in [
            ("COALESCE([Material], 0) * 10", "text"),
            ("COUNT([Due])", "date"),
            ("[Status] + 1", "choice")
        ] {
            let error = try captureFormulaError { try FormulaEngine.compile(source, catalog: catalog) }
            guard case .typeMismatch(_, let actual) = error.code else {
                Issue.record("\(source): got \(error.code)")
                continue
            }
            #expect(actual.contains("\(kind) column"), "\(source): \(actual)")
        }
        // The numeric neighbour is unaffected: 7 x 10 = 70.
        let value = try FormulaEngine.compile("[Rate] * 10", catalog: catalog)
            .evaluate(row: FormulaRow(columns: [makeColumnID(4): .number(.count(7))]))
        #expect(value == .number(.count(70)))
        #expect(catalog.column(named: "Material")?.unreadableKind == .text)
        #expect(catalog.column(named: "Rate")?.unreadableKind == nil)
    }
}
