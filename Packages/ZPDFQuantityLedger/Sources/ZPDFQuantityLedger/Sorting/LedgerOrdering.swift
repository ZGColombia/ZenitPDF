import Foundation
import ZPDFContracts

/// The one total order over ledger cell values.
///
/// # Documented ordering
///
/// **Nulls.** An empty cell and an errored cell are not values and never interleave with values.
/// They are ordered by ``LedgerSortDescriptor/nulls`` — `.last` by default — and that placement
/// is *independent of the sort direction*: reversing an ascending sort does not move the empties
/// from the bottom to the top, because "no value" is not smaller or larger than a value, it is
/// simply not on the scale. Errors always sort after empties within the null block, so a broken
/// formula is visible at one end of the table rather than scattered.
///
/// **Mixed types.** A column should hold one kind of value, but a formula column can return a
/// number on one row and a boolean on the next, and an imported project can hold anything. Rather
/// than compare across kinds — which has no meaning — values are ranked by kind first, using the
/// fixed order below, and compared within a kind:
///
/// | rank | kind |
/// |---|---|
/// | 0 | number, formula result |
/// | 1 | currency |
/// | 2 | checkbox |
/// | 3 | date |
/// | 4 | choice |
/// | 5 | text |
///
/// Currencies with different ISO codes are ordered by code first, then by amount: a total across
/// them is refused, but a *sort* must still be total, and ordering by code keeps each currency's
/// rows contiguous. Dimensioned numbers likewise order by dimension first (``DecimalQuantity``
/// is `Comparable` on exactly that rule), so metres and square metres never interleave.
///
/// **Identifiers.** ``compareIdentifiers(_:_:)`` compares Unicode scalar values, not collated
/// text: the same two ids order the same way under `sv_SE`, `tr_TR` and the C locale. Every
/// tie-break in this package, and every ordering of group keys, uses it. Human-facing text still
/// compares with `String.compare(_:options:range:locale:)` and an explicit `locale: nil`, which
/// is Foundation's non-localised comparison rather than the current locale's.
public enum LedgerOrdering: Sendable {

    /// Locale-independent scalar comparison. The tie-breaker of last resort.
    public static func compareIdentifiers(_ left: String, _ right: String) -> ComparisonResult {
        var leftIterator = left.unicodeScalars.makeIterator()
        var rightIterator = right.unicodeScalars.makeIterator()
        while true {
            switch (leftIterator.next(), rightIterator.next()) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedAscending
            case (_, nil): return .orderedDescending
            case (let leftScalar?, let rightScalar?):
                if leftScalar.value != rightScalar.value {
                    return leftScalar.value < rightScalar.value ? .orderedAscending : .orderedDescending
                }
            }
        }
    }

    /// Non-localised, digit-aware text comparison for human-readable strings.
    ///
    /// `.numeric` since 2026-08-27, for the per-sheet summary: sheet "10" must follow sheet "2",
    /// and "A-101" must follow "A-99". Plain lexicographic order put sheet 10 between 1 and 2,
    /// which on a 23-sheet set makes the grouped ledger read as shuffled. Still no locale — the
    /// order must be one order on every machine, and `compareIdentifiers` remains the
    /// deterministic tiebreak.
    ///
    /// Two texts Swift calls equal are the same text here too (U-060): NFC "Café" and NFD
    /// "Café" are `==` (and hash alike, so a full build buckets them into one group), but the
    /// scalar tiebreak used to order them, so the incremental group editor never found the
    /// existing sibling and added a second group with an identical key and path.
    public static func compareText(_ left: String, _ right: String) -> ComparisonResult {
        let result = left.compare(right, options: [.numeric], range: nil, locale: nil)
        guard result == .orderedSame else { return result }
        return left == right ? .orderedSame : compareIdentifiers(left, right)
    }

    /// The kind rank documented above. Nulls are handled separately and have no rank.
    public static func typeRank(_ value: LedgerCellValue) -> Int {
        switch value {
        case .number, .formulaResult: 0
        case .currency: 1
        case .checkbox: 2
        case .date: 3
        case .choice: 4
        case .text: 5
        case .empty: 6
        }
    }

    /// Compares two present values. Nulls must be filtered out before calling.
    public static func compareValues(
        _ left: LedgerCellValue,
        _ right: LedgerCellValue,
        choiceOrder: [ChoiceOptionID: Int] = [:]
    ) -> ComparisonResult {
        let leftRank = typeRank(left)
        let rightRank = typeRank(right)
        guard leftRank == rightRank else {
            return leftRank < rightRank ? .orderedAscending : .orderedDescending
        }
        switch (left, right) {
        case (.number(let a), .number(let b)),
             (.formulaResult(let a, _), .formulaResult(let b, _)),
             (.number(let a), .formulaResult(let b, _)),
             (.formulaResult(let a, _), .number(let b)):
            return compareQuantities(a, b)
        case (.currency(let leftAmount, let leftCode), .currency(let rightAmount, let rightCode)):
            if leftCode != rightCode { return compareIdentifiers(leftCode, rightCode) }
            if leftAmount == rightAmount { return .orderedSame }
            return leftAmount < rightAmount ? .orderedAscending : .orderedDescending
        case (.checkbox(let a), .checkbox(let b)):
            if a == b { return .orderedSame }
            return b ? .orderedAscending : .orderedDescending
        case (.date(let a), .date(let b)):
            if a == b { return .orderedSame }
            return a < b ? .orderedAscending : .orderedDescending
        case (.choice(let a), .choice(let b)):
            return compareChoices(a, b, choiceOrder: choiceOrder)
        case (.text(let a), .text(let b)):
            return compareText(a, b)
        default:
            return .orderedSame
        }
    }

    /// The one choice-option order: catalogue rank first, then unknown options — a value an
    /// import or a retired option left behind that the column no longer offers — after every
    /// known one, then the option id. A total order however many options the catalogue lacks.
    ///
    /// # Bug-hunt finding BH-195
    ///
    /// The group-key comparator used to fall from "both known and different" straight to a
    /// UUID compare, so with A (rank 0, id `f…`), B (rank 1, id `a…`) and a foreign C (id `c…`)
    /// it said A < B, B < C and C < A — a cycle that left the builder's sibling order
    /// unspecified and let the incremental editor's binary search miss a sibling. The sort
    /// comparator already put unknown options last; this is that rule, shared.
    public static func compareChoices(
        _ left: ChoiceOptionID,
        _ right: ChoiceOptionID,
        choiceOrder: [ChoiceOptionID: Int]
    ) -> ComparisonResult {
        switch (choiceOrder[left], choiceOrder[right]) {
        case (let x?, let y?) where x != y:
            return x < y ? .orderedAscending : .orderedDescending
        case (nil, _?): return .orderedDescending
        case (_?, nil): return .orderedAscending
        default:
            return compareIdentifiers(left.rawValue.uuidString, right.rawValue.uuidString)
        }
    }

    /// Dimension first, then magnitude. Never claims two different dimensions are equal.
    public static func compareQuantities(
        _ left: DecimalQuantity,
        _ right: DecimalQuantity
    ) -> ComparisonResult {
        if left.dimension != right.dimension {
            let byDimension = compareDimensions(left.dimension, right.dimension)
            if byDimension != .orderedSame { return byDimension }
        }
        if left.value == right.value { return .orderedSame }
        return left.value < right.value ? .orderedAscending : .orderedDescending
    }

    /// The total order over dimensions every sort and every group order uses: length power,
    /// then angle (plain before angular), then currency code by scalar order, then the
    /// count/ratio tag (count before ratio). `.orderedSame` only for equal dimensions.
    ///
    /// # Bug-hunt finding BH-194
    ///
    /// `DecimalQuantity.<` compares length power, angle and currency and stops there, so a
    /// count and a ratio of the same magnitude were "not less" in both directions and
    /// ``compareQuantities(_:_:)`` answered `.orderedDescending` both ways. A group order over
    /// a column mixing the two (pre-ADR-0014 stored counts beside `length/length` ratios) was
    /// then not a total order, and the incremental editor's sibling search could walk the wrong
    /// way. The ratio tag is the fourth key here, so the order is total.
    public static func compareDimensions(
        _ left: QuantityDimension,
        _ right: QuantityDimension
    ) -> ComparisonResult {
        if left.lengthPower != right.lengthPower {
            return left.lengthPower < right.lengthPower ? .orderedAscending : .orderedDescending
        }
        if left.angle != right.angle {
            return left.angle ? .orderedDescending : .orderedAscending
        }
        if left.currencyCode != right.currencyCode {
            // No code before any code, so `nil` and `""` are not a tie.
            guard let leftCode = left.currencyCode else { return .orderedAscending }
            guard let rightCode = right.currencyCode else { return .orderedDescending }
            return compareIdentifiers(leftCode, rightCode)
        }
        if left.ratio != right.ratio {
            return left.ratio ? .orderedDescending : .orderedAscending
        }
        return .orderedSame
    }
}

extension LedgerColumnDefinition {
    /// The one derivation of a Choice column's option order, shared by the group builder, the
    /// incremental group editor and the sorter (IM-078).
    ///
    /// Options rank by their `order`; two options with the same `order` keep their catalogue
    /// position, so the rule is total and does not depend on whether `sorted(by:)` happens to
    /// be stable. The builder, the editor and the sorter used to derive this separately, and
    /// the editor's binary search is only correct when its order is the builder's — one
    /// derivation makes that structural.
    public var choiceRank: [ChoiceOptionID: Int] {
        guard !choices.isEmpty else { return [:] }
        let ranked = choices.enumerated().sorted { left, right in
            if left.element.order != right.element.order {
                return left.element.order < right.element.order
            }
            return left.offset < right.offset
        }
        var rank: [ChoiceOptionID: Int] = [:]
        rank.reserveCapacity(ranked.count)
        for (position, option) in ranked.enumerated() where rank[option.element.id] == nil {
            rank[option.element.id] = position
        }
        return rank
    }
}
