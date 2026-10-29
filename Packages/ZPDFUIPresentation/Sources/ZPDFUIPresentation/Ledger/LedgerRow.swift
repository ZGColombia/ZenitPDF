import Foundation

/// The value stored in one ledger cell.
///
/// Quantity cells keep their dimension so that a column can refuse to sum values that do
/// not belong together, rather than producing a silently wrong total.
public enum LedgerCellValue: Codable, Hashable, Sendable {

    /// No value.
    case empty
    /// Free text.
    case text(String)
    /// A dimensionless number.
    case number(Decimal)
    /// A dimensioned quantity in SI base units.
    case quantity(DecimalQuantity)
    /// A monetary amount together with its ISO 4217 code.
    case currency(amount: Decimal, code: String)
    /// A calendar date.
    case date(Date)
    /// A boolean.
    case checkbox(Bool)
    /// The stored value of a choice option.
    case choice(String)

    /// The dimension of the value, or `nil` for values that carry none.
    ///
    /// **A free-typed number has no dimension of its own.** It used to be answered `.ratio`
    /// here, and before ADR-0014 that was harmless because a ratio and a count were the same
    /// value. They are not any more, so an untyped `12` in a Count column would refuse to add
    /// to the counts beside it. The column knows what its numbers are; the cell does not. Use
    /// ``dimension(inColumn:)`` wherever a column is in hand — which is everywhere a total is
    /// built — and read this one as "dimensionless, kind unknown" (ADR-0014 §3).
    public var dimension: QuantityDimension? {
        switch self {
        case .quantity(let quantity): return quantity.dimension
        case .currency(_, let code): return .currency(code)
        // BH-764: the same answer `asQuantity(inColumn: nil)` gives — an undeclared number is
        // a count — so a caller checking compatibility and a caller summing agree.
        case .number: return dimension(inColumn: nil)
        case .empty, .text, .date, .checkbox, .choice: return nil
        }
    }

    /// The dimension of the value **as the column declares it**.
    ///
    /// A stored quantity keeps its own dimension — it was measured, and the measurement is the
    /// authority. A free-typed number takes the column's, because a number typed into a Count
    /// column is a count and the same number typed into a Waste column is a factor; nothing
    /// about the digits says which. A column that declares no dimension leaves the number
    /// dimensionless-untagged, which is a count, matching the contracts' decoder.
    public func dimension(inColumn column: QuantityDimension?) -> QuantityDimension? {
        switch self {
        case .quantity(let quantity): return quantity.dimension
        case .currency(_, let code): return .currency(code)
        // The column decides, full stop. With no declaration the number is
        // dimensionless-untagged — a count — which is what the contracts' decoder also does
        // with a stored dimensionless value nothing has re-tagged.
        case .number: return column ?? .count
        case .empty, .text, .date, .checkbox, .choice: return nil
        }
    }

    /// The value as a `DecimalQuantity`, or `nil` when it is not numeric.
    ///
    /// See ``dimension`` for why a free-typed number is not a ratio by default. Prefer
    /// ``asQuantity(inColumn:)`` wherever the column is known.
    public var asQuantity: DecimalQuantity? {
        asQuantity(inColumn: nil)
    }

    /// The value as a `DecimalQuantity`, with a free-typed number taking the column's declared
    /// dimension (ADR-0014 §3).
    public func asQuantity(inColumn column: QuantityDimension?) -> DecimalQuantity? {
        switch self {
        case .quantity(let quantity): return quantity
        case .currency(let amount, let code): return DecimalQuantity.money(amount, code: code)
        case .number(let value):
            return DecimalQuantity(value: value, dimension: dimension(inColumn: column) ?? .count)
        case .empty, .text, .date, .checkbox, .choice: return nil
        }
    }

    /// The value as plain text, for text-based filters and CSV export of raw values.
    public var asText: String? {
        switch self {
        case .text(let string): return string
        case .choice(let value): return value
        case .empty, .number, .quantity, .currency, .date, .checkbox: return nil
        }
    }

    /// Whether the cell holds nothing.
    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

/// One row of the Quantity Ledger, backed by exactly one markup.
///
/// Both the raw values and the formatted strings travel together so that a virtualised
/// table can draw a row without touching the formatter or the database.
public struct LedgerRow: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity, equal to ``markupID``.
    public var id: UUID { markupID }
    /// The markup this row represents.
    public let markupID: UUID
    /// Parent row for a cutout child, or `nil` for a top-level row.
    public var parentID: UUID?
    /// Raw cell values keyed by column.
    public var values: [LedgerColumnID: LedgerCellValue]
    /// Formatted cell strings keyed by column, already rounded for display.
    public var displayValues: [LedgerColumnID: String]
    /// Markup colour, drawn as the row's leading swatch.
    public var colorRGBA: ColorRGBA
    /// Markup family, drawn in the icon column.
    public var kind: MarkupKind
    /// Measurement tool that produced the row, or `nil`.
    public var measurementKind: MeasurementKind?
    /// Whether the row passes the active filter. Rows that fail can still be shown dimmed.
    public var matchesFilter: Bool
    /// Whether the row's markup is locked.
    public var locked: Bool
    /// Whether the row's markup is hidden on the canvas.
    public var hidden: Bool
    /// Where the row's quantity came from; `nil` is an ordinary measured row (BH-314). Optional so rows encoded before it existed still decode.
    public var provenance: LedgerRowProvenance?
    /// Why a cell shows an error word instead of a value, keyed by column: the formula engine's
    /// diagnostic, which names the failing sub-expression (T-057). The table shows it as the
    /// cell's help tag and VoiceOver help. `nil` when no cell of the row failed; optional so rows
    /// encoded before it existed still decode.
    public var cellNotes: [LedgerColumnID: String]?

    /// The diagnostic behind an error cell in `column`, or `nil` for a cell that did not fail.
    public func cellNote(_ column: LedgerColumnID) -> String? {
        cellNotes?[column]
    }

    /// Whether the quantity was read from a schedule table rather than measured.
    public var isRead: Bool { provenance == .read }

    /// Creates a ledger row.
    public init(
        markupID: UUID,
        parentID: UUID? = nil,
        values: [LedgerColumnID: LedgerCellValue],
        displayValues: [LedgerColumnID: String],
        colorRGBA: ColorRGBA,
        kind: MarkupKind,
        measurementKind: MeasurementKind? = nil,
        matchesFilter: Bool = true,
        locked: Bool = false,
        hidden: Bool = false
    ) {
        self.markupID = markupID
        self.parentID = parentID
        self.values = values
        self.displayValues = displayValues
        self.colorRGBA = colorRGBA
        self.kind = kind
        self.measurementKind = measurementKind
        self.matchesFilter = matchesFilter
        self.locked = locked
        self.hidden = hidden
    }

    /// The raw value in a column, `.empty` when the column has no value on this row.
    public func value(_ column: LedgerColumnID) -> LedgerCellValue {
        values[column] ?? .empty
    }

    /// The formatted string for a column, empty when there is nothing to show.
    public func displayValue(_ column: LedgerColumnID) -> String {
        displayValues[column] ?? ""
    }

    /// The quantity in a column, or `nil` when the cell is not numeric.
    ///
    /// Without the column's declared dimension a free-typed number is dimensionless-untagged,
    /// which is a count. Use ``quantity(_:declaring:)`` wherever the column definition is in
    /// hand.
    public func quantity(_ column: LedgerColumnID) -> DecimalQuantity? {
        value(column).asQuantity
    }

    /// The quantity in a column, resolved against the column's declared dimension (ADR-0014 §3).
    public func quantity(_ column: LedgerColumnID, declaring dimension: QuantityDimension?) -> DecimalQuantity? {
        value(column).asQuantity(inColumn: dimension)
    }

    /// A localized VoiceOver label built from the visible columns of this row.
    ///
    /// - Parameter columns: The columns currently on screen, in display order.
    public func accessibilityLabel(columns: [LedgerColumn]) -> String {
        let parts = columns
            .filter { $0.visible && $0.id != .icon && $0.id != .color }
            .compactMap { column -> String? in
                let text = displayValue(column.id)
                guard !text.isEmpty else { return nil }
                return "\(column.title): \(text)"
            }
        return parts.joined(separator: ", ")
    }
}

/// One level of ledger sorting.
public struct LedgerSortDescriptor: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity, equal to ``column``.
    public var id: LedgerColumnID { column }
    /// The column to sort by.
    public var column: LedgerColumnID
    /// Whether the sort runs low to high.
    public var ascending: Bool

    /// Creates a sort descriptor.
    public init(column: LedgerColumnID, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// Where a ledger row's quantity came from (BH-314).
public enum LedgerRowProvenance: String, Codable, Hashable, Sendable {
    /// Measured on the drawing.
    case measured
    /// Read from a table on the drawing (Table Import), not measured.
    case read

    /// The glyph a row leader shows for a read row, and its spoken form.
    public var leaderGlyph: String? { self == .read ? "\u{2310}" : nil }

    /// What VoiceOver says for the provenance, or `nil` for a measured row.
    public var accessibilityLabel: String? {
        self == .read
            ? NSLocalizedString("read from a table", comment: "Accessibility: a ledger row whose quantity was read from a schedule table")
            : nil
    }
}
