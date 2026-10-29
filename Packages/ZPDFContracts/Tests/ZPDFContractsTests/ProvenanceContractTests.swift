import Foundation
import Testing
import ZPDFContracts

/// ADR-0007: the provenance record and its attachment to `MeasurementResult`.
@Suite("Measurement provenance contract")
struct ProvenanceContractTests {

    private static func makeProvenance() -> MeasurementProvenance {
        MeasurementProvenance(
            geometryDigest: String(repeating: "ab", count: 32),
            scaleID: ScaleID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4))),
            scaleVersion: 3,
            scaleSource: .calibrationTwoPoint,
            calibrationEvidence: CalibrationEvidence(
                points: [PDFPoint(x: 10, y: 20), PDFPoint(x: 110, y: 20)],
                enteredLength: .length(5),
                enteredUnit: .metre
            ),
            slope: .none,
            parameters: .default,
            formulaVersion: ContractVersion.measurementFormulaVersion,
            engineVersion: "1.0.0-test",
            computedAt: Date(timeIntervalSince1970: 1_800_000_000),
            layerName: nil
        )
    }

    @Test("Provenance round-trips through Codable byte-stably")
    func provenanceRoundTrips() throws {
        let provenance = Self.makeProvenance()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(provenance)
        let decoded = try decoder.decode(MeasurementProvenance.self, from: data)
        #expect(decoded == provenance)
        // Deterministic bytes: encoding the decoded value again is identical.
        #expect(try encoder.encode(decoded) == data)
    }

    @Test("A result attaches provenance without touching values or warnings")
    func attachingKeepsTheResult() throws {
        let result = MeasurementResult(
            values: [.planArea: .area(21)],
            warnings: [MeasurementWarning(code: .degenerateArea)]
        )
        #expect(result.provenance == nil)
        let attached = result.attaching(Self.makeProvenance())
        #expect(attached.provenance == Self.makeProvenance())
        #expect(attached.values == result.values)
        #expect(attached.warnings == result.warnings)
        #expect(attached.formulaVersion == result.formulaVersion)
        try attached.validateDimensions()
    }

    @Test("A version-2 stored result (no provenance key) still decodes, as nil provenance")
    func preADR0007ResultDecodes() throws {
        let json = """
        {"values":{},"warnings":[],"formulaVersion":2}
        """
        let decoded = try JSONDecoder().decode(MeasurementResult.self, from: Data(json.utf8))
        #expect(decoded.provenance == nil)
        #expect(decoded.formulaVersion == 2)
    }

    /// ADR-0007 bumped the measurement contract to 3 and ADR-0014 to 4; ADR-0035 bumped it to
    /// 5 for `MeasurementError.coordinateOutOfRange`, the
    /// `openingAreas` parameter key and the optional `MeasurementParameters.displayOverride`.
    @Test("ADR-0035 bumped the measurement contract to version 5")
    func contractVersionIsBumped() {
        #expect(ContractVersion.measurement == 5)
    }

    @Test("The version-5 freeze document (ADR-0035) describes the provenance types")
    func freezeDescribesProvenance() throws {
        let documents = try ContractCatalog.allDocuments(frozenAt: "2026-08-23T00:00:00Z")
        let measurement = try #require(documents.first { $0.contract == "MEASUREMENT_CONTRACT" })
        // ADR-0035 is the latest bump; the provenance field set below is unchanged by it.
        #expect(measurement.contractVersion == 5)
        let provenance = try #require(measurement.types.first { $0.name == "MeasurementProvenance" })
        #expect(provenance.fields.map(\.name) == [
            "geometryDigest", "scaleID", "scalePageID", "scaleVersion", "scaleSource",
            "calibrationEvidence",
            "slope", "parameters", "formulaVersion", "engineVersion", "computedAt", "layerName",
            // ADR-0031 (NL-AUTO-18), additively: how the geometry was captured; absent means manual.
            "captureMethod"
        ])
        let evidence = try #require(measurement.types.first { $0.name == "CalibrationEvidence" })
        // ADR-0019 added the Y line's length of a separate X/Y calibration, additively; ADR-0030
        // the scale checks (NL-MEASURE-04).
        #expect(evidence.fields.map(\.name) == ["points", "enteredLength", "enteredUnit", "secondaryEnteredLength", "verifications"])
        let result = try #require(measurement.types.first { $0.name == "MeasurementResult" })
        #expect(result.fields.contains { $0.name == "provenance" })
    }
}

/// ADR-0019: `CalibrationEvidence.secondaryEnteredLength` is additive — a record written before
/// it decodes with `nil`, and a separate X/Y record round-trips both lengths.
@Suite("CalibrationEvidence secondary length (ADR-0019)")
struct CalibrationEvidenceSecondaryLengthTests {
    @Test("An old record decodes with no Y length; a new one round-trips it")
    func additive() throws {
        // A two-point record encodes without the key — exactly the bytes written before ADR-0019.
        let twoPoint = CalibrationEvidence(
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)], enteredLength: .length(5), enteredUnit: .metre
        )
        let old = try JSONEncoder().encode(twoPoint)
        #expect(!String(decoding: old, as: UTF8.self).contains("secondaryEnteredLength"))
        let decoded = try JSONDecoder().decode(CalibrationEvidence.self, from: old)
        #expect(decoded.secondaryEnteredLength == nil)
        #expect(decoded.points.count == 2)

        let xy = CalibrationEvidence(
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 0, y: 0), PDFPoint(x: 0, y: 50)],
            enteredLength: .length(10), enteredUnit: .metre, secondaryEnteredLength: .length(10)
        )
        let back = try JSONDecoder().decode(CalibrationEvidence.self, from: JSONEncoder().encode(xy))
        #expect(back == xy)
    }
}
