import Foundation
import ZPDFContracts

// MARK: - Input

/// One named value an assembly expects from the measurement it is applied to.
///
/// An input is either a **measurement field** — a name the formula grammar already knows, such as
/// `Length`, `Height` or `Area` — or a **free parameter** the estimator supplies, such as
/// `Spacing`. The distinction is not stored: it is derived from the name through
/// ``FormulaBuiltinVariable/named(_:)``, so a name can never disagree with what it resolves to.
///
/// The declared ``dimension`` is what makes a free parameter usable at compile time. `Length /
/// Spacing` only type-checks to a count because the definition said `Spacing` is a length; without
/// it the division would defer to evaluation and a wrong unit would be caught one step later.
public struct AssemblyInput: Codable, Hashable, Sendable {

    /// The name a formula writes. Matched case-insensitively, whitespace-trimmed.
    public let name: String
    /// What a value of this input is. For a measurement field it must equal the field's own
    /// dimension; ``AssemblyDefinition/validate()`` refuses a definition where it does not.
    public let dimension: QuantityDimension
    /// Free text for the estimator. Never parsed.
    public let note: String?

    public init(name: String, dimension: QuantityDimension, note: String? = nil) {
        self.name = name
        self.dimension = dimension
        self.note = note
    }

    /// The grammar variable this input's name resolves to, when it is one.
    public var builtinVariable: FormulaBuiltinVariable? {
        FormulaBuiltinVariable.named(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The measurement field this input feeds, when it is a measurement field at all.
    public var measurementField: MeasurementField? { builtinVariable?.measurementField }

    /// True when the name is not part of the grammar's variable vocabulary, so the value has to
    /// come from the estimator rather than from the measurement.
    public var isFreeParameter: Bool { builtinVariable == nil }

    /// Stable persisted shape. See ``AssemblyDefinition`` on why these spellings do not change.
    private enum CodingKeys: String, CodingKey {
        case name
        case dimension
        case note
    }
}

// MARK: - Line

/// One quantity an assembly produces, as a formula over the assembly's inputs.
public struct AssemblyLine: Codable, Hashable, Sendable {

    /// What the produced quantity is called. Unique within a definition.
    public let name: String
    /// The formula, stored as source plus grammar version exactly as a ledger formula column is.
    /// It is parsed by the engine's own Pratt parser and by nothing else.
    public let formula: FormulaExpression
    /// The dimension the line is declared to produce. The evaluator checks the value it computed
    /// against this and refuses the line rather than handing back a quantity in the wrong unit.
    public let outputDimension: QuantityDimension
    /// Free text for the estimator. Never parsed.
    public let note: String?
    /// What one base unit of the produced quantity costs — per piece, metre, square metre or
    /// cubic metre, whatever ``outputDimension`` is — as money in one currency (ADR-0020's
    /// rate). `nil` prices nothing. Optional and omitted when `nil`, so a recipe written before
    /// it existed decodes, and re-encodes, unchanged (NL-QTY-07-UI).
    public let unitCost: DecimalQuantity?

    public init(
        name: String,
        formula: FormulaExpression,
        outputDimension: QuantityDimension,
        note: String? = nil,
        unitCost: DecimalQuantity? = nil
    ) {
        self.name = name
        self.formula = formula
        self.outputDimension = outputDimension
        self.note = note
        self.unitCost = unitCost
    }

    /// Convenience for definitions written in Swift.
    public init(
        name: String,
        source: String,
        outputDimension: QuantityDimension,
        note: String? = nil,
        unitCost: DecimalQuantity? = nil
    ) {
        self.init(
            name: name,
            formula: FormulaExpression(source: source),
            outputDimension: outputDimension,
            note: note,
            unitCost: unitCost
        )
    }

    /// The formula source verbatim. This is the text every derived quantity carries with it.
    public var formulaText: String { formula.source }

    /// Stable persisted shape. See ``AssemblyDefinition`` on why these spellings do not change.
    private enum CodingKeys: String, CodingKey {
        case name
        case formula
        case outputDimension
        case note
        case unitCost
    }
}

// MARK: - Definition

/// A named recipe: one measurement in, several quantities out.
///
/// A wall gives its area, its studs at the declared spacing, its plates and its plasterboard.
/// Define the recipe once and every wall measured afterwards produces the whole set.
///
/// # This type is computation only
///
/// Nothing here stores or names a ledger row. The definition and ``AssemblyEvaluator`` are pure
/// value-type computation over ``DecimalQuantity``: they read a measurement's fields and return
/// quantities with their provenance attached. Turning those quantities into rows — what a derived
/// row *is*, and what an export must say about it — is a separate, contract-changing job.
///
/// # Coding-key stability is load-bearing
///
/// Every `CodingKeys` enum in this file spells its keys explicitly, and those spellings are
/// **frozen**. A definition is authored once and then read back by every project that uses it, so
/// a renamed key is a silently missing recipe, and a silently missing recipe is a quantity that
/// stops being produced without anything failing. The rules that follow from that:
///
/// - **Never rename or remove a key.** Add new ones, and make them optional so an older document
///   still decodes.
/// - **Never reorder ``lines``.** Order is the order the estimator sees and the order results come
///   back in; it is data, not presentation.
/// - **Never regenerate ``id``.** It is the handle that says "this wall uses that recipe"; a new
///   id is a new recipe, and the walls pointing at the old one are orphaned.
/// - **Store the formula, not the result.** ``FormulaExpression`` carries its grammar version, so
///   a grammar fix re-parses an old recipe instead of migrating it.
///
/// Encoding is byte-stable for a given encoder configuration: every property is a value type with
/// a fixed key, and `nil` notes are omitted rather than written as null, so encode-decode-encode
/// reproduces the same bytes.
public struct AssemblyDefinition: Codable, Hashable, Sendable, Identifiable {

    /// The recipe's stable handle. Assigned once and never regenerated.
    public let id: UUID
    /// What the recipe is called, in the interface and in the export.
    public let name: String
    /// Free text for the estimator. Never parsed.
    public let note: String?
    /// The values the recipe expects from the measurement it is applied to, in the order an
    /// estimator should be asked for them.
    public let inputs: [AssemblyInput]
    /// The quantities the recipe produces, in the order they are produced and reported.
    public let lines: [AssemblyLine]

    public init(
        id: UUID,
        name: String,
        note: String? = nil,
        inputs: [AssemblyInput],
        lines: [AssemblyLine]
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.inputs = inputs
        self.lines = lines
    }

    /// Frozen persisted shape. See the type documentation.
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case note
        case inputs
        case lines
    }

    // MARK: - Lookup

    /// The declared input whose name matches, ignoring case and surrounding whitespace.
    public func input(named name: String) -> AssemblyInput? {
        let key = FormulaColumnCatalog.normalise(name)
        return inputs.first { FormulaColumnCatalog.normalise($0.name) == key }
    }

    /// The declared input that feeds a grammar variable, if the recipe declares one.
    public func input(for variable: FormulaBuiltinVariable) -> AssemblyInput? {
        inputs.first { $0.builtinVariable == variable }
    }

    /// The declared line with this name, ignoring case and surrounding whitespace.
    public func line(named name: String) -> AssemblyLine? {
        let key = FormulaColumnCatalog.normalise(name)
        return lines.first { FormulaColumnCatalog.normalise($0.name) == key }
    }

    // MARK: - Validation

    /// The checks a definition must pass before it is worth evaluating.
    ///
    /// Evaluation itself never throws — every failure is reported per line — so this is the place
    /// an editor calls to refuse a recipe that cannot be right for anybody: no name, no lines,
    /// two inputs or two lines that cannot be told apart, or an input whose declared dimension
    /// contradicts the measurement field its name resolves to.
    ///
    /// - Throws: ``AssemblyDefinitionError``.
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssemblyDefinitionError.emptyName
        }
        guard !lines.isEmpty else {
            throw AssemblyDefinitionError.noLines(assembly: name)
        }

        var seenInputs: Set<String> = []
        for input in inputs {
            let key = FormulaColumnCatalog.normalise(input.name)
            guard !key.isEmpty else { throw AssemblyDefinitionError.emptyInputName }
            guard seenInputs.insert(key).inserted else {
                throw AssemblyDefinitionError.duplicateInputName(input.name)
            }
            try input.dimension.validate()
            if let required = input.builtinVariable?.dimension, required != input.dimension {
                throw AssemblyDefinitionError.inputDimensionContradictsField(
                    input: input.name,
                    declared: input.dimension,
                    required: required
                )
            }
        }

        var seenLines: Set<String> = []
        for line in lines {
            let key = FormulaColumnCatalog.normalise(line.name)
            guard !key.isEmpty else { throw AssemblyDefinitionError.emptyLineName }
            guard seenLines.insert(key).inserted else {
                throw AssemblyDefinitionError.duplicateLineName(line.name)
            }
            try line.outputDimension.validate()
            try line.formula.validate()
            if let cost = line.unitCost {
                let money = cost.dimension
                guard let code = money.currencyCode,
                      !code.trimmingCharacters(in: .whitespaces).isEmpty,
                      money.lengthPower == 0, !money.angle, !cost.value.isNaN
                else { throw AssemblyDefinitionError.unitCostNotMoney(line: line.name) }
            }
        }
    }
}

// MARK: - Definition errors

/// Every way a recipe can be refused before anything is evaluated.
public enum AssemblyDefinitionError: Error, Hashable, Sendable, CustomStringConvertible {
    case emptyName
    case noLines(assembly: String)
    case emptyInputName
    case emptyLineName
    case duplicateInputName(String)
    case duplicateLineName(String)
    case inputDimensionContradictsField(
        input: String,
        declared: QuantityDimension,
        required: QuantityDimension
    )
    /// A line's unit cost is not an amount of money in one currency (NL-QTY-07-UI).
    case unitCostNotMoney(line: String)

    public var description: String {
        switch self {
        case .emptyName:
            "An assembly needs a name."
        case .noLines(let assembly):
            "The assembly `\(assembly)` produces nothing: it has no lines."
        case .emptyInputName:
            "An assembly input needs a name."
        case .emptyLineName:
            "An assembly line needs a name."
        case .duplicateInputName(let name):
            "Two inputs are both named `\(name)`; a formula could not tell them apart."
        case .duplicateLineName(let name):
            "Two lines are both named `\(name)`; a derived quantity could not name itself."
        case .inputDimensionContradictsField(let input, let declared, let required):
            """
            The input `\(input)` is declared as \(declared.formulaDescription), but the \
            measurement field of that name is always \(required.formulaDescription).
            """
        case .unitCostNotMoney(let line):
            "The unit cost of `\(line)` is not an amount of money in one currency."
        }
    }
}
