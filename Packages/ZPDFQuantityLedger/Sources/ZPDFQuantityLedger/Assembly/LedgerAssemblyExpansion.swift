import Foundation
import ZPDFContracts
import ZPDFFormulaEngine

/// Which assembly a measured row uses, with the estimator's free parameters (ADR-0024).
///
/// Stored on the **source** row, in the reserved hidden ledger column `zenit.assembly`, as JSON
/// text — an ordinary cell value, so assigning, changing and removing an assembly is an ordinary
/// undoable, audited, persisted value edit and needs no schema change. The derived rows are not
/// stored at all: they are materialised from this assignment whenever the ledger is built.
public struct LedgerAssemblyAssignment: Codable, Hashable, Sendable {
    /// The recipe's stable id (``ZPDFFormulaEngine/AssemblyDefinition/id``).
    public var assemblyID: UUID
    /// Values for the recipe's inputs the measurement does not carry — `Spacing`, or `Height`
    /// on a plain length. Keyed by input name, SI base units.
    public var parameters: [String: DecimalQuantity]
    /// The recipe itself, for a recipe that is not built in — an office-library or imported
    /// `.zpdfassembly` recipe (NL-QTY-07 round 2). Carried inside the project so the rows derive
    /// the same on a machine that does not have that library; `nil` for a built-in recipe, and
    /// absent from every cell written before it existed (which then decodes exactly as before).
    public var definition: AssemblyDefinition?

    public init(assemblyID: UUID, parameters: [String: DecimalQuantity] = [:], definition: AssemblyDefinition? = nil) {
        self.assemblyID = assemblyID
        self.parameters = parameters
        self.definition = definition
    }

    /// The cell that stores the assignment.
    public var cellValue: LedgerCellValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return .empty
        }
        return .text(text)
    }

    /// The assignment a stored cell holds, or `nil` for anything else.
    public init?(cell: LedgerCellValue?) {
        guard case .text(let text)? = cell, let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}

/// One assembly as the interface lists it — plain values, so a caller needs nothing from the
/// formula engine to show it.
public struct LedgerAssemblyDescription: Hashable, Sendable, Identifiable {
    public struct Input: Hashable, Sendable {
        public let name: String
        public let dimension: QuantityDimension
        /// True when the estimator supplies it (`Spacing`); false when a measurement field can.
        public let isFreeParameter: Bool
        public let note: String?
    }
    public struct Line: Hashable, Sendable {
        public let name: String
        public let formula: String
        public let dimension: QuantityDimension
    }
    public let id: UUID
    public let name: String
    public let note: String?
    public let inputs: [Input]
    public let lines: [Line]
}

/// The recipes this build offers (ADR-0024 §2.4): the built-in library. Project and
/// office-library recipes are the next slice.
public enum LedgerAssemblyLibrary {

    /// A concrete slab: its volume at a thickness, its edge formwork and its top area.
    public static let concreteSlab = AssemblyDefinition(
        id: UUID(uuid: (0x5A, 0x50, 0x44, 0x46, 0x41, 0x53, 0x4D, 0x42, 0, 0, 0, 0, 0, 0, 0, 0x02)),
        name: "Concrete slab",
        note: "Volume, edge formwork and top area from one measured slab.",
        inputs: [
            AssemblyInput(name: "Area", dimension: .area, note: "The slab's net area as measured."),
            AssemblyInput(name: "Perimeter", dimension: .length, note: "The slab's edge as measured."),
            AssemblyInput(name: "Thickness", dimension: .length, note: "Slab thickness. The estimator supplies it.")
        ],
        lines: [
            AssemblyLine(name: "Concrete", source: "Area * Thickness", outputDimension: .volume),
            AssemblyLine(name: "Edge formwork", source: "Perimeter * Thickness", outputDimension: .area),
            AssemblyLine(name: "Top area", source: "Area", outputDimension: .area)
        ]
    )

    /// Every built-in recipe, in menu order.
    public static let standard: [AssemblyDefinition] = [.timberStudWall, concreteSlab]

    /// The recipe with this id.
    public static func definition(id: UUID) -> AssemblyDefinition? {
        standard.first { $0.id == id }
    }

    /// The recipes as plain values.
    public static var descriptions: [LedgerAssemblyDescription] { descriptions(of: standard) }

    /// Any recipes as plain values — the built-ins and an office library alike.
    public static func descriptions(of definitions: [AssemblyDefinition]) -> [LedgerAssemblyDescription] {
        definitions.map { definition in
            LedgerAssemblyDescription(
                id: definition.id,
                name: definition.name,
                note: definition.note,
                inputs: definition.inputs.map {
                    .init(name: $0.name, dimension: $0.dimension, isFreeParameter: $0.isFreeParameter, note: $0.note)
                },
                lines: definition.lines.map { .init(name: $0.name, formula: $0.formulaText, dimension: $0.outputDimension) }
            )
        }
    }

    /// Evaluators are compiled once per recipe and shared (the evaluator is a `Sendable` value).
    static let evaluators: [UUID: AssemblyEvaluator] = Dictionary(
        uniqueKeysWithValues: standard.map { ($0.id, AssemblyEvaluator($0)) }
    )
}

/// Materialises the derived rows of an assembly (ADR-0012, ADR-0024).
///
/// A derived row is a ``MarkupRecord`` with provenance `.derived` whose one quantity is an
/// assembly line's value, computed by the formula engine from its source row's measured fields
/// and the assignment's parameters. It is rebuilt from its source every time the ledger is
/// built, so it can never be stale, never be edited as a quantity, and never outlive its source.
public enum LedgerAssemblyExpansion {

    /// A derived row's identity: stable for a source, a recipe and a line, so a rebuilt row is the
    /// same row to selection, grouping state and an export diff.
    public static func derivedRowID(source: MarkupID, assembly: UUID, line: Int) -> MarkupID {
        MarkupID(LedgerIdentifiers.deterministicUUID(
            namespace: "zenit.pdf/ledger/assembly-row/v1",
            name: "\(source.rawValue.uuidString)/\(assembly.uuidString)/\(line)"
        ))
    }

    /// The derived rows for one source, in line order; empty when the source carries no
    /// (readable) assignment or names a recipe this build does not know.
    ///
    /// - Parameters:
    ///   - assignmentColumn: the reserved column the assignment is stored in.
    ///   - repeatColumn: the `Repeat ×` column, copied onto every derived row so a wall drawn once
    ///     and repeated six times derives six walls' studs, exactly as its own quantities repeat.
    public static func derivedRecords(
        for source: MarkupRecord,
        assignmentColumn: ColumnID,
        repeatColumn: ColumnID?
    ) -> [MarkupRecord] {
        guard source.provenance == .measured,
              let assignment = LedgerAssemblyAssignment(cell: source.customValues[assignmentColumn]),
              let definition = LedgerAssemblyLibrary.definition(id: assignment.assemblyID)
                ?? assignment.definition.flatMap({ $0.id == assignment.assemblyID ? $0 : nil })
        else { return [] }
        // A built-in recipe's evaluator is compiled once; a carried recipe's, per build — the
        // evaluator is a pure value and a recipe is a handful of formulas.
        let evaluator = LedgerAssemblyLibrary.evaluators[definition.id] ?? AssemblyEvaluator(definition)

        // Measured fields first, then parameters for whatever the measurement does not carry.
        var inputs: [String: DecimalQuantity] = [:]
        let measured = source.measurement?.values ?? [:]
        for input in definition.inputs {
            if let field = input.measurementField, let value = measured[field] {
                inputs[input.name] = value
            } else if let value = assignment.parameters.first(where: {
                Self.normalise($0.key) == Self.normalise(input.name)
            })?.value {
                inputs[input.name] = value
            }
        }
        let results = evaluator.evaluate(inputs: inputs)
        let inputText = inputs.mapValues { "\($0.value) \($0.dimension.baseUnitSymbol)" }

        return results.enumerated().map { index, result in
            let line = definition.lines[index]
            var values: [MeasurementField: DecimalQuantity] = [:]
            var comment = "ƒ \(definition.name): \(line.formulaText)"
            if let quantity = result.quantity {
                for field in Self.fields(for: line.outputDimension) { values[field] = quantity.value }
            } else if let failure = result.failure {
                comment += " — " + failure.reason.description
            }
            var custom: [ColumnID: LedgerCellValue] = [:]
            if let repeatColumn, let repeated = source.customValues[repeatColumn] { custom[repeatColumn] = repeated }
            // NL-QTY-07-UI: the line's rate is the derived row's Unit Cost, so the store prices
            // it exactly as a typed rate (ADR-0020): Total Cost = the row's quantity × rate.
            if let rate = line.unitCost, let code = rate.dimension.currencyCode {
                custom[LedgerIdentifiers.columnID(for: .unitCost)] = .currency(amount: rate.value, code: code)
            }
            return MarkupRecord(
                id: derivedRowID(source: source.id, assembly: definition.id, line: index),
                documentID: source.documentID,
                pageID: source.pageID,
                kind: .measurement,
                tool: tool(for: line.outputDimension),
                subject: line.name,
                label: source.label,
                comment: comment,
                author: source.author,
                status: source.status,
                style: source.style,
                layerID: source.layerID,
                zoneID: source.zoneID,
                scaleRegionID: source.scaleRegionID,
                scaleID: source.scaleID,
                scaleVersion: source.scaleVersion,
                locked: true,
                hidden: source.hidden,
                measurement: MeasurementResult(values: values),
                customValues: custom,
                provenance: .derived,
                derivation: QuantityDerivation(
                    sourceMarkupID: source.id,
                    formulaText: line.formulaText,
                    inputs: inputText,
                    originIdentifier: definition.id.uuidString
                ),
                createdAt: source.createdAt,
                modifiedAt: source.modifiedAt
            )
        }
    }

    static func normalise(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The tool whose `Value` column shows a quantity of this dimension.
    static func tool(for dimension: QuantityDimension) -> MeasurementTool {
        switch dimension.lengthPower {
        case 1: .length
        case 2: .area
        case 3: .volume
        default: .count
        }
    }

    /// The measurement fields a derived quantity of this dimension fills — the ones its
    /// `tool`'s ledger columns read.
    static func fields(for dimension: QuantityDimension) -> [MeasurementField] {
        switch dimension.lengthPower {
        case 1: [.planLength]
        case 2: [.planArea, .netArea]
        case 3: [.volume]
        default: [.count]
        }
    }
}
