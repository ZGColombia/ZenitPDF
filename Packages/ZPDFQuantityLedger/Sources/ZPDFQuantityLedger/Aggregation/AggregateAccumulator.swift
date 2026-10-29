import Foundation
import ZPDFContracts

/// The exact, mergeable state behind every subtotal and the grand total.
///
/// Two properties make the whole aggregation layer work:
///
/// 1. **Every addition is exact.** Terms go through ``DecimalSummation/add(_:_:)``, which checks
///    the `NSDecimalAdd` result code, so a total is either the exact `Decimal` sum of its parts
///    or a typed refusal — never a rounded approximation (QUALITY_BAR A1, A2).
/// 2. **Merging is the same operation as adding.** A parent group's subtotal is the merge of its
///    children's accumulators, and the grand total is the merge of the roots. Because merging is
///    exact and associative, `Σ subtotal(group) == grandTotal` holds *by construction* rather
///    than by a second pass that has to agree with the first (A5, A7).
///
/// Order independence (A3) follows from the same fact: exact addition is commutative, and the
/// only order-sensitive state — the set of dimensions seen — is kept in a fixed order
/// (``LedgerOrdering/compareDimensions(_:_:)``), so two accumulators that saw the same rows in
/// a different order are `==` as well as observably equal (BH-613).
public struct AggregateAccumulator: Hashable, Sendable {

    /// Rows whose cell carried a value.
    public private(set) var valueCount: Int = 0
    /// Rows visited, empty cells included.
    public private(set) var rowCount: Int = 0

    private var total: Decimal = .zero
    private var dimension: QuantityDimension?
    /// Dimensions seen *besides* ``dimension``. Empty on the overwhelmingly common path, which is
    /// why this is an array rather than a `Set`: hashing a `QuantityDimension` on every one of a
    /// hundred thousand rows costs more than the whole rest of the accumulation.
    ///
    /// Once the accumulator is mixed, ``dimension`` and this array are re-canonicalised so that
    /// `dimension` is the smallest dimension seen and the extras are the rest in
    /// ``LedgerOrdering/compareDimensions(_:_:)`` order — the same state whichever row arrived
    /// first (BH-613).
    private var extraDimensions: [QuantityDimension] = []
    private var minimum: DecimalQuantity?
    private var maximum: DecimalQuantity?
    private var distinct: Set<String>?
    private var failure: LedgerAggregationError.Code?
    private let requirements: Requirements
    /// Of ``valueCount``, how many were *not* quantities (text in a summed column, dates,
    /// checkboxes). Tracked so ``remove(_:)`` knows whether taking out the last quantity
    /// leaves the accumulator genuinely value-free — the state a rebuilt accumulator would
    /// be in — or still holding counted non-numeric values.
    private var nonQuantityValueCount: Int = 0

    /// What an accumulator has been asked to keep track of.
    ///
    /// A `Sum` does not need the smallest member and a `Count` does not need any arithmetic at
    /// all. Tracking everything unconditionally triples the cost of the common case: over
    /// 100 000 rows, maintaining a running min and max costs more than the exact addition it was
    /// riding along with.
    public struct Requirements: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Maintain the running exact total.
        public static let sum = Requirements(rawValue: 1 << 0)
        /// Maintain the running minimum and maximum.
        public static let extremes = Requirements(rawValue: 1 << 1)
        /// Retain each value's canonical text. The largest allocation in the aggregation path,
        /// so nothing pays for it unasked.
        public static let distinct = Requirements(rawValue: 1 << 2)

        public static let `default`: Requirements = [.sum, .extremes]

        /// What one aggregate function actually needs.
        public static func of(_ function: AggregateFunction) -> Requirements {
            switch function {
            case .sum, .average, .weightedTotal: .sum
            case .minimum, .maximum: .extremes
            case .distinctCount: .distinct
            case .count, .rowCount: []
            }
        }
    }

    public init(_ requirements: Requirements = .default) {
        self.requirements = requirements
        if requirements.contains(.distinct) { distinct = [] }
    }

    /// An accumulator that can only ever answer with `failure` — for a plan key whose column
    /// or weight column the column set does not have (BH-191). Every function, tallies
    /// included, reads as the failure: a `Count` of a column that does not exist is not `0`.
    static func unresolved(_ code: LedgerAggregationError.Code) -> AggregateAccumulator {
        var accumulator = AggregateAccumulator([])
        accumulator.failure = code
        return accumulator
    }

    /// True for a failure that is about the plan, not the rows (BH-191).
    private static func isStructural(_ code: LedgerAggregationError.Code) -> Bool {
        switch code {
        case .unknownColumn, .unknownWeightColumn: true
        default: false
        }
    }

    // MARK: - Adding rows

    /// Folds one cell in.
    ///
    /// A formula cell with nothing to compute from (``LedgerCellError/Kind/missingInput``) is
    /// folded in exactly like an empty cell: counted in `Rows`, left out of `Count`, the sums
    /// and the extremes (V-058). Every other error cell is a refusal.
    public mutating func add(_ cell: LedgerCellResult) {
        rowCount += 1
        switch cell {
        case .error(let error) where error.isMissingInput:
            return
        case .error(let error):
            fail(.cellError(error.kind))
        case .value(let value):
            add(value)
        }
    }

    /// Folds one cell in after multiplying it by a dimensionless weight (spec 15.5).
    public mutating func addWeighted(_ cell: LedgerCellResult, weight: LedgerCellResult, weightColumn: ColumnID) {
        rowCount += 1
        if cell.cellError?.isMissingInput == true { return }
        guard case .value(let value) = cell else {
            fail(.cellError(cell.cellError?.kind ?? .aggregation))
            return
        }
        guard let quantity = Self.quantity(of: value) else {
            if case .empty = value { return }
            distinctInsert(Self.canonicalText(value))
            return
        }
        guard case .value(let weightValue) = weight, let weightQuantity = Self.quantity(of: weightValue) else {
            fail(.nonScalarWeight(weightColumn))
            return
        }
        guard weightQuantity.dimension.isDimensionless else {
            fail(.nonScalarWeight(weightColumn))
            return
        }
        do {
            let scaled = try DecimalSummation.multiply(quantity.value, weightQuantity.value)
            addQuantity(DecimalQuantity(value: scaled, dimension: quantity.dimension))
        } catch let error as LedgerAggregationError {
            fail(error.code)
        } catch {
            fail(.inexactAddition(.overflow))
        }
    }

    private mutating func add(_ value: LedgerCellValue) {
        if case .empty = value { return }
        if distinct != nil { distinctInsert(Self.canonicalText(value)) }
        guard requirements.contains(.sum) || requirements.contains(.extremes) else {
            valueCount += 1
            return
        }
        guard let quantity = Self.quantity(of: value) else {
            // Text, dates, checkboxes and choices count but do not sum.
            valueCount += 1
            nonQuantityValueCount += 1
            return
        }
        addQuantity(quantity)
    }

    // MARK: - Removing rows (incremental regrouping)

    /// Reverses one previously folded-in cell, exactly, or refuses.
    ///
    /// This is what makes a one-row mutation O(changed) instead of O(group): a subtotal is
    /// moved from its old value to its new value by subtracting the old cell and adding the
    /// new one, both through the same checked `Decimal` arithmetic the forward path uses —
    /// so `add` then `remove` is a bit-identical round trip, never an approximation.
    ///
    /// - Returns: `false` when the reversal cannot be proven exact — a running minimum or
    ///   maximum whose extreme *is* the removed value, a distinct set (a multiset would be
    ///   needed), a mixed or failed accumulator, or a refused error cell. The caller then recomputes
    ///   from rows; a wrong number is never produced, only a slower exact one.
    ///
    /// # Min and Max (IM-076)
    ///
    /// A running extreme is not invertible in general, but it *is* provably unchanged when the
    /// removed value lies strictly between the minimum and the maximum: neither extreme was
    /// that value, so both remain actual member values after it leaves. Only a value equal to
    /// an extreme refuses. A plan with a Min or Max column therefore keeps the O(changed) edit
    /// path for every edit but the one that touches the extreme itself.
    public mutating func remove(_ cell: LedgerCellResult) -> Bool {
        guard failure == nil, extraDimensions.isEmpty, distinct == nil else { return false }
        if cell.cellError?.isMissingInput == true {
            // Folded in as an empty cell (V-058), so it comes out as one.
            rowCount -= 1
            return true
        }
        guard case .value(let value) = cell else { return false }
        if case .empty = value {
            rowCount -= 1
            return true
        }
        guard requirements.contains(.sum) || requirements.contains(.extremes) else {
            // A pure Count tracked nothing but the tally.
            valueCount -= 1
            rowCount -= 1
            return true
        }
        guard let quantity = Self.quantity(of: value) else {
            valueCount -= 1
            nonQuantityValueCount -= 1
            rowCount -= 1
            return true
        }
        guard quantity.isFinite, quantity.dimension == dimension else { return false }
        if requirements.contains(.extremes) {
            guard let minimum, let maximum,
                  minimum.dimension == quantity.dimension,
                  maximum.dimension == quantity.dimension,
                  minimum.value < quantity.value, quantity.value < maximum.value
            else { return false }
        }
        if requirements.contains(.sum) {
            do {
                total = try DecimalSummation.subtract(total, quantity.value)
            } catch {
                return false
            }
        }
        valueCount -= 1
        rowCount -= 1
        if valueCount - nonQuantityValueCount == 0 {
            // No quantities left: the accumulator must read exactly like one that never saw
            // any, so `Sum` answers "empty" rather than "0 m²".
            dimension = nil
            total = .zero
            minimum = nil
            maximum = nil
        }
        return true
    }

    private mutating func addQuantity(_ quantity: DecimalQuantity) {
        valueCount += 1
        guard failure == nil else { return }
        guard quantity.isFinite else {
            fail(.inexactAddition(.overflow))
            return
        }
        if requirements.contains(.extremes), !isMixed { updateExtremes(quantity) }
        guard let existing = dimension else {
            dimension = quantity.dimension
            addToTotal(quantity.value)
            return
        }
        if existing != quantity.dimension {
            noteExtra(quantity.dimension)
            // Mixed. The running total is discarded on purpose: keeping it would invite a caller
            // to display "a number, but". There is no number.
            total = .zero
            return
        }
        guard !isMixed else {
            total = .zero
            return
        }
        addToTotal(quantity.value)
    }

    private var isMixed: Bool { !extraDimensions.isEmpty }

    /// Records a second (or later) dimension and re-canonicalises the mixed state so it does
    /// not depend on which dimension arrived first (BH-613): `dimension` becomes the smallest
    /// dimension seen, the extras the rest in ``LedgerOrdering/compareDimensions(_:_:)`` order,
    /// and the running extremes — never read from a mixed accumulator — are dropped so that
    /// they cannot carry the arrival order either.
    private mutating func noteExtra(_ extra: QuantityDimension) {
        guard extra != dimension, !extraDimensions.contains(extra) else { return }
        var seen = extraDimensions
        seen.append(extra)
        if let current = dimension { seen.append(current) }
        seen.sort { LedgerOrdering.compareDimensions($0, $1) == .orderedAscending }
        dimension = seen.first
        extraDimensions = Array(seen.dropFirst())
        minimum = nil
        maximum = nil
        total = .zero
    }

    private mutating func addToTotal(_ value: Decimal) {
        guard requirements.contains(.sum) else { return }
        do {
            total = try DecimalSummation.add(total, value)
        } catch let error as LedgerAggregationError {
            fail(error.code)
        } catch {
            fail(.inexactAddition(.overflow))
        }
    }

    private mutating func updateExtremes(_ quantity: DecimalQuantity) {
        if let current = minimum {
            if current.dimension == quantity.dimension, quantity.value < current.value {
                minimum = quantity
            }
        } else {
            minimum = quantity
        }
        if let current = maximum {
            if current.dimension == quantity.dimension, quantity.value > current.value {
                maximum = quantity
            }
        } else {
            maximum = quantity
        }
    }

    // MARK: - Merging

    /// Folds a child accumulator into this one. Exact, associative and commutative.
    public mutating func merge(_ other: AggregateAccumulator) {
        rowCount += other.rowCount
        valueCount += other.valueCount
        nonQuantityValueCount += other.nonQuantityValueCount
        if distinct != nil, let otherDistinct = other.distinct {
            distinct?.formUnion(otherDistinct)
        }
        if let otherFailure = other.failure {
            fail(otherFailure)
            return
        }
        guard failure == nil else { return }
        if let otherMinimum = other.minimum {
            if let current = minimum {
                if current.dimension == otherMinimum.dimension, otherMinimum.value < current.value {
                    minimum = otherMinimum
                }
            } else {
                minimum = otherMinimum
            }
        }
        if let otherMaximum = other.maximum {
            if let current = maximum {
                if current.dimension == otherMaximum.dimension, otherMaximum.value > current.value {
                    maximum = otherMaximum
                }
            } else {
                maximum = otherMaximum
            }
        }
        // A mixed child makes the parent mixed. It is never dropped from the parent's sum
        // (QUALITY_BAR A13) — a second dimension in `extraDimensions` is exactly that.
        if let otherDimension = other.dimension {
            if let existing = dimension {
                if existing != otherDimension { noteExtra(otherDimension) }
            } else {
                dimension = otherDimension
            }
        }
        for extra in other.extraDimensions where extra != dimension { noteExtra(extra) }
        guard !isMixed else {
            // Extremes are never read from a mixed accumulator; dropping them keeps the mixed
            // state independent of which child merged first (BH-613).
            total = .zero
            minimum = nil
            maximum = nil
            return
        }
        addToTotal(other.total)
    }

    // MARK: - Reading out

    /// The value of one aggregate function over what has been folded in.
    public func value(_ function: AggregateFunction) -> AggregateValue {
        // CR-62: a tally is not arithmetic. `Count` is the rows whose cell carried a value —
        // an errored cell carried none — and `Rows` is every row visited, so both stay
        // answerable when a member cell is in error; only the sums, extremes and averages
        // become the refusal. They used to be refused too: a group of three rows with one
        // formula failure printed `#ERROR` where Count 2 and Rows 3 were the truth.
        if let failure, !function.isTally || Self.isStructural(failure) { return .failed(failure) }
        switch function {
        case .count:
            return .integer(valueCount)
        case .rowCount:
            return .integer(rowCount)
        case .distinctCount:
            guard let distinct else { return .failed(.distinctNotTracked) }
            return .integer(distinct.count)
        case .minimum:
            guard !isMixed else { return mixed }
            return minimum.map { quantised($0) } ?? .empty
        case .maximum:
            guard !isMixed else { return mixed }
            return maximum.map { quantised($0) } ?? .empty
        case .sum, .weightedTotal:
            guard !isMixed else { return mixed }
            guard let dimension else { return .empty }
            return quantised(DecimalQuantity(value: total, dimension: dimension))
        case .average:
            guard !isMixed else { return mixed }
            // BH-614: the mean of the quantities that were summed. A text cell in a numeric
            // column counts as a value (`Count`) but adds nothing to the total, so dividing
            // by `valueCount` made it a silent zero in the mean — 10 m² for {10, 20, "n/a"}
            // where the numbers say 15 m².
            let quantityCount = valueCount - nonQuantityValueCount
            guard let dimension, quantityCount > 0 else { return .empty }
            do {
                let mean = try DecimalSummation.divide(total, by: Decimal(quantityCount))
                return quantised(DecimalQuantity(value: mean, dimension: dimension))
            } catch let error as LedgerAggregationError {
                return .failed(error.code)
            } catch {
                return .failed(.inexactAddition(.overflow))
            }
        }
    }

    /// The dimensions seen, in a deterministic order, when there is more than one.
    private var mixed: AggregateValue {
        .mixedDimensions(
            (dimension.map { [$0] + extraDimensions } ?? extraDimensions).sorted {
                LedgerOrdering.compareDimensions($0, $1) == .orderedAscending
            }
        )
    }

    private func quantised(_ quantity: DecimalQuantity) -> AggregateValue {
        if let code = quantity.dimension.currencyCode, quantity.dimension.lengthPower == 0 {
            return .currency(amount: quantity.value, code: code)
        }
        return .quantity(quantity)
    }

    /// Records the first failure and drops the arithmetic state, which no failed
    /// accumulator ever reads: keeping it would make two failed accumulators that saw the
    /// same rows in a different order unequal, because the total stops growing at whichever
    /// row failed first (BH-613).
    private mutating func fail(_ code: LedgerAggregationError.Code) {
        // Of several failures the reported one is chosen by a fixed rule, not by arrival:
        // the smallest by its description, so a merge in either order agrees.
        if let current = failure {
            if LedgerOrdering.compareIdentifiers(String(describing: code), String(describing: current))
                == .orderedAscending {
                failure = code
            }
        } else {
            failure = code
        }
        total = .zero
        dimension = nil
        extraDimensions = []
        minimum = nil
        maximum = nil
    }

    private mutating func distinctInsert(_ text: String?) {
        guard distinct != nil, let text else { return }
        distinct?.insert(text)
    }

    // MARK: - Cell reading

    static func quantity(of value: LedgerCellValue) -> DecimalQuantity? {
        switch value {
        case .number(let quantity): quantity
        case .formulaResult(let quantity, _): quantity
        case .currency(let amount, let code): DecimalQuantity.money(amount, currencyCode: code)
        case .empty, .text, .date, .checkbox, .choice: nil
        }
    }

    /// A canonical, locale-independent text for distinct counting. Never shown to a user.
    static func canonicalText(_ value: LedgerCellValue) -> String? {
        switch value {
        case .empty: nil
        case .text(let text): "t:\(text)"
        case .number(let quantity): "n:\(quantity.value)@\(quantity.dimension.ledgerToken)"
        case .currency(let amount, let code): "c:\(amount)@\(code)"
        case .date(let date): "d:\(date.timeIntervalSinceReferenceDate)"
        case .checkbox(let flag): "b:\(flag)"
        case .choice(let id): "o:\(id.rawValue.uuidString)"
        case .formulaResult(let quantity, _): "n:\(quantity.value)@\(quantity.dimension.ledgerToken)"
        }
    }
}

/// Every aggregate of one group or of the whole ledger.
public struct LedgerAggregates: Hashable, Sendable {
    let accumulators: [AggregateKey: AggregateAccumulator]

    init(accumulators: [AggregateKey: AggregateAccumulator]) {
        self.accumulators = accumulators
    }

    public static let empty = LedgerAggregates(accumulators: [:])

    public var keys: [AggregateKey] { Array(accumulators.keys) }

    /// The aggregate for a requested key, or `nil` when the plan did not ask for it.
    public func value(_ key: AggregateKey) -> AggregateValue? {
        accumulators[key]?.value(key.function)
    }

    /// The plain sum of a column, when the plan asked for one.
    public subscript(column: ColumnID) -> AggregateValue? {
        value(AggregateKey(column: column, function: .sum))
    }

    /// The accumulator behind a key, for callers that need to merge further.
    public func accumulator(_ key: AggregateKey) -> AggregateAccumulator? { accumulators[key] }

    func merging(_ other: LedgerAggregates) -> LedgerAggregates {
        var merged = accumulators
        for (key, accumulator) in other.accumulators {
            if var existing = merged[key] {
                existing.merge(accumulator)
                merged[key] = existing
            } else {
                merged[key] = accumulator
            }
        }
        return LedgerAggregates(accumulators: merged)
    }

    /// ``merging(_:)`` restricted to `keys` — the other keys of `self` are left untouched.
    func merging(_ other: LedgerAggregates, keys: Set<AggregateKey>) -> LedgerAggregates {
        var merged = accumulators
        for key in keys {
            guard let accumulator = other.accumulators[key] else { continue }
            if var existing = merged[key] {
                existing.merge(accumulator)
                merged[key] = existing
            } else {
                merged[key] = accumulator
            }
        }
        return LedgerAggregates(accumulators: merged)
    }

    /// `self` with the accumulators for `keys` taken from `other`.
    func replacing(_ keys: Set<AggregateKey>, with other: LedgerAggregates) -> LedgerAggregates {
        var replaced = accumulators
        for key in keys { replaced[key] = other.accumulators[key] }
        return LedgerAggregates(accumulators: replaced)
    }
}

/// Builds ``LedgerAggregates`` over a set of row indices.
public struct LedgerAggregator: Sendable {
    public let store: LedgerStore
    public let plan: LedgerAggregationPlan

    /// The plan reorganised into one pass per column.
    ///
    /// Two things are precomputed here rather than in the row loop. First, `ColumnID` is resolved
    /// to a definition once instead of 500 000 times. Second, every aggregate over the *same*
    /// column shares a single read of that column's cell: a `Sum` and a `Count` on Plan Area are
    /// one pass over 100 000 rows, not two.
    private let passes: [Pass]
    /// Plan keys whose column or weight column the column set does not have, with the typed
    /// error each one reports (BH-191). They used to be dropped from the passes in silence, so
    /// the export's totals block simply lacked a row the user had configured; now every such
    /// key is present in every aggregate set as a failed accumulator and prints `#ERROR`.
    private let unresolved: [AggregateKey: LedgerAggregationError.Code]

    private struct Slot: Sendable {
        let key: AggregateKey
        let weight: LedgerColumnDefinition?
    }

    private struct Pass: Sendable {
        let column: LedgerColumnDefinition
        let slots: [Slot]
    }

    public init(store: LedgerStore, plan: LedgerAggregationPlan) {
        self.store = store
        self.plan = plan
        var order: [ColumnID] = []
        var grouped: [ColumnID: [Slot]] = [:]
        var definitions: [ColumnID: LedgerColumnDefinition] = [:]
        var unresolved: [AggregateKey: LedgerAggregationError.Code] = [:]
        for key in plan.keys {
            guard let column = store.columns.column(id: key.column) else {
                unresolved[key] = .unknownColumn(key.column)
                continue
            }
            var weight: LedgerColumnDefinition?
            if let weightID = key.function.weightColumn {
                guard let resolved = store.columns.column(id: weightID) else {
                    unresolved[key] = .unknownWeightColumn(weightID)
                    continue
                }
                weight = resolved
            }
            if grouped[key.column] == nil {
                grouped[key.column] = []
                order.append(key.column)
                definitions[key.column] = column
            }
            grouped[key.column]?.append(Slot(key: key, weight: weight))
        }
        self.passes = order.compactMap { id in
            guard let column = definitions[id], let slots = grouped[id] else { return nil }
            return Pass(column: column, slots: slots)
        }
        self.unresolved = unresolved
    }

    /// Folds a set of rows into one set of aggregates.
    ///
    /// This is the leaf operation; every higher level merges accumulators instead of re-reading
    /// rows.
    public func aggregate(rowIndices: some Collection<Int>) -> LedgerAggregates {
        aggregate(rowIndices: rowIndices, keys: nil)
    }

    /// ``aggregate(rowIndices:)`` for a subset of the plan — the keys an incremental delta
    /// could not update exactly (IM-076). `nil` means the whole plan.
    func aggregate(rowIndices: some Collection<Int>, keys: Set<AggregateKey>?) -> LedgerAggregates {
        guard !passes.isEmpty || !unresolved.isEmpty else { return .empty }
        var accumulators: [AggregateKey: AggregateAccumulator] = [:]
        accumulators.reserveCapacity(plan.keys.count)
        for (key, code) in unresolved where keys?.contains(key) ?? true {
            accumulators[key] = .unresolved(code)
        }
        for pass in passes {
            let wanted = pass.slots.enumerated().filter { keys?.contains($0.element.key) ?? true }
            guard !wanted.isEmpty else { continue }
            var slots = wanted.map { AggregateAccumulator(.of($0.element.key.function)) }
            for index in rowIndices {
                let cell = store.value(at: index, definition: pass.column)
                for (position, slot) in wanted.enumerated() {
                    if let weight = slot.element.weight {
                        slots[position].addWeighted(
                            cell,
                            weight: store.value(at: index, definition: weight),
                            weightColumn: weight.id
                        )
                    } else {
                        slots[position].add(cell)
                    }
                }
            }
            for (position, slot) in wanted.enumerated() {
                accumulators[slot.element.key] = slots[position]
            }
        }
        return LedgerAggregates(accumulators: accumulators)
    }

    // MARK: - Row deltas (incremental regrouping)

    /// Folds one more row into an existing aggregate set. Exact by the same argument as
    /// ``aggregate(rowIndices:)`` — it is the identical `add` path, arriving one row later.
    public func adding(row index: Int, to aggregates: LedgerAggregates) -> LedgerAggregates {
        guard !passes.isEmpty || !unresolved.isEmpty else { return aggregates }
        var accumulators = aggregates.accumulators
        for (key, code) in unresolved where accumulators[key] == nil {
            accumulators[key] = .unresolved(code)
        }
        for pass in passes {
            let cell = store.value(at: index, definition: pass.column)
            for slot in pass.slots {
                var accumulator = accumulators[slot.key] ?? AggregateAccumulator(.of(slot.key.function))
                if let weight = slot.weight {
                    accumulator.addWeighted(
                        cell,
                        weight: store.value(at: index, definition: weight),
                        weightColumn: weight.id
                    )
                } else {
                    accumulator.add(cell)
                }
                accumulators[slot.key] = accumulator
            }
        }
        return LedgerAggregates(accumulators: accumulators)
    }

    /// Takes one row back out of an existing aggregate set, reading the row's cells from
    /// `oldStore` — the values that were folded in, not the values the row has now.
    ///
    /// - Returns: `nil` when any accumulator refuses (see ``AggregateAccumulator/remove(_:)``)
    ///   or the plan uses a weighted total, whose reversal would need the old weight
    ///   multiplication re-proven. The caller recomputes from rows instead.
    public func removing(
        row index: Int,
        from aggregates: LedgerAggregates,
        readingFrom oldStore: LedgerStore
    ) -> LedgerAggregates? {
        let result = removingWhereExact(row: index, from: aggregates, readingFrom: oldStore)
        return result.refused.isEmpty ? result.aggregates : nil
    }

    /// The per-slot form of ``removing(row:from:readingFrom:)`` (IM-076): every accumulator
    /// that can reverse the row exactly does, and the keys that refused are named so the
    /// caller recomputes *only those* rather than the whole aggregate set.
    struct PartialRemoval {
        let aggregates: LedgerAggregates
        let refused: Set<AggregateKey>
    }

    func removingWhereExact(
        row index: Int,
        from aggregates: LedgerAggregates,
        readingFrom oldStore: LedgerStore
    ) -> PartialRemoval {
        guard !passes.isEmpty else { return PartialRemoval(aggregates: aggregates, refused: []) }
        var accumulators = aggregates.accumulators
        var refused = Set<AggregateKey>()
        for pass in passes {
            let cell = oldStore.value(at: index, definition: pass.column)
            for slot in pass.slots {
                guard slot.weight == nil, var accumulator = accumulators[slot.key],
                      accumulator.remove(cell) else {
                    refused.insert(slot.key)
                    continue
                }
                accumulators[slot.key] = accumulator
            }
        }
        return PartialRemoval(aggregates: LedgerAggregates(accumulators: accumulators), refused: refused)
    }
}
