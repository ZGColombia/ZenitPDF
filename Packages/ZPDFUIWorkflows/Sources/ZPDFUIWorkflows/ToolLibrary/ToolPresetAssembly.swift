import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The assembly recipes a tool preset can carry (NL-QTY-07, ADR-0035 §4).
///
/// A preset's assembly is its `zenit.assembly` column default: the same assignment text Apply
/// Assembly writes on a ledger row, so a markup drawn with the preset arrives with the assembly
/// already set and its derived rows follow. This package cannot read or write that text — the
/// assignment is a ledger type below the UI seam — so the host hands the recipes over with the
/// two conversions, the way it hands over the artwork importer.
public struct ToolPresetAssemblyCatalog: Sendable {

    /// The column default key the assignment is stored under.
    public static let defaultKey = "zenit.assembly"

    /// The recipes on offer, in menu order.
    public let recipes: [LedgerAssemblySummary]
    /// The stored text for a recipe and its parameter values (SI base units), or `nil` when the
    /// recipe is not one the host knows.
    public let encode: @Sendable (_ recipeID: UUID, _ parameters: [String: DecimalQuantity]) -> String?
    /// A stored text read back, or `nil` when it is not an assignment this host can read.
    public let decode: @Sendable (_ text: String) -> (recipeID: UUID, parameters: [String: DecimalQuantity])?

    public init(
        recipes: [LedgerAssemblySummary],
        encode: @escaping @Sendable (_ recipeID: UUID, _ parameters: [String: DecimalQuantity]) -> String?,
        decode: @escaping @Sendable (_ text: String) -> (recipeID: UUID, parameters: [String: DecimalQuantity])?
    ) {
        self.recipes = recipes
        self.encode = encode
        self.decode = decode
    }
}

/// A Tool Library presenter that can offer assemblies to the preset editor. The panel asks its
/// presenter, so every host that shows the Tool Library offers the picker without wiring of its
/// own; a presenter that does not conform leaves the raw column defaults as they were.
@MainActor
public protocol ToolPresetAssemblyProviding {
    /// The recipes and conversions, or `nil` when none can be offered.
    var presetAssemblyCatalog: ToolPresetAssemblyCatalog? { get }
}

/// The Assembly row of the preset editor: which recipe, and the values for its inputs.
///
/// A value type so every rule is provable without a view. Free parameters (`Spacing`) are
/// required; an input a measurement can carry (`Height`) is optional and is used when the drawn
/// markup does not carry it. Lengths are typed in the preset's display length unit, like the
/// editor's other length fields; any other dimension in its SI base unit.
public struct ToolPresetAssemblyEditor: Hashable, Sendable {

    /// Why the Assembly row cannot be saved as it stands.
    public enum Refusal: Error, Hashable, Sendable {
        /// These free parameters are empty.
        case missingParameters([String])
        /// These inputs are not numbers.
        case unreadableInputs([String])
        /// The host could not write the recipe.
        case unknownRecipe

        public var message: String {
            switch self {
            case .missingParameters(let names):
                return String(
                    format: NSLocalizedString("Enter %@ for the assembly.", comment: "Tool preset editor: assembly parameters still empty; the names"),
                    names.joined(separator: ", ")
                )
            case .unreadableInputs(let names):
                return String(
                    format: NSLocalizedString("%@ is not a number.", comment: "Tool preset editor: assembly inputs that do not read as numbers; the names"),
                    names.joined(separator: ", ")
                )
            case .unknownRecipe:
                return NSLocalizedString("That assembly is not in this version of Zenit PDF.", comment: "Tool preset editor: the chosen recipe cannot be stored")
            }
        }
    }

    /// The chosen recipe, or `nil` for none.
    public var selectedID: UUID?
    /// What was typed for each input, by name.
    public var parameterTexts: [String: String]
    /// The unit a length input is typed in.
    public let lengthUnit: LengthUnit
    /// A stored assignment this host cannot read (a recipe from a library it does not have). It
    /// is kept exactly as it was unless the person picks another recipe or none.
    public private(set) var unreadableStoredText: String?
    /// The recipe as it was when the editor opened, to tell an edit from no edit.
    private let initialSelection: UUID?
    private let initialTexts: [String: String]

    /// Reads the preset's current `zenit.assembly` default, if any.
    public init(customDefaults: [String: String], catalog: ToolPresetAssemblyCatalog, lengthUnit: LengthUnit) {
        self.lengthUnit = lengthUnit
        var selected: UUID?
        var texts: [String: String] = [:]
        var unreadable: String?
        if let stored = customDefaults[ToolPresetAssemblyCatalog.defaultKey], !stored.isEmpty {
            if let read = catalog.decode(stored), catalog.recipes.contains(where: { $0.id == read.recipeID }) {
                selected = read.recipeID
                for (name, quantity) in read.parameters {
                    texts[name] = Self.text(of: quantity, lengthUnit: lengthUnit)
                }
            } else {
                unreadable = stored
            }
        }
        self.selectedID = selected
        self.parameterTexts = texts
        self.unreadableStoredText = unreadable
        self.initialSelection = selected
        self.initialTexts = texts
    }

    /// The chosen recipe.
    public func recipe(in catalog: ToolPresetAssemblyCatalog) -> LedgerAssemblySummary? {
        catalog.recipes.first { $0.id == selectedID }
    }

    /// The inputs the row asks for, in recipe order. All are listed: the editor does not know
    /// which ones the drawn markup will carry, and an input it does carry wins over a typed one.
    public func inputs(in catalog: ToolPresetAssemblyCatalog) -> [LedgerAssemblySummary.Input] {
        recipe(in: catalog)?.inputs ?? []
    }

    /// The unit an input is typed in, for the label after its field. The rule Apply Assembly
    /// labels its fields with too (V-067).
    public func unitLabel(for input: LedgerAssemblySummary.Input) -> String {
        input.unitLabel(lengthUnit: lengthUnit)
    }

    /// Free parameters still empty.
    public func missingParameters(in catalog: ToolPresetAssemblyCatalog) -> [String] {
        LedgerAssemblySummary.Input.missingParameters(inputs(in: catalog), texts: parameterTexts)
    }

    /// Inputs whose text is not a number.
    public func unreadableInputs(in catalog: ToolPresetAssemblyCatalog) -> [String] {
        LedgerAssemblySummary.Input.unreadableInputs(inputs(in: catalog), texts: parameterTexts, parse: Self.parse)
    }

    /// The first reason the row cannot be saved, or `nil` when it can.
    public func refusal(in catalog: ToolPresetAssemblyCatalog) -> Refusal? {
        guard selectedID != nil else { return nil }
        let unreadable = unreadableInputs(in: catalog)
        if !unreadable.isEmpty { return .unreadableInputs(unreadable) }
        let missing = missingParameters(in: catalog)
        if !missing.isEmpty { return .missingParameters(missing) }
        return nil
    }

    /// Writes the row into a preset's column defaults: the assignment text under
    /// ``ToolPresetAssemblyCatalog/defaultKey``, or no entry for none. An untouched row leaves the
    /// stored text exactly as it was, readable or not.
    public func apply(to customDefaults: inout [String: String], catalog: ToolPresetAssemblyCatalog) throws(Refusal) {
        guard selectedID != initialSelection || parameterTexts != initialTexts else { return }
        guard let selectedID else {
            customDefaults.removeValue(forKey: ToolPresetAssemblyCatalog.defaultKey)
            return
        }
        if let refusal = refusal(in: catalog) { throw refusal }
        let parameters = LedgerAssemblySummary.Input.quantities(
            inputs(in: catalog), texts: parameterTexts, lengthUnit: lengthUnit, parse: Self.parse
        )
        guard let stored = catalog.encode(selectedID, parameters) else { throw .unknownRecipe }
        customDefaults[ToolPresetAssemblyCatalog.defaultKey] = stored
    }

    /// A typed input as a quantity in SI base units.
    func quantity(_ input: LedgerAssemblySummary.Input, text: String) -> DecimalQuantity? {
        Self.parse(text).map { input.quantity(typed: $0, lengthUnit: lengthUnit) }
    }

    /// The one number reading for a typed parameter: ``ZPDFDecimalParser`` with exponents, as
    /// Apply Assembly reads it (S-076).
    static func parse(_ text: String) -> Decimal? {
        ZPDFDecimalParser.decimal(text, allowingExponent: true)
    }

    /// A stored quantity as its field shows it.
    static func text(of quantity: DecimalQuantity, lengthUnit: LengthUnit) -> String {
        guard quantity.dimension.lengthPower == 1 else { return "\(quantity.value)" }
        return ToolPresetLengthField.text(from: quantity, unit: lengthUnit)
    }
}
