import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFFormulaEngine

// MARK: - Support

/// A deterministic assembly id. No `UUID()` in the tests, so a failure is reproducible from the
/// source alone.
private func makeAssemblyID(_ index: UInt8) -> UUID {
    UUID(uuid: (0x41, 0x53, 0x4D, 0x42, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, index))
}

/// The stud wall's inputs at the dimensions the worked example uses.
private func studWallInputs(
    length: String = "9.6",
    height: String = "2.5",
    spacing: String? = "0.6"
) throws -> [String: DecimalQuantity] {
    var inputs: [String: DecimalQuantity] = [
        "Length": .length(try dec(length)),
        "Height": .length(try dec(height))
    ]
    if let spacing {
        inputs["Spacing"] = .length(try dec(spacing))
    }
    return inputs
}

private func quantity(
    _ results: [AssemblyLineResult],
    _ lineName: String
) throws -> AssemblyQuantity {
    let result = try #require(results.result(for: lineName), "no result for `\(lineName)`")
    return try #require(result.quantity, "`\(lineName)` failed: \(result.failure?.description ?? "")")
}

private func failure(
    _ results: [AssemblyLineResult],
    _ lineName: String
) throws -> AssemblyLineFailure {
    let result = try #require(results.result(for: lineName), "no result for `\(lineName)`")
    return try #require(result.failure, "`\(lineName)` unexpectedly produced a quantity")
}

// MARK: - The worked example

@Suite("Assemblies — the timber stud wall")
struct AssemblyStudWallTests {

    @Test("The seeded recipe is a valid definition")
    func standardDefinitionValidates() throws {
        try AssemblyDefinition.timberStudWall.validate()
        #expect(AssemblyDefinition.timberStudWall.lines.count == 4)
        #expect(AssemblyDefinition.timberStudWall.inputs.count == 3)
        #expect(AssemblyDefinition.timberStudWall.input(named: "spacing")?.isFreeParameter == true)
        #expect(AssemblyDefinition.timberStudWall.input(named: "Length")?.isFreeParameter == false)
    }

    @Test("FLOOR is in the engine's function set, so the stud count is whole by construction")
    func floorExists() {
        #expect(FormulaEngineFunction.named("FLOOR") == .floor)
        #expect(FormulaEngineFunction.named("floor") == .floor)
    }

    @Test("A 9.6 m by 2.5 m wall at 0.6 m spacing gives 24 m^2, 17 studs, 19.2 m, 48 m^2")
    func studWallProducesFourExactQuantities() throws {
        let results = AssemblyEvaluator.evaluate(
            .timberStudWall,
            inputs: try studWallInputs()
        )

        #expect(results.count == 4)
        #expect(results.failures.isEmpty)

        let area = try quantity(results, "Wall area")
        #expect(area.value.value == 24)
        #expect(area.value.dimension == .area)

        let studs = try quantity(results, "Studs")
        #expect(studs.value.value == 17)
        #expect(studs.value.dimension == .count)

        let plates = try quantity(results, "Plates")
        #expect(plates.value.value == (try dec("19.2")))
        #expect(plates.value.dimension == .length)

        let board = try quantity(results, "Plasterboard both sides")
        #expect(board.value.value == 48)
        #expect(board.value.dimension == .area)
    }

    @Test("Results come back in the definition's line order")
    func lineOrderIsPreserved() throws {
        let results = AssemblyEvaluator.evaluate(.timberStudWall, inputs: try studWallInputs())
        #expect(results.map(\.lineName) == AssemblyDefinition.timberStudWall.lines.map(\.name))
    }

    @Test("The same recipe evaluated twice gives identical results")
    func evaluationIsDeterministic() throws {
        let inputs = try studWallInputs()
        let first = AssemblyEvaluator(.timberStudWall).evaluate(inputs: inputs)
        let second = AssemblyEvaluator(.timberStudWall).evaluate(inputs: inputs)
        #expect(first == second)
    }

    @Test("A free parameter reads the same whether it is written bare or in brackets")
    func bracketedParameterResolvesToTheSameValue() throws {
        let definition = AssemblyDefinition(
            id: makeAssemblyID(9),
            name: "Bracket spellings",
            inputs: [
                AssemblyInput(name: "Length", dimension: .length),
                AssemblyInput(name: "Spacing", dimension: .length)
            ],
            lines: [
                AssemblyLine(name: "Bare", source: "Length / Spacing", outputDimension: .count),
                AssemblyLine(name: "Bracketed", source: "[Length] / [Spacing]", outputDimension: .count)
            ]
        )
        try definition.validate()
        let results = AssemblyEvaluator.evaluate(
            definition,
            inputs: ["Length": .length(try dec("9.6")), "Spacing": .length(try dec("0.6"))]
        )
        #expect(try quantity(results, "Bare").value.value == 16)
        #expect(try quantity(results, "Bracketed").value.value == 16)
    }
}

// MARK: - Provenance

@Suite("Assemblies — provenance")
struct AssemblyProvenanceTests {

    @Test("Every quantity carries its line's formula source verbatim")
    func formulaTextMatchesTheDefinition() throws {
        let definition = AssemblyDefinition.timberStudWall
        let results = AssemblyEvaluator.evaluate(definition, inputs: try studWallInputs())
        for line in definition.lines {
            let produced = try quantity(results, line.name)
            #expect(produced.formulaText == line.formula.source)
            #expect(produced.lineName == line.name)
            #expect(produced.assemblyID == definition.id)
            #expect(produced.assemblyName == definition.name)
            #expect(produced.note == line.note)
        }
    }

    @Test("inputsUsed carries exactly the inputs the formula read, and their values")
    func inputsUsedIsExact() throws {
        let inputs = try studWallInputs()
        let results = AssemblyEvaluator.evaluate(.timberStudWall, inputs: inputs)

        let area = try quantity(results, "Wall area")
        #expect(Set(area.inputsUsed.keys) == ["Length", "Height"])
        #expect(area.inputsUsed["Length"] == inputs["Length"])
        #expect(area.inputsUsed["Height"] == inputs["Height"])

        let studs = try quantity(results, "Studs")
        #expect(Set(studs.inputsUsed.keys) == ["Length", "Spacing"])
        #expect(studs.inputsUsed["Spacing"] == inputs["Spacing"])

        let plates = try quantity(results, "Plates")
        #expect(Set(plates.inputsUsed.keys) == ["Length"])

        let board = try quantity(results, "Plasterboard both sides")
        #expect(Set(board.inputsUsed.keys) == ["Length", "Height"])
    }

    @Test("A supplied value the recipe never reads does not appear in inputsUsed")
    func unreadInputsAreNotClaimed() throws {
        var inputs = try studWallInputs()
        inputs["Area"] = .area(try dec("99"))
        inputs["Perimeter"] = .length(try dec("24.2"))
        let results = AssemblyEvaluator.evaluate(.timberStudWall, inputs: inputs)
        for produced in results.quantities {
            #expect(!produced.inputsUsed.keys.contains("Area"))
            #expect(!produced.inputsUsed.keys.contains("Perimeter"))
        }
    }

    @Test("inputsUsed is keyed by the definition's spelling, not the caller's")
    func inputsUsedUsesTheDeclaredSpelling() throws {
        let results = AssemblyEvaluator.evaluate(
            .timberStudWall,
            inputs: [
                "length": .length(try dec("9.6")),
                "  HEIGHT ": .length(try dec("2.5")),
                "spacing": .length(try dec("0.6"))
            ]
        )
        #expect(results.failures.isEmpty)
        #expect(Set(try quantity(results, "Studs").inputsUsed.keys) == ["Length", "Spacing"])
        #expect(try quantity(results, "Wall area").value.value == 24)
    }

    @Test("A refused line still says what was attempted")
    func failuresCarryTheirFormulaText() throws {
        let results = AssemblyEvaluator.evaluate(
            .timberStudWall,
            inputs: try studWallInputs(spacing: nil)
        )
        let studs = try failure(results, "Studs")
        #expect(studs.formulaText == "FLOOR(Length / Spacing) + 1")
        #expect(studs.assemblyID == AssemblyDefinition.timberStudWall.id)
        #expect(studs.assemblyName == "Timber stud wall")
    }
}

// MARK: - Failure honesty

@Suite("Assemblies — failure honesty")
struct AssemblyFailureTests {

    @Test("A missing input fails that line only; the other three are still produced")
    func missingInputIsPerLine() throws {
        let results = AssemblyEvaluator.evaluate(
            .timberStudWall,
            inputs: try studWallInputs(spacing: nil)
        )

        #expect(results.count == 4)
        #expect(results.failures.count == 1)
        #expect(results.quantities.count == 3)

        let studs = try failure(results, "Studs")
        #expect(studs.reason == .missingInput("Spacing"))
        #expect(studs.description.contains("Spacing"))

        #expect(try quantity(results, "Wall area").value.value == 24)
        #expect(try quantity(results, "Plates").value.value == (try dec("19.2")))
        #expect(try quantity(results, "Plasterboard both sides").value.value == 48)
    }

    @Test("A name the recipe never declared is reported as a missing input, not as a parser error")
    func undeclaredNameIsAMissingInput() throws {
        let definition = AssemblyDefinition(
            id: makeAssemblyID(1),
            name: "Undeclared parameter",
            inputs: [AssemblyInput(name: "Length", dimension: .length)],
            lines: [
                AssemblyLine(name: "Needs waste", source: "Length * [Waste]", outputDimension: .length),
                AssemblyLine(name: "Doubled", source: "Length * 2", outputDimension: .length)
            ]
        )
        let results = AssemblyEvaluator.evaluate(
            definition,
            inputs: ["Length": .length(try dec("9.6"))]
        )
        #expect(try failure(results, "Needs waste").reason == .missingInput("Waste"))
        #expect(try quantity(results, "Doubled").value.value == (try dec("19.2")))
    }

    @Test("Adding metres to square metres is refused per line, and named, and never a number")
    func dimensionMismatchIsWrappedPerLine() throws {
        let definition = AssemblyDefinition(
            id: makeAssemblyID(2),
            name: "Mixed dimensions",
            inputs: [
                AssemblyInput(name: "Length", dimension: .length),
                AssemblyInput(name: "Height", dimension: .length)
            ],
            lines: [
                AssemblyLine(
                    name: "Nonsense",
                    source: "Length + Length * Height",
                    outputDimension: .area
                ),
                AssemblyLine(name: "Sound", source: "Length * Height", outputDimension: .area)
            ]
        )
        let results = AssemblyEvaluator.evaluate(
            definition,
            inputs: ["Length": .length(try dec("9.6")), "Height": .length(try dec("2.5"))]
        )

        let nonsense = try failure(results, "Nonsense")
        guard case .formulaRefused(let error) = nonsense.reason else {
            Issue.record("got \(nonsense.reason)")
            return
        }
        guard case .dimensionMismatch(let operation, let left, let right) = error.code else {
            Issue.record("got \(error.code)")
            return
        }
        #expect(operation == "add")
        #expect(left == .length)
        #expect(right == .area)
        #expect(error.subexpression == "Length + Length * Height")

        #expect(try quantity(results, "Sound").value.value == 24)
    }

    @Test("A zero spacing is a division by zero, not an infinity")
    func divisionByZeroIsRefused() throws {
        let results = AssemblyEvaluator.evaluate(
            .timberStudWall,
            inputs: try studWallInputs(spacing: "0")
        )
        let studs = try failure(results, "Studs")
        guard case .formulaRefused(let error) = studs.reason else {
            Issue.record("got \(studs.reason)")
            return
        }
        #expect(error.code == .divisionByZero)
        #expect(results.quantities.count == 3)
    }

    @Test("A value in the wrong dimension is refused rather than returned")
    func declaredOutputDimensionIsEnforced() throws {
        let definition = AssemblyDefinition(
            id: makeAssemblyID(3),
            name: "Mislabelled output",
            inputs: [
                AssemblyInput(name: "Length", dimension: .length),
                AssemblyInput(name: "Height", dimension: .length)
            ],
            lines: [
                AssemblyLine(name: "Claims a length", source: "Length * Height", outputDimension: .length)
            ]
        )
        let results = AssemblyEvaluator.evaluate(
            definition,
            inputs: ["Length": .length(try dec("9.6")), "Height": .length(try dec("2.5"))]
        )
        #expect(
            try failure(results, "Claims a length").reason
                == .unexpectedDimension(expected: .length, actual: .area)
        )
    }

    @Test("An aggregate is refused: a recipe describes one measurement, not a group")
    func aggregatesAreRefused() throws {
        let definition = AssemblyDefinition(
            id: makeAssemblyID(4),
            name: "Aggregating recipe",
            inputs: [AssemblyInput(name: "Length", dimension: .length)],
            lines: [
                AssemblyLine(name: "Everything", source: "SUM(Length)", outputDimension: .length),
                AssemblyLine(name: "This one", source: "Length", outputDimension: .length)
            ]
        )
        let results = AssemblyEvaluator.evaluate(
            definition,
            inputs: ["Length": .length(try dec("9.6"))]
        )
        #expect(try failure(results, "Everything").reason == .aggregateNotAllowed)
        #expect(try quantity(results, "This one").value.value == (try dec("9.6")))
    }

    @Test("A ledger column reference is refused: an assembly has no ledger to resolve it against")
    func columnIDReferenceIsRefused() throws {
        let id = makeColumnID(7)
        let definition = AssemblyDefinition(
            id: makeAssemblyID(5),
            name: "Reaches into the ledger",
            inputs: [AssemblyInput(name: "Length", dimension: .length)],
            lines: [
                AssemblyLine(
                    name: "Borrowed",
                    source: "Length * [col:\(id.rawValue.uuidString)]",
                    outputDimension: .length
                )
            ]
        )
        let results = AssemblyEvaluator.evaluate(
            definition,
            inputs: ["Length": .length(try dec("9.6"))]
        )
        let borrowed = try failure(results, "Borrowed")
        // The compiler refuses the unknown id before evaluation ever reaches the reference walk,
        // so either refusal is correct; what must never happen is a number.
        switch borrowed.reason {
        case .columnReferenceNotAllowed, .formulaRefused:
            break
        default:
            Issue.record("got \(borrowed.reason)")
        }
    }

    @Test("A definition that cannot be told apart from itself is refused before evaluation")
    func validationRefusesAmbiguousDefinitions() throws {
        let duplicateLines = AssemblyDefinition(
            id: makeAssemblyID(6),
            name: "Two of the same",
            inputs: [AssemblyInput(name: "Length", dimension: .length)],
            lines: [
                AssemblyLine(name: "Plates", source: "Length * 2", outputDimension: .length),
                AssemblyLine(name: "plates ", source: "Length * 3", outputDimension: .length)
            ]
        )
        #expect(throws: AssemblyDefinitionError.duplicateLineName("plates ")) {
            try duplicateLines.validate()
        }

        let contradictoryInput = AssemblyDefinition(
            id: makeAssemblyID(7),
            name: "Length that is an area",
            inputs: [AssemblyInput(name: "Length", dimension: .area)],
            lines: [AssemblyLine(name: "Any", source: "Length", outputDimension: .area)]
        )
        #expect(
            throws: AssemblyDefinitionError.inputDimensionContradictsField(
                input: "Length",
                declared: .area,
                required: .length
            )
        ) {
            try contradictoryInput.validate()
        }

        let noLines = AssemblyDefinition(
            id: makeAssemblyID(8),
            name: "Empty",
            inputs: [],
            lines: []
        )
        #expect(throws: AssemblyDefinitionError.noLines(assembly: "Empty")) {
            try noLines.validate()
        }
    }
}

// MARK: - Persistence

@Suite("Assemblies — persisted shape")
struct AssemblyCodableTests {

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    @Test("Encode, decode, encode reproduces the same bytes")
    func codableRoundTripIsByteStable() throws {
        let first = try encoder().encode(AssemblyDefinition.timberStudWall)
        let decoded = try JSONDecoder().decode(AssemblyDefinition.self, from: first)
        let second = try encoder().encode(decoded)
        #expect(first == second)
        #expect(decoded == AssemblyDefinition.timberStudWall)
    }

    @Test("A decoded recipe evaluates to the same quantities as the one in code")
    func decodedRecipeEvaluatesIdentically() throws {
        let data = try encoder().encode(AssemblyDefinition.timberStudWall)
        let decoded = try JSONDecoder().decode(AssemblyDefinition.self, from: data)
        let inputs = try studWallInputs()
        #expect(
            AssemblyEvaluator.evaluate(decoded, inputs: inputs)
                == AssemblyEvaluator.evaluate(.timberStudWall, inputs: inputs)
        )
    }

    @Test("The persisted key names are the frozen ones")
    func codingKeysAreFrozen() throws {
        let data = try encoder().encode(AssemblyDefinition.timberStudWall)
        let json = try #require(String(data: data, encoding: .utf8))
        for key in [
            "\"id\"", "\"name\"", "\"note\"", "\"inputs\"", "\"lines\"",
            "\"dimension\"", "\"formula\"", "\"outputDimension\"",
            "\"source\"", "\"grammarVersion\""
        ] {
            #expect(json.contains(key), "the persisted key \(key) is missing")
        }
    }

    @Test("A nil note is omitted rather than written as null, so the bytes stay stable")
    func absentNotesAreOmitted() throws {
        let definition = AssemblyDefinition(
            id: makeAssemblyID(10),
            name: "No notes",
            inputs: [AssemblyInput(name: "Length", dimension: .length)],
            lines: [AssemblyLine(name: "Doubled", source: "Length * 2", outputDimension: .length)]
        )
        let data = try encoder().encode(definition)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"note\""))
        #expect(!json.contains("null"))
        #expect(try JSONDecoder().decode(AssemblyDefinition.self, from: data) == definition)
    }
}
