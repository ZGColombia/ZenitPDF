// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation

/// The preview mock's grouped outline, shaped the way the aggregation core's outline is shaped
/// (IM-011, R-129).
///
/// The Quantity Ledger table has one aggregation path: it draws the presenter's outline
/// (`LedgerPresenting.suppliesDisplayOrderedOutline`) and never folds rows itself. The
/// application's presenter publishes the aggregation core's group tree. The mock has no core
/// behind it — this package does not depend on ZPDFQuantityLedger — so it builds its own tree
/// here, from its in-memory rows, and publishes it under the same three promises:
///
///   * display order is group order: ``order`` lists the input rows leaf by leaf, in outline
///     order, so each node covers the next `totals.rowCount` display positions;
///   * every node's `totals.rowCount` counts its descendants' rows;
///   * every node's totals, and ``grandTotals``, carry each summed quantity column
///     (``LedgerTotals/mockSumming(rows:columns:format:)``) and the display `Value` column's
///     merged total (``LedgerDefaultColumns/valueColumnID``).
///
/// Mock and test code only. What used to be the table's own in-memory fold
/// (`LedgerGroupingEngine.build`, `LedgerSubtotalAccumulator`) ships nowhere any more; the
/// grouping rules it applied live on here so previews and the shell tests keep realistic
/// groups: rows with no value come last, choice groups follow the option order, numbers
/// compare numerically, dates group by calendar day, and a check box reads as a state.
public struct MockLedgerOutline: Sendable {

    /// Input row indices in display order: the leaves' rows concatenated in outline order.
    /// The identity for an ungrouped outline.
    public let order: [Int]
    /// The top-level groups, empty for an ungrouped outline.
    public let rootGroups: [LedgerGroupNode]
    /// Totals over every input row.
    public let grandTotals: LedgerTotals

    /// Separator between the key components that name a node. Not user visible.
    static let pathSeparator = "\u{001F}"

    /// Heading of the group of rows that have no value in the grouped column.
    public static var emptyGroupTitle: String {
        NSLocalizedString("(No value)", comment: "Heading for the ledger group of rows with no value in the grouped column")
    }

    /// Partitions, orders and totals `rows`.
    ///
    /// - Parameters:
    ///   - rows: The rows, already filtered and sorted. Rows keep this order inside a group.
    ///   - groupingColumns: Levels, outermost first, taken as given. Empty is the flat outline.
    ///   - columns: The column definitions: choice order and colours, and the summed columns.
    ///   - format: Renders a total into display text.
    public static func build(
        rows: [LedgerRow],
        groupingColumns: [LedgerColumnID],
        columns: [LedgerColumn],
        format: (DecimalQuantity) -> String = { SampleFormatting.string($0) }
    ) -> MockLedgerOutline {
        let grand = totals(rows, columns: columns, format: format)
        guard !groupingColumns.isEmpty, !rows.isEmpty else {
            return MockLedgerOutline(order: Array(rows.indices), rootGroups: [], grandTotals: grand)
        }
        let levels = groupingColumns.map { Level(column: $0, columns: columns) }
        let keys = rows.map { row in levels.map { $0.key(for: row) } }
        let sortKeys = rows.indices.map { index in
            levels.indices.map { levels[$0].sortKey(for: rows[index], key: keys[index][$0]) }
        }
        let order = rows.indices.sorted { lhs, rhs in
            for level in levels.indices where keys[lhs][level] != keys[rhs][level] {
                let comparison = SortKey.compare(sortKeys[lhs][level], sortKeys[rhs][level])
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return keys[lhs][level] < keys[rhs][level]
            }
            return lhs < rhs
        }

        func nodes(depth: Int, range: Range<Int>, parentPath: String) -> [LedgerGroupNode] {
            var result: [LedgerGroupNode] = []
            var start = range.lowerBound
            while start < range.upperBound {
                let key = keys[order[start]][depth]
                var end = start + 1
                while end < range.upperBound, keys[order[end]][depth] == key { end += 1 }
                let path = parentPath.isEmpty ? key : parentPath + pathSeparator + key
                let members = order[start..<end].map { rows[$0] }
                let isLeaf = depth + 1 == levels.count
                let level = levels[depth]
                result.append(LedgerGroupNode(
                    id: identity(for: path),
                    title: level.title(for: rows[order[start]], key: key),
                    groupingColumn: level.column,
                    groupingValue: key,
                    depth: depth,
                    isExpanded: true,
                    children: isLeaf ? [] : nodes(depth: depth + 1, range: start..<end, parentPath: path),
                    rows: isLeaf ? members : [],
                    totals: totals(members, columns: columns, format: format),
                    colorRGBA: level.colours[key]
                ))
                start = end
            }
            return result
        }

        return MockLedgerOutline(
            order: order,
            rootGroups: nodes(depth: 0, range: 0..<order.count, parentPath: ""),
            grandTotals: grand
        )
    }

    // MARK: Totals

    /// The mock's totals for a set of rows: the summed quantity columns, plus the merged
    /// `Value` total.
    public static func totals(
        _ rows: [LedgerRow],
        columns: [LedgerColumn],
        format: (DecimalQuantity) -> String = { SampleFormatting.string($0) }
    ) -> LedgerTotals {
        var totals = LedgerTotals.mockSumming(rows: rows, columns: columns) { _, quantity in format(quantity) }
        var merged = MergedValue()
        for row in rows { merged.add(LedgerDefaultColumns.primaryQuantity(for: row)) }
        merged.apply(to: &totals, format: format)
        return totals
    }

    /// The display `Value` column's merged total: each row's primary quantity, exact, refused
    /// the moment two dimensions meet. A slope ratio or an angle is a fact about one markup and
    /// never adds up (QUALITY_BAR A14, BH-240), so a group holding one has no `Value` total.
    /// The first refusal stands, as in the application's bridge.
    private struct MergedValue {
        var sum: Decimal = 0
        var dimension: QuantityDimension?
        var isMixed = false
        var isNonAdditive = false
        var isFailed = false

        mutating func add(_ quantity: DecimalQuantity?) {
            guard let quantity, !isMixed, !isNonAdditive, !isFailed else { return }
            if quantity.dimension.ratio || quantity.dimension.angle {
                isNonAdditive = true
                return
            }
            if let dimension, !dimension.isCompatible(with: quantity.dimension) {
                isMixed = true
                return
            }
            var left = sum
            var right = quantity.value
            var result = Decimal()
            guard NSDecimalAdd(&result, &left, &right, .plain) == .noError else {
                isFailed = true
                return
            }
            sum = result
            dimension = quantity.dimension
        }

        func apply(to totals: inout LedgerTotals, format: (DecimalQuantity) -> String) {
            let id = LedgerDefaultColumns.valueColumnID
            if isFailed {
                totals.incompatibleColumns.insert(id)
                totals.displayValues[id] = NSLocalizedString(
                    "Cannot total", comment: "Ledger total cell when the total could not be computed"
                )
            } else if isMixed {
                totals.incompatibleColumns.insert(id)
                totals.displayValues[id] = LedgerTotals.incompatiblePlaceholder
            } else if !isNonAdditive, let dimension {
                let quantity = DecimalQuantity(value: sum, dimension: dimension)
                totals.quantities[id] = quantity
                totals.displayValues[id] = format(quantity)
            }
        }
    }

    // MARK: Grouping keys

    /// One grouping level: its column, its choice order and its choice colours.
    private struct Level {
        let column: LedgerColumnID
        let ranks: [String: Int]
        let colours: [String: ColorRGBA]

        init(column: LedgerColumnID, columns: [LedgerColumn]) {
            self.column = column
            let choices = columns.first { $0.id == column }?.choices ?? []
            let ranked = choices.enumerated().sorted {
                $0.element.order != $1.element.order ? $0.element.order < $1.element.order : $0.offset < $1.offset
            }
            var ranks: [String: Int] = [:]
            for (rank, entry) in ranked.enumerated() where ranks[entry.element.value] == nil {
                ranks[entry.element.value] = rank
            }
            self.ranks = ranks
            var colours: [String: ColorRGBA] = [:]
            for option in choices { colours[option.value] = option.colorRGBA }
            self.colours = colours
        }

        /// The canonical key of one cell. The Type column partitions by tool exactly as the
        /// drawn Type cell reads; a number keeps no trailing zeros, so
        /// 10 and 10.00 are one group; a date is its calendar day (BH-730).
        func key(for row: LedgerRow) -> String {
            if column == .icon || LedgerDefaultColumns.isDisplayColumn(column) {
                return LedgerDefaultColumns.displayText(for: row, columnID: column)
            }
            switch row.value(column) {
            case .empty:
                return row.displayValue(column)
            case let .text(text):
                return text
            case let .choice(value):
                return value
            case let .number(value):
                return Self.canonical(value)
            case let .quantity(quantity):
                return Self.canonical(quantity.value)
            case let .currency(amount, code):
                return "\(Self.canonical(amount)) \(code)"
            case let .date(date):
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            case let .checkbox(flag):
                return flag ? "1" : "0"
            }
        }

        /// Where a key sorts: no value last (CR-65), choices by option order (BH-239), numbers
        /// numerically (BH-730), anything else as the reader reads text.
        func sortKey(for row: LedgerRow, key: String) -> SortKey {
            guard !key.isEmpty else { return .empty }
            switch row.value(column) {
            case let .choice(value):
                return ranks[value].map(SortKey.rank) ?? .text(key)
            case let .number(value):
                return .number(value)
            case let .quantity(quantity):
                return .number(quantity.value)
            default:
                return .text(key)
            }
        }

        /// The heading: a check box reads as a state (BH-728), otherwise the cell's own text.
        func title(for row: LedgerRow, key: String) -> String {
            guard !key.isEmpty else { return MockLedgerOutline.emptyGroupTitle }
            if case let .checkbox(flag) = row.value(column) {
                return flag
                    ? NSLocalizedString("Checked", comment: "Heading for the ledger group of rows whose check box is ticked")
                    : NSLocalizedString("Not checked", comment: "Heading for the ledger group of rows whose check box is not ticked")
            }
            let display = row.displayValue(column)
            return display.isEmpty ? key : display
        }

        static func canonical(_ value: Decimal) -> String {
            NSDecimalNumber(decimal: value.isZero ? Decimal.zero : value).stringValue
        }
    }

    /// How two keys order.
    private enum SortKey {
        case empty
        case rank(Int)
        case number(Decimal)
        case text(String)

        static func compare(_ lhs: SortKey, _ rhs: SortKey) -> ComparisonResult {
            switch (lhs, rhs) {
            case (.empty, .empty): return .orderedSame
            case (.empty, _): return .orderedDescending
            case (_, .empty): return .orderedAscending
            case let (.rank(a), .rank(b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            case (.rank, _): return .orderedAscending
            case (_, .rank): return .orderedDescending
            case let (.number(a), .number(b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            case (.number, _): return .orderedAscending
            case (_, .number): return .orderedDescending
            case let (.text(a), .text(b)): return a.localizedStandardCompare(b)
            }
        }
    }

    /// A stable node identity for a group path, so a regroup keeps expansion and selection.
    static func identity(for path: String) -> UUID {
        var hashA: UInt64 = 0xCBF2_9CE4_8422_2325
        var hashB: UInt64 = 0x9E37_79B9_7F4A_7C15
        for byte in path.utf8 {
            hashA = (hashA ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            hashB = (hashB &+ UInt64(byte) &+ 1) &* 0x8864_3F65_F4A6_1B9D
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for offset in 0..<8 {
            bytes[offset] = UInt8(truncatingIfNeeded: hashA >> (8 * UInt64(offset)))
            bytes[8 + offset] = UInt8(truncatingIfNeeded: hashB >> (8 * UInt64(offset)))
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
#endif
