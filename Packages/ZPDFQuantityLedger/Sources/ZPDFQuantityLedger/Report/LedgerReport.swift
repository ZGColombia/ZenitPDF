import Foundation
import ZPDFContracts
import ZPDFFormulaEngine

/// One column, as an export sees it.
public struct LedgerReportColumn: Hashable, Sendable {
    public let id: ColumnID
    public let key: String
    public let title: String
    public let kind: ColumnKind
    public let formatting: LedgerValueFormatting
    /// Present for a formula column (QUALITY_BAR A24): written into every export's metadata.
    public let aggregationSemantics: FormulaAggregationSemantics?
    /// The canonical text of the compiled formula, so an export records what was computed rather
    /// than what the user last typed.
    public let formulaCanonicalText: String?
}

/// One exported cell: the exact value, plus everything needed to present it.
public struct LedgerReportCell: Hashable, Sendable {
    public let column: ColumnID
    public let value: LedgerCellResult
    public let formatting: LedgerValueFormatting

    /// The unrounded SI magnitude for the raw column of a CSV or the numeric cell of an XLSX.
    public var rawDecimal: Decimal? { value.quantity?.value }

    /// The single-rounded display magnitude. Rounding happens here and nowhere else.
    public var displayDecimal: Decimal? { rawDecimal.map(formatting.displayDecimal) }
}

/// One exported row.
public struct LedgerReportRow: Hashable, Sendable {
    public let markupID: MarkupID
    /// Position in the store, so an export can be traced back to a row.
    public let storeIndex: Int
    public let groupPath: [LedgerGroupKey]
    public let cells: [LedgerReportCell]
    /// What kind of claim this row's quantity makes: measured, derived, or read (ADR-0012).
    ///
    /// Rule 4 of that ADR: **every exporter prints the provenance** — CSV/JSON as a column,
    /// the summary PDF as a per-row mark and a legend. It rides the report so all four
    /// formats read the one value the store holds, instead of each re-deriving it. Defaulted
    /// to `.measured` — the only claim any row could make before the ADR — so every
    /// construction written before this field keeps compiling and keeps meaning what it meant.
    public let provenance: QuantityProvenance

    /// Creates a row. Declared (rather than memberwise) so `provenance` can default to
    /// `.measured` for construction sites that predate ADR-0012.
    public init(
        markupID: MarkupID,
        storeIndex: Int,
        groupPath: [LedgerGroupKey],
        cells: [LedgerReportCell],
        provenance: QuantityProvenance = .measured
    ) {
        self.markupID = markupID
        self.storeIndex = storeIndex
        self.groupPath = groupPath
        self.cells = cells
        self.provenance = provenance
    }
}

/// One exported total.
public struct LedgerReportTotal: Hashable, Sendable {
    public let column: ColumnID
    public let function: AggregateFunction
    public let value: AggregateValue
    public let formatting: LedgerValueFormatting

    /// The exact `Decimal`, or `nil` for a refusal or an empty aggregate.
    public var rawDecimal: Decimal? { formatting.rawDecimal(of: value) }
    /// The single-rounded display magnitude, or `nil` for the same reasons.
    public var displayDecimal: Decimal? { formatting.displayDecimal(of: value) }
    /// The machine-distinguishable token an export writes when there is no number
    /// (QUALITY_BAR A14). Identical across CSV, XLSX, JSON and PDF because there is one source.
    ///
    /// Each clashing dimension is named by its ``QuantityDimension/ledgerToken``, not its base
    /// unit symbol: count and ratio share the symbol `1`, so a count-and-ratio clash used to
    /// export as `#MIXED_UNITS[1|1]`, which names neither kind (R-131). It now reads
    /// `#MIXED_UNITS[1|1:ratio]`; every other dimension's token is its base unit symbol, so
    /// `#MIXED_UNITS[m|m^2]` is unchanged.
    public var refusalToken: String? {
        switch value {
        case .mixedDimensions(let dimensions):
            "\(LedgerReport.mixedDimensionsToken)[\(dimensions.map(\.ledgerToken).joined(separator: "|"))]"
        case .failed(let code):
            "\(LedgerReport.errorToken)[\(LedgerAggregationError(code: code).description)]"
        case .empty, .quantity, .currency, .integer:
            nil
        }
    }
}

/// One exported group, with its own subtotals.
public struct LedgerReportGroup: Hashable, Sendable {
    public let key: LedgerGroupKey
    public let path: [LedgerGroupKey]
    public let depth: Int
    public let rowCount: Int
    public let subgroups: [LedgerReportGroup]
    /// Rows directly in this group. Non-empty only for a leaf group.
    public let rows: [LedgerReportRow]
    public let totals: [LedgerReportTotal]
}

/// What produced the report.
public struct LedgerReportMetadata: Hashable, Sendable {
    /// From an injected ``TimestampProviding``. Nothing in this package reads the wall clock.
    public let generatedAt: Date
    public let ledgerContractVersion: Int
    public let formulaGrammarVersion: Int
    /// Grouping levels by column key, outermost first.
    public let groupingColumnKeys: [String]
    /// Sort descriptors as `key:asc|desc:nullsFirst|nullsLast`.
    public let sortDescription: [String]
    /// A stable, machine-readable rendering of the filter tree, so an export records what it was
    /// filtered by (spec 15.8, QUALITY_BAR A35).
    public let filterDescription: String
    public let rowCount: Int
    public let totalRowCountBeforeFilter: Int
    /// The formatting of each grouping level's column, outermost first — `nil` where the column
    /// is unknown. Carried so a group keyed on a column the export does not show is still
    /// labelled in its display unit and precision (BH-531).
    public var groupingColumnFormatting: [LedgerValueFormatting?] = []
    /// Filter rules the view could not apply, in words, so every export says the filter it
    /// names was not applied in full rather than presenting the wider row set as filtered
    /// (BH-101). Supplied by the caller that translated the filter; empty means none.
    public var unappliedFilterRules: [String] = []
    /// The time zone whose calendar days a date grouping level was cut into
    /// (``LedgerGroupTree/dayCalendar``): a date group's key is midnight in this zone. Carried so
    /// an export labels and prints each date group as the day it is a bucket of, not the day
    /// its midnight falls on in another zone (C-10, I-18).
    public var dayTimeZone: TimeZone = .gmt
}

/// A stable, export-ready snapshot of one ledger view.
///
/// # What it is for
///
/// CSV, XLSX, JSON and PDF all need the same thing: the groups, the rows, the columns, the
/// totals, exact `Decimal` values, and the formatting metadata to present them. Given four
/// exporters and no shared projection, each one re-derives that from the view — and each one
/// gets a chance to invent its own rounding, its own group order, its own handling of a mixed
/// unit cell. This type is derived once so all four read the same numbers (QUALITY_BAR A25,
/// A29-A35).
///
/// Values are exact. Rounding is not applied anywhere in this structure; it is available through
/// ``LedgerValueFormatting/displayDecimal(_:)`` on each cell and total, applied once, at the
/// moment the exporter writes a string.
public struct LedgerReport: Hashable, Sendable {
    public let title: String
    public let columns: [LedgerReportColumn]
    /// The group tree. Empty for a flat ledger, in which case ``rows`` holds everything.
    public let groups: [LedgerReportGroup]
    /// Rows of a flat ledger. Empty when ``groups`` is non-empty.
    public let rows: [LedgerReportRow]
    public let grandTotals: [LedgerReportTotal]
    public let metadata: LedgerReportMetadata

    /// The token every export writes in a cell that cannot be totalled. One spelling, four
    /// formats. The user-facing wording is owned by `Docs/Design/UX_COPY_STANDARD.md`; this is
    /// the machine-distinguishable form the golden export fixtures assert on.
    public static let mixedDimensionsToken = "#MIXED_UNITS"
    /// The same idea for an aggregate that failed arithmetically.
    public static let errorToken = "#ERROR"

    /// Every row of the report in export order, flat or grouped.
    public func allRows() -> [LedgerReportRow] {
        guard groups.isEmpty else {
            var output: [LedgerReportRow] = []
            output.reserveCapacity(metadata.rowCount)
            func visit(_ group: LedgerReportGroup) {
                output.append(contentsOf: group.rows)
                for subgroup in group.subgroups { visit(subgroup) }
            }
            for group in groups { visit(group) }
            return output
        }
        return rows
    }
}
