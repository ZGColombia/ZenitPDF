import Foundation
import GoldenMeasurements
import Testing
import ZPDFContracts
import ZPDFMeasurementEngine

/// The assertions ADR-0004 turns on, stated as differences rather than as values.
///
/// The golden gate checks that each number is what it should be. This suite checks the thing a
/// per-field tolerance cannot: that the answer is **not** the scalar model's answer, that a
/// contour-parallel edge is exactly unchanged rather than nearly unchanged, that five spellings
/// of one pitch give one result, and that a slope with no fall line is a typed error rather than
/// a quiet scalar.
@Suite("ADR-0004 directional slope")
struct DirectionalSlopeTests {

    static let engine = MeasurementEngine()

    static func run(_ id: String) throws -> MeasurementResult {
        let goldenCase = try #require(
            GoldenCorpus.all.first { $0.id == id },
            "no golden case \(id)"
        )
        return try engine.calculate(
            tool: goldenCase.tool,
            geometry: goldenCase.geometry,
            scale: goldenCase.scale,
            parameters: goldenCase.parameters
        )
    }

    static func double(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        NumericPolicy.double(from: try #require(result[field], "no \(field.rawValue)").value)
    }

    // MARK: - The number this ADR exists for

    /// The gable case, stated as the gap between the two models.
    ///
    /// ```text
    /// plan perimeter            32                       m
    /// this model    24 + 2 sqrt(20)  = 32.944271909999160 m
    /// scalar model  32 * sqrt(1.25)  = 35.777087639996640 m
    /// over-measure  24 (sqrt(1.25)-1) = 2.832815729997478 m   = 8.5988 % of the true perimeter
    /// ```
    ///
    /// The over-measure is exactly the elongation the scalar model applies to the 24 m of eave and
    /// ridge that do not elongate at all. On a real roof that is most of the boundary, which is
    /// why the error is large and why it is invisible: every individual number looks plausible.
    @Test("A gable perimeter differs from the scalar slope model by 24 (sqrt(1.25) - 1) m")
    func gableDiffersFromTheScalarModel() throws {
        let result = try Self.run("DS01")
        let plan = try Self.double(result, .perimeter)
        let truePerimeter = try Self.double(result, .truePerimeter)

        let factor = (1.25 as Double).squareRoot()
        let scalarModel = plan * factor
        let handDerived = 24 + 2 * (20.0 as Double).squareRoot()

        #expect(plan == 32)
        #expect(abs(truePerimeter - handDerived) <= 1e-12)

        // The regression guard: the engine must NOT be within a hair of the scalar answer.
        let gap = scalarModel - truePerimeter
        #expect(abs(gap - 24 * (factor - 1)) <= 1e-12, "the scalar/vector gap moved")
        #expect(gap > 2.8, "the engine has regressed towards planLength * sqrt(1 + s^2)")
        #expect(
            abs(gap / truePerimeter - 0.085_988_111_612_740) <= 1e-12,
            "the scalar model over-measures this gable by 8.5988 % of its perimeter"
        )

        // Area is untouched by the ADR: the scalar factor is exact there.
        let planArea = try Self.double(result, .planArea)
        let trueArea = try Self.double(result, .trueArea)
        #expect(abs(trueArea - planArea * factor) <= 1e-12)
    }

    /// The hip roof: three distinct elongation factors on one plane, none of them the scalar.
    @Test("On a hip plane the eave, the ridge and the hip elongate by three different factors")
    func hipEdgesElongateDifferently() throws {
        let result = try Self.run("DS03")
        let plan = try Self.double(result, .perimeter)
        let truePerimeter = try Self.double(result, .truePerimeter)
        let factor = (1.25 as Double).squareRoot()

        // eave 24 (x1), hip sqrt(72) -> 9 (x1.060660...), ridge 12 (x1), hip sqrt(72) -> 9
        #expect(abs(plan - (36 + 2 * (72.0 as Double).squareRoot())) <= 1e-12)
        #expect(abs(truePerimeter - 54) <= 1e-12)

        let hipFactor = 9 / (72.0 as Double).squareRoot()
        #expect(abs(hipFactor - 1.060_660_171_779_821) <= 1e-12)
        #expect(hipFactor < factor, "no edge on the plane reaches the fall-line factor")
        #expect(hipFactor > 1, "a hip does elongate; it is not a contour")
        #expect(truePerimeter < plan * factor, "the scalar model over-measures the hip plane too")

        // Whole roof, four planes: 54 + 54 + 30 + 30 = 168 m of true edge over
        // 2 (36 + 2 sqrt(72)) + 2 (12 + 2 sqrt(72)) = 96 + 8 sqrt(72) = 163.882250993908540 m of
        // plan edge. The scalar model would bill 163.882250993908540 * sqrt(1.25) = 183.225926764031
        // m of hip, ridge and eave that is not there.
        var trueTotal = 0.0
        var planTotal = 0.0
        for id in ["DS03", "DS04", "DS05", "DS06"] {
            let plane = try Self.run(id)
            trueTotal += try Self.double(plane, .truePerimeter)
            planTotal += try Self.double(plane, .perimeter)
        }
        #expect(abs(trueTotal - 168) <= 1e-9)
        #expect(abs(planTotal - (96 + 8 * (72.0 as Double).squareRoot())) <= 1e-9)
        #expect(abs(planTotal * factor - 183.225_926_764_031) <= 1e-9)
        #expect(
            planTotal * factor - trueTotal > 15,
            "the scalar model adds over 15 m of imaginary edge to this hip roof"
        )
    }

    // MARK: - Exactness, not closeness

    /// A contour-parallel edge must be **equal** to its plan length, in the stored `Decimal`.
    ///
    /// `d . u == 0` exactly for an axis-aligned azimuth, and `hypot(x, 0)` returns `|x|`
    /// bit-for-bit, so there is nothing here to round. A test that only asked for "close" would
    /// pass against an implementation that multiplied by `sqrt(1 + s^2 * cos^2(phi))` with a
    /// slightly wrong `phi`.
    @Test("A contour-parallel line is exactly its plan length, not approximately")
    func contourParallelIsExact() throws {
        let result = try Self.run("DS09")
        let plan = try #require(result[.planLength]).value
        let trueLength = try #require(result[.trueLength]).value
        #expect(trueLength == plan, "expected exact Decimal equality, got \(trueLength) vs \(plan)")

        // And the same on the shed case at 1 m/pt.
        let shed = try Self.run("DS08")
        #expect(try #require(shed[.trueLength]).value == (try #require(shed[.planLength]).value))
    }

    /// The two volume modes differ by exactly `sqrt(1 + s^2)`.
    ///
    /// `16` and `16 * sqrt(1.25)`: the division by 16 is exact in `Decimal` (16 is a power of
    /// two), so this is an equality, not a tolerance.
    @Test("Vertical depth and perpendicular thickness differ by exactly sqrt(1 + s^2)")
    func volumeModesDifferByTheFactor() throws {
        let vertical = try #require(try Self.run("DS11")[.volume]).value
        let perpendicular = try #require(try Self.run("DS12")[.volume]).value
        let factor = try NumericPolicy.decimal(from: (1.25 as Double).squareRoot())

        #expect(vertical == 16)
        // Compared at policy significance: CR-23 normalises stored volumes to 15
        // significant digits, which moves the raw Decimal quotient by ~2e-15.
        #expect(try NumericPolicy.decimal(from: NumericPolicy.double(from: perpendicular / vertical)) == factor)
        #expect(perpendicular > vertical)
    }

    /// One pitch, five spellings, one result.
    @Test("6:12, 1:2, 0.5, 50 % and n:1 give bit-identical results")
    func pitchSpellingsAgreeExactly() throws {
        let ids = (0..<GoldenPitch.allSpellings.count).map { String(format: "DS2%d", $0) }
        let results = try ids.map { try Self.run($0) }
        let first = try #require(results.first)
        for (index, result) in results.enumerated() {
            #expect(result == first, "spelling \(index) disagrees with spelling 0")
        }
        // And every spelling really is the same stored Decimal.
        for expression in GoldenPitch.allSpellings {
            #expect(try expression.ratio() == Decimal(sign: .plus, exponent: -1, significand: 5))
        }
        // 26.57 degrees is the inexact fifth form: close, but deliberately not asserted as equal.
        let degrees = try SlopeExpression.degrees(Decimal(string: "26.565051177078")!).ratio()
        #expect(abs(NumericPolicy.double(from: degrees) - 0.5) < 1e-12)
    }

    // MARK: - Typed errors, never a silent fallback

    @Test("A slope on a length with no fall line is a typed error")
    func lengthWithoutAzimuthThrows() throws {
        let parameters = MeasurementParameters(slope: .uniformPlane(GoldenPitch.sixOverTwelve))
        // `.slope` left this list with ADR-0019: the Slope tool no longer stretches its drawn run
        // into a length, so there is nothing a fall line would direct.
        for tool in [MeasurementTool.length, .polylength, .dimension, .trueSlopedLength] {
            #expect(throws: MeasurementEngineError.self, "\(tool.rawValue) accepted a slope with no azimuth") {
                _ = try Self.engine.calculate(
                    tool: tool,
                    geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
                    scale: GoldenScale.unit,
                    parameters: parameters
                )
            }
        }
        #expect(throws: MeasurementEngineError.self) {
            _ = try Self.engine.calculate(
                tool: .perimeter,
                geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 4, height: 3)),
                scale: GoldenScale.unit,
                parameters: parameters
            )
        }
        #expect(throws: MeasurementEngineError.self) {
            _ = try Self.engine.calculate(
                tool: .wallArea,
                geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
                scale: GoldenScale.unit,
                parameters: MeasurementParameters(
                    height: .length(2),
                    slope: .uniformPlane(GoldenPitch.sixOverTwelve)
                )
            )
        }
    }

    @Test("An area with no fall line still computes, because area needs no direction")
    func areaWithoutAzimuthSucceeds() throws {
        let result = try Self.engine.calculate(
            tool: .trueSlopedArea,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 10)),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(slope: .uniformPlane(GoldenPitch.sixOverTwelve))
        )
        let factor = (1.25 as Double).squareRoot()
        #expect(abs(try Self.double(result, .trueArea) - 100 * factor) <= 1e-9)
        // The boundary is the part that needs a direction, so it is absent and says so.
        #expect(result[.truePerimeter] == nil)
        #expect(result.hasWarning(.slopeAzimuthMissingForBoundary))
    }

    @Test("A volume on a sloped markup with no depth reference is a typed error")
    func volumeWithoutDepthReferenceThrows() {
        #expect(throws: MeasurementEngineError.self) {
            _ = try Self.engine.calculate(
                tool: .volume,
                geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 8)),
                scale: GoldenScale.unit,
                parameters: MeasurementParameters(
                    depth: .length(Decimal(sign: .plus, exponent: -1, significand: 2)),
                    slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north)
                )
            )
        }
        // A flat markup needs no choice: the two modes are the same number.
        #expect(throws: Never.self) {
            _ = try Self.engine.calculate(
                tool: .volume,
                geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 8)),
                scale: GoldenScale.unit,
                parameters: MeasurementParameters(depth: .length(Decimal(sign: .plus, exponent: -1, significand: 2)))
            )
        }
    }

    @Test("run == 0 is a typed vertical result, never a division")
    func verticalIsTyped() throws {
        let result = try Self.engine.calculate(
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(.riseOverRun(rise: 1, run: 0), azimuth: GoldenFallLine.east)
            )
        )
        #expect(result.hasWarning(.verticalSlopeUndefinedRun))
        #expect(result[.trueLength] == nil)
        #expect(result[.slopeRatio] == nil)
        for quantity in result.values.values {
            #expect(NumericPolicy.double(from: quantity.value).isFinite)
        }
    }

    // MARK: - Plan and true, side by side

    @Test("A sloped measurement stores both numbers and overwrites neither")
    func planAndTrueCoexist() throws {
        let gable = try Self.run("DS01")
        #expect(gable[.perimeter] != nil && gable[.truePerimeter] != nil)
        #expect(gable[.planArea] != nil && gable[.trueArea] != nil)
        #expect(try Self.double(gable, .perimeter) < (try Self.double(gable, .truePerimeter)))

        let wall = try Self.run("DS15")
        #expect(try Self.double(wall, .planWallArea) == 24)
        #expect(try Self.double(wall, .wallArea) > (try Self.double(wall, .planWallArea)))
        #expect(try Self.double(wall, .planLength) == 10)
    }

    // MARK: - Azimuth input

    @Test("The three ways of setting an azimuth resolve to the same vector")
    func azimuthInputsAgree() throws {
        let byAngle = SlopeAzimuth(degrees: 90)
        let byPoints = try SlopeAzimuth.between(PDFPoint(x: 3, y: 1), PDFPoint(x: 3, y: 9))
        let byRadians = try SlopeAzimuth.radians(Double.pi / 2)
        #expect(byAngle == byPoints)
        #expect(byAngle == byRadians)
        #expect(byAngle.direction.x == 0 && byAngle.direction.y == 1)

        // Normalisation, including negatives, and the opposite arrow.
        #expect(SlopeAzimuth(degrees: -90) == SlopeAzimuth(degrees: 270))
        #expect(SlopeAzimuth(degrees: 450) == SlopeAzimuth(degrees: 90))
        #expect(SlopeAzimuth(degrees: 90).opposite == SlopeAzimuth(degrees: 270))
        #expect(throws: SlopeError.azimuthFromCoincidentPoints) {
            _ = try SlopeAzimuth.between(PDFPoint(x: 1, y: 1), PDFPoint(x: 1, y: 1))
        }
    }

    @Test("Pitch text input accepts 6:12, 1:2, 26.57 deg, 50 % and rise over run")
    func pitchTextInput() throws {
        let half = Decimal(sign: .plus, exponent: -1, significand: 5)
        #expect(try SlopeExpression.parse("6:12").ratio() == half)
        #expect(try SlopeExpression.parse("1:2").ratio() == half)
        #expect(try SlopeExpression.parse("50%").ratio() == half)
        #expect(try SlopeExpression.parse("0.5").ratio() == half)
        #expect(try SlopeExpression.parse("rise 1.5 m over run 3 m").ratio() == half)
        #expect(try SlopeExpression.parse("6", pitchDefaultRun: 12).ratio() == half)
        #expect(SlopeExpression.pitch(6) == SlopeExpression.riseOverRun(rise: 6, run: 12))

        let degrees = try SlopeExpression.parse("26.57\u{00B0}")
        // tan(26.57 deg) = 0.500107971..., which is why a rounded degree entry is a display
        // form and not a storage form: 6:12 is exact, 26.57 deg is not.
        #expect(abs(NumericPolicy.double(from: try degrees.ratio()) - 0.5) < 2e-4)
        #expect(throws: SlopeError.self) { _ = try SlopeExpression.parse("not a slope") }
    }
}
