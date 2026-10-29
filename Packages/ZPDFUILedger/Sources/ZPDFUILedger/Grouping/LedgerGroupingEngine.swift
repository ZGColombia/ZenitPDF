import Foundation
import ZPDFUIPresentation

/// One node of the grouped ledger outline.
///
/// A slice never carries rows. It carries a *range* into ``LedgerGroupPlan/order``, so a
/// group of fifty thousand rows costs the same as a group of two.
public struct LedgerGroupSlice: Hashable, Sendable, Identifiable {

    /// Stable identity derived from ``path``, so expansion survives a rebuild.
    public let id: UUID
    /// A separator-joined key chain, unique in the outline.
    public let path: String
    /// The heading shown to the user.
    public let title: String
    /// The column that produced the grouping level.
    public let column: LedgerColumnID?
    /// The raw grouped value, used for round-tripping selection and filters.
    public let value: String
    /// Nesting depth, `0` for a top-level group.
    public let depth: Int
    /// Range of display positions covered by this group, including descendants.
    public let rowRange: Range<Int>
    /// Nested groups, empty for a leaf group that holds rows directly.
    public let children: [LedgerGroupSlice]
    /// Aggregates for every row in this group and its descendants.
    public let subtotals: LedgerSubtotals
    /// Whether the outline row is expanded.
    public let isExpanded: Bool
    /// Redundant colour cue from the grouped choice option, when there is one.
    public let colorRGBA: ColorRGBA?

    /// Creates a group slice.
    public init(
        path: String,
        title: String,
        column: LedgerColumnID?,
        value: String,
        depth: Int,
        rowRange: Range<Int>,
        children: [LedgerGroupSlice],
        subtotals: LedgerSubtotals,
        isExpanded: Bool,
        colorRGBA: ColorRGBA? = nil
    ) {
        self.id = LedgerGroupSlice.identity(for: path)
        self.path = path
        self.title = title
        self.column = column
        self.value = value
        self.depth = depth
        self.rowRange = rowRange
        self.children = children
        self.subtotals = subtotals
        self.isExpanded = isExpanded
        self.colorRGBA = colorRGBA
    }

    /// Whether the group holds rows directly rather than child groups.
    public var isLeaf: Bool { children.isEmpty }

    /// Number of rows underneath the group.
    public var rowCount: Int { rowRange.count }

    /// A localized VoiceOver label: heading, row count and the headline total.
    public func accessibilityLabel(
        totalColumn: LedgerColumnID?,
        policy: LedgerUnitPolicy = .metric,
        rounding: LedgerRounding = .exact
    ) -> String {
        // U-066: the row count reads "1 row" / "3 rows" (LedgerPlurals), not "1 rows".
        let format = NSLocalizedString(
            "%1$@, %2$@",
            comment: "VoiceOver label for a ledger group: title, then the number of rows (\"3 rows\")"
        )
        var label = String(format: format, title, LedgerPlurals.rows(rowCount))
        if let totalColumn, let result = subtotals.result(totalColumn) {
            let text = result.displayText(policy: policy, rounding: rounding)
            if !text.isEmpty {
                let suffix = NSLocalizedString(
                    "%1$@, total %2$@",
                    comment: "VoiceOver suffix for a ledger group total: existing label, total"
                )
                label = String(format: suffix, label, text)
            }
        }
        return label
    }

    /// A stable UUID for a group path, so `NSOutlineView` expansion state round-trips.
    public static func identity(for path: String) -> UUID {
        var hashA: UInt64 = 0xCBF2_9CE4_8422_2325
        var hashB: UInt64 = 0x9E37_79B9_7F4A_7C15
        for byte in Array(path.utf8) {
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

/// The outline produced by grouping a ledger.
public struct LedgerGroupPlan: Hashable, Sendable {

    /// Source row indices in outline order. Group ranges index into this array.
    public let order: [Int]
    /// Top-level groups.
    public let groups: [LedgerGroupSlice]
    /// Aggregates over every row in the plan.
    public let grandSubtotals: LedgerSubtotals
    /// The grouping columns the plan was built with, outermost first.
    public let groupingColumns: [LedgerColumnID]

    /// Creates a plan.
    public init(
        order: [Int],
        groups: [LedgerGroupSlice],
        grandSubtotals: LedgerSubtotals,
        groupingColumns: [LedgerColumnID]
    ) {
        self.order = order
        self.groups = groups
        self.grandSubtotals = grandSubtotals
        self.groupingColumns = groupingColumns
    }

    /// An empty plan.
    public static let empty = LedgerGroupPlan(
        order: [],
        groups: [],
        grandSubtotals: .empty,
        groupingColumns: []
    )

    /// Number of group nodes at every level.
    ///
    /// Counted by walking the tree rather than by flattening it: the accessibility summary
    /// reads this on every SwiftUI body evaluation, and a flattened copy would allocate one
    /// array per node each time.
    public var groupCount: Int {
        func count(_ slices: [LedgerGroupSlice]) -> Int {
            slices.reduce(0) { $0 + 1 + count($1.children) }
        }
        return count(groups)
    }

    /// Translates an outline position into the index the row source understands.
    public func sourceIndex(displayPosition: Int) -> Int? {
        order.indices.contains(displayPosition) ? order[displayPosition] : nil
    }

    /// Every group path, so "expand all" can be expressed as a set.
    public var allPaths: Set<String> {
        var paths: Set<String> = []
        func collect(_ slices: [LedgerGroupSlice]) {
            for slice in slices {
                paths.insert(slice.path)
                collect(slice.children)
            }
        }
        collect(groups)
        return paths
    }
}

/// The table's grouping vocabulary: how a slice's path is joined.
///
/// The table builds no outline of its own (IM-011, R-129). Every heading and subtotal comes
/// from the row source's outline (``LedgerGroupPlanProviding``) — for the application, the
/// aggregation core's group tree through ``LedgerPresenterRowSource``. A source that supplies
/// none is listed flat. The in-memory fold that used to live here, `build` and its subtotal
/// accumulator, was a second aggregation engine and is gone; the preview mock builds its
/// outline with `MockLedgerOutline` in ZPDFUIPresentation, whose `key(for:)` is the one
/// group-key rule outside the core. An uncalled copy of that rule, `groupKey(for:column:)`,
/// was removed in loop iteration 3 (T-053).
public enum LedgerGroupingEngine {

    /// Separator between key components in ``LedgerGroupSlice/path``. Not user visible.
    public static let pathSeparator = "\u{001F}"
}
