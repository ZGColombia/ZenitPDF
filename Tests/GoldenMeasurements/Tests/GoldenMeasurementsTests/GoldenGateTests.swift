import Foundation
import GoldenMeasurements
import Testing
import ZPDFContracts
import ZPDFMeasurementEngine

/// The acceptance gate: every corpus case is run through the real engine and judged against the
/// tolerances of spec 1.2 — 0.05 % for lengths, 0.10 % for areas, 0.15 % for volumes.
@Suite("Golden measurements")
struct GoldenGateTests {

    static func engine(for goldenCase: GoldenCase) -> MeasurementEngine {
        MeasurementEngine(
            options: MeasurementEngineOptions(expectedScaleVersion: goldenCase.expectedScaleVersion)
        )
    }

    @Test("Golden case", arguments: GoldenCorpus.all)
    func goldenCase(_ goldenCase: GoldenCase) throws {
        if let refusal = goldenCase.expectedRefusal {
            do {
                let result = try Self.engine(for: goldenCase).calculate(
                    tool: goldenCase.tool,
                    geometry: goldenCase.geometry,
                    scale: goldenCase.scale,
                    parameters: goldenCase.parameters
                )
                Issue.record("\(goldenCase.id): expected a refusal containing “\(refusal)”, got \(result.values.keys.map(\.rawValue))")
            } catch {
                let text = String(describing: error)
                #expect(text.contains(refusal), "\(goldenCase.id): expected a refusal containing “\(refusal)”, got \(text)")
            }
            return
        }
        let result = try Self.engine(for: goldenCase).calculate(
            tool: goldenCase.tool,
            geometry: goldenCase.geometry,
            scale: goldenCase.scale,
            parameters: goldenCase.parameters
        )

        for (field, expected) in goldenCase.expected.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let quantity = try #require(
                result[field],
                "\(goldenCase.id): expected a value for \(field.rawValue)"
            )
            #expect(
                quantity.dimension == field.dimension,
                "\(goldenCase.id): \(field.rawValue) has the wrong dimension"
            )
            let actual = NumericPolicy.double(from: quantity.value)
            #expect(actual.isFinite, "\(goldenCase.id): \(field.rawValue) is not finite")

            if abs(expected) <= GoldenTolerance.absoluteFloor {
                #expect(
                    abs(actual) <= GoldenTolerance.absoluteFloor,
                    "\(goldenCase.id): \(field.rawValue) expected ~0, got \(actual)"
                )
            } else {
                let tolerance = GoldenTolerance.relative(for: field)
                let error = abs(actual - expected) / abs(expected)
                #expect(
                    error <= tolerance,
                    """
                    \(goldenCase.id) \(field.rawValue): expected \(expected), got \(actual), \
                    relative error \(error) exceeds \(tolerance)
                    """
                )
            }
        }

        for code in goldenCase.expectedWarnings.sorted(by: { $0.rawValue < $1.rawValue }) {
            #expect(
                result.hasWarning(code),
                "\(goldenCase.id): expected warning \(code.rawValue), got \(result.warnings.map(\.code.rawValue))"
            )
        }
        for code in goldenCase.forbiddenWarnings.sorted(by: { $0.rawValue < $1.rawValue }) {
            #expect(
                !result.hasWarning(code),
                "\(goldenCase.id): unexpected warning \(code.rawValue)"
            )
        }

        // No case may produce a non-finite or NaN value, whatever else it does.
        for (field, quantity) in result.values {
            let value = NumericPolicy.double(from: quantity.value)
            #expect(value.isFinite, "\(goldenCase.id): \(field.rawValue) is \(value)")
        }
        #expect(result.formulaVersion == ContractVersion.measurementFormulaVersion)
        try result.validateDimensions()
    }

    @Test("Re-running a case gives an identical result, warnings included")
    func determinism() throws {
        for goldenCase in GoldenCorpus.all where goldenCase.expectedRefusal == nil {
            let engine = Self.engine(for: goldenCase)
            let first = try engine.calculate(
                tool: goldenCase.tool,
                geometry: goldenCase.geometry,
                scale: goldenCase.scale,
                parameters: goldenCase.parameters
            )
            let second = try engine.calculate(
                tool: goldenCase.tool,
                geometry: goldenCase.geometry,
                scale: goldenCase.scale,
                parameters: goldenCase.parameters
            )
            #expect(first == second, "\(goldenCase.id) is not deterministic")
        }
    }
}

@Suite("Golden corpus integrity")
struct CorpusIntegrityTests {

    @Test("The gate has at least 60 cases")
    func size() {
        #expect(GoldenCorpus.all.count >= 60)
    }

    @Test("Case identifiers are unique")
    func uniqueIdentifiers() {
        let ids = GoldenCorpus.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every case states where its numbers came from, and most are hand-derived")
    func provenance() {
        let handDerived = GoldenCorpus.all.filter { $0.derivation == .handDerived }
        let numerical = GoldenCorpus.all.filter { $0.derivation == .independentNumericalReference }
        let invariant = GoldenCorpus.all.filter { $0.derivation == .invariant }
        #expect(handDerived.count + numerical.count + invariant.count == GoldenCorpus.all.count)
        #expect(handDerived.count >= GoldenCorpus.all.count / 2)
    }

    @Test("Every tool in spec 12.1 is exercised by at least one case")
    func toolCoverage() {
        let covered = Set(GoldenCorpus.all.map(\.tool))
        let missing = Set(MeasurementTool.allCases).subtracting(covered)
        #expect(missing.isEmpty, "tools with no golden case: \(missing.map(\.rawValue).sorted())")
    }

    @Test("Metric, imperial, separate-XY and rotated scales are all represented")
    func scaleCoverage() {
        let labels = Set(GoldenCorpus.all.compactMap(\.scale.label))
        #expect(labels.contains("1 ft/pt"))
        #expect(labels.contains("1 in/pt"))
        #expect(labels.contains("20 mm/pt x, 50 mm/pt y"))
        #expect(labels.contains("40 mm/pt, page rotated 90 deg"))
        #expect(labels.contains("100 mm/pt, page rotated 30 deg"))
    }

    @Test("Polygons with one, two and three holes are all represented")
    func holeCoverage() {
        var counts = Set<Int>()
        for goldenCase in GoldenCorpus.all {
            for polygon in goldenCase.geometry.polygons where !polygon.holes.isEmpty {
                counts.insert(polygon.holes.count)
            }
        }
        #expect(counts.contains(1))
        #expect(counts.contains(2))
        #expect(counts.contains(3))
    }
}
