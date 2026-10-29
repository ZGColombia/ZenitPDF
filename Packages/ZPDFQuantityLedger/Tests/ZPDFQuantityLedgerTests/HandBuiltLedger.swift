import Foundation
import Testing
import ZPDFContracts
import ZPDFFormulaEngine
@testable import ZPDFQuantityLedger

/// A small ledger assembled cell by cell, for the cases where the interesting thing is one
/// awkward value rather than a hundred thousand ordinary ones.
struct HandBuiltLedger {

    static func columnID(_ name: String) -> ColumnID {
        ColumnID(LedgerIdentifiers.deterministicUUID(namespace: "test/handbuilt", name: name))
    }

    static let valueColumn = columnID("value")
    static let moneyColumn = columnID("money")
    static let textColumn = columnID("text")
    static let subjectColumn = LedgerIdentifiers.columnID(for: .subject)
    static let weightColumn = columnID("weight")

    /// `value` is a dynamic-dimension number column, which is the only honest way to model a
    /// column that an import or a unit change has left holding two different dimensions.
    static func makeColumnSet(currencyCode: String? = nil) throws -> LedgerColumnSet {
        var definitions: [LedgerColumnDefinition] = [
            LedgerColumnDefinition(
                id: subjectColumn,
                key: "subject",
                title: "subject",
                kind: .text,
                standard: .subject,
                order: 0
            ),
            LedgerColumnDefinition(
                id: valueColumn,
                key: "value",
                title: "Value",
                kind: .number,
                dimension: nil,
                precision: .decimalPlaces(3),
                order: 1
            ),
            LedgerColumnDefinition(
                id: textColumn,
                key: "text",
                title: "Text",
                kind: .text,
                order: 2
            ),
            LedgerColumnDefinition(
                id: weightColumn,
                key: "weight",
                title: "Weight",
                kind: .number,
                dimension: .count,
                order: 3
            )
        ]
        definitions.append(
            LedgerColumnDefinition(
                id: moneyColumn,
                key: "money",
                title: "Money",
                kind: .currency,
                dimension: currencyCode.map { QuantityDimension.currency($0) },
                displayUnit: currencyCode.map { AnyDisplayUnit.currency($0) },
                precision: .decimalPlaces(2),
                order: 4
            )
        )
        return try LedgerColumnSet(columns: definitions)
    }

    static func makeStore(
        rows: [[ColumnID: LedgerCellValue]],
        subjects: [String] = [],
        columns: LedgerColumnSet? = nil
    ) throws -> LedgerStore {
        let columnSet = try columns ?? makeColumnSet()
        let documentID = DocumentID(SyntheticLedger.deterministicUUID(-1))
        let pageID = PageID(SyntheticLedger.deterministicUUID(-2))
        let markups = rows.enumerated().map { index, cells in
            MarkupRecord(
                id: MarkupID(SyntheticLedger.deterministicUUID(index)),
                documentID: documentID,
                pageID: pageID,
                kind: .measurement,
                subject: index < subjects.count ? subjects[index] : "S",
                customValues: cells,
                createdAt: SyntheticLedger.epoch,
                modifiedAt: SyntheticLedger.epoch
            )
        }
        return try LedgerStore(markups: markups, columns: columnSet)
    }

    static func plan(_ columns: [ColumnID], functions: [AggregateFunction] = [.sum, .count])
        -> LedgerAggregationPlan {
        var plan = LedgerAggregationPlan()
        for column in columns {
            for function in functions {
                plan.add(AggregateKey(column: column, function: function))
            }
        }
        return plan
    }
}

/// The 100 000-row fixture, built once for the whole test run.
///
/// `static let` initialisation is lazy and thread-safe, so parallel suites share one store
/// instead of each paying a second to build its own.
enum BigLedger {
    static let rowCount = 100_000
    static let shared: LedgerStore? = try? SyntheticLedger.makeStore(rowCount: rowCount)

    static func store() throws -> LedgerStore {
        try #require(shared, "the 100 000-row fixture failed to build")
    }
}

/// A seeded generator, so "a random permutation" is the same permutation on every machine.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
