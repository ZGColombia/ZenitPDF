import Foundation

/// The standard Quantity Ledger columns (spec 15.2).
///
/// These are built in, always present, and identified by a stable key rather than by position,
/// so re-ordering the ledger never rewrites a saved layout or a formula.
public enum StandardLedgerColumn: String, Codable, Hashable, Sendable, CaseIterable {
    case icon
    case subject
    case label
    case comment
    case pageLabel
    case pageIndex
    case projectZone
    case scaleRegion
    case layer
    case status
    case author
    case created
    case modified
    case color
    case count
    case planLength
    case trueLength
    case perimeter
    case planArea
    case trueArea
    case wallArea
    case volume
    case rise
    case run
    case slopeRatio
    case slopePercent
    case slopeAngle
    case depth
    case height
    case radius
    case diameter
    case displayUnit
    case scale
    case costCode
    case trade
    case phase
    case material
    case unitCost
    case totalCost
    /// The outline's area before cutouts: the ``MeasurementField/planArea`` field, reported
    /// beside Plan Area (ADR-0018). Read-only, and never part of Plan Area.
    case grossArea
    /// The area cutouts take away (ADR-0018). On a parent row it is the union of its cutouts;
    /// on a cutout's own row it is that cutout's area, shown only when the parent's
    /// ``CutoutPolicy`` is ``CutoutPolicy/subtractAndReportSeparately``. Read-only and never
    /// summed: a parent and its cutout rows report the same area, so a sum would count it twice.
    case cutoutArea

    /// The measurement field this column reads, when it reads one.
    ///
    /// A quantity column reads the **net** field where one exists: `Plan Area` reads
    /// ``MeasurementField/netArea`` and `Wall Area` reads ``MeasurementField/netWallArea``
    /// (ADR-0016). The net figure is the takeoff quantity — it is what `Volume`, `True Area`
    /// and the formula variable `Area` are built from (spec 12.4, 12.6, 12.8) — so the one area
    /// column that is a quantity must agree with them. The gross outline and the area removed
    /// are reported beside it, in `Gross Area` and `Cutout Area` (ADR-0018); neither is summed
    /// into Plan Area.
    public var measurementField: MeasurementField? {
        switch self {
        case .count: .count
        case .planLength: .planLength
        case .trueLength: .trueLength
        case .perimeter: .perimeter
        case .planArea: .netArea
        case .trueArea: .trueArea
        case .wallArea: .netWallArea
        case .volume: .volume
        case .rise: .rise
        case .run: .run
        case .slopeRatio: .slopeRatio
        case .slopePercent: .slopePercent
        case .slopeAngle: .slopeAngle
        case .depth: .depth
        case .height: .height
        case .radius: .radius
        case .diameter: .diameter
        case .grossArea: .planArea
        case .cutoutArea: .cutoutArea
        default: nil
        }
    }

    /// Whether this column shows a value on a **cutout's own row** (ADR-0018).
    ///
    /// A cutout is part of its parent, never a quantity of its own: the parent's Plan Area is
    /// already its outline minus the union of its cutouts, so a cutout row that carried an area,
    /// a perimeter, a radius or a formula input would add to — or subtract from — a subtotal
    /// what the parent has already accounted for. Every quantity cell of a cutout row is
    /// therefore empty, under every ``CutoutPolicy``. The one exception is `Cutout Area`, which
    /// reports the cutout's own area when the parent's policy is
    /// ``CutoutPolicy/subtractAndReportSeparately`` — and that column is never summed.
    /// Columns that do not read a measurement (subject, label, comment, page …) show normally.
    ///
    /// - Parameter parentPolicy: the parent's cutout policy, or `nil` when the parent is not
    ///   known (an orphaned cutout reports nothing).
    public func showsValueOnCutoutRow(parentPolicy: CutoutPolicy?) -> Bool {
        guard measurementField != nil else { return true }
        return self == .cutoutArea && parentPolicy == .subtractAndReportSeparately
    }

    /// The value kind the column holds.
    public var kind: ColumnKind {
        switch self {
        case .icon, .color: .text
        case .subject, .label, .comment, .pageLabel, .projectZone, .scaleRegion,
             .layer, .author, .displayUnit, .scale, .costCode, .trade, .phase, .material:
            .text
        case .status: .choice
        case .created, .modified: .date
        case .pageIndex: .number
        case .unitCost, .totalCost: .currency
        default: .number
        }
    }

    /// True when the user may type into the column. Derived quantities are read-only, which is
    /// the difference between a takeoff and a spreadsheet.
    ///
    /// Every column with a ``measurementField`` is read-only, `Depth` and `Height` included
    /// (ADR-0017): their cells show the parameter the measurement was computed with, and a
    /// value typed into the cell would have nowhere to go — the store reads the measurement
    /// first and the volume would not follow. Depth and height are changed through the tool's
    /// parameters, which re-measure (spec 12.6: "markup; tool default; custom column;
    /// formula").
    public var isUserEditable: Bool {
        switch self {
        case .subject, .label, .comment, .status, .costCode, .trade, .phase, .material,
             .unitCost, .displayUnit:
            true
        default:
            false
        }
    }
}

/// The kinds a ledger column can be (spec 15.3).
public enum ColumnKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case number
    case currency
    case date
    case checkbox
    case choice
    case formula
}

/// One option of a Choice column (spec 15.3).
public struct ChoiceOption: Codable, Hashable, Sendable {
    public var id: ChoiceOptionID
    /// The stored value. Renaming the display text must not change this.
    public var value: String
    /// Swatch colour. Never the only carrier of meaning — the value text always shows too.
    public var color: RGBAColor?
    /// Sort position within the column.
    public var order: Int
    /// A retired option stays readable on existing rows but is not offered for new ones.
    public var isRetired: Bool

    public init(
        id: ChoiceOptionID,
        value: String,
        color: RGBAColor? = nil,
        order: Int = 0,
        isRetired: Bool = false
    ) {
        self.id = id
        self.value = value
        self.color = color
        self.order = order
        self.isRetired = isRetired
    }
}

/// Definition of one Quantity Ledger column, standard or custom (spec 15.2, 15.3).
public struct LedgerColumnDefinition: Codable, Hashable, Sendable {
    public var id: ColumnID
    /// Stable identifier used in formulas and saved layouts. Unique within a project.
    public var key: String
    /// Header text. Localised at the view boundary.
    public var title: String
    public var kind: ColumnKind
    /// Set for the built-in columns, `nil` for custom ones.
    public var standard: StandardLedgerColumn?
    /// The dimension the column's values carry, for number and formula columns.
    public var dimension: QuantityDimension?
    /// Display unit for the column.
    public var displayUnit: AnyDisplayUnit?
    /// Display precision. Applied at the view and export boundary only.
    public var precision: PrecisionMode?
    /// Options, for a Choice column.
    public var choices: [ChoiceOption]
    /// The default option id, for a Choice column.
    public var defaultChoiceID: ChoiceOptionID?
    /// The expression, for a Formula column.
    public var formula: FormulaExpression?
    /// Whether the user may edit values in this column.
    public var isEditable: Bool
    /// Whether the column is currently shown.
    public var isVisible: Bool
    /// Left-to-right position in the current layout.
    public var order: Int
    /// `true` when the column's values describe one row and never add up — a pack size, a
    /// spacing — so the standard aggregation plan gives it no Sum; its Count stays (ADR-0039).
    /// `nil`, which every column written before ADR-0039 decodes as, lets the standard rule
    /// decide. Encoded only when set, so an existing definition keeps its bytes.
    public var neverSums: Bool?

    public init(
        id: ColumnID,
        key: String,
        title: String,
        kind: ColumnKind,
        standard: StandardLedgerColumn? = nil,
        dimension: QuantityDimension? = nil,
        displayUnit: AnyDisplayUnit? = nil,
        precision: PrecisionMode? = nil,
        choices: [ChoiceOption] = [],
        defaultChoiceID: ChoiceOptionID? = nil,
        formula: FormulaExpression? = nil,
        isEditable: Bool = true,
        isVisible: Bool = true,
        order: Int = 0,
        neverSums: Bool? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.kind = kind
        self.standard = standard
        self.dimension = dimension
        self.displayUnit = displayUnit
        self.precision = precision
        self.choices = choices
        self.defaultChoiceID = defaultChoiceID
        self.formula = formula
        self.isEditable = isEditable
        self.isVisible = isVisible
        self.order = order
        // `false` and `nil` mean the same thing; one spelling keeps equality and bytes honest.
        self.neverSums = neverSums == true ? true : nil
    }

    public func validate() throws {
        if kind == .choice {
            guard !choices.isEmpty else { throw LedgerError.invalidChoiceConfiguration(id) }
            if let defaultChoiceID {
                guard let option = choices.first(where: { $0.id == defaultChoiceID }),
                      !option.isRetired else {
                    throw LedgerError.invalidChoiceConfiguration(id)
                }
            }
        }
        if kind == .formula {
            // A formula column without an expression is its own error, not a choice problem
            // (BH-489): the message keyed on the case must describe what is actually wrong.
            guard let formula else { throw LedgerError.missingFormula(id) }
            try formula.validate()
        }
        if let standard, isEditable, !standard.isUserEditable {
            throw LedgerError.standardColumnNotEditable(standard)
        }
    }
}

/// One cell value (spec 15.3).
public enum LedgerCellValue: Codable, Hashable, Sendable {
    case empty
    case text(String)
    /// A dimensioned number in SI base units.
    case number(DecimalQuantity)
    case currency(amount: Decimal, code: String)
    case date(Date)
    case checkbox(Bool)
    case choice(ChoiceOptionID)
    /// The evaluated result of a formula column, cached with the grammar version that made it.
    case formulaResult(value: DecimalQuantity, grammarVersion: Int)

    /// The column kind this value belongs in.
    public var kind: ColumnKind {
        switch self {
        case .empty, .text: .text
        case .number: .number
        case .currency: .currency
        case .date: .date
        case .checkbox: .checkbox
        case .choice: .choice
        case .formulaResult: .formula
        }
    }

    /// Checks the value against its column, so a text value can never land in a currency column.
    public func validate(against column: LedgerColumnDefinition) throws {
        if case .empty = self { return }
        guard kind == column.kind else {
            throw LedgerError.cellKindMismatch(
                column: column.id,
                expected: column.kind,
                actual: kind
            )
        }
    }
}

/// One row of the Quantity Ledger (spec 15.1, 15.5).
///
/// Rows are a flattened tree: `parentRowID` and `depth` describe the outline the `NSOutlineView`
/// draws, and `groupPath` records the grouping keys that produced the row, so a regroup can be
/// diffed instead of rebuilt.
public struct LedgerRowRecord: Codable, Hashable, Sendable {
    public var id: RowID
    /// The markup this row reports on. `nil` for a group header or an aggregate row.
    public var markupID: MarkupID?
    /// The parent group row.
    public var parentRowID: RowID?
    /// Outline depth, 0 for a top-level row.
    public var depth: Int
    /// The grouping key values that led to this row, outermost first (spec 15.5).
    public var groupPath: [String]
    /// Cell values by column.
    public var cells: [ColumnID: LedgerCellValue]
    /// True for a group header / aggregate row rather than a markup row.
    public var isGroupRow: Bool
    /// Number of markup rows underneath, for a group row.
    public var descendantCount: Int

    public init(
        id: RowID,
        markupID: MarkupID? = nil,
        parentRowID: RowID? = nil,
        depth: Int = 0,
        groupPath: [String] = [],
        cells: [ColumnID: LedgerCellValue] = [:],
        isGroupRow: Bool = false,
        descendantCount: Int = 0
    ) {
        self.id = id
        self.markupID = markupID
        self.parentRowID = parentRowID
        self.depth = depth
        self.groupPath = groupPath
        self.cells = cells
        self.isGroupRow = isGroupRow
        self.descendantCount = descendantCount
    }

    /// Validates every cell against the column set it claims to belong to.
    public func validate(columns: [ColumnID: LedgerColumnDefinition]) throws {
        for (columnID, value) in cells {
            guard let column = columns[columnID] else {
                throw LedgerError.unknownColumn(columnID)
            }
            try value.validate(against: column)
        }
    }
}

/// The grouping keys the ledger offers (spec 15.5).
public enum LedgerGroupingKey: String, Codable, Hashable, Sendable, CaseIterable {
    case subject
    case label
    case page
    case zone
    case scaleRegion
    case layer
    case status
    case trade
    case phase
    case material
    case author
    case customChoice
}
