import Foundation
import ZPDFContracts

/// Runs an ``AssemblyDefinition`` against one measurement's values.
///
/// ```swift
/// let evaluator = AssemblyEvaluator(.timberStudWall)
/// let results = evaluator.evaluate(inputs: [
///     "Length": .length(9.6),
///     "Height": .length(2.5),
///     "Spacing": .length(Decimal(string: "0.6", locale: nil) ?? 0)
/// ])
/// ```
///
/// # There is exactly one parser in this package
///
/// Every line goes through ``FormulaCompiler`` — the same lexer, the same Pratt parser, the same
/// dimensional analysis and the same `Decimal` arithmetic a ledger formula column uses. This type
/// adds no grammar of its own. What it adds is the binding: it turns a measurement's fields and the
/// estimator's free parameters into the ``FormulaRow`` the compiled program expects, and it turns
/// the program's answer into a quantity that carries its own provenance.
///
/// # Compile once, evaluate per measurement
///
/// Building an evaluator compiles every line. Applying the recipe to a thousand walls compiles
/// nothing further — ``evaluate(inputs:)`` only fills a row and calls the stored closures. The type
/// is a `Sendable` value, so one evaluator can be shared across tasks.
///
/// # Nothing here throws
///
/// ``evaluate(inputs:)`` cannot throw and cannot trap. Every refusal — a missing input, a
/// dimension clash, a division by zero, a line that will not compile at all — comes back as an
/// ``AssemblyLineFailure`` in that line's slot, and the remaining lines are evaluated anyway. One
/// bad line never costs the estimator the other three.
public struct AssemblyEvaluator: Sendable {

    /// The recipe this evaluator runs.
    public let definition: AssemblyDefinition

    private let lines: [CompiledLine]
    private let inputsByNormalisedName: [String: AssemblyInput]
    private let inputsByVariable: [FormulaBuiltinVariable: AssemblyInput]
    private let columnIDByNormalisedName: [String: ColumnID]

    // MARK: - Building

    public init(_ definition: AssemblyDefinition) {
        self.definition = definition

        var byName: [String: AssemblyInput] = [:]
        var byVariable: [FormulaBuiltinVariable: AssemblyInput] = [:]
        var columnIDs: [String: ColumnID] = [:]
        var descriptors: [FormulaColumnDescriptor] = []

        for (index, input) in definition.inputs.enumerated() {
            let key = FormulaColumnCatalog.normalise(input.name)
            // An empty or duplicate name is a definition defect that `validate()` reports. Here the
            // first declaration wins so that building an evaluator stays total.
            guard !key.isEmpty, byName[key] == nil else { continue }
            byName[key] = input
            if let variable = input.builtinVariable, byVariable[variable] == nil {
                byVariable[variable] = input
            }
            let id = AssemblyEvaluator.parameterColumnID(index: index)
            columnIDs[key] = id
            descriptors.append(
                FormulaColumnDescriptor(id: id, name: input.name, type: .number(input.dimension))
            )
        }

        self.inputsByNormalisedName = byName
        self.inputsByVariable = byVariable
        self.columnIDByNormalisedName = columnIDs

        // Names were de-duplicated above and ids are distinct by construction, so this cannot
        // fail. `.empty` is the honest fallback rather than a trap: a line that then cannot find
        // its parameter is refused by name, not by crashing.
        let catalog = (try? FormulaColumnCatalog(columns: descriptors)) ?? .empty
        let compiler = FormulaCompiler(catalog: catalog)
        self.lines = definition.lines.map { CompiledLine($0, compiler: compiler) }
    }

    /// One-shot convenience for a recipe that is applied once.
    public static func evaluate(
        _ definition: AssemblyDefinition,
        inputs: [String: DecimalQuantity]
    ) -> [AssemblyLineResult] {
        AssemblyEvaluator(definition).evaluate(inputs: inputs)
    }

    // MARK: - Evaluating

    /// Evaluates every line of the recipe against one measurement's values.
    ///
    /// `inputs` is keyed by name, matched case-insensitively and whitespace-trimmed: `"Area"`,
    /// `"Length"`, `"Height"` and any free parameter the definition declares, such as `"Spacing"`.
    /// A supplied value the recipe never reads is ignored; a value the recipe reads and did not
    /// get is an ``AssemblyLineFailure/Reason/missingInput(_:)`` on the lines that needed it and
    /// on no others. A line that only *names* an absent input — as the first argument of
    /// `COALESCE`, or in an `IF` branch that is not taken — did not need it and is evaluated with
    /// its own fallback (W-071).
    ///
    /// - Returns: one result per line, in the definition's line order.
    ///
    /// A supplied value must carry its input's declared dimension. A dimensionless value is
    /// re-tagged to the declared count or ratio (ADR-0014: the consumer that knows what a value
    /// means re-tags it by identity); any other disagreement is an
    /// ``AssemblyLineFailure/Reason/inputDimensionMismatch(name:expected:actual:)`` on the lines
    /// that read it (BH-539).
    public func evaluate(inputs: [String: DecimalQuantity]) -> [AssemblyLineResult] {
        let (supplied, mismatched) = checkedInputs(normalisedInputs(inputs))
        let row = makeRow(supplied)
        return lines.map { evaluate($0, supplied: supplied, mismatched: mismatched, row: row) }
    }

    /// Holds each supplied value against its declared input. Returns the values to evaluate with
    /// (re-tagged where only the count/ratio tag differed) and the ones whose dimension disagrees
    /// with the declaration, which never reach the row.
    private func checkedInputs(
        _ supplied: [String: DecimalQuantity]
    ) -> (supplied: [String: DecimalQuantity], mismatched: [String: DecimalQuantity]) {
        var checked: [String: DecimalQuantity] = [:]
        var mismatched: [String: DecimalQuantity] = [:]
        for (key, value) in supplied {
            guard let declared = inputsByNormalisedName[key]?.dimension,
                  value.dimension != declared
            else {
                checked[key] = value
                continue
            }
            if value.dimension.isDimensionless && declared.isDimensionless {
                checked[key] = DecimalQuantity(value: value.value, dimension: declared)
            } else {
                mismatched[key] = value
            }
        }
        return (checked, mismatched)
    }

    // MARK: - Binding the row

    /// Re-keys the caller's dictionary the way the catalog matches names.
    ///
    /// Iteration is over sorted keys so that two spellings that normalise to the same name resolve
    /// deterministically rather than by dictionary order.
    private func normalisedInputs(
        _ inputs: [String: DecimalQuantity]
    ) -> [String: DecimalQuantity] {
        var supplied: [String: DecimalQuantity] = [:]
        supplied.reserveCapacity(inputs.count)
        for key in inputs.keys.sorted() {
            guard let value = inputs[key] else { continue }
            supplied[FormulaColumnCatalog.normalise(key)] = value
        }
        return supplied
    }

    /// Turns the supplied values into the row a compiled program reads.
    ///
    /// A measurement field is written to ``FormulaRow/fields`` so a bare `Length` resolves, and a
    /// declared input is *also* written to its catalog column so a bracketed `[Length]` resolves to
    /// the same number. `UnitCost` has no measurement field and goes to the row's own slot.
    private func makeRow(_ supplied: [String: DecimalQuantity]) -> FormulaRow {
        var row = FormulaRow()
        for key in supplied.keys.sorted() {
            guard let value = supplied[key] else { continue }
            if let id = columnIDByNormalisedName[key] {
                row.columns[id] = .number(value)
            }
            guard let variable = inputsByNormalisedName[key]?.builtinVariable
                    ?? FormulaBuiltinVariable.named(key)
            else { continue }
            if let field = variable.measurementField {
                row.fields[field] = value
            } else if variable == .unitCost {
                row.unitCost = value
            }
        }
        return row
    }

    // MARK: - One line

    private func evaluate(
        _ compiled: CompiledLine,
        supplied: [String: DecimalQuantity],
        mismatched: [String: DecimalQuantity],
        row: FormulaRow
    ) -> AssemblyLineResult {
        let line = compiled.line

        func refuse(_ reason: AssemblyLineFailure.Reason) -> AssemblyLineResult {
            .failure(
                AssemblyLineFailure(
                    assemblyID: definition.id,
                    assemblyName: definition.name,
                    lineName: line.name,
                    formulaText: line.formulaText,
                    reason: reason
                )
            )
        }

        if let reason = compiled.compileFailure { return refuse(reason) }
        guard let program = compiled.program else {
            return refuse(.arithmeticFailed("the line was never compiled"))
        }

        // Provenance first: resolve every name the formula reads, in the order it reads them. A
        // value whose dimension disagrees with its declaration refuses the line here (BH-539). A
        // name with no value does not: `COALESCE(Height, 2.4)` and an IF branch that is not taken
        // never read it, and only evaluation can say whether the line needed it. The line used to
        // be refused here for every absent name it mentioned, so a recipe's own fallback never
        // ran (W-071). Supplied values become `inputsUsed`; absent ones are remembered, in
        // reading order, so a line that does need one is still refused by name below.
        var inputsUsed: [String: DecimalQuantity] = [:]
        var absentNames: [String] = []
        var absentNameByOperandText: [String: String] = [:]
        for (reference, operandText) in zip(compiled.references, compiled.referenceTexts) {
            let key: String
            let name: String
            switch reference {
            case .columnID(let id):
                return refuse(.columnReferenceNotAllowed(id))
            case .variable(let variable):
                name = inputsByVariable[variable]?.name ?? variable.rawValue
                key = FormulaColumnCatalog.normalise(name)
            case .name(let normalised, let written):
                name = inputsByNormalisedName[normalised]?.name ?? written
                key = normalised
            }
            if let wrong = mismatched[key], let declared = inputsByNormalisedName[key] {
                return refuse(.inputDimensionMismatch(
                    name: declared.name, expected: declared.dimension, actual: wrong.dimension
                ))
            }
            if let value = supplied[key] {
                inputsUsed[name] = value
            } else {
                if !absentNames.contains(name) { absentNames.append(name) }
                absentNameByOperandText[operandText] = name
            }
        }

        /// A blank can only come from an absent input: the row holds nothing else, and a literal
        /// is never blank. The input is the operand the engine names when that operand is one of
        /// the absent references, and otherwise the first absent one in reading order.
        func refuseMissing(operand: String?) -> AssemblyLineResult? {
            guard let first = absentNames.first else { return nil }
            return refuse(.missingInput(operand.flatMap { absentNameByOperandText[$0] } ?? first))
        }

        let value: FormulaValue
        do {
            value = try program.evaluate(row: row)
        } catch let error as FormulaEngineError {
            switch error.code {
            case .blankValue(let operand), .blankCondition(let operand):
                if let missing = refuseMissing(operand: operand) { return missing }
            default:
                break
            }
            return refuse(.formulaRefused(error))
        } catch {
            return refuse(.arithmeticFailed(String(describing: error)))
        }
        if value.isBlank, let missing = refuseMissing(operand: nil) { return missing }

        guard let computed = value.quantity else {
            return refuse(.notANumber(value.typeName))
        }
        // The line's declaration is the authority on what a dimensionless result *means*: the
        // algebra types `Length / Spacing` as a ratio, and the recipe says those are studs — a
        // count (ADR-0014). Only the count/ratio tag is relabelled; a length power, angle or
        // currency that disagrees with the declaration is still refused.
        let quantity = FormulaRuntimeChecks.retagged(computed, to: line.outputDimension)
        guard quantity.dimension == line.outputDimension else {
            return refuse(
                .unexpectedDimension(expected: line.outputDimension, actual: quantity.dimension)
            )
        }

        return .quantity(
            AssemblyQuantity(
                assemblyID: definition.id,
                assemblyName: definition.name,
                lineName: line.name,
                value: quantity,
                formulaText: line.formulaText,
                inputsUsed: inputsUsed,
                note: line.note
            )
        )
    }

    // MARK: - Checking a recipe before it is used

    /// What stops a line before any measurement exists, or `nil` when it compiles, reads only
    /// inputs the recipe declares, and produces the dimension it declares (count and ratio are
    /// one tag apart, as at evaluation). The check a recipe editor and a recipe import share
    /// (NL-QTY-07-UI): every refusal here is one ``evaluate(inputs:)`` would give the line on
    /// every measurement, so a recipe that passes cannot be refused for its own text later.
    public func staticRefusal(forLine index: Int) -> AssemblyLineFailure.Reason? {
        guard lines.indices.contains(index) else { return nil }
        let compiled = lines[index]
        if let failure = compiled.compileFailure { return failure }
        guard let program = compiled.program else { return .arithmeticFailed("the line was never compiled") }
        for reference in compiled.references {
            switch reference {
            case .columnID(let id):
                return .columnReferenceNotAllowed(id)
            case .variable(let variable):
                // A grammar variable the recipe never declared is never filled in.
                if inputsByVariable[variable] == nil { return .missingInput(variable.rawValue) }
            case .name(let normalised, let written):
                if inputsByNormalisedName[normalised] == nil { return .missingInput(written) }
            }
        }
        switch program.resultType {
        case .boolean:
            return .notANumber(FormulaStaticType.boolean.describedName)
        case .number(let dimension, _):
            let declared = compiled.line.outputDimension
            if dimension != declared && !(dimension.isDimensionless && declared.isDimensionless) {
                return .unexpectedDimension(expected: declared, actual: dimension)
            }
        case .dynamicNumber:
            break
        }
        return nil
    }

    // MARK: - Compiled line

    /// One line, compiled once, with the names it reads already extracted.
    private struct CompiledLine: Sendable {
        let line: AssemblyLine
        let program: FormulaProgram?
        let compileFailure: AssemblyLineFailure.Reason?
        let references: [Reference]
        /// Each reference's canonical text, index for index: what a blank error names as its
        /// operand, so a blank can be traced back to the input that was absent (W-071).
        let referenceTexts: [String]

        init(_ line: AssemblyLine, compiler: FormulaCompiler) {
            self.line = line
            do {
                let program = try compiler.compile(line.formula)
                if program.usesAggregates {
                    self.program = nil
                    self.compileFailure = .aggregateNotAllowed
                    self.references = []
                    self.referenceTexts = []
                    return
                }
                self.program = program
                self.compileFailure = nil
                let ordered = Reference.ordered(in: program.ast)
                self.references = ordered.map(\.reference)
                self.referenceTexts = ordered.map(\.text)
            } catch let error as FormulaEngineError {
                self.program = nil
                self.references = []
                self.referenceTexts = []
                // A name the compiler could not resolve is, to the estimator, the same condition
                // as an input that was not supplied: the line had nothing to compute with. It is
                // reported that way rather than as a parser diagnostic about columns.
                switch error.code {
                case .unknownColumnName(let name), .unknownVariable(let name):
                    self.compileFailure = .missingInput(name)
                default:
                    self.compileFailure = .formulaRefused(error)
                }
            } catch {
                self.program = nil
                self.references = []
                self.referenceTexts = []
                self.compileFailure = .arithmeticFailed(String(describing: error))
            }
        }
    }

    /// A name a formula reads, in the form the evaluator has to resolve it.
    private enum Reference: Hashable, Sendable {
        /// A grammar variable such as `Length`.
        case variable(FormulaBuiltinVariable)
        /// A bracketed or bare name, carried both normalised (for lookup) and as written (so a
        /// failure can quote what the estimator typed).
        case name(String, written: String)
        /// `[col:...]`, which an assembly has no way to resolve.
        case columnID(ColumnID)

        /// Every name the tree reads, in the order it first reads them, without repeats, each
        /// with the canonical text of the node that reads it.
        ///
        /// Order matters: it is what makes "which input is missing" the same answer on every run.
        static func ordered(in node: FormulaNode) -> [(reference: Reference, text: String)] {
            var ordered: [(reference: Reference, text: String)] = []
            var seen: Set<Reference> = []
            node.forEachNode { child in
                let reference: Reference?
                switch child {
                case .variable(let variable, _):
                    reference = .variable(variable)
                case .columnByName(let name, _):
                    reference = .name(FormulaColumnCatalog.normalise(name), written: name)
                case .columnByID(let id, _):
                    reference = .columnID(id)
                default:
                    reference = nil
                }
                if let reference, seen.insert(reference).inserted {
                    ordered.append((reference, FormulaFormatter.render(child)))
                }
            }
            return ordered
        }
    }

    // MARK: - Ephemeral column ids

    /// A deterministic id for the catalog column that carries one declared input.
    ///
    /// These ids exist only inside this evaluator: they are never stored, never exported and never
    /// seen by a ledger. They are derived from the input's position rather than generated, because
    /// `UUID()` would make two evaluators of the same recipe differ and this package's determinism
    /// guarantee is not negotiable. The prefix spells `ZPDFASMB` so a stray id is recognisable in
    /// a diagnostic.
    private static func parameterColumnID(index: Int) -> ColumnID {
        ColumnID(
            UUID(
                uuid: (
                    0x5A, 0x50, 0x44, 0x46, 0x41, 0x53, 0x4D, 0x42,
                    0x00, 0x00, 0x00, 0x00,
                    UInt8(truncatingIfNeeded: index >> 24),
                    UInt8(truncatingIfNeeded: index >> 16),
                    UInt8(truncatingIfNeeded: index >> 8),
                    UInt8(truncatingIfNeeded: index)
                )
            )
        )
    }
}
