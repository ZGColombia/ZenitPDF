import Foundation
import ZPDFContracts

/// The aggregate functions the ledger offers (spec 15.5).
public enum AggregateFunction: Hashable, Sendable {
    case sum
    /// Rows whose cell carries a value. Always an integer.
    case count
    /// Every row in the group, empty cells included. Always an integer.
    case rowCount
    /// `sum / count` at ``LedgerAggregationPolicy/averageScale``, one definition everywhere.
    case minimum
    case maximum
    case average
    /// Number of distinct cell values. Must be planned in advance — see
    /// ``LedgerAggregationPlan``.
    case distinctCount
    /// `Σ value × weight`, with `weight` read from a dimensionless column (spec 15.5).
    case weightedTotal(weight: ColumnID)

    /// The functions that count rather than compute. A tally stays answerable when a member
    /// cell is in error — the errored cell simply carried no value — where a sum, an extreme
    /// or an average becomes a refusal (CR-62).
    public var isTally: Bool {
        switch self {
        case .count, .rowCount, .distinctCount: true
        case .sum, .minimum, .maximum, .average, .weightedTotal: false
        }
    }

    /// The weight column, for a weighted total.
    public var weightColumn: ColumnID? {
        if case .weightedTotal(let column) = self { return column }
        return nil
    }
}

/// One requested aggregate: a column and what to do with it.
public struct AggregateKey: Hashable, Sendable {
    public let column: ColumnID
    public let function: AggregateFunction

    public init(column: ColumnID, function: AggregateFunction) {
        self.column = column
        self.function = function
    }
}

/// The result of an aggregate.
///
/// The important case is ``mixedDimensions(_:)``. Spec 15.5 says incompatible dimensions
/// are never summed in the same cell; QUALITY_BAR A11 turns that into a modelling requirement,
/// because rendering "cannot be added" as a blank, a dash or a `0` reads to the user as "nothing
/// here" and hides the very thing they need to see. Currency codes are part of the dimension, so
/// a SEK column that picks up one EUR row becomes mixed by the same mechanism (A12).
public enum AggregateValue: Hashable, Sendable {
    /// No row contributed a value. Genuinely nothing, not a refusal.
    case empty
    /// A dimensioned total in SI base units.
    case quantity(DecimalQuantity)
    /// A money total. Always one ISO 4217 code; a second code makes the aggregate mixed.
    case currency(amount: Decimal, code: String)
    /// A count. Counts are integers, never decimals that happen to look like integers.
    case integer(Int)
    /// The members could not be added. Carries every dimension seen, in a deterministic order.
    case mixedDimensions([QuantityDimension])
    /// The arithmetic itself failed — an inexact `NSDecimalAdd`, a bad weight column, a cell that
    /// was an error. Never rounded away.
    case failed(LedgerAggregationError.Code)

    /// The exact decimal this aggregate contributes to a parent, if it contributes one.
    public var decimal: Decimal? {
        switch self {
        case .quantity(let quantity): quantity.value
        case .currency(let amount, _): amount
        case .integer(let value): Decimal(value)
        case .empty, .mixedDimensions, .failed: nil
        }
    }

    public var dimension: QuantityDimension? {
        switch self {
        case .quantity(let quantity): quantity.dimension
        case .currency(_, let code): .currency(code)
        case .integer: .count
        case .empty, .mixedDimensions, .failed: nil
        }
    }

    /// True when the aggregate is a refusal rather than a number. The view and every export must
    /// render these as an explicit state (QUALITY_BAR A11, A14).
    public var isRefusal: Bool {
        switch self {
        case .mixedDimensions, .failed: true
        case .empty, .quantity, .currency, .integer: false
        }
    }
}

/// Which aggregates to compute, per column.
///
/// Declared up front rather than discovered per group, because `distinctCount` needs the
/// accumulator to keep every value it saw and nothing should pay that cost unasked.
public struct LedgerAggregationPlan: Hashable, Sendable {
    public private(set) var keys: [AggregateKey]

    public init(keys: [AggregateKey] = []) {
        var seen = Set<AggregateKey>()
        self.keys = keys.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { keys.isEmpty }

    public mutating func add(_ key: AggregateKey) {
        guard !keys.contains(key) else { return }
        keys.append(key)
    }

    public func adding(_ key: AggregateKey) -> LedgerAggregationPlan {
        var copy = self
        copy.add(key)
        return copy
    }

    /// The columns this plan reads, including weight columns.
    public var referencedColumns: Set<ColumnID> {
        var columns = Set(keys.map(\.column))
        for key in keys {
            if let weight = key.function.weightColumn { columns.insert(weight) }
        }
        return columns
    }

    /// The default plan: sum every column whose values are extensive quantities — see
    /// ``sums(_:)`` — and count every column.
    ///
    /// Deterministic in column order, so two plans built from the same column set are equal.
    public static func standard(for columns: LedgerColumnSet) -> LedgerAggregationPlan {
        var plan = LedgerAggregationPlan()
        for column in columns.columns {
            if sums(column) {
                plan.add(AggregateKey(column: column.id, function: .sum))
            }
            plan.add(AggregateKey(column: column.id, function: .count))
        }
        return plan
    }

    /// Whether the standard plan totals a column.
    ///
    /// # Code-review finding CR-55
    ///
    /// A sum is only a quantity when the cells are *extensive*: lengths, areas, volumes,
    /// counts and money add up to the length, area, volume, count or cost of the whole. A page
    /// index, a slope in any of its three spellings, an angle, a rise, a run, a depth or a
    /// height is a property of one markup — three drawings on pages 1, 2 and 3 are not on
    /// "page 6", and three ramps at 10 %, 20 % and 30 % are not a 60 % ramp. The on-screen
    /// ledger refuses these totals; the exports used to print them, so a workbook carried a
    /// "Page index 3" and a "Slope % 60" the screen never showed. One rule, for both sides:
    ///
    /// - money sums — but a **rate** is not money, it is money per something, and never sums
    ///   (ADR-0020): the built-in `Unit Cost`, and any money column whose declared dimension
    ///   carries a length power (SEK/m², SEK/m). "Sum: Unit Cost" is a number that means
    ///   nothing, and it used to print in every grouped export;
    /// - an angle never sums;
    /// - the built-in `pageIndex` never sums, and neither does any built-in column whose
    ///   measurement field does not repeat with the markup (`slopeRatio`, `slopePercent`,
    ///   `slopeAngle`, `rise`, `run`, `depth`, `height`, `radius`, `diameter`) — the sum rule and
    ///   the repeat rule are one rule (W-060);
    /// - a dimensionless column sums only when it is a count (`count`, or a custom column
    ///   declared with the count dimension) — a ratio is not an extent;
    /// - a number or formula column with no declared dimension sums: its dimension is decided
    ///   per row, and the accumulator refuses a mix;
    /// - the built-in `cutoutArea` never sums (ADR-0018): a parent row reports the union of
    ///   its cutouts and, under `subtractAndReportSeparately`, each cutout row reports its own
    ///   area, so a sum would count the same removed area twice. `grossArea` sums — each
    ///   outline appears once, on its own row;
    /// - a column marked `neverSums` never sums (ADR-0039): its values describe one row — a
    ///   pack size is an area, and three rows of 2.88 m² boards are not a 8.64 m² board.
    public static func sums(_ column: LedgerColumnDefinition) -> Bool {
        if column.neverSums == true { return false }
        switch column.kind {
        case .text, .date, .checkbox, .choice: return false
        case .currency:
            if column.standard == .unitCost { return false }
            if let dimension = column.dimension, dimension.lengthPower != 0 { return false }
            return true
        case .number, .formula: break
        }
        switch column.standard {
        case .pageIndex, .cutoutArea:
            return false
        default:
            break
        }
        // W-060: a built-in column that reads a property of one markup — the slope in its three
        // spellings, rise, run, depth, height, radius and diameter — never sums. The rule is the
        // repeat rule's own (``MeasurementField/repeatsWithMarkup``): six columns share one
        // radius, so three circles of r = 1, 2 and 3 m are not "6 m" of anything. Radius and
        // Diameter used to be missing from a hand-kept list here and were totalled everywhere.
        if let field = column.standard?.measurementField, !field.repeatsWithMarkup {
            return false
        }
        guard let dimension = column.dimension else { return true }
        if dimension.currencyCode != nil { return dimension.lengthPower == 0 }
        if dimension.angle { return false }
        if dimension.lengthPower == 0 { return dimension == .count }
        return true
    }
}
