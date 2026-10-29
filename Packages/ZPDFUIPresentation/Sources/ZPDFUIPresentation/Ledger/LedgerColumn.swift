import Foundation

/// Stable identity of a Quantity Ledger column.
///
/// Standard columns use reserved lower-camel identifiers; custom columns are namespaced
/// under `custom.` so that a user column can never shadow a built-in one.
public struct LedgerColumnID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {

    /// The raw identifier string, persisted verbatim.
    public let rawValue: String

    /// Creates a column identifier from a raw string.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Creates a column identifier from a raw string.
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Creates a column identifier from a literal, used for the standard constants.
    public init(stringLiteral value: String) { self.rawValue = value }

    /// Whether the column was created by the user rather than shipped with Zenit.
    public var isCustom: Bool { rawValue.hasPrefix("custom.") }

    /// Builds the identifier for a user-created column.
    public static func custom(_ name: String) -> LedgerColumnID { LedgerColumnID("custom.\(name)") }
}

extension LedgerColumnID: CodingKeyRepresentable {

    /// Encodes the identifier as a JSON object key rather than as an array element.
    public var codingKey: any CodingKey { rawValue.codingKey }

    /// Restores an identifier from a coding key.
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

extension LedgerColumnID: CustomStringConvertible {
    /// The raw identifier, for logs and diagnostics only.
    public var description: String { rawValue }
}

extension LedgerColumnID {

    // MARK: Standard columns

    /// Markup type glyph.
    public static let icon: LedgerColumnID = "icon"
    /// Takeoff subject.
    public static let subject: LedgerColumnID = "subject"
    /// Instance label.
    public static let label: LedgerColumnID = "label"
    /// Free-text comment.
    public static let comment: LedgerColumnID = "comment"
    /// PDF page label.
    public static let pageLabel: LedgerColumnID = "pageLabel"
    /// Zero-based page index.
    public static let pageIndex: LedgerColumnID = "pageIndex"
    /// Project Zone name.
    public static let projectZone: LedgerColumnID = "projectZone"
    /// Scale Region name.
    public static let scaleRegion: LedgerColumnID = "scaleRegion"
    /// Layer name.
    public static let layer: LedgerColumnID = "layer"
    /// Review status.
    public static let status: LedgerColumnID = "status"
    /// Author.
    public static let author: LedgerColumnID = "author"
    /// Creation date.
    public static let created: LedgerColumnID = "created"
    /// Modification date.
    public static let modified: LedgerColumnID = "modified"
    /// Markup colour.
    public static let color: LedgerColumnID = "color"
    /// Counted items.
    public static let count: LedgerColumnID = "count"
    /// Plan length.
    public static let planLength: LedgerColumnID = "planLength"
    /// Slope-corrected length.
    public static let trueLength: LedgerColumnID = "trueLength"
    /// Closed outline length.
    public static let perimeter: LedgerColumnID = "perimeter"
    /// Plan area.
    public static let planArea: LedgerColumnID = "planArea"
    /// Slope-corrected area.
    public static let trueArea: LedgerColumnID = "trueArea"
    /// Wall area.
    public static let wallArea: LedgerColumnID = "wallArea"
    /// Volume.
    public static let volume: LedgerColumnID = "volume"
    /// Slope rise.
    public static let rise: LedgerColumnID = "rise"
    /// Slope run.
    public static let run: LedgerColumnID = "run"
    /// Slope ratio.
    public static let slopeRatio: LedgerColumnID = "slopeRatio"
    /// Slope percent.
    public static let slopePercent: LedgerColumnID = "slopePercent"
    /// Slope angle.
    public static let slopeAngle: LedgerColumnID = "slopeAngle"
    /// Volume depth.
    public static let depth: LedgerColumnID = "depth"
    /// Wall height.
    public static let height: LedgerColumnID = "height"
    /// Circle radius.
    public static let radius: LedgerColumnID = "radius"
    /// Circle diameter.
    public static let diameter: LedgerColumnID = "diameter"
    /// Active display unit.
    public static let displayUnit: LedgerColumnID = "displayUnit"
    /// Scale name.
    public static let scale: LedgerColumnID = "scale"
    /// Cost code.
    public static let costCode: LedgerColumnID = "costCode"
    /// Trade.
    public static let trade: LedgerColumnID = "trade"
    /// Construction phase.
    public static let phase: LedgerColumnID = "phase"
    /// Material.
    public static let material: LedgerColumnID = "material"
    /// Unit cost.
    public static let unitCost: LedgerColumnID = "unitCost"
    /// Total cost.
    public static let totalCost: LedgerColumnID = "totalCost"

    /// Every standard column identifier, in the standard order.
    public static let standardColumns: [LedgerColumnID] = [
        .icon, .subject, .label, .comment, .pageLabel, .pageIndex, .projectZone,
        .scaleRegion, .layer, .status, .author, .created, .modified, .color, .count,
        .planLength, .trueLength, .perimeter, .planArea, .trueArea, .wallArea, .volume,
        .rise, .run, .slopeRatio, .slopePercent, .slopeAngle, .depth, .height, .radius,
        .diameter, .displayUnit, .scale, .costCode, .trade, .phase, .material,
        .unitCost, .totalCost
    ]
}

/// The data type of a ledger column.
public enum LedgerColumnKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Free text.
    case text
    /// A dimensioned or dimensionless number.
    case number
    /// A monetary amount in the project currency.
    case currency
    /// A calendar date.
    case date
    /// A boolean tick box.
    case checkbox
    /// One value from a controlled list.
    case choice
    /// A value computed by the Zenit formula engine.
    case formula

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether the cell can be edited directly in the table.
    public var isDirectlyEditable: Bool { self != .formula }

    /// A localized name for the column-type picker.
    public var displayName: String {
        switch self {
        case .text: return NSLocalizedString("Text", comment: "Ledger column type")
        case .number: return NSLocalizedString("Number", comment: "Ledger column type")
        case .currency: return NSLocalizedString("Currency", comment: "Ledger column type")
        case .date: return NSLocalizedString("Date", comment: "Ledger column type")
        case .checkbox: return NSLocalizedString("Checkbox", comment: "Ledger column type")
        case .choice: return NSLocalizedString("Choice", comment: "Ledger column type")
        case .formula: return NSLocalizedString("Formula", comment: "Ledger column type")
        }
    }
}

/// Horizontal alignment of a ledger column's cells.
public enum LedgerColumnAlignment: String, Codable, Hashable, Sendable, CaseIterable {
    /// Leading edge, for text.
    case leading
    /// Centred, for glyphs and check boxes.
    case center
    /// Trailing edge, for numbers so digits line up.
    case trailing
}

/// The aggregate a group or grand-total row shows for a column.
public enum LedgerAggregate: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Sum of the values.
    case sum
    /// Number of contributing rows.
    case count
    /// Arithmetic mean.
    case average
    /// Smallest value.
    case minimum
    /// Largest value.
    case maximum
    /// Number of distinct values.
    case distinctCount
    /// Sum weighted by another column.
    case weightedTotal

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the aggregate picker and the total row's VoiceOver label.
    public var displayName: String {
        switch self {
        case .sum: return NSLocalizedString("Sum", comment: "Ledger aggregate function")
        case .count: return NSLocalizedString("Count", comment: "Ledger aggregate function")
        case .average: return NSLocalizedString("Average", comment: "Ledger aggregate function")
        case .minimum: return NSLocalizedString("Minimum", comment: "Ledger aggregate function")
        case .maximum: return NSLocalizedString("Maximum", comment: "Ledger aggregate function")
        case .distinctCount: return NSLocalizedString("Distinct Count", comment: "Ledger aggregate function")
        case .weightedTotal: return NSLocalizedString("Weighted Total", comment: "Ledger aggregate function")
        }
    }
}

/// One option of a `choice` column.
public struct LedgerChoiceOption: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the option.
    public let id: UUID
    /// Stored value, which stays constant even if ``title`` is renamed.
    public var value: String
    /// Localized display title.
    public var title: String
    /// Redundant colour cue; the title always carries the meaning.
    public var colorRGBA: ColorRGBA
    /// Sort position in the picker.
    public var order: Int
    /// Whether the option is retired: kept for existing rows, hidden from new pickers.
    public var isRetired: Bool

    /// Creates a choice option.
    public init(
        id: UUID,
        value: String,
        title: String,
        colorRGBA: ColorRGBA,
        order: Int,
        isRetired: Bool = false
    ) {
        self.id = id
        self.value = value
        self.title = title
        self.colorRGBA = colorRGBA
        self.order = order
        self.isRetired = isRetired
    }
}

/// A column in the Quantity Ledger.
public struct LedgerColumn: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity.
    public let id: LedgerColumnID
    /// Localized header title.
    public var title: String
    /// Data type of the column's cells.
    public var kind: LedgerColumnKind
    /// The dimension every quantity in this column must have, or `nil` for
    /// non-quantity columns. Values of another dimension are never summed into it.
    public var dimension: QuantityDimension?
    /// Rendered width in points.
    public var width: Double
    /// Whether the column stays visible while the table scrolls horizontally.
    public var pinned: Bool
    /// Whether the column is currently shown.
    public var visible: Bool
    /// Cell alignment.
    public var alignment: LedgerColumnAlignment
    /// Whether cells can be edited in place.
    public var isEditable: Bool
    /// Options for a `choice` column, otherwise empty.
    public var choices: [LedgerChoiceOption]
    /// Source text for a `formula` column, otherwise `nil`.
    public var formulaSource: String?
    /// Aggregate shown on group and grand-total rows, or `nil` for no total.
    public var aggregate: LedgerAggregate?
    /// Display unit symbol appended to formatted values, empty when the column has none.
    public var displayUnitSymbol: String
    /// Whether a person — or a table import acting for one — created the column, rather than
    /// Zenit shipping it (NL-QTY-01).
    ///
    /// This is the one rule for "user column". It used to be the `custom.` prefix of the
    /// identifier, which a table import's `zenit.import.<uuid>` keys never carried, so the
    /// columns a person had just imported were hidden, missing from Bulk Edit and the
    /// Inspector, and their inline edits were dropped. The producer sets it from the column's
    /// definition; a column built without saying falls back to the prefix.
    public var isUserDefined: Bool
    /// Whether each row stores its own value for the column, typed by a person — a user
    /// column, or a built-in such as Cost Code, Trade, Phase, Material or Unit Cost
    /// (NL-QTY-01). Subject, Label, Comment and Status are not in this set: each has a command
    /// of its own. Formula and measured columns are never in it.
    public var holdsUserValues: Bool

    /// Creates a ledger column.
    ///
    /// `isUserDefined` and `holdsUserValues` default from the identifier (the `custom.`
    /// prefix) when the caller does not say, which is what every column built before
    /// NL-QTY-01 meant.
    public init(
        id: LedgerColumnID,
        title: String,
        kind: LedgerColumnKind,
        dimension: QuantityDimension? = nil,
        width: Double,
        pinned: Bool = false,
        visible: Bool = true,
        alignment: LedgerColumnAlignment = .leading,
        isEditable: Bool = false,
        choices: [LedgerChoiceOption] = [],
        formulaSource: String? = nil,
        aggregate: LedgerAggregate? = nil,
        displayUnitSymbol: String = "",
        isUserDefined: Bool? = nil,
        holdsUserValues: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.dimension = dimension
        self.width = width
        self.pinned = pinned
        self.visible = visible
        self.alignment = alignment
        self.isEditable = isEditable
        self.choices = choices
        self.formulaSource = formulaSource
        self.aggregate = aggregate
        self.displayUnitSymbol = displayUnitSymbol
        let userDefined = isUserDefined ?? id.isCustom
        self.isUserDefined = userDefined
        self.holdsUserValues = holdsUserValues ?? (userDefined && isEditable && kind.isDirectlyEditable)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, dimension, width, pinned, visible, alignment, isEditable, choices
        case formulaSource, aggregate, displayUnitSymbol, isUserDefined, holdsUserValues
    }

    /// Decodes a column, including one encoded before NL-QTY-01 added the two user-column
    /// flags: a missing flag takes the default the initialiser gives it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(LedgerColumnID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            kind: try container.decode(LedgerColumnKind.self, forKey: .kind),
            dimension: try container.decodeIfPresent(QuantityDimension.self, forKey: .dimension),
            width: try container.decode(Double.self, forKey: .width),
            pinned: try container.decode(Bool.self, forKey: .pinned),
            visible: try container.decode(Bool.self, forKey: .visible),
            alignment: try container.decode(LedgerColumnAlignment.self, forKey: .alignment),
            isEditable: try container.decode(Bool.self, forKey: .isEditable),
            choices: try container.decode([LedgerChoiceOption].self, forKey: .choices),
            formulaSource: try container.decodeIfPresent(String.self, forKey: .formulaSource),
            aggregate: try container.decodeIfPresent(LedgerAggregate.self, forKey: .aggregate),
            displayUnitSymbol: try container.decode(String.self, forKey: .displayUnitSymbol),
            isUserDefined: try container.decodeIfPresent(Bool.self, forKey: .isUserDefined),
            holdsUserValues: try container.decodeIfPresent(Bool.self, forKey: .holdsUserValues)
        )
    }

    /// Whether the column carries dimensioned quantities that roll up into totals.
    public var isQuantityColumn: Bool { dimension != nil }

    /// A localized header accessibility label including the unit, when there is one.
    public var accessibilityLabel: String {
        guard !displayUnitSymbol.isEmpty else { return title }
        let format = NSLocalizedString(
            "%1$@ in %2$@",
            comment: "VoiceOver label for a ledger column header: column title, unit symbol"
        )
        return String(format: format, title, displayUnitSymbol)
    }
}
