import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// S-088: a money column the user
/// declares as a rate ("Rate per m²", SEK/m²) is a rate in formulas too.
///
/// Before, the formula catalog typed every currency column from its display code alone, as plain
/// money, and the ledger fed its cells in as plain money. `Area * [Rate]` then compiled to SEK·m²:
/// the right number with the wrong dimension, so the cost column got no subtotal and no grand
/// total, and `Area * [Rate] + [Fee]` was refused as a dimension mismatch. Only the built-in Unit
/// Cost had the ADR-0020 rate retag. Expected values are derived by hand beside each assertion.
@Suite("Iteration 2 — measurement presentation, rate columns in formulas")
struct Iter2RateColumnFormulaTests {

    static let documentID = DocumentID(UUID(uuidString: "00000000-0000-4000-8000-0000000A0880")!)
    static let pageID = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000A0881")!)
    static let rate = ColumnID(UUID(uuidString: "00000000-0000-4000-8000-0000000A0882")!)
    static let fee = ColumnID(UUID(uuidString: "00000000-0000-4000-8000-0000000A0883")!)
    static let cost = ColumnID(UUID(uuidString: "00000000-0000-4000-8000-0000000A0884")!)
    static let total = ColumnID(UUID(uuidString: "00000000-0000-4000-8000-0000000A0885")!)

    /// The two user columns exactly as the Column Manager's bridge writes them: a currency
    /// column declared SEK/m² ("Holds: Rate per m²") and a plain money column.
    static func userColumns(order: Int) -> [LedgerColumnDefinition] {
        [
            LedgerColumnDefinition(
                id: rate, key: "custom.rate", title: "Rate", kind: .currency,
                dimension: .currencyRate("SEK", perLengthPower: 2), displayUnit: .currency("SEK"),
                precision: .decimalPlaces(2), order: order
            ),
            LedgerColumnDefinition(
                id: fee, key: "custom.fee", title: "Fee", kind: .currency,
                dimension: .currency("SEK"), displayUnit: .currency("SEK"),
                precision: .decimalPlaces(2), order: order + 1
            )
        ]
    }

    static func formula(
        _ id: ColumnID, key: String, title: String, source: String,
        dimension: QuantityDimension?, order: Int
    ) -> LedgerColumnDefinition {
        LedgerColumnDefinition(
            id: id, key: key, title: title, kind: .formula, dimension: dimension,
            formula: FormulaExpression(source: source), isEditable: false, order: order
        )
    }

    static func area(_ index: Int, _ square: String, rate: String, fee: String) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let value = Decimal(string: square)!
        return MarkupRecord(
            id: MarkupID(SyntheticLedger.deterministicUUID(8_800 + index)),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Screed",
            measurement: MeasurementResult(values: [.planArea: .area(value), .netArea: .area(value)]),
            customValues: [
                Self.rate: .currency(amount: Decimal(string: rate)!, code: "SEK"),
                Self.fee: .currency(amount: Decimal(string: fee)!, code: "SEK")
            ],
            createdAt: stamp,
            modifiedAt: stamp
        )
    }

    /// Old output: `Area * [Rate]` typed as currency with lengthPower 2 (SEK·m²), and
    /// `Area * [Rate] + [Fee]` threw a dimension mismatch.
    @Test("The catalog types a currency column by its declared rate, so Area × Rate is money")
    func catalogTypesTheDeclaredRate() throws {
        let catalog = try FormulaColumnCatalog(ledgerColumns: Self.userColumns(order: 0))
        #expect(catalog.column(id: Self.rate)?.type == .number(.currencyRate("SEK", perLengthPower: 2)))
        #expect(catalog.column(id: Self.fee)?.type == .number(.currency("SEK")))
        #expect(try FormulaEngine.compile("Area * [Rate]", catalog: catalog).resultType.dimension == .currency("SEK"))
        #expect(try FormulaEngine.compile("Area * [Rate] + [Fee]", catalog: catalog).resultType.dimension == .currency("SEK"))
        // A length times a per-area rate is a per-length rate, not a refusal and not money.
        #expect(
            try FormulaEngine.compile("Length * [Rate]", catalog: catalog).resultType.dimension
                == .currencyRate("SEK", perLengthPower: 1)
        )
        // A currency column that declares no money dimension still types from its display code.
        let undeclared = LedgerColumnDefinition(
            id: Self.total, key: "custom.plain", title: "Plain", kind: .currency, displayUnit: .currency("EUR")
        )
        #expect(FormulaColumnDescriptor(undeclared).type == .number(.currency("EUR")))
    }

    /// Old output: the Cost cells were 4 500 and 249.75 with dimension SEK·m², the column was
    /// declared SEK·m², `LedgerAggregationPlan.sums` refused it and the grand total was absent;
    /// the Cost + Fee column could not be built at all.
    @Test("Area × Rate is money per row and totals; it adds to other money")
    func rateFormulaIsMoneyAndTotals() throws {
        var definitions = try LedgerColumnSet.standard().columns
        definitions += Self.userColumns(order: definitions.count)
        // First pass exactly as the Column Manager does it: build, read the compiled result's
        // dimension, and declare the formula column with it (formulaResultDimension).
        let probe = try LedgerColumnSet(columns: definitions + [
            Self.formula(Self.cost, key: "custom.cost", title: "Cost", source: "Area * [Rate]", dimension: nil, order: definitions.count),
            Self.formula(Self.total, key: "custom.total", title: "Total", source: "[Cost] + [Fee]", dimension: nil, order: definitions.count + 1)
        ])
        let costDimension = probe.formulaResultDimension(Self.cost)
        let totalDimension = probe.formulaResultDimension(Self.total)
        #expect(costDimension == .currency("SEK"))
        #expect(totalDimension == .currency("SEK"))

        let costColumn = Self.formula(Self.cost, key: "custom.cost", title: "Cost", source: "Area * [Rate]", dimension: costDimension, order: definitions.count)
        let totalColumn = Self.formula(Self.total, key: "custom.total", title: "Total", source: "[Cost] + [Fee]", dimension: totalDimension, order: definitions.count + 1)
        let columns = try LedgerColumnSet(columns: definitions + [costColumn, totalColumn])
        #expect(LedgerAggregationPlan.sums(costColumn))

        let store = try LedgerStore(
            markups: [
                // 10 m² at 450 SEK/m² = 4 500 SEK; + 100 SEK fee = 4 600 SEK.
                Self.area(0, "10", rate: "450", fee: "100"),
                // 2.5 m² at 99.90 SEK/m² = 249.75 SEK; + 0.25 SEK fee = 250 SEK.
                Self.area(1, "2.5", rate: "99.90", fee: "0.25")
            ],
            columns: columns
        )
        let sek = { (text: String) in DecimalQuantity(value: Decimal(string: text)!, dimension: .currency("SEK")) }
        #expect(store.value(at: 0, definition: costColumn).cellValue?.formulaQuantity == sek("4500"))
        #expect(store.value(at: 1, definition: costColumn).cellValue?.formulaQuantity == sek("249.75"))
        #expect(store.value(at: 0, definition: totalColumn).cellValue?.formulaQuantity == sek("4600"))
        #expect(store.value(at: 1, definition: totalColumn).cellValue?.formulaQuantity == sek("250"))

        // 4 500 + 249.75 = 4 749.75 SEK; 4 600 + 250 = 4 850 SEK — exact, in the grand total.
        let view = store.makeView(LedgerViewSpec(aggregation: .standard(for: columns)))
        #expect(view.grandTotal[Self.cost]?.decimal == Decimal(string: "4749.75")!)
        #expect(view.grandTotal[Self.total]?.decimal == 4_850)
        // The rate itself never sums (ADR-0020).
        #expect(view.grandTotal[Self.rate] == nil)
    }
}

private extension LedgerCellResult {
    var cellValue: LedgerCellValue? {
        if case .value(let value) = self { return value }
        return nil
    }
}

private extension LedgerCellValue {
    var formulaQuantity: DecimalQuantity? {
        if case .formulaResult(let value, _) = self { return value }
        return nil
    }
}
