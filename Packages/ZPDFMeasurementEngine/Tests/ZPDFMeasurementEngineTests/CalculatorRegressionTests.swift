import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

/// Regression suite for the bug-hunt-2 findings on the calculators.
///
/// Every expected number is derived by hand in the comment beside it, never read from the code
/// under test (QUALITY_BAR §2.6). Each test states the output the old code produced.
@Suite("Calculator regressions (bug hunt 2)")
struct CalculatorRegressionTests {
    let engine = MeasurementEngine()

    static let square = Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)])

    // MARK: - BH-023 ellipse cutout

    /// Old output: the ellipse cutout row carried `netArea = 25 pi` (and, when sloped,
    /// `trueArea = 25 pi * sqrt(1 + s^2)`), so the `Area` formula variable and the True Area
    /// column added the cutout back into the subject total. A polygon cutout never wrote either.
    @Test("BH-023: an ellipse cutout reports what it removes, never a net or true area")
    func ellipseCutoutWritesNoNetArea() throws {
        let geometry = Fixture.polyline([(-5, -5), (5, 5)])
        let flat = try engine.calculate(tool: .ellipseCutout, geometry: geometry, scale: Fixture.unitScale)
        // pi a b = pi * 5 * 5 = 78.53981633974483
        let expected = Double.pi * 25
        #expect(abs(Fixture.double(try #require(flat[.planArea]).value) - expected) / expected < 1e-12)
        #expect(abs(Fixture.double(try #require(flat[.cutoutArea]).value) - expected) / expected < 1e-12)
        #expect(flat[.netArea] == nil, "an ellipse cutout must not carry a net area")

        let sloped = try engine.calculate(
            tool: .ellipseCutout, geometry: geometry, scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .uniformPlane(.decimalRatio(Decimal(string: "0.75")!)))
        )
        #expect(sloped[.netArea] == nil)
        #expect(sloped[.trueArea] == nil, "a cutout has no true area of its own; the parent owns the slope")
        #expect(sloped[.slopeRatio] == nil)

        // The polygon cutout is the reference behaviour: the same field set, minus the ellipse-only
        // circumference and radius fields.
        let polygon = try engine.calculate(tool: .polygonCutout, geometry: Self.square, scale: Fixture.unitScale)
        #expect(Set(polygon.values.keys) == [.planArea, .cutoutArea, .perimeter])
        #expect(Set(flat.values.keys) == [.planArea, .cutoutArea, .perimeter, .circumference, .radius, .diameter])
    }

    // MARK: - BH-163 negative depth

    /// Old output: `volume = -20 m^3` for a 100 m^2 slab and a depth of -0.2 m, summed exactly
    /// into the subject and grand totals. QUALITY_BAR P11: a negative net quantity is a typed
    /// error, never a value. The refusal is `MeasurementParameters.validate()`'s
    /// `negativeParameter` (contract fix BH-018); the engine adds the zero-depth flag.
    @Test("BH-163: a negative depth is refused; a zero depth is flagged")
    func negativeDepthIsRefused() throws {
        #expect(throws: MeasurementEngineError.measurement(.negativeParameter(.depth))) {
            try engine.calculate(
                tool: .volume, geometry: Self.square, scale: Fixture.unitScale,
                parameters: MeasurementParameters(depth: .length(Decimal(string: "-0.2")!))
            )
        }
        // 100 m^2 * 0 m = 0 m^3, a legitimate zero that is flagged rather than refused.
        let zero = try engine.calculate(
            tool: .volume, geometry: Self.square, scale: Fixture.unitScale,
            parameters: MeasurementParameters(depth: .length(0))
        )
        #expect(try #require(zero[.volume]).value == 0)
        #expect(zero.hasWarning(.degenerateArea))
        // The positive case is unchanged: 100 * 0.2 = 20.
        let positive = try engine.calculate(
            tool: .volume, geometry: Self.square, scale: Fixture.unitScale,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.2")!))
        )
        #expect(try #require(positive[.volume]).value == 20)
        // The same rule for a wall height: 10 m run * -3 m used to be a -30 m^2 wall.
        #expect(throws: MeasurementEngineError.measurement(.negativeParameter(.height))) {
            try engine.calculate(
                tool: .wallArea, geometry: Fixture.polyline([(0, 0), (10, 0)]), scale: Fixture.unitScale,
                parameters: MeasurementParameters(height: .length(-3))
            )
        }
    }

    // MARK: - BH-164 slope tool

    /// The engine side of BH-164: once the app supplies a magnitude and the fall line of the
    /// drawn run, the Slope tool commits. Two points 10 m apart on a 1:2 plane whose fall line
    /// is the run itself: ratio 0.5; percent 50. Since ADR-0019 the run writes no length.
    @Test("BH-164: the Slope tool commits with a magnitude and the run's own fall line")
    func slopeToolCommitsWithMagnitudeAndAzimuth() throws {
        let start = PDFPoint(x: 0, y: 0)
        let end = PDFPoint(x: 10, y: 0)
        let result = try engine.calculate(
            tool: .slope,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, points: [start, end]),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                slope: try .uniformPlane(.ratioOneToN(2), fallLineFrom: start, to: end)
            )
        )
        // ADR-0019 (formula version 4): the drawn run is where the slope is read, not a
        // quantity. Old output: `planLength 10`, `trueLength 11.18033988749895` — both summed.
        #expect(result[.planLength] == nil)
        #expect(result[.trueLength] == nil)
        #expect(try #require(result[.slopeRatio]).value == Decimal(string: "0.5")!)
        #expect(try #require(result[.slopePercent]).value == 50)
        // Without the magnitude the refusal is typed, and it names the missing parameter.
        #expect(throws: MeasurementEngineError.measurement(.missingParameter(.riseRun))) {
            try engine.calculate(
                tool: .slope,
                geometry: MeasurementGeometry(pageID: Fixture.pageID, points: [start, end]),
                scale: Fixture.unitScale
            )
        }
    }

    // MARK: - BH-558 vertical plane, perpendicular thickness

    /// Old output: `volume = 100 * 0.2 = 20 m^3`, the plan-area volume, for a surface whose true
    /// area does not exist — with a warning about the slope being vertical, not about the
    /// fallback (contrast CR-25, which refuses the rise/drop modes for the same reason).
    @Test("BH-558: a perpendicular thickness on a vertical plane is refused, not laid over the plan area")
    func perpendicularThicknessOnVerticalPlaneIsRefused() throws {
        let parameters = MeasurementParameters(
            depth: .length(Decimal(string: "0.2")!),
            slope: .uniformPlane(.riseOverRun(rise: 1, run: 0)),
            volumeDepthReference: .perpendicularThickness
        )
        #expect(throws: MeasurementEngineError.measurement(.unsupportedField(.trueArea))) {
            try engine.calculate(tool: .volume, geometry: Self.square, scale: Fixture.unitScale, parameters: parameters)
        }
        // A plumb depth on the same markup is still the plan volume: 100 * 0.2 = 20.
        var plumb = parameters
        plumb.volumeDepthReference = .verticalDepth
        let result = try engine.calculate(tool: .volume, geometry: Self.square, scale: Fixture.unitScale, parameters: plumb)
        #expect(try #require(result[.volume]).value == 20)
        #expect(result.hasWarning(.verticalSlopeUndefinedRun))
    }

    // MARK: - BH-559 wall area under rise/drop

    /// Old output: `wallArea = planWallArea = 30 m^2`, no `trueLength`, no rise/run fields — the
    /// slope parameter was accepted and discarded.
    @Test("BH-559: a wall on a rise/drop run uses the true base length")
    func wallAreaAppliesRiseDrop() throws {
        // Total mode: 10 m run with a 2 m total drop, 3 m high.
        // trueBase = sqrt(10^2 + 2^2) = sqrt(104) = 10.198039027185569 m
        // wallArea = 3 * 10.198039027185569 = 30.594117081556707 m^2; planWallArea = 30 m^2.
        let total = try engine.calculate(
            tool: .wallArea, geometry: Fixture.polyline([(0, 0), (10, 0)]), scale: Fixture.unitScale,
            parameters: MeasurementParameters(height: .length(3), slope: .total(2))
        )
        let trueLength = Fixture.double(try #require(total[.trueLength]).value)
        #expect(abs(trueLength - 10.198039027185569) < 1e-12)
        let wall = Fixture.double(try #require(total[.wallArea]).value)
        #expect(abs(wall - 30.594117081556707) / 30.594117081556707 < 1e-13)
        #expect(try #require(total[.planWallArea]).value == 30)
        #expect(try #require(total[.rise]).value == 2)
        #expect(try #require(total[.run]).value == 10)

        // Per-segment mode on a 3-4 polyline with rises 4 and 3: two 3-4-5 triangles.
        // trueBase = 5 + 5 = 10 m exactly; wallArea = 10 * 3 = 30; planWallArea = 7 * 3 = 21.
        let perSegment = try engine.calculate(
            tool: .wallArea, geometry: Fixture.polyline([(0, 0), (3, 0), (3, 4)]), scale: Fixture.unitScale,
            parameters: MeasurementParameters(height: .length(3), slope: .perSegment([4, 3]))
        )
        #expect(try #require(perSegment[.trueLength]).value == 10)
        #expect(try #require(perSegment[.wallArea]).value == 30)
        #expect(try #require(perSegment[.planWallArea]).value == 21)

        // A closed ring has no single run for a rise/drop to follow: a typed refusal, never a
        // wall that silently ignores its slope.
        #expect(throws: MeasurementEngineError.measurement(.missingParameter(.riseRun))) {
            try engine.calculate(
                tool: .wallArea, geometry: Self.square, scale: Fixture.unitScale,
                parameters: MeasurementParameters(height: .length(3), slope: .total(2))
            )
        }
    }

    // MARK: - BH-560 / BH-566 arcs under per-segment rise/drop

    /// A 10 m straight edge plus a 5 m arc (radius 5 pt, sweep 1 rad, at 1 m/pt).
    static let edgeAndArc = MeasurementGeometry(
        pageID: Fixture.pageID,
        points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)],
        arcs: [ArcGeometry(center: PDFPoint(x: 20, y: 0), radius: 5, startAngle: 0, sweepAngle: 1)]
    )

    /// Old output: `trueLength = sqrt(101) = 10.04987562112089 m` and `run = 10 m` — both
    /// *shorter* than the 15 m plan length, because the arc was dropped from the per-segment
    /// list; the total mode on the same drawing included it.
    @Test("BH-560/BH-566: per-segment rise/drop includes arcs, so the true length is never below the plan")
    func perSegmentRiseDropIncludesArcs() throws {
        // planLength = 10 + 5 = 15. Rise 1 on the edge, 0 on the arc:
        // trueLength = sqrt(10^2 + 1^2) + 5 = 10.04987562112089 + 5 = 15.04987562112089; run = 15.
        let perSegment = try engine.calculate(
            tool: .riseDrop, geometry: Self.edgeAndArc, scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .perSegment([1, 0]))
        )
        #expect(try #require(perSegment[.planLength]).value == 15)
        let trueLength = Fixture.double(try #require(perSegment[.trueLength]).value)
        #expect(abs(trueLength - 15.04987562112089) < 1e-12)
        #expect(try #require(perSegment[.run]).value == 15)
        #expect(try #require(perSegment[.rise]).value == 1)
        #expect(!perSegment.hasWarning(.riseDropCountMismatch), "two rises for two pieces is a match")

        // The total mode agrees on what the plan length is: sqrt(15^2 + 1^2) = 15.033296378372908.
        let total = try engine.calculate(
            tool: .riseDrop, geometry: Self.edgeAndArc, scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .total(1))
        )
        #expect(abs(Fixture.double(try #require(total[.trueLength]).value) - 15.033296378372908) < 1e-12)

        // An arc-only run with one rise: run 5, trueLength sqrt(26) = 5.0990195135927845.
        // Old output: run 0, trueLength 0 and a verticalSlopeUndefinedRun warning.
        let arcOnly = try engine.calculate(
            tool: .riseDrop,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, arcs: Self.edgeAndArc.arcs),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .perSegment([1]))
        )
        #expect(try #require(arcOnly[.run]).value == 5)
        #expect(abs(Fixture.double(try #require(arcOnly[.trueLength]).value) - 5.0990195135927845) < 1e-12)
        #expect(!arcOnly.hasWarning(.verticalSlopeUndefinedRun))
    }

    // MARK: - IM-066 one writer for the area tools

    /// Old output: under `.subtractAndReportSeparately` with no holes, Area wrote `cutoutArea = 0`
    /// and Rectangle Area wrote nothing — two ledgers for one square.
    @Test("IM-066: Area and Rectangle Area write identical fields for the same square")
    func areaAndRectangleAreaAgree() throws {
        for policy in CutoutPolicy.allCases {
            let parameters = MeasurementParameters(cutoutPolicy: policy)
            let area = try engine.calculate(tool: .area, geometry: Self.square, scale: Fixture.unitScale, parameters: parameters)
            let rectangle = try engine.calculate(
                tool: .rectangleArea, geometry: Fixture.polyline([(0, 0), (10, 10)]),
                scale: Fixture.unitScale, parameters: parameters
            )
            #expect(area.values == rectangle.values, "policy \(policy.rawValue): \(area.values.keys.map(\.rawValue).sorted()) vs \(rectangle.values.keys.map(\.rawValue).sorted())")
            // 10 x 10 = 100 m^2, perimeter 40 m, and under the reporting policy a cutout area of 0.
            #expect(try #require(rectangle[.planArea]).value == 100)
            #expect(try #require(rectangle[.perimeter]).value == 40)
            if policy == .subtractAndReportSeparately {
                #expect(try #require(rectangle[.cutoutArea]).value == 0)
            }
        }
    }

    // MARK: - BH-024 polylength segment count

    /// Old output: a two-leg polyline wrote `count = 2` into `.count` ("number of count
    /// points"), and the ledger's Count column sums that field over every row, so one 7-segment
    /// run added 7 phantom pieces to a page's Count total.
    @Test("BH-024: a polylength reports its length and never a count")
    func polylengthWritesNoCount() throws {
        // 30 pt + 40 pt at 1 m/pt = 70 m.
        let result = try engine.calculate(
            tool: .polylength,
            geometry: Fixture.polyline([(0, 0), (30, 0), (30, 40)]),
            scale: Fixture.unitScale
        )
        #expect(try #require(result[.planLength]).value == 70)
        #expect(result[.count] == nil, "a segment count is not a count of pieces")
        #expect(Set(result.values.keys) == [.planLength])

        // The ledger-level consequence: 3 count points plus one 7-segment run is 3 pieces, not 10.
        let counted = try engine.calculate(
            tool: .count,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(1, 1), (2, 2), (3, 3)])),
            scale: Fixture.unitScale
        )
        let run = try engine.calculate(
            tool: .polylength,
            geometry: Fixture.polyline([(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (5, 0), (6, 0), (7, 0)]),
            scale: Fixture.unitScale
        )
        let countTotal = [counted, run].compactMap { $0[.count]?.value }.reduce(Decimal(0), +)
        #expect(countTotal == 3)
    }
}
