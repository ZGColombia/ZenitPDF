import Foundation
import ZPDFContracts

/// One exported number, in every form any of the four formats needs.
///
/// All five members are derived from the same `Decimal` by the same call, inside
/// ``ExportProjector``. No exporter converts a unit, applies a precision or formats a digit; by
/// the time a value reaches CSV, JSON, PDF or XLSX code, the arithmetic is over
/// (QUALITY_BAR A29, A30).
public struct ExportNumber: Hashable, Sendable {
    /// The exact stored value, in the SI base unit of its dimension. Unrounded, unconverted.
    public let raw: Decimal
    /// ``raw`` expressed in the column's display unit. Exact — converted but **not** rounded.
    public let convertedRaw: Decimal
    /// ``convertedRaw`` with the column's precision applied. Rounded exactly once, here.
    public let display: Decimal
    /// ``display`` rendered in the projection's number locale. The string the user sees.
    public let text: String
    /// ``raw`` as a locale-independent decimal string, for the JSON interchange.
    public let invariantRawText: String
    public let unitSymbol: String
    public let dimension: QuantityDimension?
    /// How many fraction digits ``text`` carries, or `nil` when the digit count is not a fixed
    /// number — an imperial length spelled in feet and inches has no decimal count at all.
    ///
    /// Per cell, not per column: a `Count` total on a three-place length column is the integer
    /// `12`, and a currency column with no declared precision holds `125.5` on one row and
    /// `12.3456` on the next. The column's digit count described none of them, and the workbook
    /// that formatted every cell with it showed `12.000`, `126` and `12` where the CSV and the
    /// PDF said `12`, `125.5` and `12.3456` (BH-139, BH-140, BH-141, BH-149, BH-150).
    public let decimalPlaces: Int?
    /// The Excel number-format code that renders ``convertedRaw`` as ``text`` reads: the
    /// per-cell counterpart of ``ExportColumn/numberFormatCode``, and the one the XLSX exporter
    /// applies. For a feet-and-inches length — a spelling no spreadsheet number format can
    /// produce — it is decimal feet to four places, which resolves a sixty-fourth of an inch.
    public let numberFormatCode: String

    init(
        raw: Decimal,
        convertedRaw: Decimal,
        display: Decimal,
        text: String,
        invariantRawText: String,
        unitSymbol: String,
        dimension: QuantityDimension?,
        decimalPlaces: Int? = nil,
        numberFormatCode: String = ExportProjector.generalNumberFormatCode
    ) {
        self.raw = raw
        self.convertedRaw = convertedRaw
        self.display = display
        self.text = text
        self.invariantRawText = invariantRawText
        self.unitSymbol = unitSymbol
        self.dimension = dimension
        self.decimalPlaces = decimalPlaces
        self.numberFormatCode = numberFormatCode
    }
}

/// One exported date. ISO-8601 in all four formats, so there is nothing for a locale to disagree
/// about and nothing for a reader to guess.
public struct ExportDate: Hashable, Sendable {
    public let date: Date
    public let iso8601: String
    /// The same instant written the way a person reads it — `29 Aug 2026`.
    ///
    /// The three machine formats keep ``iso8601``: a CSV, a workbook and the interchange JSON are
    /// parsed, and a parser wants an unambiguous instant. The printed report is read by a human
    /// being holding a sheet of paper, and `2026-08-29T14:55:25Z` on a takeoff summary is a
    /// timestamp pretending to be a date (live-test finding LT-19). So the report — and only the
    /// report — prints this instead.
    ///
    /// Built from a fixed Gregorian calendar with fixed English month names, for the same reason
    /// ``ExportProjector/iso8601(_:)`` is: no `DateFormatter`, no ICU version, no user regional
    /// settings, so two renders of the same projection on two machines produce the same bytes
    /// (QUALITY_BAR A34). The calendar day is taken in
    /// ``ExportProjectionOptions/humanDateTimeZone`` — UTC unless the caller says otherwise, and
    /// the on-screen ledger's zone when it does, so a markup created at 00:30 local time is
    /// dated the same day on paper as on screen (BH-533).
    public let humanText: String

    init(date: Date, iso8601: String, humanText: String? = nil) {
        self.date = date
        self.iso8601 = iso8601
        self.humanText = humanText ?? ExportProjector.humanDate(date)
    }
}

/// One exported cell, already resolved to what will be written.
public enum ExportCell: Hashable, Sendable {
    case blank
    case text(String)
    case number(ExportNumber)
    case date(ExportDate)
    case boolean(Bool)
    /// A value that is not a number and must not be rendered as one: mixed dimensions, or a cell
    /// or aggregate that failed. Carries the machine-distinguishable token from
    /// ``ZPDFQuantityLedger/LedgerReport`` so the same spelling appears in all four formats
    /// (QUALITY_BAR A11, A14).
    case refusal(token: String)

    /// The single string every format writes for this cell. There is one, and this is it.
    public var text: String {
        switch self {
        case .blank: ""
        case .text(let value): value
        case .number(let number): number.text
        case .date(let value): value.iso8601
        case .boolean(let flag): flag ? "TRUE" : "FALSE"
        case .refusal(let token): token
        }
    }

    public var number: ExportNumber? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var isRefusal: Bool {
        if case .refusal = self { return true }
        return false
    }
}

/// One exported column.
public struct ExportColumn: Hashable, Sendable {
    public let key: String
    public let title: String
    public let kind: ColumnKind
    /// `m²`, `ft`, `SEK`, or empty for a column that carries no unit.
    public let unitSymbol: String
    /// Decimal places for a metric precision; `nil` for a column with no declared precision or
    /// an imperial fraction precision, where the digit count is not fixed.
    public let decimalPlaces: Int?
    /// The Excel number-format code that renders ``ExportNumber/display`` the way
    /// ``ExportNumber/text`` reads. `nil` for a non-numeric column.
    public let numberFormatCode: String?
    /// `evaluateThenAggregate` / `aggregateThenEvaluate`, for a formula column (QUALITY_BAR A24).
    public let aggregationSemantics: String?
    public let formulaCanonicalText: String?
    /// The ledger column's stable id, so a formula's `[col:UUID]` reference can be resolved to
    /// the exported cell it reads (NL-QTY-13). `nil` only for a column made outside the projector.
    public let columnID: ColumnID?

    public var isNumeric: Bool {
        switch kind {
        case .number, .currency, .formula: true
        case .text, .date, .checkbox, .choice: false
        }
    }

    init(
        key: String,
        title: String,
        kind: ColumnKind,
        unitSymbol: String,
        decimalPlaces: Int?,
        numberFormatCode: String?,
        aggregationSemantics: String?,
        formulaCanonicalText: String?,
        columnID: ColumnID? = nil
    ) {
        self.columnID = columnID
        self.key = key
        self.title = title
        self.kind = kind
        self.unitSymbol = unitSymbol
        self.decimalPlaces = decimalPlaces
        self.numberFormatCode = numberFormatCode
        self.aggregationSemantics = aggregationSemantics
        self.formulaCanonicalText = formulaCanonicalText
    }
}

/// One exported row. Cells are positional and parallel to ``ExportTable/columns``.
public struct ExportRow: Hashable, Sendable {

    /// The header of the provenance column CSV and XLSX append (ADR-0012 rule 4), spelled once.
    public static let provenanceColumnTitle = "Provenance"

    public let markupID: String
    public let storeIndex: Int
    public let groupPath: [String]
    public let cells: [ExportCell]
    /// Sheet, scale-at-measure-time, dates and author (feature 16). `nil` when the caller supplied
    /// no trace for this markup — see ``ExportRowTrace/unknown`` for what the formats then print.
    public let trace: ExportRowTrace?
    /// What kind of claim this row's quantity makes (ADR-0012 rule 4): the raw value of
    /// ``ZPDFContracts/QuantityProvenance`` — `measured`, `derived` or `read`. Defaulted to
    /// `measured`, the only claim any row could make before that ADR, so every construction
    /// written before this field keeps compiling and keeps meaning what it meant.
    public let provenance: String
    /// Whether this row's value was kept under an older version of its scale when the scale
    /// changed (ADR-0030 §2, K-04): measured correctly, but not at the scale in force now.
    public let keptUnderOlderScale: Bool

    /// The header of the column CSV and XLSX append when any row was kept under an older scale.
    public static let scaleStatusColumnTitle = "Scale status"
    /// What that column says on such a row.
    public static let keptUnderOlderScaleText = "kept under an older scale"

    init(
        markupID: String,
        storeIndex: Int,
        groupPath: [String],
        cells: [ExportCell],
        trace: ExportRowTrace? = nil,
        provenance: String = QuantityProvenance.measured.rawValue,
        keptUnderOlderScale: Bool = false
    ) {
        self.markupID = markupID
        self.storeIndex = storeIndex
        self.groupPath = groupPath
        self.cells = cells
        self.trace = trace
        self.provenance = provenance
        self.keptUnderOlderScale = keptUnderOlderScale
    }

    /// The scale-status field for this row: the words on a kept row, empty otherwise.
    public var scaleStatusText: String { keptUnderOlderScale ? Self.keptUnderOlderScaleText : "" }

    /// `true` for the default claim — the one the formats may leave unlabelled, because a table
    /// of nothing but measured rows mixes nothing (ADR-0012 rule 4).
    public var makesMeasuredClaim: Bool {
        provenance == QuantityProvenance.measured.rawValue
    }

    /// The mark the printed report draws beside this row: ADR-0012 rule 5's glyph vocabulary,
    /// reused so the PDF and the ledger say "derived" and "read" with the same character.
    /// `nil` for a measured row, which carries no mark — the legend says so.
    public var provenanceGlyph: String? {
        switch QuantityProvenance(rawValue: provenance) {
        case .derived: "\u{0192}" // ƒ
        case .read: "\u{2310}"    // ⌐
        case .measured, nil: nil
        }
    }
}

/// One subtotal or grand total. Positional against ``ExportTable/columns``: a column with no
/// planned aggregate carries ``ExportCell/blank``.
public struct ExportTotalRow: Hashable, Sendable {
    /// `Sum`, `Count`, `Average`, ... — the aggregate function, spelled once.
    public let function: String
    public let cells: [ExportCell]

    init(function: String, cells: [ExportCell]) {
        self.function = function
        self.cells = cells
    }

    /// The aggregate functions that count rows rather than add values.
    static let countingFunctions: Set<String> = ["Count", "Rows", "Distinct"]

    /// Whether this line counts rows — `Count`, `Rows`, `Distinct` — rather than adding values.
    public var isCountingLine: Bool { Self.countingFunctions.contains(function) }
}

/// One exported group.
public struct ExportGroup: Hashable, Sendable {
    /// A stable, locale-independent identity for the group.
    public let token: String
    /// The human-readable label.
    public let label: String
    /// What the printed report writes for this group: ``label``, except for a group keyed on a
    /// date, which the report spells as a day — `29 Aug 2026` — the way it spells the date
    /// cells beneath it, while ``label`` is the ISO-8601 calendar date the three parsed formats
    /// use (`2026-08-29`). Both name the day in the zone the ledger cut the group in (C-10).
    /// The counterpart of ``ExportCell/printedText`` for a heading (BH-532).
    public let printedLabel: String
    public let depth: Int
    public let rowCount: Int
    public let path: [String]
    public let subgroups: [ExportGroup]
    /// Rows directly in this group; non-empty only for a leaf.
    public let rows: [ExportRow]
    public let subtotals: [ExportTotalRow]

    init(
        token: String,
        label: String,
        printedLabel: String? = nil,
        depth: Int,
        rowCount: Int,
        path: [String],
        subgroups: [ExportGroup],
        rows: [ExportRow],
        subtotals: [ExportTotalRow]
    ) {
        self.token = token
        self.label = label
        self.printedLabel = printedLabel ?? label
        self.depth = depth
        self.rowCount = rowCount
        self.path = path
        self.subgroups = subgroups
        self.rows = rows
        self.subtotals = subtotals
    }
}

/// Everything a cover page, a metadata sheet or a JSON header needs and the ledger does not know.
///
/// The Quantity Ledger reports on markups; it has never heard of a revision number or a drawing
/// scale caption. Those come from the document, so the caller supplies them rather than the
/// exporter inventing them.
public struct ExportDocumentContext: Hashable, Sendable {
    public var projectName: String?
    public var documentName: String?
    public var revision: String?
    public var scaleDescription: String?
    public var unitsDescription: String?
    public var preparedBy: String?
    public var notes: String?

    public init(
        projectName: String? = nil,
        documentName: String? = nil,
        revision: String? = nil,
        scaleDescription: String? = nil,
        unitsDescription: String? = nil,
        preparedBy: String? = nil,
        notes: String? = nil
    ) {
        self.projectName = projectName
        self.documentName = documentName
        self.revision = revision
        self.scaleDescription = scaleDescription
        self.unitsDescription = unitsDescription
        self.preparedBy = preparedBy
        self.notes = notes
    }
}

/// What produced this export.
public struct ExportMetadata: Hashable, Sendable {
    public let title: String
    public let generatedAt: ExportDate
    public let ledgerContractVersion: Int
    public let formulaGrammarVersion: Int
    public let groupingColumnKeys: [String]
    public let sortDescription: [String]
    public let filterDescription: String
    public let rowCount: Int
    public let totalRowCountBeforeFilter: Int
    public let numberLocaleIdentifier: String
    public let document: ExportDocumentContext
    /// Filter rules the ledger could not apply, in words (BH-101). Printed on the PDF cover and
    /// in the workbook's metadata sheet beside the filter they belong to.
    public let unappliedFilterRules: [String]
    /// How many exported rows hold a value kept under an older scale (ADR-0030 §2, K-04).
    public let staleScaleRowCount: Int
    /// The grouping columns as the ledger titles them, outermost first — "Subject", not
    /// `subject` (L-46). What the printed report's cover and the workbook's group columns name;
    /// ``groupingColumnKeys`` stays the machine spelling the interchange JSON carries.
    public let groupingColumnTitles: [String]
    /// The sort levels in words — "Plan Area, descending" — for the printed report's cover and
    /// the workbook's metadata sheet (L-46). ``sortDescription`` stays the audit spelling.
    public let printedSortDescription: [String]
    /// The filter in words for the printed report's cover: the caller's summary when it gave
    /// one, "(none)" for an unfiltered view, the audit spelling otherwise (L-46).
    public let printedFilterDescription: String

    /// The sentence every format prints when some values were kept under an older scale, or
    /// `nil` when none were: the file must not look like a takeoff at today's scale when it is not.
    public var staleScaleNotice: String? {
        guard staleScaleRowCount > 0 else { return nil }
        let count = staleScaleRowCount == 1 ? "1 value in this export was" : "\(staleScaleRowCount) values in this export were"
        return count + " kept under an older scale: the scale changed after they were measured and they were not"
            + " recalculated. Measure ▸ Recalculate Stale Measurements in Zenit PDF brings them to the current scale."
    }

    init(
        title: String,
        generatedAt: ExportDate,
        ledgerContractVersion: Int,
        formulaGrammarVersion: Int,
        groupingColumnKeys: [String],
        sortDescription: [String],
        filterDescription: String,
        rowCount: Int,
        totalRowCountBeforeFilter: Int,
        numberLocaleIdentifier: String,
        document: ExportDocumentContext,
        unappliedFilterRules: [String] = [],
        staleScaleRowCount: Int = 0,
        groupingColumnTitles: [String]? = nil,
        printedSortDescription: [String]? = nil,
        printedFilterDescription: String? = nil
    ) {
        self.title = title
        self.generatedAt = generatedAt
        self.ledgerContractVersion = ledgerContractVersion
        self.formulaGrammarVersion = formulaGrammarVersion
        self.groupingColumnKeys = groupingColumnKeys
        self.sortDescription = sortDescription
        self.filterDescription = filterDescription
        self.rowCount = rowCount
        self.totalRowCountBeforeFilter = totalRowCountBeforeFilter
        self.numberLocaleIdentifier = numberLocaleIdentifier
        self.document = document
        self.unappliedFilterRules = unappliedFilterRules
        self.staleScaleRowCount = staleScaleRowCount
        self.groupingColumnTitles = groupingColumnTitles ?? groupingColumnKeys
        self.printedSortDescription = printedSortDescription ?? sortDescription
        self.printedFilterDescription = printedFilterDescription ?? filterDescription
    }
}

/// The finished, format-independent table.
public struct ExportTable: Hashable, Sendable {
    public let columns: [ExportColumn]
    /// The group tree. Empty for a flat table, in which case ``rows`` holds everything.
    public let groups: [ExportGroup]
    /// Rows of a flat table. Empty when ``groups`` is non-empty.
    public let rows: [ExportRow]
    public let grandTotals: [ExportTotalRow]
    public let metadata: ExportMetadata
    /// True when the caller supplied row traces, and therefore when the formats emit the trace
    /// columns at all. A projection made without them exports exactly the bytes it always did.
    public let carriesRowTraces: Bool
    /// True when any row's quantity makes a claim other than `measured`, and therefore when the
    /// formats print the provenance labels at all (ADR-0012 rule 4): CSV and XLSX a column,
    /// JSON a per-row key, the PDF a per-row mark and a legend. A table of nothing but measured
    /// rows mixes nothing and exports exactly the bytes it always did — the same additive
    /// pattern ``carriesRowTraces`` follows. The moment a derived or read row is present, every
    /// row is labelled; an export that mixes the three without labels cannot be produced.
    public let carriesProvenanceLabels: Bool

    init(
        columns: [ExportColumn],
        groups: [ExportGroup],
        rows: [ExportRow],
        grandTotals: [ExportTotalRow],
        metadata: ExportMetadata,
        carriesRowTraces: Bool = false,
        carriesProvenanceLabels: Bool = false
    ) {
        self.columns = columns
        self.groups = groups
        self.rows = rows
        self.grandTotals = grandTotals
        self.metadata = metadata
        self.carriesRowTraces = carriesRowTraces
        self.carriesProvenanceLabels = carriesProvenanceLabels
    }

    /// True when some row was kept under an older scale, and therefore when CSV and XLSX append
    /// the scale-status column and every format prints the notice (K-04). A table without such a
    /// row exports exactly the bytes it always did.
    public var carriesScaleStatus: Bool { metadata.staleScaleRowCount > 0 }

    /// Every row in export order, flat or grouped.
    public func allRows() -> [ExportRow] {
        guard groups.isEmpty else {
            var output: [ExportRow] = []
            output.reserveCapacity(metadata.rowCount)
            func visit(_ group: ExportGroup) {
                output.append(contentsOf: group.rows)
                for subgroup in group.subgroups { visit(subgroup) }
            }
            for group in groups { visit(group) }
            return output
        }
        return rows
    }
}

extension ExportColumn {
    /// Whether a value in `unitSymbol` of `dimension` is shown in a unit of its own rather than
    /// this column's (NL-MEASURE-10, ADR-0035 §1.3): a markup with a display override puts
    /// metres in a feet column. A currency cell in another currency (CR-66) does not count — its
    /// total is already a refusal — and neither does a column or a cell that names no unit.
    func showsInOwnUnit(unitSymbol symbol: String, dimension: QuantityDimension?) -> Bool {
        isNumeric && !unitSymbol.isEmpty && dimension?.currencyCode == nil && !symbol.isEmpty && symbol != unitSymbol
    }

    func showsInOwnUnit(_ number: ExportNumber) -> Bool {
        showsInOwnUnit(unitSymbol: number.unitSymbol, dimension: number.dimension)
    }

    /// A value column's heading in the workbook and the printed report: the title and its unit,
    /// or the title alone when the column has no unit or its rows do not share one.
    func heading(sharesUnit: Bool) -> String {
        unitSymbol.isEmpty || !sharesUnit ? title : "\(title) (\(unitSymbol))"
    }
}

extension ExportNumber {
    /// ``text`` followed by its unit, for a column whose heading names none because its rows do
    /// not share one (T-042). A feet-and-inches spelling (`12'-6"`) names its units already, and
    /// a count or a ratio has no unit to name: its symbol is the SI base unit's `1`, which read
    /// `Doors: 12 1` in a snippet caption (V-055). The one unit-naming rule for cells, captions
    /// and group headings.
    var textNamingUnit: String {
        guard !unitSymbol.isEmpty, !text.isEmpty, dimension?.isDimensionless != true else { return text }
        if decimalPlaces == nil, text.contains("'") || text.contains("\"") { return text }
        return "\(text) \(unitSymbol)"
    }
}

extension ExportTable {
    /// What a total line shows a person under each column — the cells the workbook and the
    /// printed report write (L-46).
    ///
    /// Every cell, except that a counting line (`Count`, `Rows`, `Distinct`) says nothing under a
    /// column that is not a number. The core counts every column, so the report's
    /// "Count (all rows)" printed `2` under Type, Subject, Label and Page, and `0` under an empty
    /// Comment — figures no reader asked for, under columns that hold words (live test 8). A
    /// count under a quantity column stays: it says how many rows carry that quantity. The
    /// interchange JSON and the CSV keep every aggregate; they are read by machines.
    public func printedCells(of total: ExportTotalRow) -> [ExportCell] {
        guard total.isCountingLine else { return total.cells }
        return total.cells.enumerated().map { index, cell in
            index < columns.count && !columns[index].isNumeric ? .blank : cell
        }
    }

    /// The numeric columns, by index, where some row is shown in a unit other than the
    /// column's. The workbook, the printed report and the export profiles all read this one
    /// answer, so a column that says "ft" in one format and nothing in another cannot happen
    /// (T-042). Totals are in the column's unit by construction and are not consulted. Empty
    /// for every table without a display override.
    func mixedUnitColumns() -> Set<Int> {
        var mixed: Set<Int> = []
        let rows = allRows()
        for (index, column) in columns.enumerated() where column.isNumeric && !column.unitSymbol.isEmpty {
            let differs = rows.contains { row in
                guard index < row.cells.count, let number = row.cells[index].number else { return false }
                return column.showsInOwnUnit(number)
            }
            if differs { mixed.insert(index) }
        }
        return mixed
    }
}

/// The only thing an exporter can be handed.
///
/// There is exactly one initialiser and it is not public: ``ExportProjector/project(_:options:)``
/// makes these, from a `LedgerReport`, and nothing else can. A CSV writer therefore cannot be
/// given a bag of `Decimal`s and asked to round them, and a PDF renderer cannot be given a
/// `LedgerView` and asked to regroup it — those calls do not typecheck. That is what "the report
/// projection is the only source" means here: a property of the API, not a convention
/// (QUALITY_BAR A25).
public struct ExportProjection: Hashable, Sendable {
    public let table: ExportTable
    /// The locale the strings in ``table`` were rendered in. Exporters read it; none of them
    /// re-render with a different one.
    public let numberLocale: ExportNumberLocale
    /// The optional two-way summary (NL-QTY-09): the workbook's "Summary" sheet and the report's
    /// matrix page. `nil` — the default — exports exactly the bytes it always did.
    public internal(set) var summaryMatrix: ExportSummaryMatrix?

    init(table: ExportTable, numberLocale: ExportNumberLocale) {
        self.table = table
        self.numberLocale = numberLocale
    }
}
