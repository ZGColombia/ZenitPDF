import Foundation
import ZPDFContracts

/// Where cells with no value go. Independent of ``LedgerSortDescriptor/ascending`` by design —
/// see ``LedgerOrdering``.
public enum LedgerNullOrdering: String, Hashable, Sendable, CaseIterable {
    case first
    case last
}

/// One level of a sort.
public struct LedgerSortDescriptor: Hashable, Sendable {
    public let column: ColumnID
    public let ascending: Bool
    public let nulls: LedgerNullOrdering

    public init(column: ColumnID, ascending: Bool = true, nulls: LedgerNullOrdering = .last) {
        self.column = column
        self.ascending = ascending
        self.nulls = nulls
    }
}

/// Stable multi-column sorting over row indices.
///
/// Stability is not left to `Array.sort`, which is not documented as stable: the original index
/// is the final tie-breaker, so the order is fully determined by the descriptors plus the store's
/// row order. Two sorts of the same view therefore produce byte-identical output, which is what
/// QUALITY_BAR A34 needs from an export.
public struct LedgerSorter: Sendable {
    public let store: LedgerStore
    public let descriptors: [LedgerSortDescriptor]

    /// Descriptor, resolved column and choice order, prepared once. The comparator runs
    /// `n log n` times; nothing in it may do a dictionary lookup that the initialiser could have
    /// done instead.
    private struct Level: Sendable {
        let descriptor: LedgerSortDescriptor
        let column: LedgerColumnDefinition
        let choiceOrder: [ChoiceOptionID: Int]
    }

    private let levels: [Level]

    public init(store: LedgerStore, descriptors: [LedgerSortDescriptor]) {
        self.store = store
        self.descriptors = descriptors
        self.levels = descriptors.compactMap { descriptor in
            guard let column = store.columns.column(id: descriptor.column) else { return nil }
            // IM-078: the one choice-order derivation the group builder and the incremental
            // editor use too, ties on `order` broken by catalogue position.
            return Level(descriptor: descriptor, column: column, choiceOrder: column.choiceRank)
        }
    }

    /// The indices in sorted order.
    ///
    /// # Precomputed keys (IM-008)
    ///
    /// Each level's cells are read **once per row** into a key array, and the comparator
    /// compares those keys; it used to call ``LedgerStore/value(at:definition:)`` twice per
    /// comparison per level — about 3.4 million cell reads per level at 100 000 rows, each a
    /// formula-dictionary lookup, an edit-overlay probe and, for page, zone and layer
    /// columns, a name-catalog hash — and, for a text column, as many `.numeric` string
    /// comparisons.
    ///
    /// A level whose column repeats its values heavily (a label, a status, a page, a zone —
    /// the columns people actually sort by) goes one step further: its distinct cells are
    /// ordered once with the very same comparison (``compareCells(_:_:by:)``) and every row
    /// gets the dense rank of its cell, so the n log n comparisons are integer compares. The
    /// rank is exact because that comparison is a total preorder: equal cells get equal
    /// ranks, and the original index is still the final tie-breaker, so the order is
    /// identical to ``compare(_:_:)``'s — the differential test asserts it.
    public func sorted(_ indices: [Int]) -> [Int] {
        guard !levels.isEmpty else { return indices }
        let keys = levels.map { level in
            LevelKeys(level: level, cells: indices.map { store.value(at: $0, definition: level.column) })
        }
        var positions = Array(indices.indices)
        if keys.count == 1, keys[0].isRanked {
            let ranks = keys[0].ranks
            positions.sort { left, right in
                let leftRank = ranks[left]
                let rightRank = ranks[right]
                return leftRank != rightRank ? leftRank < rightRank : indices[left] < indices[right]
            }
        } else {
            positions.sort { left, right in
                for key in keys {
                    let result = key.compare(left, right)
                    if result != .orderedSame { return result == .orderedAscending }
                }
                return indices[left] < indices[right]
            }
        }
        return positions.map { indices[$0] }
    }

    /// One level's precomputed sort keys: the cells, and their dense ranks when the level
    /// repeats values often enough for ranking to pay.
    private struct LevelKeys {
        let level: Level
        let cells: [LedgerCellResult]
        /// Dense rank per position under ``compareCells(_:_:by:)``; empty when not ranked.
        let ranks: [Int]
        let isRanked: Bool

        /// Ranking pays when a column holds at most one distinct cell per this many rows.
        private static let rankingDuplication = 4

        init(level: Level, cells: [LedgerCellResult]) {
            self.level = level
            self.cells = cells
            let limit = max(1, cells.count / Self.rankingDuplication)
            var slots: [LedgerCellResult: Int] = [:]
            var distinct: [LedgerCellResult] = []
            var slotOfPosition: [Int] = []
            slotOfPosition.reserveCapacity(cells.count)
            var ranked = cells.count >= Self.rankingDuplication
            if ranked {
                for cell in cells {
                    if let slot = slots[cell] {
                        slotOfPosition.append(slot)
                        continue
                    }
                    guard distinct.count < limit else { ranked = false; break }
                    slots[cell] = distinct.count
                    slotOfPosition.append(distinct.count)
                    distinct.append(cell)
                }
            }
            guard ranked else {
                self.ranks = []
                self.isRanked = false
                return
            }
            let order = distinct.indices.sorted {
                LedgerSorter.compareCells(distinct[$0], distinct[$1], by: level) == .orderedAscending
            }
            var rankOfSlot = [Int](repeating: 0, count: distinct.count)
            var rank = 0
            for (position, slot) in order.enumerated() {
                if position > 0,
                   LedgerSorter.compareCells(distinct[order[position - 1]], distinct[slot], by: level) != .orderedSame {
                    rank += 1
                }
                rankOfSlot[slot] = rank
            }
            self.ranks = slotOfPosition.map { rankOfSlot[$0] }
            self.isRanked = true
        }

        func compare(_ left: Int, _ right: Int) -> ComparisonResult {
            if isRanked {
                let leftRank = ranks[left]
                let rightRank = ranks[right]
                if leftRank == rightRank { return .orderedSame }
                return leftRank < rightRank ? .orderedAscending : .orderedDescending
            }
            return LedgerSorter.compareCells(cells[left], cells[right], by: level)
        }
    }


    /// Where `rowIndex` would be inserted into an already-sorted index list to keep it
    /// sorted: the first position whose element does not order before `rowIndex`.
    ///
    /// O(log n) against a list this sorter produced (or any list ordered by ``compare(_:_:)``,
    /// which is a strict total order). This is what lets a one-row mutation reposition its
    /// row without re-sorting 100 000 indices.
    public func insertionIndex(for rowIndex: Int, in sortedIndices: [Int]) -> Int {
        var low = 0
        var high = sortedIndices.count
        while low < high {
            let mid = (low + high) / 2
            if compare(sortedIndices[mid], rowIndex) == .orderedAscending {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// The exact position of `rowIndex` in a list this sorter ordered, or `nil` when the
    /// row is not in the list. O(log n), by the same total-order argument.
    public func position(of rowIndex: Int, in sortedIndices: [Int]) -> Int? {
        let candidate = insertionIndex(for: rowIndex, in: sortedIndices)
        guard candidate < sortedIndices.count, sortedIndices[candidate] == rowIndex else { return nil }
        return candidate
    }

    /// Total order over two row indices. Never returns `.orderedSame` for distinct rows.
    public func compare(_ leftIndex: Int, _ rightIndex: Int) -> ComparisonResult {
        for level in levels {
            let result = compare(leftIndex, rightIndex, by: level)
            if result != .orderedSame { return result }
        }
        if leftIndex == rightIndex { return .orderedSame }
        return leftIndex < rightIndex ? .orderedAscending : .orderedDescending
    }

    private func compare(
        _ leftIndex: Int,
        _ rightIndex: Int,
        by level: Level
    ) -> ComparisonResult {
        Self.compareCells(
            store.value(at: leftIndex, definition: level.column),
            store.value(at: rightIndex, definition: level.column),
            by: level
        )
    }

    /// One level's order over two cells: the null block, then ``LedgerOrdering``, then the
    /// direction. The single comparison both the key-based sort and the row comparator use.
    private static func compareCells(
        _ left: LedgerCellResult,
        _ right: LedgerCellResult,
        by level: Level
    ) -> ComparisonResult {
        let descriptor = level.descriptor
        let leftNull = Self.nullRank(left)
        let rightNull = Self.nullRank(right)
        if leftNull != 0 || rightNull != 0 {
            if leftNull == rightNull { return .orderedSame }
            let nullFirst = descriptor.nulls == .first
            if leftNull == 0 { return nullFirst ? .orderedDescending : .orderedAscending }
            if rightNull == 0 { return nullFirst ? .orderedAscending : .orderedDescending }
            // Both null: empty before error, always.
            return leftNull < rightNull ? .orderedAscending : .orderedDescending
        }
        guard case .value(let leftValue) = left, case .value(let rightValue) = right else {
            return .orderedSame
        }
        let result = LedgerOrdering.compareValues(
            leftValue,
            rightValue,
            choiceOrder: level.choiceOrder
        )
        guard result != .orderedSame else { return .orderedSame }
        if descriptor.ascending { return result }
        return result == .orderedAscending ? .orderedDescending : .orderedAscending
    }

    /// 0 = a value, 1 = empty, 2 = error. A "No input" cell is empty here, as it is for totals,
    /// grouping and the Is empty filter (W-063); it used to sort in the error block.
    static func nullRank(_ cell: LedgerCellResult) -> Int {
        if cell.hasNoValue { return 1 }
        switch cell {
        case .error: return 2
        case .value: return 0
        }
    }
}
