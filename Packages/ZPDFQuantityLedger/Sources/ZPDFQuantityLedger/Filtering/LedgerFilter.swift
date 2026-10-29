import Foundation
import ZPDFContracts

/// What a rule compares against.
public enum LedgerFilterValue: Hashable, Sendable {
    case text(String)
    case number(Decimal)
    case quantity(DecimalQuantity)
    case date(Date)
    case boolean(Bool)
    case choice(ChoiceOptionID)
    /// Inclusive numeric range.
    case numberRange(lower: Decimal, upper: Decimal)
    /// Inclusive date range.
    case dateRange(lower: Date, upper: Date)
    /// Membership over canonical texts, used by multi-choice filters (spec 15.6).
    case textSet([String])
    case choiceSet([ChoiceOptionID])
    /// No operand — for `isEmpty`, `isNotEmpty`, `isTrue`, `isFalse`.
    case none
}

/// The operators a rule can apply (spec 15.6).
///
/// Deliberately closed and deliberately without regex: spec 15.6 requires a
/// complexity/time guard for regex, and a guard that can fire mid-scan produces a *partial*
/// result set that looks complete (QUALITY_BAR A23). Regex therefore belongs behind a
/// cancellable, budgeted evaluator rather than in the pure rule tree, and is not in this build.
public enum LedgerFilterOperator: String, Hashable, Sendable, CaseIterable {
    case equals
    case notEquals
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case between
    case contains
    case notContains
    case beginsWith
    case endsWith
    case isEmpty
    case isNotEmpty
    case isTrue
    case isFalse
    case inSet
    case notInSet
}

/// One leaf of the filter tree.
public struct LedgerFilterRule: Hashable, Sendable {
    public let column: ColumnID
    public let op: LedgerFilterOperator
    public let value: LedgerFilterValue

    public init(column: ColumnID, op: LedgerFilterOperator, value: LedgerFilterValue = .none) {
        self.column = column
        self.op = op
        self.value = value
    }
}

/// A filter as a tree of AND/OR groups over rules.
///
/// Evaluation is a pure function of `(store, rowIndex)`: no caching, no short-circuit that
/// depends on evaluation order having side effects, no locale. `and([])` matches everything and
/// `or([])` matches nothing, which are the identities of the two operations and keep an
/// incrementally-built tree well defined at every step.
public indirect enum LedgerFilterNode: Hashable, Sendable {
    case all
    case nothing
    case rule(LedgerFilterRule)
    case and([LedgerFilterNode])
    case or([LedgerFilterNode])
    case not(LedgerFilterNode)
    /// Exactly these markups — an export of the selected rows (NL-QTY-14). Narrowing by
    /// identity through the filter, rather than dropping rows after the fact, keeps every
    /// subtotal and total the exact sum of the rows printed (QUALITY_BAR A35).
    case markups(Set<MarkupID>)

    /// True when the node cannot exclude any row, so the caller can skip the scan entirely.
    public var matchesEverything: Bool {
        switch self {
        case .all: true
        case .and(let children): children.allSatisfy(\.matchesEverything)
        default: false
        }
    }
}

/// Evaluates a filter tree against a store.
public struct LedgerFilterEvaluator: Sendable {
    public let store: LedgerStore
    /// Column definitions resolved once, so the rule loop never hashes a `ColumnID`.
    private let definitions: [ColumnID: LedgerColumnDefinition]

    public init(store: LedgerStore) {
        self.store = store
        self.definitions = Dictionary(
            uniqueKeysWithValues: store.columns.columns.map { ($0.id, $0) }
        )
    }

    /// The subset of `indices` that matches, in the same relative order.
    ///
    /// Order preservation matters: it is what makes filter-then-sort and sort-then-filter produce
    /// the same visible rows (QUALITY_BAR A22).
    ///
    /// The tree is compiled once per call (IM-077, ``CompiledLedgerFilter``): each rule's
    /// column is resolved, a Choice column's option texts become one dictionary, and a set
    /// operand becomes a `Set`, so "Status in {…}" is a hash lookup per row instead of a scan
    /// of the catalogue and of the set.
    public func filter(_ indices: [Int], with node: LedgerFilterNode) -> [Int] {
        guard !node.matchesEverything else { return indices }
        let compiled = CompiledLedgerFilter(node, definitions: definitions)
        return indices.filter { compiled.matches(rowIndex: $0, in: store) }
    }

    /// ``filter(_:with:)`` that a caller can abandon: `isCancelled` is polled every
    /// ``cancellationStride`` rows, and a cancelled scan returns `nil` — never the partial set
    /// it had built, which would look like a complete answer (QUALITY_BAR A23).
    public func filter(
        _ indices: [Int],
        with node: LedgerFilterNode,
        isCancelled: () -> Bool
    ) -> [Int]? {
        if isCancelled() { return nil }
        guard !node.matchesEverything else { return indices }
        let compiled = CompiledLedgerFilter(node, definitions: definitions)
        var output: [Int] = []
        for (position, index) in indices.enumerated() {
            if position > 0, position % Self.cancellationStride == 0, isCancelled() { return nil }
            if compiled.matches(rowIndex: index, in: store) { output.append(index) }
        }
        return isCancelled() ? nil : output
    }

    /// Rows scanned between two cancellation polls: small enough that a 100 000-row text scan
    /// answers a cancel within a few milliseconds, large enough that the poll costs nothing.
    public static let cancellationStride = 1_024

    public func matches(rowIndex: Int, node: LedgerFilterNode) -> Bool {
        compiled(node).matches(rowIndex: rowIndex, in: store)
    }

    /// `node` compiled against this store's columns, for a caller that tests many rows one at
    /// a time (the incremental updater, V-061) and must not recompile per row.
    func compiled(_ node: LedgerFilterNode) -> CompiledLedgerFilter {
        CompiledLedgerFilter(node, definitions: definitions)
    }

    /// The stored value of a Choice cell's option — `"open"`, not its UUID — for a rule whose
    /// operand is text. `nil` for every other cell, and for an option no catalogue knows.
    ///
    /// # Code-review finding CR-52
    ///
    /// The application's filter seam translates a Status rule into a *text* operand: the
    /// filter builder collects option values ("open") and the seam forwards them as `.text`
    /// or `.textSet`. This evaluator only knew how to compare a `.choice` cell with a
    /// `.choice` operand, so "Status is Open" matched nothing, "Status is not Open" matched
    /// every row, and an export then carried zero rows under a banner claiming the filter.
    /// A Choice cell compared with text is therefore compared by its option's stored value,
    /// or by its option id spelled as a UUID string — whichever the operand carries. The seam
    /// sending `.choice` / `.choiceSet`, its own half of the finding, keeps working unchanged.
    ///
    /// Resolved from the column's own catalogue first. The built-in Status column's options
    /// are ``LedgerStatusChoices`` and are known even to a column set that carries none.
    static func choiceText(
        of value: LedgerCellValue,
        in definition: LedgerColumnDefinition?
    ) -> String? {
        guard case .choice(let id) = value else { return nil }
        if let option = definition?.choices.first(where: { $0.id == id }) { return option.value }
        return LedgerStatusChoices.optionValue(id)
    }

    /// - Parameter exactText: `true` for a column whose text is a token, not a name
    ///   (``comparesTextExactly(_:)``): "is", "is not" and "is any of" then compare it exactly.
    static func matches(
        value: LedgerCellValue,
        op: LedgerFilterOperator,
        operand: LedgerFilterValue,
        choiceText: String? = nil,
        exactText: Bool = false
    ) -> Bool {
        switch op {
        case .isEmpty:
            if case .empty = value { return true }
            return false
        case .isNotEmpty:
            if case .empty = value { return false }
            return true
        case .isTrue:
            if case .checkbox(let flag) = value { return flag }
            return false
        case .isFalse:
            if case .checkbox(let flag) = value { return !flag }
            return false
        case .equals, .notEquals:
            let equal = isEqual(value, operand, choiceText: choiceText, exactText: exactText)
            return op == .equals ? equal : !equal
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            guard let result = compare(value, operand, choiceText: choiceText) else { return false }
            switch op {
            case .lessThan: return result == .orderedAscending
            case .lessThanOrEqual: return result != .orderedDescending
            case .greaterThan: return result == .orderedDescending
            default: return result != .orderedAscending
            }
        case .between:
            switch operand {
            case .numberRange(let lower, let upper):
                guard let decimal = numericValue(value) else { return false }
                return decimal >= lower && decimal <= upper
            case .dateRange(let lower, let upper):
                guard case .date(let date) = value else { return false }
                return date >= lower && date <= upper
            default:
                return false
            }
        case .contains, .notContains, .beginsWith, .endsWith:
            // CR-58: a negated operator is the exact complement of its positive form over
            // every non-error cell, as `notEquals` and `notInSet` already were. A cell that is
            // empty or not text does not contain the needle, so `notContains` keeps it. It used
            // to drop it, so "Label does not contain X" hid every blank label while "Label is
            // not X" showed them — two negations, two answers.
            guard case .text(let needle) = operand,
                  let haystack = textValue(value, choiceText: choiceText) else {
                return op == .notContains
            }
            let found: Bool
            switch op {
            case .contains, .notContains:
                found = haystack.range(
                    of: needle,
                    options: [.caseInsensitive],
                    range: nil,
                    locale: nil
                ) != nil
            case .beginsWith:
                found = haystack.range(
                    of: needle,
                    options: [.caseInsensitive, .anchored],
                    range: nil,
                    locale: nil
                ) != nil
            default:
                found = haystack.range(
                    of: needle,
                    options: [.caseInsensitive, .anchored, .backwards],
                    range: nil,
                    locale: nil
                ) != nil
            }
            return op == .notContains ? !found : found
        case .inSet, .notInSet:
            let member: Bool
            switch operand {
            case .textSet(let texts):
                guard let candidates = textCandidates(value, choiceText: choiceText) else {
                    return op == .notInSet
                }
                if case .text(let text) = value, !exactText {
                    // V-069: a text cell follows the one text rule, case-insensitive.
                    member = texts.contains { sameText(text, $0) }
                } else {
                    member = candidates.contains { texts.contains($0) }
                }
            case .choiceSet(let ids):
                guard case .choice(let id) = value else { return op == .notInSet }
                member = ids.contains(id)
            default:
                member = false
            }
            return op == .inSet ? member : !member
        }
    }

    static func isEqual(
        _ value: LedgerCellValue,
        _ operand: LedgerFilterValue,
        choiceText: String? = nil,
        exactText: Bool = false
    ) -> Bool {
        switch (value, operand) {
        // V-069: "is" and "is not" follow the rule contains / begins / ends already use —
        // case-insensitive — so "Label is wall" finds a "Wall" row. A token column's text,
        // choice ids and option values below stay exact.
        case (.text(let a), .text(let b)): exactText ? a == b : sameText(a, b)
        // CR-52: a Choice cell against a text operand — the option's stored value or its id.
        case (.choice, .text(let b)):
            textCandidates(value, choiceText: choiceText)?.contains(b) ?? false
        case (.checkbox(let a), .boolean(let b)): a == b
        case (.date(let a), .date(let b)): a == b
        case (.choice(let a), .choice(let b)): a == b
        case (.currency(let amount, let code), .quantity(let quantity)):
            quantity.dimension.currencyCode == code && quantity.value == amount
        case (_, .number(let expected)): numericValue(value) == expected
        case (_, .quantity(let expected)):
            AggregateAccumulator.quantity(of: value).map {
                $0.dimension == expected.dimension && $0.value == expected.value
            } ?? false
        default: false
        }
    }

    static func compare(
        _ value: LedgerCellValue,
        _ operand: LedgerFilterValue,
        choiceText: String? = nil
    ) -> ComparisonResult? {
        switch operand {
        case .number(let expected):
            guard let decimal = numericValue(value) else { return nil }
            if decimal == expected { return .orderedSame }
            return decimal < expected ? .orderedAscending : .orderedDescending
        case .quantity(let expected):
            guard let quantity = AggregateAccumulator.quantity(of: value),
                  quantity.dimension == expected.dimension else { return nil }
            if quantity.value == expected.value { return .orderedSame }
            return quantity.value < expected.value ? .orderedAscending : .orderedDescending
        case .date(let expected):
            guard case .date(let date) = value else { return nil }
            if date == expected { return .orderedSame }
            return date < expected ? .orderedAscending : .orderedDescending
        case .text(let expected):
            guard let text = textValue(value, choiceText: choiceText) else { return nil }
            return LedgerOrdering.compareText(text, expected)
        default:
            return nil
        }
    }

    /// The magnitude a numeric comparison uses. Currency compares on its amount; the ISO code is
    /// checked by ``isEqual(_:_:choiceText:)`` when the operand carries one.
    static func numericValue(_ value: LedgerCellValue) -> Decimal? {
        AggregateAccumulator.quantity(of: value)?.value
    }

    /// The text a cell compares as: its own text, or — for a Choice cell — its option's stored
    /// value, falling back to the option id when no catalogue names it.
    static func textValue(_ value: LedgerCellValue, choiceText: String? = nil) -> String? {
        switch value {
        case .text(let text): text
        case .choice(let id): choiceText ?? id.rawValue.uuidString
        default: nil
        }
    }

    /// Every spelling a text operand may use for a cell: the text itself, or — for a Choice
    /// cell — the option's stored value and its id. `nil` for a cell that has no text form.
    static func textCandidates(_ value: LedgerCellValue, choiceText: String?) -> [String]? {
        switch value {
        case .text(let text): [text]
        case .choice(let id): [choiceText, id.rawValue.uuidString].compactMap { $0 }
        default: nil
        }
    }

    /// The one text-matching rule every text operator follows (V-069): case-insensitive, no
    /// locale — the comparison `contains`, `beginsWith` and `endsWith` make.
    static func sameText(_ left: String, _ right: String) -> Bool {
        left.compare(right, options: .caseInsensitive, range: nil, locale: nil) == .orderedSame
    }

    /// `text` case-folded, so that a set of folded keys answers ``sameText(_:_:)`` by hashing.
    static func textKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Whether "is", "is not" and "is any of" compare `definition`'s text cells exactly
    /// rather than by ``sameText(_:_:)`` (V-069 re-fix).
    ///
    /// The built-in Type column holds the tool's token — `"length"`, `"rectangleArea"`, the
    /// spelling the archive and the search index use (T-046) — not a name anybody typed. Its
    /// filter is a pick list whose options carry that token (U-059), and V-069 kept tokens as
    /// they were. Folding case there made the display name "Length" equal the token
    /// `"length"`, so "Type is Length" typed as free text matched the length rows by accident
    /// while "Type is Rectangle Area" still matched nothing. The substring operators keep
    /// their case-insensitive rule on every column, as they always had.
    static func comparesTextExactly(_ definition: LedgerColumnDefinition?) -> Bool {
        definition?.standard == .icon
    }
}

/// A filter tree compiled against one column set (IM-077).
///
/// The one evaluator: ``LedgerFilterEvaluator`` builds this for every scan and every
/// single-row check, and every rule still ends in
/// ``LedgerFilterEvaluator/matches(value:op:operand:choiceText:)``. What compiling removes is
/// the per-row set-up: resolving the rule's column, scanning a Choice column's catalogue for
/// the option's text (`choices.first(where:)`, linear in the options) and scanning a
/// `textSet` / `choiceSet` operand (linear in the set).
struct CompiledLedgerFilter: Sendable {

    private indirect enum Node: Sendable {
        case all
        case nothing
        case markups(Set<MarkupID>)
        case rule(Rule)
        case and([Node])
        case or([Node])
        case not(Node)
    }

    private struct Rule: Sendable {
        let rule: LedgerFilterRule
        let definition: LedgerColumnDefinition?
        /// The column's option texts, the first option per id winning as `first(where:)` did.
        let choiceTexts: [ChoiceOptionID: String]
        let textSet: Set<String>?
        /// ``textSet`` case-folded, for a text cell (V-069); a Choice cell's option value and
        /// id still match ``textSet`` exactly, and so does a token column's text (`nil` there).
        let foldedTextSet: Set<String>?
        let choiceSet: Set<ChoiceOptionID>?
        /// ``LedgerFilterEvaluator/comparesTextExactly(_:)`` for the rule's column.
        let exactText: Bool
    }

    private let root: Node

    init(_ node: LedgerFilterNode, definitions: [ColumnID: LedgerColumnDefinition]) {
        root = Self.compile(node, definitions: definitions)
    }

    private static func compile(
        _ node: LedgerFilterNode,
        definitions: [ColumnID: LedgerColumnDefinition]
    ) -> Node {
        switch node {
        case .all: return .all
        case .nothing: return .nothing
        case .markups(let ids): return .markups(ids)
        case .not(let child): return .not(compile(child, definitions: definitions))
        case .and(let children): return .and(children.map { compile($0, definitions: definitions) })
        case .or(let children): return .or(children.map { compile($0, definitions: definitions) })
        case .rule(let rule):
            let definition = definitions[rule.column]
            var texts: [ChoiceOptionID: String] = [:]
            for option in definition?.choices ?? [] where texts[option.id] == nil {
                texts[option.id] = option.value
            }
            let exactText = LedgerFilterEvaluator.comparesTextExactly(definition)
            var textSet: Set<String>?
            var foldedTextSet: Set<String>?
            var choiceSet: Set<ChoiceOptionID>?
            switch rule.value {
            case .textSet(let values):
                textSet = Set(values)
                if !exactText { foldedTextSet = Set(values.map(LedgerFilterEvaluator.textKey)) }
            case .choiceSet(let ids): choiceSet = Set(ids)
            default: break
            }
            return .rule(Rule(
                rule: rule, definition: definition, choiceTexts: texts,
                textSet: textSet, foldedTextSet: foldedTextSet, choiceSet: choiceSet,
                exactText: exactText
            ))
        }
    }

    func matches(rowIndex: Int, in store: LedgerStore) -> Bool {
        matches(rowIndex: rowIndex, node: root, store: store)
    }

    private func matches(rowIndex: Int, node: Node, store: LedgerStore) -> Bool {
        switch node {
        case .all:
            return true
        case .nothing:
            return false
        case .markups(let ids):
            return ids.contains(store.row(at: rowIndex).markupID)
        case .not(let child):
            return !matches(rowIndex: rowIndex, node: child, store: store)
        case .and(let children):
            for child in children where !matches(rowIndex: rowIndex, node: child, store: store) { return false }
            return true
        case .or(let children):
            for child in children where matches(rowIndex: rowIndex, node: child, store: store) { return true }
            return false
        case .rule(let rule):
            return matches(rowIndex: rowIndex, rule: rule, store: store)
        }
    }

    private func matches(rowIndex: Int, rule compiled: Rule, store: LedgerStore) -> Bool {
        let rule = compiled.rule
        let cell = compiled.definition.map { store.value(at: rowIndex, definition: $0) }
            ?? store.value(at: rowIndex, column: rule.column)
        switch rule.op {
        // W-063: "No input" is no value, as it is for totals — Is empty finds it, and Is not
        // empty does not. It used to match neither. A refusal still matches neither.
        case .isEmpty:
            return cell.hasNoValue
        case .isNotEmpty:
            return !cell.hasNoValue && cell.cellError == nil
        default:
            break
        }
        // A refusal matches no operator below. It is never silently treated as blank, and
        // never as zero.
        //
        // X-032: a "No input" cell is no value, so every other operator reads it as the empty
        // cell it groups, sorts and totals like (W-063). It used to fail the guard, so "is not
        // X", "does not contain X" and "is none of" dropped it while keeping an empty cell —
        // and a rule and its negation no longer split the rows between them (CR-58).
        let value: LedgerCellValue
        if cell.hasNoValue {
            value = .empty
        } else if case .value(let stored) = cell {
            value = stored
        } else {
            return false
        }
        var choiceText: String?
        if case .choice(let id) = value {
            choiceText = compiled.choiceTexts[id] ?? LedgerStatusChoices.optionValue(id)
        }
        if rule.op == .inSet || rule.op == .notInSet {
            if let texts = compiled.textSet {
                guard let candidates = LedgerFilterEvaluator.textCandidates(value, choiceText: choiceText) else {
                    return rule.op == .notInSet
                }
                let member: Bool
                if case .text(let text) = value, let folded = compiled.foldedTextSet {
                    member = folded.contains(LedgerFilterEvaluator.textKey(text))
                } else {
                    member = candidates.contains { texts.contains($0) }
                }
                return rule.op == .inSet ? member : !member
            }
            if let ids = compiled.choiceSet {
                guard case .choice(let id) = value else { return rule.op == .notInSet }
                let member = ids.contains(id)
                return rule.op == .inSet ? member : !member
            }
        }
        return LedgerFilterEvaluator.matches(
            value: value,
            op: rule.op,
            operand: rule.value,
            choiceText: choiceText,
            exactText: compiled.exactText
        )
    }
}
