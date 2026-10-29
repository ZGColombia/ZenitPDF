import Foundation
import ZPDFContracts
import ZPDFQuantityLedger

/// Options for the one translation step between the ledger and the exporters.
public struct ExportProjectionOptions: Hashable, Sendable {
    /// How numbers become digits, for every format at once.
    public var numberLocale: ExportNumberLocale
    /// The visible column set, by key, in order. Empty means every column of the report.
    public var columnKeys: [String]
    /// Human labels for group keys, by ``ZPDFQuantityLedger/LedgerGroupKey/token``. The report
    /// carries a stable token, not a label; a caller that has the choice catalogue supplies the
    /// wording here rather than the exporter guessing it.
    public var groupLabels: [String: String]
    /// Human labels for Choice cells, keyed by the option's UUID string.
    public var choiceLabels: [String: String]
    /// Cover-page and metadata material the ledger does not know.
    public var document: ExportDocumentContext
    /// Overrides the report's own title.
    public var title: String?
    /// Per-row provenance, keyed by the markup's UUID string (feature 16). Empty — the default —
    /// means no trace columns anywhere, and every existing export is unchanged byte for byte.
    ///
    /// The ledger does not know a sheet label, a scale ratio or which recalibration a markup
    /// predates, so this is supplied rather than derived. See ``ExportRowTrace`` for the one rule
    /// the supplier must keep.
    public var rowTraces: [String: ExportRowTrace]
    /// The zone whose calendar day the printed report's dates name — the cover's date and every
    /// date cell's ``ExportDate/humanText``. The ISO-8601 instants the three parsed formats
    /// carry are always UTC and are not affected.
    ///
    /// UTC by default, which keeps two renders of one projection byte-identical on two machines
    /// (QUALITY_BAR A34). The application passes the zone its ledger shows dates in, so a markup
    /// created at 00:30 on 2 September local time is dated 2 September on paper as well as on
    /// screen, instead of 1 September because that is the day in Greenwich (BH-533).
    public var humanDateTimeZone: TimeZone
    /// The on-screen ledger's two digit-count rules that no column precision carries, or `nil`
    /// — the default — to render every cell at its column's precision exactly as before.
    ///
    /// The ledger on screen does not print every cell at its column's precision. A
    /// dimensionless cell — a count, a ratio — shows the digits its value has (`2`, not
    /// `2.00`), and under an imperial project, whose column set gives *every* dimension the
    /// imperial-fraction precision, an area or a volume shows the metric decimal count
    /// (`1,076.39 ft²`, not `1076.375`). Neither number is in the frozen `DisplayUnitPolicy`,
    /// so the caller that holds the screen's settings passes them here and the report prints
    /// the digits the screen prints (BH-142, BH-143; QUALITY_BAR A25).
    public var screenNotation: ExportScreenNotation?
    /// The markups (UUID strings, keyed as ``rowTraces`` is) whose values were kept under an
    /// older version of their scale when the scale changed (ADR-0030 §2). Every format then says
    /// so: a notice in the file, and the rows marked (K-04). Empty — the default — changes nothing.
    public var staleScaleRowIDs: Set<String>
    /// The titles the on-screen ledger and its CSV show, keyed by column key: "Plan Area",
    /// "Page", "Unit", "Cost Code" (L-46).
    ///
    /// A built-in column's report title is its key — `planArea`, `pageLabel`, `displayUnit` —
    /// because the key is what the ledger package knows; the words are the application's. The
    /// workbook, the printed report and the export profiles used to head their columns with
    /// those keys while the ledger and its CSV said "Plan Area" (live test 8). The application
    /// passes the ledger's own titles here; a key the map does not name keeps the report's
    /// title. Empty — the default — exports exactly the titles it always did.
    public var columnTitles: [String: String] = [:]
    /// What the ledger's Unit column shows on each row — `m`, `m²`, `pcs` — keyed by the
    /// markup's UUID string, as ``rowTraces`` is (L-46, L-46b).
    ///
    /// The built-in `displayUnit` column holds no stored value, so every projected format wrote
    /// it blank while the ledger and its CSV (L-25) showed the row's unit. The unit is the
    /// application's rule (the row's primary quantity), so the caller supplies it; a row the map
    /// does not name keeps its blank cell. Empty — the default — changes nothing.
    public var rowUnitTexts: [String: String] = [:]
    /// What the ledger's Type column shows on each row — "Area", "Rectangle Area", "ƒ Area" —
    /// keyed by the markup's UUID string (L-46). The built-in `icon` column stores the tool's
    /// token (`rectangleArea`), which the ledger never shows; a row the map does not name keeps it.
    public var rowTypeTexts: [String: String] = [:]
    /// The filter in the words the ledger's CSV banner uses, for the printed report's cover
    /// (L-46). `nil` prints the report's own audit spelling, an unfiltered view as "(none)"
    /// rather than the grammar's `ALL`.
    public var filterSummary: String?

    public init(
        numberLocale: ExportNumberLocale = .invariant,
        columnKeys: [String] = [],
        groupLabels: [String: String] = [:],
        choiceLabels: [String: String] = [:],
        document: ExportDocumentContext = ExportDocumentContext(),
        title: String? = nil,
        rowTraces: [String: ExportRowTrace] = [:],
        humanDateTimeZone: TimeZone = .gmt,
        screenNotation: ExportScreenNotation? = nil,
        staleScaleRowIDs: Set<String> = []
    ) {
        self.numberLocale = numberLocale
        self.columnKeys = columnKeys
        self.groupLabels = groupLabels
        self.choiceLabels = choiceLabels
        self.document = document
        self.title = title
        self.rowTraces = rowTraces
        self.humanDateTimeZone = humanDateTimeZone
        self.screenNotation = screenNotation
        self.staleScaleRowIDs = staleScaleRowIDs
    }
}

/// The on-screen ledger's digit counts for the two kinds of cell a column precision does not
/// describe the way the screen renders them. See ``ExportProjectionOptions/screenNotation``.
public struct ExportScreenNotation: Hashable, Sendable {
    /// The decimal count the screen uses for a dimensioned value that is not a length in feet
    /// or inches — its "metric decimal places" setting, which it applies to square feet and
    /// cubic yards as well. Used for a cell whose column precision is an imperial fraction and
    /// which is not spelled in feet and inches.
    public var decimalPlaces: Int
    /// The most fraction digits a dimensionless value shows. The screen prints the digits the
    /// value has, capped here so a repeating ratio does not print thirty of them.
    public var dimensionlessDigitCap: Int

    public init(decimalPlaces: Int = 2, dimensionlessDigitCap: Int = 6) {
        self.decimalPlaces = max(0, min(9, decimalPlaces))
        self.dimensionlessDigitCap = max(0, dimensionlessDigitCap)
    }
}

/// Turns a `LedgerReport` into an ``ExportProjection``.
///
/// # This is the boundary
///
/// Every conversion from an SI base value to a display unit, every application of a
/// ``ZPDFContracts/PrecisionMode``, and every `Decimal`-to-`String` rendering in the whole export
/// layer happens inside this one type, once per value. Downstream there are no `Decimal`s left to
/// round and no formatting metadata left to interpret differently — only finished strings, the
/// exact `Decimal`s they came from, and the number-format code that reproduces them
/// (QUALITY_BAR A29, A30, A31).
///
/// It is also the only type in the package that imports `ZPDFQuantityLedger`. The four exporters
/// do not, and cannot: they take an ``ExportProjection``, whose initialiser is internal to this
/// module and whose only caller is ``project(_:options:)``.
public struct ExportProjector: Sendable {

    public init() {}

    /// - Throws: ``ExportError/unknownColumn(_:)`` if `options.columnKeys` names a column the
    ///   report does not have. Silently dropping it would produce an export missing a column the
    ///   user asked for, with nothing to say so.
    public func project(
        _ report: LedgerReport,
        options: ExportProjectionOptions = ExportProjectionOptions()
    ) throws -> ExportProjection {
        let locale = options.numberLocale
        let selected = try select(report.columns, keys: options.columnKeys)
        let titles = Self.headings(of: selected, titles: options.columnTitles)
        let columns = zip(selected, titles).map { column($0, title: $1, locale: locale) }
        let order = selected.map(\.id)
        // Every column of the report, selected or not: a weighted total names its weight
        // column by key (CR-70) whether or not that column is exported.
        let keysByColumn = Dictionary(
            report.columns.map { ($0.id, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        // CR-59: a group keyed on a number or currency column is labelled the way that
        // column's cells read — display unit, column precision, unit symbol — not as the raw
        // SI magnitude. The grouping column at each depth is found by key from the report's
        // metadata; a grouping column the report does not carry (one grouped on while hidden)
        // is labelled in its SI base unit, with the unit symbol, which is at least unambiguous
        // (BH-531).
        // The report now carries each grouping column's own formatting, so a hidden grouping
        // column is labelled in its display unit too; the SI label is the last resort.
        let carried = report.metadata.groupingColumnFormatting
        let groupingFormatting: [LedgerValueFormatting?] = report.metadata.groupingColumnKeys
            .enumerated().map { depth, key in
                report.columns.first { $0.key == key }?.formatting
                    ?? (depth < carried.count ? carried[depth] : nil)
            }
        // IM-189: the position of every exported column, computed once. A row is then filled
        // by indexing, not by building a dictionary of its cells and looking each one up.
        var positions: [ColumnID: Int] = [:]
        positions.reserveCapacity(order.count)
        for (position, id) in order.enumerated() where positions[id] == nil {
            positions[id] = position
        }
        let context = Context(
            options: options,
            locale: locale,
            humanCalendar: Self.calendar(in: options.humanDateTimeZone),
            dayCalendar: Self.calendar(in: report.metadata.dayTimeZone),
            columnOrder: order,
            positions: positions,
            keysByColumn: keysByColumn,
            groupingFormatting: groupingFormatting,
            groupingKeys: report.metadata.groupingColumnKeys,
            unitPosition: selected.firstIndex { $0.key == StandardLedgerColumn.displayUnit.rawValue },
            typePosition: selected.firstIndex { $0.key == StandardLedgerColumn.icon.rawValue },
            pageIndexPosition: selected.firstIndex { $0.key == StandardLedgerColumn.pageIndex.rawValue }
        )

        let groups = report.groups.map { group($0, context: context) }
        let rows = report.rows.map { row($0, context: context) }

        // ADR-0012 rule 4: the moment any row claims something other than "measured", every
        // format labels every row. A pure-measured table exports the bytes it always did.
        func groupCarriesNonMeasured(_ group: ExportGroup) -> Bool {
            group.rows.contains { !$0.makesMeasuredClaim }
                || group.subgroups.contains(where: groupCarriesNonMeasured)
        }
        let carriesProvenanceLabels = rows.contains { !$0.makesMeasuredClaim }
            || groups.contains(where: groupCarriesNonMeasured)
        // K-04: how many exported rows hold a value kept under an older scale.
        func staleCount(_ group: ExportGroup) -> Int {
            group.rows.filter(\.keptUnderOlderScale).count + group.subgroups.map(staleCount).reduce(0, +)
        }
        let staleScaleRowCount = rows.filter(\.keptUnderOlderScale).count + groups.map(staleCount).reduce(0, +)

        let table = ExportTable(
            columns: columns,
            groups: groups,
            rows: rows,
            grandTotals: totals(report.grandTotals, context: context),
            metadata: ExportMetadata(
                title: options.title ?? report.title,
                generatedAt: date(report.metadata.generatedAt, context: context),
                ledgerContractVersion: report.metadata.ledgerContractVersion,
                formulaGrammarVersion: report.metadata.formulaGrammarVersion,
                groupingColumnKeys: report.metadata.groupingColumnKeys,
                sortDescription: report.metadata.sortDescription,
                filterDescription: report.metadata.filterDescription,
                rowCount: report.metadata.rowCount,
                totalRowCountBeforeFilter: report.metadata.totalRowCountBeforeFilter,
                numberLocaleIdentifier: locale.identifier,
                document: options.document,
                unappliedFilterRules: report.metadata.unappliedFilterRules,
                staleScaleRowCount: staleScaleRowCount,
                groupingColumnTitles: report.metadata.groupingColumnKeys.map {
                    Self.title(ofKey: $0, report: report, options: options)
                },
                printedSortDescription: report.metadata.sortDescription.map {
                    Self.printedSortLevel($0, report: report, options: options)
                },
                printedFilterDescription: options.filterSummary
                    ?? (report.metadata.filterDescription == "ALL" ? "(none)" : report.metadata.filterDescription)
            ),
            carriesRowTraces: !options.rowTraces.isEmpty,
            carriesProvenanceLabels: carriesProvenanceLabels
        )
        return ExportProjection(table: table, numberLocale: locale)
    }

    // MARK: - Columns

    private func select(
        _ columns: [LedgerReportColumn],
        keys: [String]
    ) throws -> [LedgerReportColumn] {
        guard !keys.isEmpty else { return columns }
        let byKey = Dictionary(columns.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return try keys.map { key in
            guard let column = byKey[key] else { throw ExportError.unknownColumn(key) }
            return column
        }
    }

    /// The heading each selected column is exported under (L-46): the ledger's title from
    /// ``ExportProjectionOptions/columnTitles`` when the caller supplied one, else the report's.
    ///
    /// Titles are what the workbook's round-trip sheet matches columns by, so two columns that
    /// would share one — a custom column a person called "Subject" beside the built-in one — are
    /// told apart by their key. Keys were unique by construction; the words are not.
    static func headings(of columns: [LedgerReportColumn], titles: [String: String]) -> [String] {
        let proposed = columns.map { column -> String in
            let title = titles[column.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? column.title : title
        }
        guard !titles.isEmpty else { return proposed }
        var counts: [String: Int] = [:]
        for title in proposed { counts[title, default: 0] += 1 }
        return zip(columns, proposed).map { column, title in
            (counts[title] ?? 0) > 1 && title != column.key ? "\(title) (\(column.key))" : title
        }
    }

    private func column(_ source: LedgerReportColumn, title: String, locale: ExportNumberLocale) -> ExportColumn {
        let places = decimalPlaces(source.formatting.precision)
        let isNumeric: Bool
        switch source.kind {
        case .number, .currency, .formula: isNumeric = true
        case .text, .date, .checkbox, .choice: isNumeric = false
        }
        let grouped = locale.groupingSeparator != nil
        let code: String?
        if !isNumeric {
            code = nil
        } else if case .imperialFraction = source.formatting.precision,
                  Self.isImperialLength(dimension: source.formatting.dimension, formatting: source.formatting) {
            // Feet and inches are not a spreadsheet number format; the workbook column holds
            // decimal feet at the resolution a sixty-fourth of an inch needs.
            code = Self.numberFormatCode(decimalPlaces: Self.imperialFeetDecimalPlaces, grouped: grouped)
        } else {
            code = Self.numberFormatCode(decimalPlaces: places, grouped: grouped)
        }
        return ExportColumn(
            key: source.key,
            title: title,
            kind: source.kind,
            unitSymbol: source.formatting.unitSymbol,
            decimalPlaces: places,
            numberFormatCode: code,
            aggregationSemantics: source.aggregationSemantics?.rawValue,
            formulaCanonicalText: source.formulaCanonicalText,
            columnID: source.id
        )
    }

    /// Excel's own name for "every digit the value has": the column-level code of a numeric
    /// column with no declared precision, whose cells each carry their own exact code.
    public static let generalNumberFormatCode = "General"

    /// Decimal feet, to this many places, is what the workbook holds for a length the report
    /// spells in feet and inches. Four places resolve 1/64" (1/768 ft ≈ 0.0013 ft).
    static let imperialFeetDecimalPlaces = 4

    /// The Excel number-format code that renders the same digits ``ExportNumberLocale`` does.
    ///
    /// Excel substitutes the *host's* decimal and thousands separators for the `.` and `,` in a
    /// format code; a workbook cannot carry its own. So the code fixes the digit count, which is
    /// the part that must not drift, and the separators follow the machine the file is opened on.
    /// `XLSXExporter` documents that consequence rather than pretending it away.
    ///
    /// `nil` — no fixed digit count — is `General`, not an integer code: a column with no
    /// declared precision prints every digit its values have, and the workbook that formatted
    /// `125.5` with `0` displayed `126` where the CSV and the PDF said `125.5` (BH-139, BH-140).
    static func numberFormatCode(decimalPlaces: Int?, grouped: Bool) -> String {
        guard let decimalPlaces else { return generalNumberFormatCode }
        let integerPart = grouped ? "#,##0" : "0"
        guard decimalPlaces > 0 else { return integerPart }
        return integerPart + "." + String(repeating: "0", count: decimalPlaces)
    }

    private func decimalPlaces(_ precision: PrecisionMode?) -> Int? {
        switch precision {
        case .decimalPlaces(let places): places
        // An imperial fraction has no fixed digit count; the value is rendered with whatever
        // digits the rounded sixteenth actually has.
        case .imperialFraction, nil: nil
        }
    }

    /// `value` rounded once to `places`, half away from zero, with a zero that rounds away
    /// written as the unsigned `0` — the rule ``ZPDFQuantityLedger/LedgerValueFormatting``
    /// applies, for the two digit counts no column precision carries.
    static func roundedOnce(_ value: Decimal, places: Int) -> Decimal {
        let rounded = PrecisionMode.decimalPlaces(places).apply(to: value)
        return rounded.isZero ? .zero : rounded
    }

    /// The most fraction digits a per-cell format code asks for: a double's fifteen
    /// significant digits are all a workbook cell can hold.
    static let maximumFormatDecimalPlaces = 15

    /// True for a dimension the screen prints with the digits the value has: a count or a
    /// ratio — not an angle, not a currency, nothing with a length power.
    static func isDimensionless(_ dimension: QuantityDimension?) -> Bool {
        guard let dimension else { return false }
        return dimension == .count || dimension == .ratio
    }

    /// The fraction digits a `Decimal` is stored with — the screen's rule for a dimensionless
    /// value (`-exponent`, never negative).
    static func exponentDigits(of value: Decimal) -> Int {
        max(0, -value.exponent)
    }

    /// How many fraction digits `value.description` — and therefore
    /// ``ExportNumberLocale/string(_:decimalPlaces:)`` with `nil` places — writes for it.
    static func fractionDigits(of value: Decimal) -> Int {
        let plain = value.description
        guard let dot = plain.firstIndex(of: ".") else { return 0 }
        return plain.distance(from: plain.index(after: dot), to: plain.endIndex)
    }

    // MARK: - The projection context

    /// Everything the per-row and per-cell functions need, computed once per projection.
    private struct Context {
        let options: ExportProjectionOptions
        let locale: ExportNumberLocale
        /// The Gregorian calendar the human-readable dates are taken in (BH-533, IM-189).
        let humanCalendar: Calendar
        /// The calendar the ledger cut its date groups into days with. A date group's label and
        /// printed heading name the day in this one zone, the day the group is a bucket of (C-10).
        let dayCalendar: Calendar
        let columnOrder: [ColumnID]
        /// Exported column id to its position in ``columnOrder`` (IM-189).
        let positions: [ColumnID: Int]
        let keysByColumn: [ColumnID: String]
        let groupingFormatting: [LedgerValueFormatting?]
        /// The grouping column at each depth, by key.
        let groupingKeys: [String]
        /// Where the built-in `displayUnit` column is, when it is exported (L-46).
        let unitPosition: Int?
        /// Where the built-in `icon` (Type) column is, when it is exported (L-46).
        let typePosition: Int?
        /// Where the built-in `pageIndex` column is, when it is exported (L-46).
        let pageIndexPosition: Int?
    }

    // MARK: - Rows and groups

    private func group(_ source: LedgerReportGroup, context: Context) -> ExportGroup {
        let formatting = source.depth < context.groupingFormatting.count
            ? context.groupingFormatting[source.depth]
            : nil
        var label = label(source.key, context: context, formatting: formatting)
        // A group keyed on the page index is headed by the page's number, as its cells read.
        if source.depth < context.groupingKeys.count,
           context.groupingKeys[source.depth] == StandardLedgerColumn.pageIndex.rawValue,
           context.options.groupLabels[source.key.token] == nil,
           case .number(let quantity) = source.key {
            label = Self.pageNumber(quantity.value, locale: context.locale).text
        }
        return ExportGroup(
            token: source.key.token,
            label: label,
            printedLabel: printedLabel(source.key, label: label, context: context),
            depth: source.depth,
            rowCount: source.rowCount,
            path: source.path.map(\.token),
            subgroups: source.subgroups.map { group($0, context: context) },
            rows: source.rows.map { row($0, context: context) },
            subtotals: totals(source.totals, context: context)
        )
    }

    private func row(_ source: LedgerReportRow, context: Context) -> ExportRow {
        // IM-189: the report's cells are placed by the column-position map built once per
        // projection. No dictionary is allocated per row; a column the row does not carry stays
        // blank, and a duplicate column id keeps its first cell, as the lookup used to.
        var cells = [ExportCell](repeating: .blank, count: context.columnOrder.count)
        var filled = [Bool](repeating: false, count: cells.count)
        for cell in source.cells {
            guard let position = context.positions[cell.column], !filled[position] else { continue }
            filled[position] = true
            cells[position] = self.cell(cell, context: context)
        }
        let markupID = source.markupID.rawValue.uuidString
        // L-46: the Unit column carries what the ledger's Unit column shows on this row.
        if let position = context.unitPosition, case .blank = cells[position],
           let unit = context.options.rowUnitTexts[markupID], !unit.isEmpty {
            cells[position] = .text(unit)
        }
        // L-46: the Type column reads the tool's name, as the ledger's Type column does.
        if let position = context.typePosition, let type = context.options.rowTypeTexts[markupID], !type.isEmpty {
            switch cells[position] {
            case .blank, .text: cells[position] = .text(type)
            default: break
            }
        }
        if let position = context.pageIndexPosition, case .number(let index) = cells[position] {
            cells[position] = .number(Self.pageNumber(index, locale: context.locale))
        }
        return ExportRow(
            markupID: markupID,
            storeIndex: source.storeIndex,
            groupPath: source.groupPath.map(\.token),
            cells: cells,
            trace: context.options.rowTraces[markupID],
            provenance: source.provenance.rawValue,
            keptUnderOlderScale: context.options.staleScaleRowIDs.contains(markupID)
        )
    }

    private func cell(_ source: LedgerReportCell, context: Context) -> ExportCell {
        switch source.value {
        case .error(let error):
            // Same token spelling as an aggregate refusal, so a reader has one thing to look for
            // (QUALITY_BAR A14). The diagnostic detail is deliberately not in the token: it is
            // free text and would make two exports of the same view differ.
            return .refusal(token: "\(LedgerReport.errorToken)[\(error.kind.rawValue)]")
        case .value(let value):
            switch value {
            case .empty:
                return .blank
            case .text(let text):
                return text.isEmpty ? .blank : .text(text)
            case .checkbox(let flag):
                return .boolean(flag)
            case .date(let instant):
                return .date(date(instant, context: context))
            case .choice(let id):
                return .text(Self.choiceLabel(id, options: context.options))
            case .number(let quantity), .formulaResult(let quantity, _):
                return .number(number(
                    raw: quantity.value,
                    dimension: quantity.dimension,
                    formatting: source.formatting,
                    locale: context.locale,
                    notation: context.options.screenNotation
                ))
            case .currency(let amount, let code):
                return .number(number(
                    raw: amount,
                    dimension: .currency(code),
                    formatting: source.formatting,
                    locale: context.locale,
                    notation: context.options.screenNotation
                ))
            }
        }
    }

    /// The human-readable label of a group.
    ///
    /// - Parameter formatting: the grouping column's formatting, when the report carries that
    ///   column. A number or currency key is then rendered exactly as a cell of that column is
    ///   — converted to the display unit, rounded once to the column's precision, followed by
    ///   the unit symbol — so a group of 500 mm cells is headed "500 mm", not "0.5" (CR-59).
    ///   Without it — the report carries only the visible columns, and a view can group on a
    ///   column it hides — the key is rendered in its SI base unit *with that unit's symbol*,
    ///   "0.5 m", so the heading at least says what the magnitude is a magnitude of (BH-531).
    private func label(
        _ key: LedgerGroupKey,
        context: Context,
        formatting: LedgerValueFormatting? = nil
    ) -> String {
        let locale = context.locale
        if let supplied = context.options.groupLabels[key.token] { return supplied }
        switch key {
        case .text(let text): return text
        case .number(let quantity):
            let rendered = number(
                raw: quantity.value,
                dimension: quantity.dimension,
                formatting: formatting ?? LedgerValueFormatting(dimension: quantity.dimension),
                locale: locale,
                notation: context.options.screenNotation
            )
            // Named the way a cell names its unit: a feet-and-inches heading used to read
            // `12'-6" ft` (U-054), and a count names none (V-055).
            return rendered.textNamingUnit
        case .currency(let amount, let code):
            guard let formatting else { return locale.string(amount, decimalPlaces: nil) + " " + code }
            let rendered = number(
                raw: amount, dimension: .currency(code), formatting: formatting, locale: locale,
                notation: context.options.screenNotation
            )
            return "\(rendered.text) \(code)"
        case .date(let dayStart):
            // The day the bucket holds, as an ISO-8601 calendar date in the zone the ledger cut
            // it in: the ISO instant of its midnight named another day in any other zone —
            // "2026-09-01T22:00:00Z" for 2 September in Stockholm (C-10, I-18).
            return Self.isoDay(dayStart, calendar: context.dayCalendar)
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        case .choice(let id):
            return Self.choiceLabel(id, options: context.options)
        case .none: return "(none)"
        case .error: return "(error)"
        }
    }

    /// What the printed report writes as the heading: the label, except that a date key is
    /// spelled as the day a person reads, the way the date cells beneath it are (BH-532). A
    /// label the caller supplied is printed as supplied.
    ///
    /// The day is taken in the zone the ledger cut the bucket in, as ``label(_:context:formatting:)``
    /// takes it: in the human-date zone, a bucket cut in Stockholm was headed with the UTC day
    /// before it whenever the two zones differ (C-10). The application projects in the zone its
    /// ledger groups in, so there the heading also names the day its date cells print.
    private func printedLabel(_ key: LedgerGroupKey, label: String, context: Context) -> String {
        guard context.options.groupLabels[key.token] == nil, case .date(let dayStart) = key else {
            return label
        }
        return Self.humanDate(dayStart, calendar: context.dayCalendar)
    }

    // MARK: - Words for keys (L-46)

    /// The title a column key is shown under: the caller's, the report's, or the key itself.
    static func title(ofKey key: String, report: LedgerReport, options: ExportProjectionOptions) -> String {
        if let supplied = options.columnTitles[key], !supplied.isEmpty { return supplied }
        return report.columns.first { $0.key == key }?.title ?? key
    }

    /// One sort level in words — "Plan Area, descending" — from the report's audit spelling
    /// `planArea:desc:nullsLast`. A spelling this does not recognise is printed as it is.
    static func printedSortLevel(_ level: String, report: LedgerReport, options: ExportProjectionOptions) -> String {
        let parts = level.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[1] == "asc" || parts[1] == "desc" else { return level }
        let direction = parts[1] == "asc" ? "ascending" : "descending"
        return "\(title(ofKey: parts[0], report: report, options: options)), \(direction)"
    }

    // MARK: - Page numbers (L-46)

    /// The page a 0-based page index names, as a person counts it: the first page is page 1.
    ///
    /// The built-in `pageIndex` column holds the sheet's position in its PDF from 0, and every
    /// format printed it so — the report's first sheet was "0" (live test 8). ``ExportNumber/raw``
    /// keeps the stored index, so the interchange JSON's exact value and a reconciliation
    /// against a file written before this rule are unchanged; the converted, displayed and
    /// written value is the page number.
    static func pageNumber(_ index: ExportNumber, locale: ExportNumberLocale) -> ExportNumber {
        let number = index.convertedRaw + 1
        return ExportNumber(
            raw: index.raw,
            convertedRaw: number,
            display: number,
            text: locale.string(number, decimalPlaces: 0),
            invariantRawText: index.invariantRawText,
            unitSymbol: index.unitSymbol,
            dimension: index.dimension,
            decimalPlaces: 0,
            numberFormatCode: numberFormatCode(decimalPlaces: 0, grouped: locale.groupingSeparator != nil)
        )
    }

    /// ``pageNumber(_:locale:)`` for a group key's stored index.
    static func pageNumber(_ index: Decimal, locale: ExportNumberLocale) -> ExportNumber {
        pageNumber(ExportNumber(
            raw: index, convertedRaw: index, display: index, text: index.description,
            invariantRawText: index.description, unitSymbol: "", dimension: .count, decimalPlaces: 0
        ), locale: locale)
    }

    // MARK: - Choices

    /// What a Choice cell — and a group headed by one — reads.
    ///
    /// Three answers, in order of authority:
    ///
    /// 1. The label the caller supplied for this option id. A caller holding the choice catalogue
    ///    knows the wording; nothing here second-guesses it.
    /// 2. For the **built-in Status column**, the option's own title. Its options are not free
    ///    text — they are `MarkupStatus`'s cases, with ids fixed by
    ///    ``ZPDFQuantityLedger/LedgerIdentifiers``, so the export layer can resolve them without
    ///    being told. This is live-test finding LT-19: the application builds its projection with
    ///    no choice catalogue, and the Status cell of every export therefore printed a raw UUID
    ///    where the on-screen ledger and its CSV print "No status". A UUID in a Status column is
    ///    not a value a reader can use in any format, so the fix is here rather than in the one
    ///    format that happened to be noticed.
    /// 3. The option id, for a user column whose catalogue nobody supplied. Unhelpful, but at
    ///    least unambiguous — there is nothing else in a `LedgerReport` to print.
    static func choiceLabel(_ id: ChoiceOptionID, options: ExportProjectionOptions) -> String {
        if let supplied = options.choiceLabels[id.rawValue.uuidString] { return supplied }
        if let status = LedgerStatusChoices.statusByOptionID[id] { return statusTitle(status) }
        return id.rawValue.uuidString
    }

    /// Review-status copy, the same wording the ledger shows on screen and writes to its CSV.
    ///
    /// Exhaustive on purpose — no `default`. `MarkupStatus` is a frozen contract enum whose
    /// `rawValue` is a camel-cased serialisation detail; a ninth case must not be able to reach a
    /// printed report as `someNewCase`, so it has to fail the build here first.
    static func statusTitle(_ status: MarkupStatus) -> String {
        switch status {
        case .none: "No status"
        case .open: "Open"
        case .inProgress: "In progress"
        case .resolved: "Resolved"
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case .cancelled: "Cancelled"
        case .completed: "Completed"
        }
    }

    // MARK: - Totals

    private func totals(_ source: [LedgerReportTotal], context: Context) -> [ExportTotalRow] {
        // One row per aggregate function, in the order the plan first mentions it, so two
        // exports of the same view produce the same rows in the same order (QUALITY_BAR A34).
        var functionOrder: [String] = []
        var byFunction: [String: [ColumnID: LedgerReportTotal]] = [:]
        for total in source {
            let key = Self.functionKey(total.function, keysByColumn: context.keysByColumn)
            if byFunction[key] == nil {
                byFunction[key] = [:]
                functionOrder.append(key)
            }
            byFunction[key]?[total.column] = total
        }
        return functionOrder.map { function in
            let members = byFunction[function] ?? [:]
            let cells = context.columnOrder.map { id -> ExportCell in
                guard let total = members[id] else { return .blank }
                return self.cell(total, context: context)
            }
            return ExportTotalRow(function: function, cells: cells)
        }
    }

    private func cell(_ total: LedgerReportTotal, context: Context) -> ExportCell {
        let locale = context.locale
        if let token = total.refusalToken { return .refusal(token: token) }
        switch total.value {
        case .empty:
            return .blank
        case .integer(let count):
            // A count is an integer. Rendering it with the column's three decimal places would
            // say "12.000 rows", which is not a thing — and the cell says so itself, carrying
            // the integer format code, so the workbook cannot format it with the column's
            // three places either (BH-141, BH-150).
            return .number(ExportNumber(
                raw: Decimal(count),
                convertedRaw: Decimal(count),
                display: Decimal(count),
                text: locale.string(Decimal(count), decimalPlaces: 0),
                invariantRawText: Decimal(count).description,
                unitSymbol: "",
                dimension: .count,
                decimalPlaces: 0,
                numberFormatCode: Self.numberFormatCode(
                    decimalPlaces: 0, grouped: locale.groupingSeparator != nil
                )
            ))
        case .quantity(let quantity):
            return .number(number(
                raw: quantity.value,
                dimension: quantity.dimension,
                formatting: total.formatting,
                locale: locale,
                notation: context.options.screenNotation
            ))
        case .currency(let amount, let code):
            return .number(number(
                raw: amount,
                dimension: .currency(code),
                formatting: total.formatting,
                locale: locale,
                notation: context.options.screenNotation
            ))
        case .mixedDimensions, .failed:
            // Unreachable: both produce a refusalToken above. Kept explicit so a new case in
            // AggregateValue is a compile error here rather than a silent blank in four formats.
            return .refusal(token: LedgerReport.errorToken)
        }
    }

    /// A stable, locale-independent name for an aggregate function.
    ///
    /// A weighted total carries its weight column — `WeightedTotal[weight]` — because two
    /// weighted totals of one column by two different weights are two different numbers, and
    /// the key is what separates their rows. Keyed on the function alone, the second used to
    /// overwrite the first and one row went missing from every format (CR-70). The weight is
    /// named by its column key, or by its id when the report does not carry the column.
    static func functionKey(
        _ function: AggregateFunction,
        keysByColumn: [ColumnID: String] = [:]
    ) -> String {
        switch function {
        case .sum: "Sum"
        case .count: "Count"
        case .rowCount: "Rows"
        case .minimum: "Min"
        case .maximum: "Max"
        case .average: "Average"
        case .distinctCount: "Distinct"
        case .weightedTotal(let weight): "WeightedTotal[\(keysByColumn[weight] ?? weight.description)]"
        }
    }

    // MARK: - Values

    /// Converts once, rounds once, renders once — and says, per cell, how many digits it
    /// rendered and which Excel format code reproduces them.
    private func number(
        raw: Decimal,
        dimension: QuantityDimension?,
        formatting: LedgerValueFormatting,
        locale: ExportNumberLocale,
        notation: ExportScreenNotation? = nil
    ) -> ExportNumber {
        let converted = formatting.converted(raw)
        let grouped = locale.groupingSeparator != nil
        // CR-66: a currency cell whose ISO code differs from its column's — a EUR row in a
        // SEK column — carries its own code. The column's symbol would label the amount with
        // a currency it is not in, and the column's total already refuses the mix.
        let unitSymbol: String
        if let cellCode = dimension?.currencyCode, cellCode != formatting.currencyCode {
            unitSymbol = cellCode
        } else {
            unitSymbol = formatting.unitSymbol.isEmpty
                ? (dimension?.baseUnitSymbol ?? "")
                : formatting.unitSymbol
        }
        let display: Decimal
        let text: String
        let places: Int?
        let code: String
        // BH-142: with the screen's rules supplied, a dimensionless cell — a count, a ratio —
        // prints the digits its value has, capped, as the ledger on screen does: `2`, not the
        // column precision's `2.00`. The value is rounded once, to that count, here.
        if let notation, Self.isDimensionless(dimension ?? formatting.dimension) {
            let digits = min(notation.dimensionlessDigitCap, Self.exponentDigits(of: converted))
            display = Self.roundedOnce(converted, places: digits)
            text = locale.string(display, decimalPlaces: digits)
            return ExportNumber(
                raw: raw,
                convertedRaw: converted,
                display: display,
                text: text,
                invariantRawText: raw.description,
                unitSymbol: unitSymbol,
                dimension: dimension,
                decimalPlaces: digits,
                numberFormatCode: Self.numberFormatCode(decimalPlaces: digits, grouped: grouped)
            )
        }
        switch formatting.precision {
        case .decimalPlaces(let declared):
            display = formatting.displayDecimal(raw)
            text = locale.string(display, decimalPlaces: declared)
            places = declared
            code = Self.numberFormatCode(decimalPlaces: declared, grouped: grouped)
        case .imperialFraction(let denominator):
            if let imperial = Self.imperialLength(
                raw: raw, dimension: dimension, formatting: formatting, denominator: denominator
            ) {
                // BH-021: a length under an imperial fraction reads `3'-4 13/16"` — feet, inches
                // and a fraction of an inch at the selected denominator — exactly as the
                // ledger prints it, not the value rounded to a sixteenth of a *foot* and
                // written as `3.375`. No spreadsheet number format spells feet and inches, so
                // the workbook holds decimal feet to four places.
                display = imperial.display
                text = imperial.text
                places = nil
                code = Self.numberFormatCode(
                    decimalPlaces: Self.imperialFeetDecimalPlaces, grouped: grouped
                )
            } else if let notation {
                // BH-143: an area, a volume or any non-length under an imperial project prints
                // the screen's decimal count — `1076.39 ft²` — rather than the value rounded to
                // a sixteenth of a square foot. Rounded once, to that count.
                display = Self.roundedOnce(converted, places: notation.decimalPlaces)
                text = locale.string(display, decimalPlaces: notation.decimalPlaces)
                places = notation.decimalPlaces
                code = Self.numberFormatCode(decimalPlaces: notation.decimalPlaces, grouped: grouped)
            } else {
                // An imperial fraction of anything but a length is the contract's literal
                // rule — the nearest 1/denominator of the display unit — printed with the
                // digits it has. The screen's decimal count for these is not in the frozen
                // `DisplayUnitPolicy`; a caller that has it passes ``ExportScreenNotation``.
                display = formatting.displayDecimal(raw)
                text = locale.string(display, decimalPlaces: nil)
                let digits = Self.fractionDigits(of: display)
                places = digits
                code = Self.numberFormatCode(decimalPlaces: digits, grouped: grouped)
            }
        case nil:
            // No declared precision: every digit the value has, and a format code that shows
            // exactly those digits rather than the integer code that rounded 125.5 to 126 in
            // the workbook (BH-139, BH-140, BH-149).
            display = converted
            text = locale.string(display, decimalPlaces: nil)
            let digits = Self.fractionDigits(of: display)
            places = digits
            // A spreadsheet holds a double: past fifteen places its digits are noise, and a
            // format code longer than Excel accepts would cost the whole workbook a repair.
            code = Self.numberFormatCode(
                decimalPlaces: min(digits, Self.maximumFormatDecimalPlaces), grouped: grouped
            )
        }
        return ExportNumber(
            raw: raw,
            convertedRaw: converted,
            display: display,
            text: text,
            invariantRawText: raw.description,
            unitSymbol: unitSymbol,
            dimension: dimension,
            decimalPlaces: places,
            numberFormatCode: code
        )
    }

    // MARK: - Feet and inches

    /// A length rendered in feet, inches and a fraction of an inch.
    struct ImperialLength: Hashable, Sendable {
        /// `3'-4 13/16"` — the spelling the on-screen ledger uses.
        let text: String
        /// The rounded length, in the column's display unit.
        let display: Decimal
    }

    /// True for a length column shown in feet or inches: the one case an imperial-fraction
    /// precision spells with foot and inch marks.
    static func isImperialLength(
        dimension: QuantityDimension?,
        formatting: LedgerValueFormatting
    ) -> Bool {
        guard (dimension ?? formatting.dimension) == .length,
              case .length(let unit) = formatting.displayUnit
        else { return false }
        // Feet-and-inches marks are for the foot and the inch only; yards and miles are
        // decimal, as the on-screen ledger renders them.
        return unit == .foot || unit == .inch
    }

    /// The feet-and-inches spelling of `raw` metres, rounded once to the nearest
    /// 1/`denominator` of an inch — the same rule the on-screen ledger applies, so the paper
    /// and the screen print the same digits (QUALITY_BAR A25, A29; BH-021).
    ///
    /// Counted in the smallest unit the precision can express, then carried upwards, so a
    /// fraction that rounds up to a whole inch becomes the next inch and a whole foot the next
    /// foot — never `11 16/16"`. The fraction is reduced. A length below the smallest fraction
    /// but not zero says so, `< 1/16"`, rather than printing `0'-0"` for a real length.
    ///
    /// `nil` when the cell is not a length shown in an imperial unit, or when the length is
    /// too large to count in fractions of an inch — a value no takeoff holds.
    static func imperialLength(
        raw: Decimal,
        dimension: QuantityDimension?,
        formatting: LedgerValueFormatting,
        denominator: ImperialFractionDenominator
    ) -> ImperialLength? {
        guard isImperialLength(dimension: dimension, formatting: formatting),
              case .length(let unit) = formatting.displayUnit
        else { return nil }
        let feet = LengthUnit.foot.fromBase(raw)
        let negative = feet < 0
        let magnitude = abs(feet)
        let stepsPerFoot = 12 * denominator.rawValue
        var scaled = magnitude * Decimal(stepsPerFoot)
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded < Decimal(Int.max / 2) else { return nil }
        let steps = NSDecimalNumber(decimal: rounded).intValue
        let roundedFeet = rounded / Decimal(stepsPerFoot)
        let display = unit == .foot ? roundedFeet : LengthUnit.foot.convert(roundedFeet, to: unit)
        let sign = negative ? "-" : ""

        if steps == 0, magnitude > 0 {
            return ImperialLength(text: "\(sign)< 1/\(denominator.rawValue)\"", display: .zero)
        }
        let wholeFeet = steps / stepsPerFoot
        let fraction = steps % denominator.rawValue
        // A column shown in inches reads `40 13/16"` — inches and a fraction, no feet — the
        // way the screen writes it.
        var text = unit == .inch
            ? "\(steps / denominator.rawValue)"
            : "\(wholeFeet)'-\((steps / denominator.rawValue) % 12)"
        if fraction > 0 {
            var numerator = fraction
            var base = denominator.rawValue
            while numerator % 2 == 0, base % 2 == 0 {
                numerator /= 2
                base /= 2
            }
            text += " \(numerator)/\(base)"
        }
        return ImperialLength(text: sign + text + "\"", display: negative ? -display : display)
    }

    // MARK: - Dates

    /// The one Gregorian UTC calendar every ISO-8601 instant is built from, made once (IM-189).
    private static let utcCalendar = calendar(in: .gmt)

    /// A Gregorian calendar in the given zone, for the human-readable dates (BH-533).
    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// ISO-8601, UTC, second resolution, built from a fixed Gregorian calendar rather than from
    /// a `DateFormatter`: no locale, no ICU version, no user regional settings, byte-stable.
    static func iso8601(_ instant: Date) -> String {
        let parts = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: instant
        )
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(abs(value ?? 0))
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
            + "T\(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))Z"
    }

    /// `2026-09-02` — the ISO-8601 calendar date `instant` falls on in `calendar`'s zone.
    static func isoDay(_ instant: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(abs(value ?? 0))
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    /// `29 Aug 2026` — day, abbreviated month, year, in UTC.
    ///
    /// The printed report's date, and nothing else's: see ``ExportDate/humanText`` for why the
    /// three machine formats keep ISO-8601. Built the same hermetic way ``iso8601(_:)`` is —
    /// a fixed Gregorian calendar and a fixed month table, no `DateFormatter` — so the report a
    /// machine in Stockholm prints is byte for byte the report a machine in Denver prints.
    static func humanDate(_ instant: Date) -> String {
        humanDate(instant, calendar: utcCalendar)
    }

    /// `humanDate(_:)` with the calendar day taken in `calendar`'s zone (BH-533).
    static func humanDate(_ instant: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              (1...12).contains(month)
        else { return iso8601(instant) }
        return "\(day) \(monthAbbreviations[month - 1]) \(year)"
    }

    private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]

    private func date(_ instant: Date, context: Context) -> ExportDate {
        ExportDate(
            date: instant,
            iso8601: Self.iso8601(instant),
            humanText: Self.humanDate(instant, calendar: context.humanCalendar)
        )
    }
}
