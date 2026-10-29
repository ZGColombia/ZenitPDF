import Foundation
import ZPDFContracts
import ZPDFFormulaEngine

/// How a formula column's value relates to the group it is summarised in (QUALITY_BAR A24).
///
/// For `UnitCost * Area`, evaluating per row and summing is not the same number as evaluating on
/// the aggregated inputs. Both are defensible; picking one silently is not. The declaration
/// lives on the column, travels into every export's metadata, and is versioned with the grammar.
public enum FormulaAggregationSemantics: String, Codable, Hashable, Sendable, CaseIterable {
    /// Evaluate per row, then sum the results. The default and the only semantics this build
    /// implements.
    case evaluateThenAggregate
    /// Aggregate the inputs, then evaluate once per group. Declared, refused with a typed error
    /// until implemented — see ``LedgerAggregationError/Code/unsupportedAggregationSemantics(_:)``.
    case aggregateThenEvaluate
}

/// The validated column set a ledger view is built against.
///
/// Building one is where column-level failures happen — a duplicate key, an invalid choice
/// configuration, a formula that does not compile, a cycle in the formula graph. By the time a
/// `LedgerColumnSet` exists, every formula in it has been compiled exactly once and the ledger
/// can evaluate 100 000 rows without touching the parser again.
public struct LedgerColumnSet: Sendable {

    public let columns: [LedgerColumnDefinition]
    public let compiledFormulas: CompiledFormulaLedger
    /// Aggregation semantics per formula column, defaulted to `evaluateThenAggregate`.
    public let formulaSemantics: [ColumnID: FormulaAggregationSemantics]

    private let byID: [ColumnID: LedgerColumnDefinition]
    private let byKey: [String: LedgerColumnDefinition]
    private let byStandard: [StandardLedgerColumn: ColumnID]

    /// - Throws: ``LedgerError`` for a duplicate key or an invalid column, ``FormulaEngineError``
    ///   for anything the formula compiler rejects, and ``LedgerAggregationError`` for a formula
    ///   column that this build cannot evaluate per row.
    public init(
        columns: [LedgerColumnDefinition],
        formulaSemantics: [ColumnID: FormulaAggregationSemantics] = [:]
    ) throws {
        var byID: [ColumnID: LedgerColumnDefinition] = [:]
        var byKey: [String: LedgerColumnDefinition] = [:]
        var byStandard: [StandardLedgerColumn: ColumnID] = [:]
        for column in columns {
            try column.validate()
            guard byKey[column.key] == nil else {
                throw LedgerError.duplicateColumnKey(column.key)
            }
            byKey[column.key] = column
            byID[column.id] = column
            if let standard = column.standard { byStandard[standard] = column.id }
        }
        self.columns = columns
        self.byID = byID
        self.byKey = byKey
        self.byStandard = byStandard

        let catalog = try FormulaColumnCatalog(ledgerColumns: columns)
        let compiled = try FormulaEngine.compileLedger(catalog: catalog)
        self.compiledFormulas = compiled

        var semantics: [ColumnID: FormulaAggregationSemantics] = [:]
        for id in compiled.programs.keys {
            let declared = formulaSemantics[id] ?? .evaluateThenAggregate
            guard declared == .evaluateThenAggregate else {
                throw LedgerAggregationError(code: .unsupportedAggregationSemantics(id))
            }
            // A group aggregate inside a row formula would need every sibling row present at row
            // evaluation time. At 100 000 rows that is quadratic, so it is refused rather than
            // quietly evaluated against an empty group — which would return zero.
            if compiled.programs[id]?.usesAggregates == true {
                throw LedgerAggregationError(code: .aggregateFormulaUnsupported(id))
            }
            semantics[id] = declared
        }
        self.formulaSemantics = semantics
    }

    public var count: Int { columns.count }

    public func column(id: ColumnID) -> LedgerColumnDefinition? { byID[id] }
    public func column(key: String) -> LedgerColumnDefinition? { byKey[key] }
    public func column(standard: StandardLedgerColumn) -> LedgerColumnDefinition? {
        byStandard[standard].flatMap { byID[$0] }
    }
    public func columnID(standard: StandardLedgerColumn) -> ColumnID? { byStandard[standard] }

    /// The formula columns that read `column`, directly or through another formula, in
    /// dependency order — what a Column Manager names when it refuses to delete or retype a
    /// column a formula needs (NL-QTY-02).
    public func formulaColumns(reading column: ColumnID) -> [ColumnID] {
        var readers = Set<ColumnID>()
        for id in formulaColumnIDs {
            let direct = compiledFormulas.programs[id]?.referencedColumns ?? []
            let through = compiledFormulas.dependencies[id] ?? []
            if direct.contains(column) || !through.isDisjoint(with: readers.union([column])) {
                readers.insert(id)
            }
        }
        return formulaColumnIDs.filter { readers.contains($0) && $0 != column }
    }

    /// The dimension a formula column's compiled result carries when the compiler knows it,
    /// `nil` for a result whose dimension is decided per row (NL-QTY-03).
    public func formulaResultDimension(_ column: ColumnID) -> QuantityDimension? {
        compiledFormulas.programs[column]?.resultType.dimension
    }

    /// Formula columns in dependency order.
    public var formulaColumnIDs: [ColumnID] {
        compiledFormulas.evaluationOrder.filter { compiledFormulas.programs[$0] != nil }
    }

    /// The built-in column set of spec 15.2, with stable ids.
    ///
    /// `Status` is a Choice column over ``LedgerStatusChoices``; every other built-in takes the
    /// kind ``StandardLedgerColumn/kind`` declares.
    public static func standard(
        displayPolicy: DisplayUnitPolicy = DisplayUnitPolicy()
    ) throws -> LedgerColumnSet {
        var definitions: [LedgerColumnDefinition] = []
        definitions.reserveCapacity(StandardLedgerColumn.allCases.count)
        for (order, standard) in StandardLedgerColumn.allCases.enumerated() {
            let field = standard.measurementField
            let dimension = field?.dimension
            definitions.append(
                LedgerColumnDefinition(
                    id: LedgerIdentifiers.columnID(for: standard),
                    key: standard.rawValue,
                    title: standard.rawValue,
                    kind: standard.kind,
                    standard: standard,
                    dimension: dimension,
                    displayUnit: displayUnit(for: dimension, policy: displayPolicy),
                    precision: dimension == nil ? nil : displayPolicy.precision,
                    choices: standard == .status ? LedgerStatusChoices.options : [],
                    defaultChoiceID: standard == .status
                        ? LedgerIdentifiers.choiceOptionID(for: .none)
                        : nil,
                    isEditable: standard.isUserEditable,
                    isVisible: true,
                    order: order
                )
            )
        }
        return try LedgerColumnSet(columns: definitions)
    }

    /// The display unit a column of `dimension` takes under `policy` — public so a column the
    /// Column Manager makes is displayed like a built-in of the same dimension (NL-QTY-02).
    public static func displayUnit(
        for dimension: QuantityDimension?,
        policy: DisplayUnitPolicy
    ) -> AnyDisplayUnit? {
        guard let dimension else { return nil }
        if let code = dimension.currencyCode { return .currency(code) }
        if dimension.angle { return .angle(policy.angle) }
        switch dimension.lengthPower {
        case 1: return .length(policy.length)
        case 2: return .area(policy.area)
        case 3: return .volume(policy.volume)
        default: return .count
        }
    }
}
