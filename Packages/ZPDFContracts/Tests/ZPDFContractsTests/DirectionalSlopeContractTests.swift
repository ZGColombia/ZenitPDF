import Foundation
import Testing
@testable import ZPDFContracts

/// The contract half of ADR-0004: the slope vocabulary itself, independent of any engine.
@Suite("ADR-0004 slope contract")
struct DirectionalSlopeContractTests {

    static let half = Decimal(sign: .plus, exponent: -1, significand: 5)

    // MARK: - Azimuth

    @Test("An axis-aligned azimuth gives an exact unit vector, with no trigonometry")
    func axisDirectionsAreExact() {
        #expect(SlopeAzimuth(degrees: 0).direction == PlanarDirection(x: 1, y: 0))
        #expect(SlopeAzimuth(degrees: 90).direction == PlanarDirection(x: 0, y: 1))
        #expect(SlopeAzimuth(degrees: 180).direction == PlanarDirection(x: -1, y: 0))
        #expect(SlopeAzimuth(degrees: 270).direction == PlanarDirection(x: 0, y: -1))
        // The component of a contour-parallel displacement is exactly zero, which is what makes
        // an eave come out at its plan length rather than near it.
        #expect(SlopeAzimuth(degrees: 90).direction.component(dx: 137.25, dy: 0) == 0)
    }

    @Test("Azimuths normalise into [0, 360) in both directions")
    func normalisation() {
        #expect(SlopeAzimuth(degrees: 360).degrees == 0)
        #expect(SlopeAzimuth(degrees: 450).degrees == 90)
        #expect(SlopeAzimuth(degrees: -90).degrees == 270)
        #expect(SlopeAzimuth(degrees: -450).degrees == 270)
        #expect(SlopeAzimuth(degrees: 1_080).degrees == 0)
        #expect(SlopeAzimuth(degrees: 90).opposite.degrees == 270)
        #expect(SlopeAzimuth(degrees: 270).opposite.degrees == 90)
    }

    @Test("The three ways of naming a fall line agree, and a degenerate one is a typed error")
    func azimuthSources() throws {
        #expect(try SlopeAzimuth.between(PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 0)).degrees == 0)
        #expect(try SlopeAzimuth.between(PDFPoint(x: 0, y: 0), PDFPoint(x: -5, y: 0)).degrees == 180)
        #expect(try SlopeAzimuth.between(PDFPoint(x: 2, y: 1), PDFPoint(x: 2, y: 9)).degrees == 90)
        #expect(try SlopeAzimuth.between(PDFPoint(x: 2, y: 9), PDFPoint(x: 2, y: 1)).degrees == 270)
        #expect(try SlopeAzimuth.radians(Double.pi / 2).degrees == 90)

        let diagonal = try SlopeAzimuth.between(PDFPoint(x: 0, y: 0), PDFPoint(x: 3, y: 4))
        #expect(abs(NumericPolicy.double(from: diagonal.degrees) - 53.130_102_354_155_98) < 1e-9)

        #expect(throws: SlopeError.azimuthFromCoincidentPoints) {
            _ = try SlopeAzimuth.between(PDFPoint(x: 1, y: 1), PDFPoint(x: 1, y: 1))
        }
        #expect(throws: SlopeError.nonFiniteAzimuth) {
            _ = try SlopeAzimuth.radians(.infinity)
        }
        try Self.roundTripJSON(SlopeAzimuth(degrees: Decimal(string: "26.565051177078")!))
    }

    // MARK: - Specification

    @Test("A slope with no azimuth is a typed error for a length and fine for an area")
    func azimuthIsRequiredOnlyForDirectionalQuantities() throws {
        let specification = SlopeSpecification.uniformPlane(.riseOverRun(rise: 6, run: 12))
        #expect(throws: MeasurementError.slopeAzimuthRequired(.trueLength)) {
            _ = try specification.requireAzimuth(for: .trueLength)
        }
        #expect(throws: MeasurementError.slopeAzimuthRequired(.truePerimeter)) {
            _ = try specification.requireAzimuth(for: .truePerimeter)
        }
        // Area does not ask, so nothing here can throw for it.
        #expect(throws: Never.self) { try specification.validate() }

        let located = specification.with(azimuth: SlopeAzimuth(degrees: 90))
        #expect(try located.requireAzimuth(for: .trueLength).degrees == 90)

        let fromPoints = try SlopeSpecification.uniformPlane(
            .percent(50),
            fallLineFrom: PDFPoint(x: 0, y: 0),
            to: PDFPoint(x: 0, y: 4)
        )
        #expect(fromPoints.azimuth == SlopeAzimuth(degrees: 90))
    }

    @Test("Each mode demands its own input")
    func modeValidation() {
        #expect(throws: Never.self) { try SlopeSpecification.none.validate() }
        #expect(throws: MeasurementError.missingParameter(.riseRun)) {
            try SlopeSpecification(mode: .uniformPlane).validate()
        }
        #expect(throws: MeasurementError.missingParameter(.perSegmentRiseDrop)) {
            try SlopeSpecification(mode: .perSegmentRiseDrop).validate()
        }
        #expect(throws: MeasurementError.missingParameter(.totalRiseDrop)) {
            try SlopeSpecification(mode: .totalRiseDrop).validate()
        }
    }

    @Test("Above 100 % is flagged, not rejected; vertical is its own condition")
    func magnitudeFlag() {
        #expect(!SlopeSpecification.uniformPlane(.percent(100)).exceedsOneHundredPercent)
        #expect(SlopeSpecification.uniformPlane(.percent(150)).exceedsOneHundredPercent)
        #expect(SlopeSpecification.uniformPlane(.degrees(60)).exceedsOneHundredPercent)
        #expect(!SlopeSpecification.uniformPlane(.riseOverRun(rise: 1, run: 0)).exceedsOneHundredPercent)
        #expect(!SlopeSpecification.perSegment([9]).exceedsOneHundredPercent)
    }

    @Test("A record written under measurement contract v1 still decodes")
    func legacyModeDecodes() throws {
        let decoded = try JSONDecoder().decode(SlopeMode.self, from: Data(#""uniformSlope""#.utf8))
        #expect(decoded == .uniformPlane)
        for mode in SlopeMode.allCases { try Self.roundTripJSON(mode) }
        for reference in VolumeDepthReference.allCases { try Self.roundTripJSON(reference) }
        try Self.roundTripJSON(
            SlopeSpecification.uniformPlane(.riseOverRun(rise: 6, run: 12), azimuth: SlopeAzimuth(degrees: 90))
        )
    }

    // MARK: - Pitch input (ADR-0004 §3)

    @Test("6:12, 1:2, 0.5, 50 % and rise-over-run are one exact Decimal")
    func pitchFormsAreExact() throws {
        let forms: [SlopeExpression] = [
            .riseOverRun(rise: 6, run: 12),
            .ratioOneToN(2),
            .ratioNToOne(Self.half),
            .decimalRatio(Self.half),
            .percent(50),
            .pitch(6),
            .pitch(1, run: 2)
        ]
        for form in forms {
            #expect(try form.ratio() == Self.half, "\(form) is not exactly 1/2")
            #expect(try form.trueLengthFactor() == (1.25 as Double).squareRoot())
        }
    }

    @Test("Text input reads every form ADR-0004 accepts, and refuses the rest")
    func textInput() throws {
        #expect(try SlopeExpression.parse("6:12").ratio() == Self.half)
        #expect(try SlopeExpression.parse(" 1:2 ").ratio() == Self.half)
        #expect(try SlopeExpression.parse("1/2").ratio() == Self.half)
        #expect(try SlopeExpression.parse("50%").ratio() == Self.half)
        #expect(try SlopeExpression.parse("50 %").ratio() == Self.half)
        #expect(try SlopeExpression.parse("0.5").ratio() == Self.half)
        #expect(try SlopeExpression.parse("rise 1.5 m over run 3 m").ratio() == Self.half)
        // Imperial pitch defaults to a run of 12, and only when the caller asks for it.
        #expect(try SlopeExpression.parse("6", pitchDefaultRun: SlopeExpression.imperialPitchRun).ratio() == Self.half)
        #expect(try SlopeExpression.parse("6").ratio() == 6)

        if case .degrees(let value) = try SlopeExpression.parse("26.57\u{00B0}") {
            #expect(value == Decimal(string: "26.57"))
        } else {
            Issue.record("26.57 degrees did not parse as degrees")
        }

        #expect(throws: SlopeError.self) { _ = try SlopeExpression.parse("") }
        #expect(throws: SlopeError.self) { _ = try SlopeExpression.parse("steep") }
        #expect(throws: SlopeError.self) { _ = try SlopeExpression.parse("1:2:3") }
    }

    @Test("Measurement parameters carry the slope and the volume depth reference")
    func parametersCarryTheADR() throws {
        var parameters = MeasurementParameters(
            depth: .length(Decimal(string: "0.2")!),
            height: .length(Decimal(string: "2.4")!),
            heightAtEnd: .length(4),
            slope: .uniformPlane(.pitch(6), azimuth: SlopeAzimuth(degrees: 90)),
            volumeDepthReference: .perpendicularThickness
        )
        #expect(throws: Never.self) { try parameters.validate() }
        parameters.heightAtEnd = .area(4)
        #expect(throws: UnitConversionError.self) { try parameters.validate() }
    }

    static func roundTripJSON<T: Codable & Equatable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(T.self, from: data) == value)
    }
}
