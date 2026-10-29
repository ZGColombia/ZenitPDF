import Foundation
import ZPDFContracts

// MARK: - Quantity

/// One quantity an assembly produced, carrying everything needed to say where it came from.
///
/// # The provenance fields are the point
///
/// A derived quantity that cannot name the recipe, the line and the formula that produced it is
/// indistinguishable from a measured one, and that is exactly the failure this type exists to make
/// impossible. ``formulaText`` is the line's source **verbatim** — not a re-rendering, not a
/// summary — and ``inputsUsed`` holds exactly the inputs the formula actually read, with the values
/// it actually read, so a reader can redo the arithmetic by hand and get the same number.
///
/// Nothing downstream has to reconstruct any of it, which means nothing downstream can lose it.
public struct AssemblyQuantity: Hashable, Sendable {

    /// The recipe this came from.
    public let assemblyID: UUID
    /// The recipe's name, copied at evaluation so a report never has to look it up again.
    public let assemblyName: String
    /// The line's name, which is what the quantity is called.
    public let lineName: String
    /// The computed value, in SI base units, unrounded.
    public let value: DecimalQuantity
    /// The line's formula source, verbatim.
    public let formulaText: String
    /// Exactly the inputs the formula read, keyed by the name the definition declares them under.
    /// An input that was supplied but never referenced is not here.
    public let inputsUsed: [String: DecimalQuantity]
    /// The line's note, if it has one.
    public let note: String?

    public init(
        assemblyID: UUID,
        assemblyName: String,
        lineName: String,
        value: DecimalQuantity,
        formulaText: String,
        inputsUsed: [String: DecimalQuantity],
        note: String? = nil
    ) {
        self.assemblyID = assemblyID
        self.assemblyName = assemblyName
        self.lineName = lineName
        self.value = value
        self.formulaText = formulaText
        self.inputsUsed = inputsUsed
        self.note = note
    }
}

// MARK: - Failure

/// One line that did not produce a quantity, and why.
///
/// A failure is never a zero and never a missing entry: it takes the same slot in the result list
/// that a quantity would have, so a caller counting results cannot mistake a refusal for an
/// absence. The other lines of the same assembly are evaluated regardless.
public struct AssemblyLineFailure: Error, Hashable, Sendable, CustomStringConvertible {

    /// Why the line was refused.
    public enum Reason: Hashable, Sendable, CustomStringConvertible {

        /// The formula names something no value could be found for: an input the definition
        /// declares but the caller did not supply, or a name the definition never declared at all.
        /// Both read the same way to a person — the line had nothing to compute with.
        case missingInput(String)

        /// The formula refers to a ledger column by its stable id. An assembly line may only name
        /// its own declared inputs; it has no ledger to resolve an id against.
        case columnReferenceNotAllowed(ColumnID)

        /// The line reads the whole group (`SUM`, `AVG`, `COUNT`). An assembly is a recipe over
        /// *one* measurement, so there is no group here to aggregate and a silent empty one would
        /// answer zero.
        case aggregateNotAllowed

        /// The formula engine refused the line: a dimension clash such as adding metres to square
        /// metres, a division by zero, a blank in arithmetic, an unknown function. The engine's own
        /// error is carried whole, with its message, its source span and the offending
        /// sub-expression.
        case formulaRefused(FormulaEngineError)

        /// Arithmetic that failed outside the engine's own error type, for example a `Decimal`
        /// overflow. Carried as text rather than dropped.
        case arithmeticFailed(String)

        /// The line produced something that is not a number — a true/false value, or a blank.
        case notANumber(String)

        /// The line computed a value in a dimension other than the one it declared. Refused
        /// rather than returned, because a quantity in the wrong unit is the silent-wrongness this
        /// whole package exists to prevent.
        case unexpectedDimension(expected: QuantityDimension, actual: QuantityDimension)

        /// A value the line reads was supplied in a dimension other than the one its input
        /// declares — `Height` declared a length and passed as a count. Refused on every line that
        /// reads it, because the declaration is what made the formula type-check (BH-539).
        case inputDimensionMismatch(name: String, expected: QuantityDimension, actual: QuantityDimension)

        public var description: String {
            switch self {
            case .missingInput(let name):
                "There is no value for `\(name)`."
            case .columnReferenceNotAllowed(let id):
                "An assembly line cannot read the ledger column \(id.description)."
            case .aggregateNotAllowed:
                "An assembly line describes one measurement, so it cannot use SUM, AVG or COUNT."
            case .formulaRefused(let error):
                error.description
            case .arithmeticFailed(let text):
                "The arithmetic failed: \(text)."
            case .notANumber(let type):
                "The line produced \(type) rather than a quantity."
            case .unexpectedDimension(let expected, let actual):
                """
                The line is declared to produce \(expected.formulaDescription) but computed \
                \(actual.formulaDescription).
                """
            case .inputDimensionMismatch(let name, let expected, let actual):
                """
                `\(name)` is declared as \(expected.formulaDescription) but was given \
                \(actual.formulaDescription).
                """
            }
        }
    }

    /// The recipe this line belongs to.
    public let assemblyID: UUID
    /// The recipe's name.
    public let assemblyName: String
    /// The line's name.
    public let lineName: String
    /// The line's formula source, verbatim. Present on a failure for the same reason it is present
    /// on a success: the reader needs to see what was attempted.
    public let formulaText: String
    /// Why the line was refused.
    public let reason: Reason

    public init(
        assemblyID: UUID,
        assemblyName: String,
        lineName: String,
        formulaText: String,
        reason: Reason
    ) {
        self.assemblyID = assemblyID
        self.assemblyName = assemblyName
        self.lineName = lineName
        self.formulaText = formulaText
        self.reason = reason
    }

    public var description: String { "\(lineName): \(reason.description)" }
}

// MARK: - Result

/// One slot in an assembly's result list: a quantity, or the refusal that stands in its place.
public enum AssemblyLineResult: Hashable, Sendable {
    case quantity(AssemblyQuantity)
    case failure(AssemblyLineFailure)

    public var lineName: String {
        switch self {
        case .quantity(let quantity): quantity.lineName
        case .failure(let failure): failure.lineName
        }
    }

    public var formulaText: String {
        switch self {
        case .quantity(let quantity): quantity.formulaText
        case .failure(let failure): failure.formulaText
        }
    }

    public var assemblyID: UUID {
        switch self {
        case .quantity(let quantity): quantity.assemblyID
        case .failure(let failure): failure.assemblyID
        }
    }

    /// The quantity, when the line produced one.
    public var quantity: AssemblyQuantity? {
        if case .quantity(let quantity) = self { return quantity }
        return nil
    }

    /// The failure, when the line was refused.
    public var failure: AssemblyLineFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }

    public var isFailure: Bool { failure != nil }
}

extension Array where Element == AssemblyLineResult {
    /// The lines that produced a quantity, in line order.
    public var quantities: [AssemblyQuantity] { compactMap(\.quantity) }

    /// The lines that were refused, in line order.
    public var failures: [AssemblyLineFailure] { compactMap(\.failure) }

    /// The result for one line, matched the way the definition matches names.
    public func result(for lineName: String) -> AssemblyLineResult? {
        let key = FormulaColumnCatalog.normalise(lineName)
        return first { FormulaColumnCatalog.normalise($0.lineName) == key }
    }
}
