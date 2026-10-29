import Foundation

/// Aggregated quantities for a group of ledger rows, or for the whole ledger.
///
/// A column only appears in ``quantities`` when every contributing row agreed on its
/// dimension. Columns where the rows disagreed are listed in ``incompatibleColumns``, and
/// the table must render those cells as an explicit "mixed units" state rather than a
/// number.
public struct LedgerTotals: Codable, Hashable, Sendable {

    /// Number of rows that contributed.
    public var rowCount: Int
    /// Summed quantity per column.
    public var quantities: [LedgerColumnID: DecimalQuantity]
    /// Formatted total per column, already rounded for display.
    public var displayValues: [LedgerColumnID: String]
    /// Columns whose rows had incompatible dimensions and were therefore not summed.
    public var incompatibleColumns: Set<LedgerColumnID>
    /// Per totalled column, how many rows carried a value into it — read off the same
    /// aggregation that made the total, so "Lengths 4" beside a length total is the number of
    /// rows in that total, and the number a "has a value" filter on the column shows (S-043,
    /// iteration 2). A column the producer aggregated has an entry, `0` when no row filled it;
    /// a column it did not aggregate (or a producer that does not count) has none.
    public var valueCounts: [LedgerColumnID: Int]

    /// Creates a totals record.
    public init(
        rowCount: Int = 0,
        quantities: [LedgerColumnID: DecimalQuantity] = [:],
        displayValues: [LedgerColumnID: String] = [:],
        incompatibleColumns: Set<LedgerColumnID> = [],
        valueCounts: [LedgerColumnID: Int] = [:]
    ) {
        self.rowCount = rowCount
        self.quantities = quantities
        self.displayValues = displayValues
        self.incompatibleColumns = incompatibleColumns
        self.valueCounts = valueCounts
    }

    private enum CodingKeys: String, CodingKey {
        case rowCount, quantities, displayValues, incompatibleColumns, valueCounts
    }

    /// Decodes a record; one written before ``valueCounts`` existed decodes with none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowCount = try container.decode(Int.self, forKey: .rowCount)
        quantities = try container.decode([LedgerColumnID: DecimalQuantity].self, forKey: .quantities)
        displayValues = try container.decode([LedgerColumnID: String].self, forKey: .displayValues)
        incompatibleColumns = try container.decode(Set<LedgerColumnID>.self, forKey: .incompatibleColumns)
        valueCounts = try container.decodeIfPresent([LedgerColumnID: Int].self, forKey: .valueCounts) ?? [:]
    }

    /// An empty totals record.
    public static let empty = LedgerTotals()

    /// The total for one column, or `nil` when the column has no compatible total.
    public func total(_ column: LedgerColumnID) -> DecimalQuantity? { quantities[column] }

    /// The formatted total for one column, empty when there is none.
    public func displayValue(_ column: LedgerColumnID) -> String { displayValues[column] ?? "" }

    /// A localized "mixed units" placeholder for an incompatible total cell.
    public static var incompatiblePlaceholder: String {
        NSLocalizedString(
            "Mixed units",
            comment: "Shown instead of a total when a column's rows have incompatible dimensions"
        )
    }
}

/// A node in the grouped Quantity Ledger outline.
///
/// A node holds either child groups or rows, never both in the same ledger configuration,
/// but both fields exist so a partially expanded outline can be described in one value.
public struct LedgerGroupNode: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the group node.
    public let id: UUID
    /// Localized group heading, for example a zone name.
    public var title: String
    /// The column the grouping was made on, or `nil` for the synthetic root.
    public var groupingColumn: LedgerColumnID?
    /// The raw grouped value, used for selection round-tripping.
    public var groupingValue: String?
    /// Nesting depth, `0` for a top-level group.
    public var depth: Int
    /// Whether the outline row is expanded.
    public var isExpanded: Bool
    /// Nested groups.
    public var children: [LedgerGroupNode]
    /// Rows that belong directly to this group.
    public var rows: [LedgerRow]
    /// Aggregates for this group, including everything in ``children``.
    public var totals: LedgerTotals
    /// Redundant colour cue taken from the grouped choice option, when there is one.
    public var colorRGBA: ColorRGBA?

    /// Creates a group node.
    public init(
        id: UUID,
        title: String,
        groupingColumn: LedgerColumnID? = nil,
        groupingValue: String? = nil,
        depth: Int = 0,
        isExpanded: Bool = true,
        children: [LedgerGroupNode] = [],
        rows: [LedgerRow] = [],
        totals: LedgerTotals = .empty,
        colorRGBA: ColorRGBA? = nil
    ) {
        self.id = id
        self.title = title
        self.groupingColumn = groupingColumn
        self.groupingValue = groupingValue
        self.depth = depth
        self.isExpanded = isExpanded
        self.children = children
        self.rows = rows
        self.totals = totals
        self.colorRGBA = colorRGBA
    }

    /// Every row in this group and its descendants, in outline order.
    public var allRows: [LedgerRow] {
        children.flatMap(\.allRows) + rows
    }

    /// Every descendant group, in outline order, excluding this node.
    public var allDescendants: [LedgerGroupNode] {
        children.flatMap { [$0] + $0.allDescendants }
    }
}
