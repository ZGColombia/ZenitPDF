import Foundation

/// The Quantity Ledger's default column arrangement, fixed by the main-window mockup:
/// `Page · Type · Label · Subject · Comment · Value · Unit`, with widths that keep Value
/// and Unit on screen at the default window size.
///
/// `Value` and `Unit` are *display* columns: the aggregation core keeps one column per
/// measurement field (plan length, plan area, count, …), which is right for totals but is
/// not what the mockup shows. The two display columns render each row's primary quantity —
/// the field ``MeasurementKind/primaryField`` names — split into its number and its unit
/// symbol. They synthesise nothing: every string they show is taken verbatim from the
/// formatted cell the core produced, so the number on screen is still the number in the
/// export (QUALITY_BAR A25).
///
/// Saved layouts migrate untouched: `LedgerColumnLayout.applied(to:)` already ignores
/// identifiers it does not know and appends columns a layout never mentioned, so a stored
/// layout keeps working — only the *default* arrangement changes.
public enum LedgerDefaultColumns {

    // MARK: Display column identities

    /// The mockup's `Value` column: the row's primary quantity, number only.
    public static let valueColumnID = LedgerColumnID("display.value")
    /// The mockup's `Unit` column: the primary quantity's unit symbol.
    public static let unitColumnID = LedgerColumnID("display.unit")

    /// Whether a column is one of the two synthesised display columns.
    public static func isDisplayColumn(_ id: LedgerColumnID) -> Bool {
        id == valueColumnID || id == unitColumnID
    }

    /// The default grouping: by measurement type — the Type column — with collapsible
    /// per-type subtotal headers. The grouping menu still offers
    /// every other level, and "no grouping" remains the flat list.
    public static let defaultGroupingColumns: [LedgerColumnID] = [.icon]

    /// The default visible columns, in mockup order, with one addition:
    /// `Perimeter` joins the set right after `Value`/`Unit` — populated for areas,
    /// perimeters and polygons, empty for pure lengths and counts.
    public static let defaultOrder: [LedgerColumnID] = [
        .pageLabel, .icon, .label, .subject, .comment, valueColumnID, unitColumnID, .perimeter
    ]

    /// Default widths, chosen so the whole default set fits the minimum window width
    /// (1040 pt) with room to spare — re-trimmed when Perimeter joined the set so it never
    /// lands off-screen. `Value` is wide enough for six
    /// digits plus decimals; `Unit` is deliberately narrow — it holds a symbol, never a
    /// number.
    public static func defaultWidth(for id: LedgerColumnID) -> Double {
        switch id {
        case .pageLabel: return 46
        case .icon: return 50
        case .label: return 98
        case .subject: return 126
        case .comment: return 110
        case valueColumnID: return 88
        case unitColumnID: return 48
        case .perimeter: return 84
        default: return 96
        }
    }

    /// The `Value` display column: right-aligned, monospaced digits (its kind is `number`).
    ///
    /// Carries `.sum` so a *group* header can show one merged total for its rows — the
    /// summary shape type grouping needs. The presenter's outline carries that
    /// total, the sum of each row's primary quantity, and the unit-compatibility rule applies
    /// unchanged: a group that mixes metres with square metres refuses the sum rather than
    /// inventing one. The grand-total bar renders engine totals and display columns are
    /// excluded there, so this aggregate changes group headers only.
    public static func valueColumn() -> LedgerColumn {
        LedgerColumn(
            id: valueColumnID,
            title: NSLocalizedString("Value", comment: "Ledger column: the row's primary quantity"),
            kind: .number,
            width: defaultWidth(for: valueColumnID),
            alignment: .trailing,
            aggregate: .sum
        )
    }

    /// The `Unit` display column: a narrow text column for the unit symbol.
    public static func unitColumn() -> LedgerColumn {
        LedgerColumn(
            id: unitColumnID,
            title: NSLocalizedString("Unit", comment: "Ledger column: the primary quantity's unit"),
            kind: .text,
            width: defaultWidth(for: unitColumnID),
            alignment: .leading
        )
    }

    // MARK: Arrangement

    /// Rearranges a projection's columns into the default: the mockup's seven lead and are
    /// visible, everything else keeps its place after them, hidden until the user shows it.
    ///
    /// User-created (`custom.`) columns keep their own visibility — hiding a column the
    /// user built because a default changed would read as data loss.
    public static func arranged(_ columns: [LedgerColumn]) -> [LedgerColumn] {
        var byID: [LedgerColumnID: LedgerColumn] = [:]
        for column in columns { byID[column.id] = column }

        var result: [LedgerColumn] = []
        result.reserveCapacity(columns.count + 2)
        var consumed: Set<LedgerColumnID> = []

        // The lead is ``defaultOrder``, declared once (R-148: this loop used to spell the same
        // order out as its own literal, so editing `defaultOrder` changed nothing).
        for id in defaultOrder {
            switch id {
            case valueColumnID:
                result.append(valueColumn())
            case unitColumnID:
                result.append(unitColumn())
            default:
                guard var column = byID[id] else { continue }
                column.visible = true
                column.pinned = false
                column.width = defaultWidth(for: id)
                // The projection's own Perimeter column — dimension,
                // aggregate and unit symbol intact — becomes visible right after Value/Unit.
                if id == .perimeter { column.alignment = .trailing }
                result.append(column)
                consumed.insert(id)
            }
        }

        for column in columns where !consumed.contains(column.id) && !isDisplayColumn(column.id) {
            var trailing = column
            trailing.pinned = false
            // NL-QTY-01: a column a person made (or imported) stays as its definition says;
            // the built-in extras start hidden until shown from the Columns menu.
            if !trailing.isUserDefined { trailing.visible = false }
            result.append(trailing)
        }
        return result
    }

    // MARK: Row rendering

    /// The formatted text a row shows in a column, display columns included.
    ///
    /// The `Type` column falls back to the measurement tool's name when the core supplied
    /// no cell text — the mockup's `Type` column reads `Length`/`Area`/`Count`, not a blank.
    public static func displayText(for row: LedgerRow, columnID: LedgerColumnID) -> String {
        switch columnID {
        case valueColumnID:
            return valueText(for: row)
        case unitColumnID:
            return unitText(for: row)
        case .icon:
            let stored = row.displayValue(.icon)
            guard stored.isEmpty else { return stored }
            return row.measurementKind?.displayName ?? ""
        default:
            return row.displayValue(columnID)
        }
    }

    /// The row's primary quantity, number only.
    public static func valueText(for row: LedgerRow) -> String {
        // IM-098: the producer's own number text wins, so a row's
        // Value cell never re-parses formatted text; splitting is the fallback.
        let stored = row.displayValue(valueColumnID)
        if !stored.isEmpty { return stored }
        return splitUnit(primaryDisplay(for: row)).value
    }

    /// The row's primary quantity's unit symbol.
    ///
    /// The producer may store the symbol directly under ``unitColumnID`` — the app tier
    /// derives it from the primary quantity's dimension, which survives display strings
    /// that carry no unit. Splitting the formatted primary display is the fallback for
    /// rows built without that cell.
    public static func unitText(for row: LedgerRow) -> String {
        let stored = row.displayValue(unitColumnID)
        if !stored.isEmpty { return stored }
        return splitUnit(primaryDisplay(for: row)).unit
    }

    /// The columns that can carry a row's primary quantity, most specific first.
    ///
    /// The first candidate is the column behind ``MeasurementKind/primaryField``; the rest
    /// are honest stand-ins for tools whose primary field has no ledger column of its own
    /// (an arc length lands in plan length). An angle has no column at all — the Angle tool
    /// writes only `angle` (ADR-0019 §2.1) and no ledger column reads it — so it has no
    /// candidate, and the app tier stores its Value and Unit cells from the record (X-038).
    public static func primaryCandidates(for kind: MeasurementKind?) -> [LedgerColumnID] {
        switch kind {
        case .count:
            return [.count]
        case .length, .dimension, .polylength, .temporaryMeasure, .arcLength:
            return [.planLength, .trueLength]
        case .perimeter:
            return [.perimeter, .planLength]
        case .area, .rectangleArea, .ellipseArea, .polygonCutout, .ellipseCutout:
            return [.planArea, .trueArea]
        case .volume:
            return [.volume, .planArea]
        case .wallArea:
            return [.wallArea, .planArea]
        case .radius, .threePointCircle:
            return [.radius, .diameter]
        case .diameter:
            return [.diameter, .radius]
        case .angle:
            return []
        case .slope:
            return [.slopeRatio, .slopePercent, .slopeAngle]
        case .riseDrop:
            return [.rise, .run]
        case .trueSlopedLength:
            return [.trueLength, .planLength]
        case .trueSlopedArea:
            return [.trueArea, .planArea]
        case nil:
            return []
        }
    }

    /// Every quantity column worth scanning when the kind-specific candidates are empty.
    public static let fallbackCandidates: [LedgerColumnID] = [
        .count, .planLength, .planArea, .perimeter, .volume, .wallArea,
        .trueLength, .trueArea, .radius, .diameter, .rise, .run,
        .slopeRatio, .slopePercent, .slopeAngle
    ]

    /// The formatted primary quantity of a row, exactly as the core rendered it.
    static func primaryDisplay(for row: LedgerRow) -> String {
        for candidate in primaryCandidates(for: row.measurementKind) {
            let text = row.displayValue(candidate)
            if !text.isEmpty { return text }
        }
        guard row.measurementKind != nil else { return "" }
        for candidate in fallbackCandidates {
            let text = row.displayValue(candidate)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// The raw quantity behind the row's primary display, or `nil` when the row carries
    /// no quantity at all.
    ///
    /// Reads the same candidate columns as ``primaryDisplay(for:)``, so the number a group
    /// header sums is the number the row shows — never a second evaluation path
    /// (QUALITY_BAR A25). A bare count reads as a dimensionless quantity, so a Count group
    /// sums to a count of pieces.
    public static func primaryQuantity(for row: LedgerRow) -> DecimalQuantity? {
        // The producer's own Value cell wins, as it does for ``valueText(for:)``, so a row whose
        // headline has no column (an angle, X-038) still reads as the number it shows.
        if let stored = row.quantity(valueColumnID) { return stored }
        for candidate in primaryCandidates(for: row.measurementKind) {
            if let quantity = row.quantity(candidate) { return quantity }
        }
        guard row.measurementKind != nil else { return nil }
        for candidate in fallbackCandidates {
            if let quantity = row.quantity(candidate) { return quantity }
        }
        return nil
    }

    /// Splits a formatted quantity into its number and its trailing unit symbol.
    ///
    /// `"14.72 m²"` → (`"14.72"`, `"m²"`); `"5"` → (`"5"`, `""`). The split only happens
    /// when the trailing token carries no digits and the leading part carries at least
    /// one, so `"1:100"`, `"A-101"` and a bare number pass through untouched.
    public static func splitUnit(_ display: String) -> (value: String, unit: String) {
        guard let lastSpace = display.lastIndex(where: { $0.isWhitespace }) else {
            return (display, "")
        }
        let unit = String(display[display.index(after: lastSpace)...])
        let value = String(display[..<lastSpace])
            .trimmingCharacters(in: .whitespaces)
        // ASCII digits only: `Character.isNumber` is true for the superscript in "m²",
        // which would make every area unit read as a number.
        func hasDigit(_ text: String) -> Bool {
            text.contains { $0.isASCII && $0.isNumber }
        }
        guard !unit.isEmpty, !hasDigit(unit), hasDigit(value) else {
            return (display, "")
        }
        return (value, unit)
    }
}
