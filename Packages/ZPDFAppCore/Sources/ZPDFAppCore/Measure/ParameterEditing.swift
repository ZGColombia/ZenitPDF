import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The measurement parameters a committed markup can be edited in the Inspector (NL-MEASURE-07).
public enum MeasurementParameterRowKind: String, CaseIterable, Hashable, Sendable {
    /// A volume's thickness.
    case depth
    /// A wall's height.
    case height
    /// A gable wall's height at the far end; empty means the same as ``height``.
    case heightAtEnd
    /// The plane's steepness, in any ADR-0004 §3 form.
    case slope
    /// The units this markup's ledger row and exports are shown in (NL-MEASURE-10, ADR-0035
    /// §1.3): a choice, not a typed value. Not one of ``valueKinds``; see
    /// ``ParameterEditing/displayUnitsRow(for:)``.
    case displayUnits

    public var title: String {
        switch self {
        case .depth: return NSLocalizedString("Depth", comment: "Inspector parameter row: a volume's thickness")
        case .height: return NSLocalizedString("Height", comment: "Inspector parameter row: a wall's height")
        case .heightAtEnd: return NSLocalizedString("Height at end", comment: "Inspector parameter row: a gable wall's far-end height")
        case .slope: return NSLocalizedString("Slope", comment: "Inspector parameter row: the plane's steepness")
        case .displayUnits: return NSLocalizedString("Display units", comment: "Inspector parameter row: the units one markup's quantities are shown in")
        }
    }

    /// Whether the value is a length in the display unit (the slope and the unit choice are not).
    public var isLength: Bool { self != .slope && self != .displayUnits }

    /// The rows that edit a value the engine computes with, in display order.
    public static let valueKinds: [MeasurementParameterRowKind] = [.depth, .height, .heightAtEnd, .slope]
}

/// The display units one markup can be given instead of the project's (NL-MEASURE-10, ADR-0035
/// §1.3). Metadata only: the stored SI value never changes, totals still sum in SI, and the
/// choice travels as `MeasurementParameters.displayOverride`.
///
/// Each choice is a whole ``DisplayUnitSelection`` — the same presets the project units use — so
/// a row given its own units reads exactly as a project in those units would read it.
public enum MeasurementDisplayUnitsChoice: String, CaseIterable, Hashable, Sendable {
    /// No override: the row follows the project (`displayOverride == nil`).
    case project
    /// Metres, square metres, cubic metres, two decimals.
    case metres
    /// Millimetres (whole), square metres, cubic metres.
    case millimetres
    /// Feet and inches to a sixteenth, square feet, cubic yards.
    case feetAndInches
    /// Decimal feet to two places, square feet, cubic yards.
    case decimalFeet

    public var title: String {
        switch self {
        case .project: return NSLocalizedString("Project units", comment: "Display units choice: follow the project's units")
        case .metres: return NSLocalizedString("Metres", comment: "Display units choice: metres, square metres, cubic metres")
        case .millimetres: return NSLocalizedString("Millimetres", comment: "Display units choice: millimetres for lengths")
        case .feetAndInches: return NSLocalizedString("Feet and inches", comment: "Display units choice: feet, inches and fractions")
        case .decimalFeet: return NSLocalizedString("Decimal feet", comment: "Display units choice: feet as a decimal")
        }
    }

    /// The override this choice stores; `nil` for ``project``.
    public var policy: DisplayUnitPolicy? {
        switch self {
        case .project: return nil
        case .metres: return DisplayUnitSelection.metric.domainPolicy
        case .millimetres:
            return DisplayUnitSelection(length: .millimetre, area: .squareMetre, volume: .cubicMetre, metricDecimalPlaces: 0).domainPolicy
        case .feetAndInches: return DisplayUnitSelection.imperial.domainPolicy
        case .decimalFeet: return DisplayUnitSelection.imperial.withImperialLengthStyle(.decimalFeet).domainPolicy
        }
    }

    /// The choice a stored override is, or `nil` for an override none of the choices wrote (a
    /// template's or an older build's) — shown as custom, never silently rewritten.
    public init?(policy: DisplayUnitPolicy?) {
        guard let match = Self.allCases.first(where: { $0.policy == policy }) else { return nil }
        self = match
    }
}

/// Reading and committing the Inspector's parameter rows (NL-MEASURE-07).
///
/// Which rows a markup has is ``ToolPresetApplicability``'s rule, the one the Tool Library uses:
/// depth for Volume, the heights for Wall Area, the slope for the true-sloped tools and Volume. A
/// multi-selection shows the rows every selected markup has, mixed where they disagree, and a
/// commit writes every selected markup in one step through `DocumentCommand.editParameters`, so
/// the engine recomputes each one and one ⌘Z restores them all.
public enum ParameterEditing {

    /// One row as the Inspector shows it.
    public struct Row: Hashable, Sendable, Identifiable {
        /// One option of a choice row: what the commit text is, and what the menu says.
        public struct Choice: Hashable, Sendable, Identifiable {
            public let id: String
            public let title: String
        }

        public let kind: MeasurementParameterRowKind
        /// The value in the display unit ("200"), the slope as it was typed ("6:12"), the chosen
        /// option's id for a choice row; empty when unset, mixed or (a choice row) custom.
        public let text: String
        public let isMixed: Bool
        /// The unit symbol after the field ("mm"), empty for the slope.
        public let unitSymbol: String
        /// The options of a choice row (Display units); empty for a typed value.
        public var choices: [Choice] = []
        public var id: String { kind.rawValue }
    }

    /// Why a commit was refused.
    public enum Refusal: Error, Hashable, Sendable {
        /// The text is not a number (or, for a slope, not a slope form).
        case unreadable(String)
        /// Zero or negative where only a positive value means anything.
        case notPositive
    }

    /// Whether a tool uses this parameter.
    public static func applies(_ kind: MeasurementParameterRowKind, to tool: MeasurementTool?) -> Bool {
        let shown = tool.map { Shown.Kind(domain: $0) }
        switch kind {
        case .depth: return ToolPresetApplicability.acceptsDepth(shown)
        case .height, .heightAtEnd: return ToolPresetApplicability.acceptsWallHeight(shown)
        case .slope: return ToolPresetApplicability.acceptsSlope(shown)
        // Every measurement with a quantity to show; a count is a number of things in any units.
        case .displayUnits: return tool != nil && tool != .count
        }
    }

    /// The rows every one of `records` has, in a fixed order; empty for a selection with no
    /// measurement or with nothing in common.
    public static func rows(for records: [MarkupRecord], lengthUnit: ZPDFUIPresentation.LengthUnit) -> [Row] {
        guard !records.isEmpty, records.allSatisfy({ $0.tool != nil && $0.parentMarkupID == nil }) else { return [] }
        return MeasurementParameterRowKind.valueKinds.compactMap { kind in
            guard records.allSatisfy({ applies(kind, to: $0.tool) }) else { return nil }
            let texts = Set(records.map { text(of: kind, in: $0.parameters ?? .default, lengthUnit: lengthUnit) })
            return Row(
                kind: kind,
                text: texts.count == 1 ? (texts.first ?? "") : "",
                isMixed: texts.count > 1,
                unitSymbol: kind.isLength ? lengthUnit.symbol : ""
            )
        }
    }

    /// The Display units row for `records` (NL-MEASURE-10), or `nil` when not every one of them
    /// can have units of its own. Shown after the value rows; its commit goes through
    /// ``commands(setting:to:on:lengthUnit:)`` like theirs, so it is one undoable
    /// `editParameters` step over the selection.
    public static func displayUnitsRow(for records: [MarkupRecord]) -> Row? {
        guard !records.isEmpty,
              records.allSatisfy({ $0.parentMarkupID == nil && applies(.displayUnits, to: $0.tool) }) else { return nil }
        let texts = Set(records.map { text(of: .displayUnits, in: $0.parameters ?? .default, lengthUnit: .metre) })
        return Row(
            kind: .displayUnits,
            text: texts.count == 1 ? (texts.first ?? "") : "",
            isMixed: texts.count > 1,
            unitSymbol: "",
            choices: MeasurementDisplayUnitsChoice.allCases.map { Row.Choice(id: $0.rawValue, title: $0.title) }
        )
    }

    /// A parameter's value as its row shows it.
    public static func text(of kind: MeasurementParameterRowKind, in parameters: MeasurementParameters, lengthUnit: ZPDFUIPresentation.LengthUnit) -> String {
        switch kind {
        case .displayUnits:
            return MeasurementDisplayUnitsChoice(policy: parameters.displayOverride)?.rawValue ?? ""
        case .depth: return lengthText(parameters.depth, lengthUnit: lengthUnit)
        case .height: return lengthText(parameters.height, lengthUnit: lengthUnit)
        case .heightAtEnd: return lengthText(parameters.heightAtEnd, lengthUnit: lengthUnit)
        case .slope:
            guard parameters.slope.mode == .uniformPlane, let magnitude = parameters.slope.magnitude else { return "" }
            return slopeText(magnitude)
        }
    }

    /// The commands that write `text` into `kind` on every record, one `editParameters` each.
    ///
    /// Lengths go through the display unit's exact `Decimal` factor (`200 mm` stores as exactly
    /// 0.2 m). The slope keeps the form it was typed in (ADR-0004 §3) and the fall line the markup
    /// already had. An empty Height at end clears it; every other row needs a positive value.
    /// Display units takes a ``MeasurementDisplayUnitsChoice`` raw value and writes its override.
    public static func commands(
        setting kind: MeasurementParameterRowKind,
        to text: String,
        on records: [MarkupRecord],
        lengthUnit: ZPDFUIPresentation.LengthUnit
    ) throws(Refusal) -> [DocumentCommand] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var edit: (inout MeasurementParameters) -> Void
        switch kind {
        case .depth, .height, .heightAtEnd:
            if trimmed.isEmpty, kind == .heightAtEnd {
                edit = { $0.heightAtEnd = nil }
            } else {
                guard let value = AppMeasurementToolPresenter.parseParameter(trimmed) else { throw .unreadable(text) }
                guard value > 0 else { throw .notPositive }
                let metres = ZPDFContracts.DecimalQuantity.length(value * lengthUnit.metresPerUnit)
                switch kind {
                case .depth: edit = { $0.depth = metres }
                case .height: edit = { $0.height = metres }
                default: edit = { $0.heightAtEnd = metres }
                }
            }
        case .displayUnits:
            guard let choice = MeasurementDisplayUnitsChoice(rawValue: trimmed) else { throw .unreadable(text) }
            edit = { $0.displayOverride = choice.policy }
        case .slope:
            let expression: SlopeExpression
            do { expression = try SlopeExpression.parse(trimmed) } catch { throw .unreadable(text) }
            guard let ratio = try? expression.ratio(), ratio > 0 else { throw .notPositive }
            edit = { parameters in
                parameters.slope = .uniformPlane(expression, azimuth: parameters.slope.azimuth)
            }
        }
        return records.compactMap { record in
            guard applies(kind, to: record.tool) else { return nil }
            var parameters = record.parameters ?? .default
            edit(&parameters)
            guard parameters != record.parameters else { return nil }
            return .editParameters(id: record.id, parameters: parameters)
        }
    }

    /// The commands that set the fall line of every sloped record to the direction `from → to`
    /// (downhill to uphill), keeping each one's steepness ("Pick fall line", NL-MEASURE-07).
    public static func fallLineCommands(from: PDFPoint, to: PDFPoint, on records: [MarkupRecord]) throws -> [DocumentCommand] {
        let azimuth = try SlopeAzimuth.between(from, to)
        return records.compactMap { record in
            guard applies(.slope, to: record.tool), var parameters = record.parameters,
                  parameters.slope.mode == .uniformPlane else { return nil }
            parameters.slope = parameters.slope.with(azimuth: azimuth)
            return .editParameters(id: record.id, parameters: parameters)
        }
    }

    // MARK: Formatting

    static func lengthText(_ quantity: ZPDFContracts.DecimalQuantity?, lengthUnit: ZPDFUIPresentation.LengthUnit) -> String {
        guard let quantity else { return "" }
        var shown = quantity.value / lengthUnit.metresPerUnit
        var rounded = Decimal()
        NSDecimalRound(&rounded, &shown, 6, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    static func slopeText(_ expression: SlopeExpression) -> String {
        func plain(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
        switch expression {
        case .ratioOneToN(let n): return "1:" + plain(n)
        case .ratioNToOne(let n): return plain(n) + ":1"
        case .decimalRatio(let value): return plain(value)
        case .percent(let value): return plain(value) + " %"
        case .degrees(let value): return plain(value) + "\u{00B0}"
        case .riseOverRun(let rise, let run): return plain(rise) + ":" + plain(run)
        }
    }
}
