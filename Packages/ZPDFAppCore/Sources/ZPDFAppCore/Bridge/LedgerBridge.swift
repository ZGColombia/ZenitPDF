import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// A ledger projection that can cross an actor boundary without copying any cells.
///
/// `LedgerView` is a `Sendable` value over `LedgerStore`'s immutable shared backing: it
/// holds arrays of `Int` and the group tree, and produces a cell only when someone asks
/// for one by index. So the session hands the whole projection to the main actor for the
/// price of a few retains, and the presenter builds the forty rows it is about to draw —
/// not the hundred thousand it could draw.
///
/// This is the shape ADR-0003 §3.4 requires, unbroken from `LedgerStore.value(at:column:)`
/// through `LedgerPresenting.row(at:)` to the table's data source.
public struct LedgerProjection: Sendable {

    /// The engine-side projection: filter, sort and grouping already applied.
    public let view: LedgerView
    /// The columns the table draws, in display order, in presentation form.
    public let columns: [ZPDFUIPresentation.LedgerColumn]
    /// Totals over every row that passed the filter, computed by the aggregation core and
    /// never by folding the rows the table happens to have loaded (ADR-0003 §2.2).
    public let grandTotals: LedgerTotals
    /// The group outline, in presentation form. Group *rows* stay index-addressed; only
    /// the outline skeleton is materialised, and it is one node per group, not per row.
    public let rootGroups: [ZPDFUIPresentation.LedgerGroupNode]
    /// Units and precision the display strings were rendered with.
    public let formatter: QuantityFormatter
    /// Display position of each markup, so revealing a markup from the canvas is a lookup
    /// rather than a scan (ADR-0003 §2.3).
    public let positionByMarkupID: [UUID: Int]
    /// The filter rules the engine could not apply, so the pane and the export can say so
    /// rather than claim a filter that quietly lost a rule (CR-56).
    public var unappliedFilterRules: [LedgerFilterDiagnostic] = []
    /// How many markups in the document carry no quantity, whether or not the ledger has a row
    /// for them — the Markups chip's figure (L-50). `nil` for a projection that was not built
    /// from a whole document (a live summary table's own).
    public var nonMeasurementMarkupCount: Int?

    /// Number of rows in display order.
    public var rowCount: Int { view.rowCount }

    /// Number of rows the store holds before the filter narrowed it.
    ///
    /// The same number `LedgerReportBuilder` writes as
    /// `LedgerReportMetadata.totalRowCountBeforeFilter`, read off the same view, so the
    /// pane's "12 of 40 rows" and the export's cannot disagree.
    public var unfilteredRowCount: Int { view.store.rowCount }

    /// Whether the view's own spec is narrowing the store.
    public var isFiltered: Bool { !view.spec.filter.matchesEverything }

    /// An empty projection, for a presenter that has no document yet.
    public static func empty(formatter: QuantityFormatter = QuantityFormatter()) throws -> LedgerProjection {
        let store = try LedgerStore(markups: [], columns: LedgerColumnSet.standard())
        return LedgerBridge.project(store.makeView(LedgerViewSpec()), formatter: formatter)
    }

    /// Builds one presentation row on demand.
    ///
    /// O(visible columns), not O(rows): the only work is reading the cells of this one row
    /// through `LedgerStore.value(at:column:)` — the same single evaluation path the
    /// subtotals and the exporters use, which is what makes "the same number on screen and
    /// in the CSV" structural (QUALITY_BAR A25).
    public func row(at displayIndex: Int) -> ZPDFUIPresentation.LedgerRow? {
        guard displayIndex >= 0, displayIndex < view.rowCount else { return nil }
        return LedgerBridge.row(view: view, displayIndex: displayIndex, formatter: formatter)
    }
}

/// Converts the aggregation core's vocabulary into the table's.
public enum LedgerBridge {

    // MARK: Projection

    /// Wraps an engine view as a projection the presenter can serve rows from.
    public static func project(
        _ view: LedgerView,
        formatter: QuantityFormatter,
        unappliedFilterRules: [LedgerFilterDiagnostic] = []
    ) -> LedgerProjection {
        let definitions = view.columns
        let currency = ledgerCurrencyCode(store: view.store, formatter: formatter)
        var positions: [UUID: Int] = [:]
        positions.reserveCapacity(view.rowCount)
        for display in 0..<view.rowCount {
            positions[view.row(displayRow: display).markupID.rawValue] = display
        }
        let primary = PrimaryQuantityReader(view: view, formatter: formatter)
        var grand = PrimaryTotal()
        for display in 0..<view.rowCount {
            grand.add(primary.contribution(atStoreIndex: view.tree.orderedRowIndices[display]))
        }
        var projection = LedgerProjection(
            view: view,
            columns: definitions.map { column(definition: $0, formatter: formatter, ledgerCurrencyCode: currency) },
            grandTotals: grand.applied(to: totals(
                view.grandTotal,
                rowCount: view.rowCount,
                definitions: definitions,
                formatter: formatter
            ), formatter: formatter),
            rootGroups: view.tree.roots.map {
                group(node: $0, view: view, definitions: definitions, formatter: formatter, primary: primary).node
            },
            formatter: formatter,
            positionByMarkupID: positions
        )
        projection.unappliedFilterRules = unappliedFilterRules
        return projection
    }

    // MARK: Columns

    /// One column header, in presentation form.
    ///
    /// - Parameter ledgerCurrencyCode: the currency a money column without a declared
    ///   currency is typed in — see ``ledgerCurrencyCode(store:formatter:)``. Without it the
    ///   first Unit Cost of a project had no currency to be stored in (NL-QTY-04).
    public static func column(
        definition: LedgerColumnDefinition,
        formatter: QuantityFormatter,
        ledgerCurrencyCode: String? = nil
    ) -> ZPDFUIPresentation.LedgerColumn {
        var dimension = definition.dimension.map { Shown.Dimension(domain: $0) }
        if dimension == nil, definition.kind == .currency, let ledgerCurrencyCode {
            dimension = .currency(ledgerCurrencyCode)
        }
        return ZPDFUIPresentation.LedgerColumn(
            id: LedgerColumnID(definition.key),
            title: title(of: definition),
            kind: columnKind(definition.kind),
            dimension: dimension,
            width: defaultWidth(of: definition),
            pinned: definition.standard == .icon || definition.standard == .subject,
            visible: definition.isVisible,
            alignment: dimension == nil ? .leading : .trailing,
            isEditable: definition.isEditable,
            choices: definition.choices.map {
                LedgerChoiceOption(
                    id: $0.id.rawValue,
                    value: $0.value,
                    title: choiceTitle($0.value, in: definition),
                    colorRGBA: $0.color.map { ColorRGBA(domain: $0) } ?? ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0),
                    order: $0.order,
                    isRetired: $0.isRetired
                )
            },
            formulaSource: definition.formula?.source,
            aggregate: aggregate(for: definition),
            displayUnitSymbol: definition.kind == .currency ? "" : (dimension.map { formatter.units.symbol(for: $0) } ?? ""),
            isUserDefined: definition.standard == nil,
            holdsUserValues: holdsUserValues(definition)
        )
    }

    /// The one rule for "a column whose rows hold a typed value" (NL-QTY-01).
    ///
    /// A user column — made by a person or by a table import, whatever its key — and the
    /// built-in estimating columns the contract marks editable: Cost Code, Trade, Phase,
    /// Material and Unit Cost. Subject, Label, Comment and Status are editable too, but each has
    /// a command of its own. `Unit` (the display unit) is editable in the contract and has no
    /// value in the store to write, so an edit to it would vanish; it is left out. Formula and
    /// measured columns are never typed into.
    public static func holdsUserValues(_ definition: LedgerColumnDefinition) -> Bool {
        guard definition.isEditable, definition.kind != .formula else { return false }
        guard let standard = definition.standard else { return true }
        switch standard {
        case .costCode, .trade, .phase, .material, .unitCost: return true
        default: return false
        }
    }

    /// The currency a money column that declares none is typed in (NL-QTY-04, ADR-0020).
    ///
    /// The currency the ledger already uses — the first Unit Cost stored on any row — so a
    /// project priced in SEK keeps pricing in SEK on every machine that opens it. A project
    /// with no money yet takes the formatter locale's currency, and failing that SEK, the
    /// product's home market. Once a value is stored its own code is what every surface shows,
    /// so the fallback only ever decides the first rate.
    ///
    /// `preferring` names a money column whose own stored amounts decide first — a spreadsheet
    /// filling a custom money column keeps that column's currency. The one rule for every
    /// surface (U-031): the Column Manager, the rate import, assembly recipes and the
    /// spreadsheet round trip all ask here, with the projection's formatter.
    static func ledgerCurrencyCode(
        store: LedgerStore,
        formatter: QuantityFormatter,
        preferring column: ColumnID? = nil
    ) -> String {
        var priced: [ColumnID] = []
        if let column { priced.append(column) }
        if let unitCost = store.columns.columnID(standard: .unitCost), unitCost != column { priced.append(unitCost) }
        for id in priced {
            for index in 0..<store.rowCount {
                if case .currency(_, let code)? = store.row(at: index).record.customValues[id],
                   QuantityDimension.isValidCurrencyCode(code) {
                    return code
                }
            }
        }
        if let code = Locale(identifier: formatter.localeIdentifier).currency?.identifier,
           QuantityDimension.isValidCurrencyCode(code) {
            return code
        }
        return "SEK"
    }

    /// The header text. A built-in column's `key` is a camel-cased identifier, not copy, so
    /// the human title comes from here; a user column already carries its own title.
    static func title(of definition: LedgerColumnDefinition) -> String {
        guard let standard = definition.standard else { return definition.title }
        return standardTitle(standard)
    }

    /// The human title of one choice option.
    ///
    /// A user column's options are typed by the person who made the column, so their value
    /// *is* their title. The built-in Status column is different: its options are
    /// ``ZPDFContracts/MarkupStatus``'s cases, and a frozen enum's `rawValue` is a
    /// camel-cased identifier, not copy. Left alone, the Status cell reads `inProgress`,
    /// the bulk-edit Status menu offers `inProgress`, the filter builder's operand list
    /// offers `inProgress` and a ledger grouped by Status heads a group `inProgress` —
    /// four surfaces showing a serialisation detail. The stored value is untouched; only
    /// what the person reads changes, so filters, exports and round-trips keep comparing
    /// the same tokens they always did.
    static func choiceTitle(_ value: String, in definition: LedgerColumnDefinition) -> String {
        guard definition.standard == .status,
              let status = ZPDFContracts.MarkupStatus(rawValue: value)
        else { return value }
        return statusTitle(status)
    }

    /// Review-status copy (UX_COPY_STANDARD: sentence case, no invented vocabulary).
    ///
    /// Exhaustive on purpose — no `default`. A ninth `MarkupStatus` case must not be able
    /// to reach a person as `someNewCase`; it has to fail the build here first.
    static func statusTitle(_ status: ZPDFContracts.MarkupStatus) -> String {
        switch status {
        case .none: NSLocalizedString("No status", comment: "Review status: not set")
        case .open: NSLocalizedString("Open", comment: "Review status")
        case .inProgress: NSLocalizedString("In progress", comment: "Review status")
        case .resolved: NSLocalizedString("Resolved", comment: "Review status")
        case .accepted: NSLocalizedString("Accepted", comment: "Review status")
        case .rejected: NSLocalizedString("Rejected", comment: "Review status")
        case .cancelled: NSLocalizedString("Cancelled", comment: "Review status")
        case .completed: NSLocalizedString("Completed", comment: "Review status")
        }
    }

    static func standardTitle(_ standard: StandardLedgerColumn) -> String {
        switch standard {
        case .icon: NSLocalizedString("Type", comment: "Ledger column: markup type glyph")
        case .subject: NSLocalizedString("Subject", comment: "Ledger column: takeoff subject")
        case .label: NSLocalizedString("Label", comment: "Ledger column: instance label")
        case .comment: NSLocalizedString("Comment", comment: "Ledger column: comment")
        case .pageLabel: NSLocalizedString("Page", comment: "Ledger column: page label")
        case .pageIndex: NSLocalizedString("Page index", comment: "Ledger column: the sheet's position in its PDF, counted from 1")
        case .projectZone: NSLocalizedString("Project Zone", comment: "Ledger column: Project Zone")
        case .scaleRegion: NSLocalizedString("Scale Region", comment: "Ledger column: Scale Region")
        case .layer: NSLocalizedString("Layer", comment: "Ledger column: layer")
        case .status: NSLocalizedString("Status", comment: "Ledger column: review status")
        case .author: NSLocalizedString("Author", comment: "Ledger column: author")
        case .created: NSLocalizedString("Created", comment: "Ledger column: creation date")
        case .modified: NSLocalizedString("Modified", comment: "Ledger column: modification date")
        case .color: NSLocalizedString("Colour", comment: "Ledger column: markup colour")
        case .count: NSLocalizedString("Count", comment: "Ledger column: count")
        case .planLength: NSLocalizedString("Plan Length", comment: "Ledger column: plan length")
        case .trueLength: NSLocalizedString("True Length", comment: "Ledger column: true length")
        case .perimeter: NSLocalizedString("Perimeter", comment: "Ledger column: perimeter")
        case .planArea: NSLocalizedString("Plan Area", comment: "Ledger column: plan area")
        case .trueArea: NSLocalizedString("True Area", comment: "Ledger column: true area")
        case .wallArea: NSLocalizedString("Wall Area", comment: "Ledger column: net wall area")
        case .volume: NSLocalizedString("Volume", comment: "Ledger column: volume")
        case .rise: NSLocalizedString("Rise", comment: "Ledger column: slope rise")
        case .run: NSLocalizedString("Run", comment: "Ledger column: slope run")
        case .slopeRatio: NSLocalizedString("Slope Ratio", comment: "Ledger column: slope ratio")
        case .slopePercent: NSLocalizedString("Slope %", comment: "Ledger column: slope percent")
        case .slopeAngle: NSLocalizedString("Slope Angle", comment: "Ledger column: slope angle")
        case .depth: NSLocalizedString("Depth", comment: "Ledger column: extrusion depth")
        case .height: NSLocalizedString("Height", comment: "Ledger column: wall height")
        case .radius: NSLocalizedString("Radius", comment: "Ledger column: radius")
        case .diameter: NSLocalizedString("Diameter", comment: "Ledger column: diameter")
        case .displayUnit: NSLocalizedString("Unit", comment: "Ledger column: display unit")
        case .scale: NSLocalizedString("Scale", comment: "Ledger column: scale")
        case .costCode: NSLocalizedString("Cost Code", comment: "Ledger column: cost code")
        case .trade: NSLocalizedString("Trade", comment: "Ledger column: trade")
        case .phase: NSLocalizedString("Phase", comment: "Ledger column: phase")
        case .material: NSLocalizedString("Material", comment: "Ledger column: material")
        case .unitCost: NSLocalizedString("Unit Cost", comment: "Ledger column: unit cost")
        case .totalCost: NSLocalizedString("Total Cost", comment: "Ledger column: total cost")
        case .grossArea: NSLocalizedString("Gross Area", comment: "Ledger column: outline area before cutouts (ADR-0018)")
        case .cutoutArea: NSLocalizedString("Cutout Area", comment: "Ledger column: area removed by cutouts (ADR-0018)")
        }
    }

    static func columnKind(_ kind: ColumnKind) -> LedgerColumnKind {
        switch kind {
        case .text: .text
        case .number: .number
        case .currency: .currency
        case .date: .date
        case .checkbox: .checkbox
        case .choice: .choice
        case .formula: .formula
        }
    }

    /// Which columns roll up into a total. Only dimensioned quantities and money sum; a
    /// page index or a slope ratio must never appear as a grand total, because adding it
    /// produces a number that means nothing (QUALITY_BAR A14).
    ///
    /// The rule is the core's own ``LedgerAggregationPlan/sums(_:)``, not a second copy of it.
    /// The copy that stood here let Rise, Run, Depth and Height through, which the core refuses
    /// to sum, so the totals row drew a labelled, permanently blank slot for each and the
    /// presentation-side summing would have added three wall heights into one "total" (BH-416).
    ///
    /// The dimension guard that stood here is gone: money
    /// columns and number or formula columns without a declared dimension — which the core
    /// totals in every export — drew no subtotal and no grand total on screen, so the screen and
    /// the file disagreed. The core's rule alone decides now.
    static func aggregate(for definition: LedgerColumnDefinition) -> LedgerAggregate? {
        LedgerAggregationPlan.sums(definition) ? .sum : nil
    }

    static func defaultWidth(of definition: LedgerColumnDefinition) -> Double {
        switch definition.standard {
        case .icon, .color: 32
        case .subject, .comment: 180
        case .label, .projectZone, .scaleRegion, .layer, .material: 120
        case .pageLabel, .pageIndex, .status, .displayUnit: 88
        case .created, .modified: 140
        default: definition.dimension == nil ? 120 : 96
        }
    }

    // MARK: Rows

    /// One display row, with its raw values and its formatted strings side by side.
    ///
    /// Both are filled here because the table draws a cell without touching a formatter,
    /// and a filter or a sort needs the raw value. Doing it twice on two code paths is how
    /// a cell and its total come to disagree.
    public static func row(
        view: LedgerView,
        displayIndex: Int,
        formatter: QuantityFormatter
    ) -> ZPDFUIPresentation.LedgerRow {
        row(view: view, handle: view.row(displayRow: displayIndex), formatter: formatter)
    }

    /// One row by its store index, whether or not the view's filter passes it — the same
    /// cells, through the same evaluation path, as a display row (W-042: the Inspector's
    /// Custom Data for a selected markup the filter hides).
    public static func row(
        view: LedgerView,
        storeIndex: Int,
        formatter: QuantityFormatter
    ) -> ZPDFUIPresentation.LedgerRow {
        row(view: view, handle: view.store.row(at: storeIndex), formatter: formatter)
    }

    private static func row(
        view: LedgerView,
        handle: LedgerRowView,
        formatter: QuantityFormatter
    ) -> ZPDFUIPresentation.LedgerRow {
        let record = handle.record
        // NL-MEASURE-10 / ADR-0035: a markup with display units of its own shows its row in
        // them, through the one formatter type; every other row, and every total, stays in the
        // project's units (totals still sum in SI).
        let formatter = record.parameters?.displayOverride.map(formatter.overriding) ?? formatter
        var values: [LedgerColumnID: Shown.CellValue] = [:]
        var displays: [LedgerColumnID: String] = [:]
        // T-057: an error cell's diagnostic, for the table's help tag.
        var notes: [LedgerColumnID: String] = [:]
        let kind = record.tool.map { Shown.Kind(domain: $0) }
        for definition in view.columns {
            let id = LedgerColumnID(definition.key)
            let result = view.store.value(at: handle.index, definition: definition)
            let (value, text) = cell(result, definition: definition, formatter: formatter)
            values[id] = value
            if let error = result.cellError, !error.detail.isEmpty { notes[id] = error.detail }
            // The `Type` column reads `Length` / `Area` / `Count` — the tool's
            // name — not the markup kind's raw token ("measurement"). The raw token stays
            // in `values` for filtering; only the drawn text is the tool's name.
            displays[id] = (definition.standard == .icon ? kind?.displayName : nil) ?? text
        }
        // ADR-0012 rule 5 / ADR-0024: a derived row says so in its Type cell with the ƒ glyph —
        // in words and a glyph, never colour alone — and its comment names the recipe and formula.
        if record.provenance == .derived {
            let type = LedgerColumnID(StandardLedgerColumn.icon.rawValue)
            displays[type] = "ƒ " + (displays[type] ?? "")
        }
        // ADR-0012 rule 5, S-090: a row read from a schedule table leads its Type cell with the
        // ⌐ read marker and says "Read from table" in words where a measured row names its tool.
        // It used to show the markup kind's raw token ("note") and nothing that said read, although
        // the import's own status note promised rows "marked ⌐".
        let provenance: LedgerRowProvenance? = record.provenance == .read ? .read : nil
        if let glyph = provenance?.leaderGlyph {
            let type = LedgerColumnID(StandardLedgerColumn.icon.rawValue)
            let name = kind?.displayName ?? NSLocalizedString(
                "Read from table",
                comment: "Ledger Type cell of a row whose quantity was read from a schedule table, after the read marker"
            )
            displays[type] = glyph + " " + name
        }
        // NL-MEASURE-03: a value kept under an older scale says so, first,
        // in words — the Type cell leads with the badge, so even a narrow column shows it and the
        // row's spoken label and Copy carry it.
        if LedgerOlderScale.isKept(record) {
            let type = LedgerColumnID(StandardLedgerColumn.icon.rawValue)
            displays[type] = LedgerOlderScale.badge + " · " + (displays[type] ?? "")
        }
        displays[LedgerDefaultColumns.unitColumnID] = primaryUnitText(
            kind: kind,
            values: values,
            displays: displays,
            formatter: formatter
        )
        // The `Value` cell as its own number, from the same candidates the unit comes from, so
        // the row never has to parse its value back out of formatted text (IM-098).
        if let primary = primaryValue(kind: kind, values: values, displays: displays) {
            values[LedgerDefaultColumns.valueColumnID] = primary.value
            displays[LedgerDefaultColumns.valueColumnID] = primary.display
        } else if kind == .angle, let angle = record.measurement?[.angle] {
            // X-038: an angle has no ledger column (the Angle tool writes only `angle` since
            // ADR-0019 §2.1), so no candidate carries it and the row's Value and Unit were blank.
            // The headline is read off the record, through the same formatter. Angles never add
            // up, so no total reads this cell (`PrimaryQuantityReader` reads columns only).
            let shown = Shown.Quantity(domain: angle)
            values[LedgerDefaultColumns.valueColumnID] = .quantity(shown)
            displays[LedgerDefaultColumns.valueColumnID] = formatter.text(shown)
            displays[LedgerDefaultColumns.unitColumnID] = formatter.symbol(shown)
        }
        var row = ZPDFUIPresentation.LedgerRow(
            markupID: record.id.rawValue,
            // A cutout's parent, or the measured row an assembly derived this one from — the
            // table steps both in under their source (NL-QTY-07).
            parentID: (record.parentMarkupID ?? record.derivation?.sourceMarkupID)?.rawValue,
            values: values,
            displayValues: displays,
            colorRGBA: ColorRGBA(domain: record.style.color),
            kind: Shown.Markup(domain: record.kind),
            measurementKind: kind,
            matchesFilter: true,
            locked: record.locked,
            hidden: record.hidden
        )
        row.provenance = provenance
        row.cellNotes = notes.isEmpty ? nil : notes
        return row
    }

    /// The unit symbol of the row's primary quantity — the string the `Unit` column shows.
    ///
    /// Derived from the same cell values the `Value` column reads, through the same
    /// formatter, so the number and its unit can never disagree. A bare count reads as
    /// pieces — `st` — because a blank unit next to `5` reads as a missing
    /// value, not as a count. Rows that carry no quantity (text, callouts) stay blank.
    public static func primaryUnitText(
        kind: Shown.Kind?,
        values: [LedgerColumnID: Shown.CellValue],
        displays: [LedgerColumnID: String],
        formatter: QuantityFormatter
    ) -> String {
        var candidates = LedgerDefaultColumns.primaryCandidates(for: kind)
        if kind != nil {
            candidates += LedgerDefaultColumns.fallbackCandidates
        }
        for candidate in candidates {
            guard let display = displays[candidate], !display.isEmpty else { continue }
            if candidate == .count {
                return NSLocalizedString("pcs", comment: "Unit symbol for a count of pieces")
            }
            if case .quantity(let quantity)? = values[candidate] {
                return formatter.symbol(quantity)
            }
        }
        return ""
    }

    /// The row's primary quantity cell and its display text, or `nil` when the row carries no
    /// quantity — the pair the `Value` column shows.
    public static func primaryValue(
        kind: Shown.Kind?,
        values: [LedgerColumnID: Shown.CellValue],
        displays: [LedgerColumnID: String]
    ) -> (value: Shown.CellValue, display: String)? {
        var candidates = LedgerDefaultColumns.primaryCandidates(for: kind)
        if kind != nil { candidates += LedgerDefaultColumns.fallbackCandidates }
        for candidate in candidates {
            guard let display = displays[candidate], !display.isEmpty, let value = values[candidate] else { continue }
            return (value, display)
        }
        return nil
    }

    /// One cell: the value the filter reads and the string the table draws.
    ///
    /// An error cell is *not* an empty cell. It renders as an explicit reason, because a
    /// blank where a number failed is the single most expensive lie a takeoff can tell
    /// (QUALITY_BAR A11, A27).
    public static func cell(
        _ result: LedgerCellResult,
        definition: LedgerColumnDefinition,
        formatter: QuantityFormatter
    ) -> (Shown.CellValue, String) {
        switch result {
        case .error(let error):
            return (.text(errorText(error)), errorText(error))
        case .value(let value):
            return cellValue(value, definition: definition, formatter: formatter)
        }
    }

    static func cellValue(
        _ value: Domain.CellValue,
        definition: LedgerColumnDefinition,
        formatter: QuantityFormatter
    ) -> (Shown.CellValue, String) {
        switch value {
        case .empty:
            return (.empty, "")
        case .text(let text):
            return (.text(text), text)
        case .date(let date):
            return (.date(date), dateText(date, localeIdentifier: formatter.localeIdentifier))
        case .checkbox(let flag):
            return (.checkbox(flag), flag ? "✓" : "")
        case .choice(let optionID):
            guard let option = definition.choices.first(where: { $0.id == optionID }) else {
                return (.choice(""), "")
            }
            // The cell keeps the stored option value — filters, grouping keys, bulk-edit
            // comparisons and every export compare on it — while the person reads the
            // option's title. For a user column the two are the same string.
            return (.choice(option.value), choiceTitle(option.value, in: definition))
        case .currency(let amount, let code):
            return (
                .currency(amount: amount, code: code),
                currencyText(amount, code: code, localeIdentifier: formatter.localeIdentifier)
            )
        case .number(let quantity):
            return quantityCell(quantity, definition: definition, formatter: formatter)
        case .formulaResult(let quantity, let grammarVersion):
            guard grammarVersion == FormulaGrammarVersion.current else {
                let text = NSLocalizedString(
                    "Recalculate",
                    comment: "Ledger cell shown when a cached formula result predates the current grammar"
                )
                return (.text(text), text)
            }
            return quantityCell(quantity, definition: definition, formatter: formatter)
        }
    }

    static func quantityCell(
        _ quantity: Domain.Quantity,
        definition: LedgerColumnDefinition,
        formatter: QuantityFormatter
    ) -> (Shown.CellValue, String) {
        let shown = Shown.Quantity(domain: quantity)
        // The Repeat × cell shows the multiplier the row actually carries, so a stored 2.9
        // or 0 (an older file, a hand edit) cannot read one number while the badge and the
        // totals use another (BH-104, BH-105).
        if definition.id == RepetitionColumn.columnID {
            let count = RepetitionColumn.effectiveCount(of: quantity) ?? RepetitionColumn.defaultCount
            return (.number(Decimal(count)), formatter.text(Shown.Quantity(value: Decimal(count), dimension: .ratio)))
        }
        if definition.standard == .slopeRatio {
            return (.quantity(shown), formatter.slopeText(ratio: shown.value))
        }
        // L-46: the Page index cell names the sheet the way a person counts it,
        // from 1. The stored index stays 0-based in the value the filter seam, the sort and the
        // round trip read; only the drawn text — which the on-screen CSV copies — moves, so the
        // screen, the CSV and every projected export print the same number (QUALITY_BAR A29).
        if definition.standard == .pageIndex {
            return (.number(shown.value), pageNumberText(shown, formatter: formatter))
        }
        let dimensionless = shown.dimension.lengthPower == 0
            && !shown.dimension.angle
            && shown.dimension.currencyCode == nil
        if dimensionless, definition.standard != .count {
            return (.number(shown.value), formatter.text(shown))
        }
        return (.quantity(shown), formatter.text(shown))
    }

    /// The page a stored 0-based page index names, as the Page index cell and its group heading
    /// write it: the first sheet is page 1 (L-46). The one rule for the screen; the projected
    /// exports apply the same `+ 1` in `ExportProjector.pageNumber`, and
    /// `L8PageIndexAgreementTests` holds the two to each other cell for cell.
    static func pageNumberText(_ index: Shown.Quantity, formatter: QuantityFormatter) -> String {
        formatter.text(Shown.Quantity(value: index.value + 1, dimension: index.dimension))
    }

    /// A filter operand on the Page index column, typed as the page number the cells show,
    /// moved onto the 0-based index the engine compares (L-46). "Page index is 2" keeps the rows
    /// whose cell reads 2 — the second sheet, stored as 1. Any other operand is unchanged.
    static func pageIndexFilterValue(_ value: LedgerFilterValue) -> LedgerFilterValue {
        switch value {
        case .number(let page): .number(page - 1)
        case let .numberRange(lower, upper): .numberRange(lower: lower - 1, upper: upper - 1)
        case let .quantity(quantity):
            .quantity(ZPDFContracts.DecimalQuantity(value: quantity.value - 1, dimension: quantity.dimension))
        default: value
        }
    }

    /// A dimensionless quantity re-tagged as the count or the ratio its column declares
    /// (ADR-0014 §3).
    ///
    /// The seam carries the `ratio` tag both ways (S-089), but a value can still arrive
    /// untagged — a bare number typed into the panel, a cell decoded from a project written
    /// before the tag — and is then a *count* by default, and a count added to a stored ratio
    /// is refused. The column is
    /// the authority on what a dimensionless number in it means: `Repeat ×` and a
    /// ratio-typed custom column say ratio, a count column says count, and a number column
    /// with no declared dimension keeps the factor reading an untyped number has always had.
    /// A dimensioned quantity, or a dimensioned column, is left alone so the mismatch stays
    /// visible to `validate(against:)`.
    public static func retagged(
        _ quantity: Domain.Quantity,
        for definition: LedgerColumnDefinition
    ) -> Domain.Quantity {
        guard quantity.dimension.isDimensionless else { return quantity }
        let tag: Bool
        if let declared = definition.dimension {
            guard declared.isDimensionless else { return quantity }
            tag = declared.ratio
        } else {
            tag = true
        }
        guard quantity.dimension.ratio != tag else { return quantity }
        return Domain.Quantity(value: quantity.value, dimension: tag ? .ratio : .count)
    }

    /// The reverse of ``cellValue(_:definition:formatter:)``: a value the user typed into
    /// a panel, turned back into the domain value a `MarkupRecord` stores.
    ///
    /// `nil` means "this value does not belong in this column" — a text value aimed at a
    /// currency column, or a choice whose option the column does not offer. Returning
    /// `nil` rather than coercing is deliberate: `LedgerCellValue.validate(against:)`
    /// would reject the coercion anyway, and a silently coerced cell is a wrong number
    /// with a plausible face.
    public static func domainCellValue(
        _ value: ZPDFUIPresentation.LedgerCellValue,
        definition: LedgerColumnDefinition
    ) -> Domain.CellValue? {
        switch value {
        case .empty:
            return .empty
        case .text(let text):
            guard definition.kind == .text else { return nil }
            return .text(text)
        case .number(let decimal):
            guard definition.kind == .number else { return nil }
            let cell = Domain.CellValue.number(Domain.Quantity(value: decimal, dimension: definition.dimension ?? .ratio))
            // The reserved Repeat × column takes whole counts only (BH-104, BH-105, BH-437).
            if definition.id == RepetitionColumn.columnID { return RepetitionColumn.validatedCellValue(cell) }
            return cell
        case .quantity(let quantity):
            guard definition.kind == .number else { return nil }
            let cell = Domain.CellValue.number(retagged(Domain.Quantity(shown: quantity), for: definition))
            if definition.id == RepetitionColumn.columnID { return RepetitionColumn.validatedCellValue(cell) }
            return cell
        case .currency(let amount, let code):
            guard definition.kind == .currency else { return nil }
            return .currency(amount: amount, code: code)
        case .date(let date):
            guard definition.kind == .date else { return nil }
            return .date(date)
        case .checkbox(let flag):
            guard definition.kind == .checkbox else { return nil }
            return .checkbox(flag)
        case .choice(let stored):
            guard definition.kind == .choice,
                  let option = definition.choices.first(where: { $0.value == stored })
            else { return nil }
            return .choice(option.id)
        }
    }

    static func errorText(_ error: LedgerCellError) -> String {
        switch error.kind {
        case .formulaEvaluation:
            return NSLocalizedString("Formula error", comment: "Ledger cell whose formula failed")
        case .dimensionMismatch:
            return NSLocalizedString("Mixed units", comment: "Ledger cell whose dimensions disagree")
        case .divisionByZero:
            return NSLocalizedString("Divide by zero", comment: "Ledger cell that divided by zero")
        case .grammarVersionMismatch:
            return NSLocalizedString("Recalculate", comment: "Ledger cell cached under an older grammar")
        case .aggregation:
            return NSLocalizedString("Not available", comment: "Ledger cell the aggregation core refused")
        case .missingInput:
            // V-058: nothing to compute from on this row (no area, no pack size); totals leave
            // the cell out, and the help tag names the blank input.
            return NSLocalizedString("No input", comment: "Ledger formula cell whose input is blank on this row")
        }
    }

    // MARK: Totals and groups

    /// The words a refused total shows in its cell.
    static func refusalText(_ aggregate: AggregateValue) -> String {
        switch aggregate {
        case .mixedDimensions:
            return NSLocalizedString(
                "Mixed units",
                comment: "Ledger total cell when the rows carry units that cannot be added"
            )
        default:
            return NSLocalizedString(
                "Cannot total",
                comment: "Ledger total cell when the total could not be computed"
            )
        }
    }

    /// Aggregates in the shape the totals row draws.
    ///
    /// A column only gets a number when the core produced one. A refusal becomes an entry
    /// in ``LedgerTotals/incompatibleColumns`` so the cell states "Mixed units" rather than
    /// showing a partial sum.
    public static func totals(
        _ aggregates: LedgerAggregates,
        rowCount: Int,
        definitions: [LedgerColumnDefinition],
        formatter: QuantityFormatter
    ) -> LedgerTotals {
        var quantities: [LedgerColumnID: Shown.Quantity] = [:]
        var displays: [LedgerColumnID: String] = [:]
        var incompatible: Set<LedgerColumnID> = []
        var valueCounts: [LedgerColumnID: Int] = [:]

        for definition in definitions {
            let id = LedgerColumnID(definition.key)
            guard let aggregate = aggregates[definition.id] else { continue }
            // S-043: the rows that carried a value into this total, from
            // the accumulator that made it, so a summary chip's count cannot disagree with it.
            if let accumulator = aggregates.accumulator(AggregateKey(column: definition.id, function: .sum)) {
                valueCounts[id] = accumulator.valueCount
            }
            // A refusal is a state the cell says in words. It used to get no display text at
            // all, so "Mixed units" rendered as an empty cell — the blank-for-a-failed-number
            // QUALITY_BAR A11 forbids (BH-091).
            if aggregate.isRefusal {
                incompatible.insert(id)
                displays[id] = refusalText(aggregate)
                continue
            }
            // `.empty` — no row contributed — is not a refusal and not a unit conflict; it was
            // filed under `incompatibleColumns` beside real mixed-unit totals (BH-417).
            guard let decimal = aggregate.decimal,
                  let dimension = aggregate.dimension ?? definition.dimension else { continue }
            let quantity = Shown.Quantity(value: decimal, dimension: Shown.Dimension(domain: dimension))
            quantities[id] = quantity
            // Money reads the way its cells read — through the same currency style — so a
            // column of "450,00 kr" cells totals to "1 350,00 kr", not to a bare number.
            if case .currency(let amount, let code) = aggregate {
                displays[id] = currencyText(amount, code: code, localeIdentifier: formatter.localeIdentifier)
            } else {
                displays[id] = formatter.text(quantity)
            }
        }

        return LedgerTotals(
            rowCount: rowCount,
            quantities: quantities,
            displayValues: displays,
            incompatibleColumns: incompatible,
            valueCounts: valueCounts
        )
    }

    /// One outline node. Children recurse; the node's rows are *not* materialised — the
    /// table asks the projection for them by display index like every other row.
    static func group(
        node: ZPDFQuantityLedger.LedgerGroupNode,
        view: LedgerView,
        definitions: [LedgerColumnDefinition],
        formatter: QuantityFormatter
    ) -> ZPDFUIPresentation.LedgerGroupNode {
        group(
            node: node, view: view, definitions: definitions, formatter: formatter,
            primary: PrimaryQuantityReader(view: view, formatter: formatter)
        ).node
    }

    /// One group, with its `Value` subtotal: the sum of its rows' primary quantities, refused
    /// as mixed when their dimensions differ (IM-014). The subtotal is read through the
    /// same cells the rows show, so a group header and its rows cannot disagree (A25).
    static func group(
        node: ZPDFQuantityLedger.LedgerGroupNode,
        view: LedgerView,
        definitions: [LedgerColumnDefinition],
        formatter: QuantityFormatter,
        primary: PrimaryQuantityReader
    ) -> (node: ZPDFUIPresentation.LedgerGroupNode, total: PrimaryTotal) {
        let definition = view.store.columns.column(id: node.field.column)
        var total = PrimaryTotal()
        var children: [ZPDFUIPresentation.LedgerGroupNode] = []
        if node.isLeaf {
            for index in node.rowIndices { total.add(primary.contribution(atStoreIndex: index)) }
        } else {
            for child in node.children {
                let built = group(node: child, view: view, definitions: definitions, formatter: formatter, primary: primary)
                children.append(built.node)
                total.merge(built.total)
            }
        }
        let presented = ZPDFUIPresentation.LedgerGroupNode(
            id: groupIdentity(node.path),
            title: groupTitle(node.key, definition: definition, formatter: formatter),
            groupingColumn: definition.map { LedgerColumnID($0.key) },
            groupingValue: node.key.token,
            depth: node.depth,
            isExpanded: true,
            children: children,
            rows: [],
            totals: total.applied(to: totals(
                node.aggregates,
                rowCount: node.descendantRowCount,
                definitions: definitions,
                formatter: formatter
            ), formatter: formatter),
            colorRGBA: groupColor(node.key, definition: definition)
        )
        return (presented, total)
    }

    /// Reads a row's primary quantity — the `Value` column — from the store, through the same
    /// cell rendering and candidate order the row itself uses.
    struct PrimaryQuantityReader {
        let view: LedgerView
        let formatter: QuantityFormatter
        private let definitionsByKey: [String: LedgerColumnDefinition]

        init(view: LedgerView, formatter: QuantityFormatter) {
            self.view = view
            self.formatter = formatter
            var byKey: [String: LedgerColumnDefinition] = [:]
            for column in view.store.columns.columns where byKey[column.key] == nil { byKey[column.key] = column }
            self.definitionsByKey = byKey
        }

        func quantity(atStoreIndex index: Int) -> Shown.Quantity? {
            contribution(atStoreIndex: index)?.quantity
        }

        /// The row's primary quantity and whether the core sums the column it came from.
        ///
        /// A Slope row's `Value` is its slope ratio, a Rise/Drop row's its rise: the core's
        /// ``LedgerAggregationPlan/sums(_:)`` refuses to total those columns (QUALITY_BAR A14,
        /// BH-416), so their `Value` must not total either (BH-240). The column decides, not
        /// the dimension: the core stores a slope ratio as a plain dimensionless number, which
        /// a dimension check cannot tell from a count.
        func contribution(atStoreIndex index: Int) -> PrimaryContribution? {
            let kind = view.store.row(at: index).record.tool.map { Shown.Kind(domain: $0) }
            var candidates = LedgerDefaultColumns.primaryCandidates(for: kind)
            if kind != nil { candidates += LedgerDefaultColumns.fallbackCandidates }
            for candidate in candidates {
                guard let definition = definitionsByKey[candidate.rawValue] else { continue }
                let (value, text) = LedgerBridge.cell(
                    view.store.value(at: index, definition: definition),
                    definition: definition,
                    formatter: formatter
                )
                guard !text.isEmpty else { continue }
                guard let quantity = value.asQuantity else { return nil }
                return PrimaryContribution(quantity: quantity, isAdditive: LedgerAggregationPlan.sums(definition))
            }
            return nil
        }
    }

    /// One row's `Value`, and whether it may be added to another row's.
    struct PrimaryContribution {
        let quantity: Shown.Quantity
        let isAdditive: Bool
    }

    /// A running `Value` total: exact, and refused the moment two dimensions meet.
    ///
    /// Since IM-011 this is the only fold behind the table's `Value` headings — the table
    /// draws the core's outline instead of re-adding its rows — so it carries the two rules
    /// the table's own fold used to apply: a slope ratio or an angle is a fact about one
    /// markup and never summable (QUALITY_BAR A14, BH-240), and an addition that is not exact
    /// refuses the total rather than rounding it (CR-54).
    struct PrimaryTotal {
        var value: Decimal = 0
        var dimension: Shown.Dimension?
        var isMixed = false
        var hasValue = false
        /// A ratio or an angle reached the fold: the group has no `Value` total at all —
        /// not a unit conflict, just nothing that adds up.
        var isNonAdditive = false
        /// An addition overflowed `Decimal`'s 38 digits.
        var isFailed = false

        private var isRefused: Bool { isMixed || isNonAdditive || isFailed }

        mutating func add(_ contribution: PrimaryContribution?) {
            guard let contribution else { return }
            guard contribution.isAdditive else {
                if !isRefused { isNonAdditive = true }
                return
            }
            add(contribution.quantity)
        }

        mutating func add(_ quantity: Shown.Quantity?) {
            guard let quantity, !isRefused else { return }
            if quantity.dimension.ratio || quantity.dimension.angle {
                isNonAdditive = true
                return
            }
            if let dimension, dimension != quantity.dimension {
                isMixed = true
                return
            }
            var left = value
            var right = quantity.value
            var sum = Decimal()
            guard NSDecimalAdd(&sum, &left, &right, .plain) == .noError else {
                isFailed = true
                return
            }
            dimension = quantity.dimension
            value = sum
            hasValue = true
        }

        mutating func merge(_ other: PrimaryTotal) {
            // Same precedence as the table's former fold: a failure, then a unit conflict,
            // then a non-additive member.
            if other.isFailed { isFailed = true }
            guard !isFailed else { return }
            if other.isMixed { isMixed = true }
            guard !isMixed else { return }
            if other.isNonAdditive { isNonAdditive = true }
            guard !isNonAdditive else { return }
            guard other.hasValue, let otherDimension = other.dimension else { return }
            add(Shown.Quantity(value: other.value, dimension: otherDimension))
        }

        func applied(to totals: LedgerTotals, formatter: QuantityFormatter) -> LedgerTotals {
            var result = totals
            let id = LedgerDefaultColumns.valueColumnID
            if isFailed {
                result.incompatibleColumns.insert(id)
                result.displayValues[id] = NSLocalizedString(
                    "Cannot total",
                    comment: "Ledger total cell when the total could not be computed"
                )
            } else if isMixed {
                result.incompatibleColumns.insert(id)
                result.displayValues[id] = NSLocalizedString(
                    "Mixed units",
                    comment: "Ledger total cell when the rows carry units that cannot be added"
                )
            } else if isNonAdditive {
                // No number and no refusal text: a Slope group's heading shows its count, and
                // its `Value` cell stays empty, like a column that declares no total.
                result.quantities[id] = nil
                result.displayValues[id] = nil
            } else if hasValue, let dimension {
                let quantity = Shown.Quantity(value: value, dimension: dimension)
                result.quantities[id] = quantity
                result.displayValues[id] = formatter.text(quantity)
            }
            return result
        }
    }

    /// The heading a person reads above a group's subtotal row.
    ///
    /// ``ZPDFQuantityLedger/LedgerGroupKey/token`` is deliberately a machine token — `t:Slab`,
    /// `o:9F3C…`, `d:781372800.0` — and says so in its own documentation: *"the human-readable
    /// label is the view's business"*. It stays the group's `groupingValue`, which is what
    /// ordering, expansion identity and round-tripping compare on; the title is rendered the
    /// same way the corresponding *cell* is rendered, so a group heading and the rows under it
    /// agree word for word.
    static func groupTitle(
        _ key: LedgerGroupKey,
        definition: LedgerColumnDefinition?,
        formatter: QuantityFormatter
    ) -> String {
        switch key {
        case .text(let text):
            // T-046: a Type group is keyed on the tool token ("rectangleArea"); its heading is
            // the tool's name, the text the Type cells under it show ("Rectangle Area").
            if definition?.standard == .icon, let tool = MeasurementTool(rawValue: text) {
                return Shown.Kind(domain: tool).displayName
            }
            return text
        case .number(let quantity):
            // A Slope Ratio heading is rendered the way its cells are — "50.0 %", "1:2.00" —
            // not as the bare ratio "0.5" (BH-418).
            if definition?.standard == .slopeRatio {
                return formatter.slopeText(ratio: quantity.value)
            }
            let shown = Shown.Quantity(value: quantity.value, dimension: Shown.Dimension(domain: quantity.dimension))
            // A Page index group is headed by the page number its cells show (L-46).
            if definition?.standard == .pageIndex {
                return pageNumberText(shown, formatter: formatter)
            }
            return formatter.text(shown)
        case .currency(let amount, let code):
            return currencyText(amount, code: code, localeIdentifier: formatter.localeIdentifier)
        case .date(let date):
            return dateText(date, localeIdentifier: formatter.localeIdentifier)
        case .boolean(let flag):
            return flag
                ? NSLocalizedString("Yes", comment: "Ledger group heading for a ticked checkbox")
                : NSLocalizedString("No", comment: "Ledger group heading for an unticked checkbox")
        case .choice(let optionID):
            guard let definition,
                  let option = definition.choices.first(where: { $0.id == optionID })
            else { return NSLocalizedString("(none)", comment: "Ledger group heading: no value") }
            return choiceTitle(option.value, in: definition)
        case .none:
            return NSLocalizedString("(none)", comment: "Ledger group heading: no value")
        case .error:
            return NSLocalizedString("(error)", comment: "Ledger group heading: the key cell failed")
        }
    }

    /// The redundant colour cue of a choice group: its option's colour, as the table's own
    /// grouping drew it before the table took its outline from here (IM-011). `nil` for every
    /// other key and for an option without a colour.
    static func groupColor(_ key: LedgerGroupKey, definition: LedgerColumnDefinition?) -> ColorRGBA? {
        guard case .choice(let optionID) = key,
              let option = definition?.choices.first(where: { $0.id == optionID }),
              let color = option.color
        else { return nil }
        return ColorRGBA(domain: color)
    }

    /// A stable identity for a group node, derived from its path rather than generated.
    ///
    /// Generating a fresh `UUID` per rebuild would collapse every expanded group the
    /// moment the user changed a filter; deriving it from the path means the same group is
    /// the same node across rebuilds.
    static func groupIdentity(_ path: [LedgerGroupKey]) -> UUID {
        LedgerIdentifiers.deterministicUUID(
            namespace: "zenit.pdf/ledger/group-node/v1",
            name: path.map(\.token).joined(separator: "\u{1F}")
        )
    }

    // MARK: Formatters

    /// A date cell, in the formatter's locale rather than the process locale.
    ///
    /// The locale is threaded through from ``QuantityFormatter`` deliberately: a cell that
    /// reads `23 aug. 2026` on one machine and `Aug 23, 2026` on another is a diff in every
    /// exported CSV and a mismatch in every golden test.
    /// A date cell's text. Through `Date.FormatStyle` — a value type whose ICU formatter
    /// Foundation caches — rather than a `DateFormatter` allocated per cell (IM-096).
    static func dateText(_ date: Date, localeIdentifier: String) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: localeIdentifier)))
    }

    /// A money cell's text, through the cached currency format style (IM-096).
    ///
    /// Rounded half away from zero at the currency's own minor digits, the product-wide display
    /// rule (`LedgerDisplayRounding`, `.plain`) the group header and the exports use. The
    /// style's default is ICU's half-even, so a Total Cost of 17 × 45.125 = 767.125 read
    /// "767,12 kr" in the cell while its heading and the workbook said 767.13 (S-079).
    /// Through `LedgerMoneyFormatting`, the one money formatter the table, its headings and the
    /// Rate Library share, so the rule cannot drift between them again (T-052).
    static func currencyText(_ amount: Decimal, code: String, localeIdentifier: String) -> String {
        LedgerMoneyFormatting.text(amount, currencyCode: code, locale: Locale(identifier: localeIdentifier))
    }
}

/// The formula grammar version this build evaluates against.
enum FormulaGrammarVersion {
    static let current = ContractVersion.formula
}
