import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFMeasurementEngine

@Suite("Measurement engine behaviour")
struct EngineBehaviourTests {
    let engine = MeasurementEngine()

    // MARK: - Every tool is wired

    @Test("Every tool in spec 12.1 has a calculator")
    func everyToolHasCalculator() {
        for tool in MeasurementTool.allCases {
            _ = engine.calculator(for: tool)
        }
        #expect(MeasurementTool.allCases.count == 22)
    }

    // MARK: - Cutouts (spec 12.4)

    @Test("Overlapping cutouts are unioned before subtraction, never subtracted twice")
    func overlappingCutoutsAreUnioned() throws {
        // 10 x 10 outer. Two 4 x 4 holes overlapping on a 2 x 2 square.
        let geometry = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [
                [(1, 1), (5, 1), (5, 5), (1, 5)],
                [(3, 3), (7, 3), (7, 7), (3, 7)]
            ]
        )
        let result = try engine.calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale
        )
        // union area = 16 + 16 - 4 = 28, so net = 100 - 28 = 72.
        // Naive per-hole subtraction would give 100 - 32 = 68.
        // Integer coordinates sit exactly on the clipper lattice, so the stored Decimal is exact
        // and QUALITY_BAR M-A1 asks for equality, not a 1e-6 window (CR-34).
        #expect(try #require(result[.netArea]).value == 72)
        #expect(try #require(result[.cutoutArea]).value == 28)
    }

    @Test("Cutouts wound opposite ways still union — the overlap is subtracted exactly once (CR-20)")
    func oppositeWindingCutoutsStillUnion() throws {
        // The same two 4 × 4 holes as above, but the second is drawn CLOCKWISE. A non-zero
        // union of rings in as-drawn winding let the overlap cancel (+1 −1 = 0) and the
        // engine answered 76 — the overlap was never subtracted (code review CR-20).
        let geometry = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [
                [(1, 1), (5, 1), (5, 5), (1, 5)],
                [(3, 3), (3, 7), (7, 7), (7, 3)]
            ]
        )
        let result = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale)
        #expect(try #require(result[.netArea]).value == 72,
                "opposite winding must not cancel the overlap")
        #expect(try #require(result[.cutoutArea]).value == 28)

        // Three overlapping holes with the middle one clockwise: 16 + 16 + 16 − 4 − 4 = 40
        // if every overlap is subtracted once; the as-drawn union gave 72 net (holes 28).
        let three = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [
                [(1, 1), (5, 1), (5, 5), (1, 5)],
                [(3, 3), (3, 7), (7, 7), (7, 3)],
                [(5, 5), (9, 5), (9, 9), (5, 9)]
            ]
        )
        let threeResult = try engine.calculate(tool: .area, geometry: three, scale: Fixture.unitScale)
        #expect(try #require(threeResult[.netArea]).value == 60)
    }

    @Test("A cutout hanging over the parent edge only removes the part inside")
    func cutoutOutsideParent() throws {
        let geometry = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [[(8, 8), (14, 8), (14, 14), (8, 14)]]
        )
        let result = try engine.calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale
        )
        #expect(try #require(result[.netArea]).value == 96)
        #expect(result.hasWarning(.cutoutOutsideParent))
    }

    /// QUALITY_BAR 2.5: a cutout with no overlap is rejected. Old output: net area 100 with a
    /// `cutoutOutsideParent` warning — a correct-looking number for a drawing mistake, and the
    /// contract's `MeasurementError.cutoutOutsideParent` was thrown nowhere (CR-33, ADR-0015).
    @Test("A cutout entirely outside its parent is refused, naming the cutout")
    func cutoutFullyOutside() throws {
        let geometry = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [[(20, 20), (24, 20), (24, 24), (20, 24)]]
        )
        #expect(throws: MeasurementEngineError.measurement(.cutoutOutsideParent(cutoutIndex: 0))) {
            try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale)
        }
        // The index is the cutout as drawn, so a degenerate one before it does not shift it.
        let shifted = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [[(1, 1), (2, 2)], [(20, 20), (24, 20), (24, 24), (20, 24)]]
        )
        #expect(throws: MeasurementEngineError.measurement(.cutoutOutsideParent(cutoutIndex: 1))) {
            try engine.calculate(tool: .area, geometry: shifted, scale: Fixture.unitScale)
        }
        // Ignoring cutouts means the outside one is never looked at.
        let ignored = try engine.calculate(
            tool: .area, geometry: geometry, scale: Fixture.unitScale,
            parameters: MeasurementParameters(cutoutPolicy: .ignore)
        )
        #expect(try #require(ignored[.netArea]).value == 100)
        // The splitter and the perimeter tool refuse the same polygon the same way.
        #expect(throws: MeasurementEngineError.measurement(.cutoutOutsideParent(cutoutIndex: 0))) {
            try engine.calculate(tool: .perimeter, geometry: geometry, scale: Fixture.unitScale)
        }
    }

    @Test("Perimeter policy: outer only versus outer plus cutout edges")
    func perimeterPolicy() throws {
        let geometry = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [[(2, 2), (4, 2), (4, 4), (2, 4)]]
        )
        let outerOnly = try engine.calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(perimeterPolicy: .outerOnly)
        )
        let withHoles = try engine.calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(perimeterPolicy: .outerPlusCutoutEdges)
        )
        #expect(abs(Fixture.double(try #require(outerOnly[.perimeter]).value) - 40) < 1e-9)
        #expect(abs(Fixture.double(try #require(withHoles[.perimeter]).value) - 48) < 1e-9)
    }

    @Test("Cutout policy .ignore leaves the parent quantity alone")
    func ignoredCutouts() throws {
        let geometry = Fixture.polygon(
            [(0, 0), (10, 0), (10, 10), (0, 10)],
            holes: [[(2, 2), (4, 2), (4, 4), (2, 4)]]
        )
        let result = try engine.calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(cutoutPolicy: .ignore)
        )
        #expect(abs(Fixture.double(try #require(result[.netArea]).value) - 100) < 1e-9)
    }

    // MARK: - Self-intersection (spec 12.3)

    @Test("A bowtie is normalised through Clipper2 and warns")
    func bowtieNormalised() throws {
        // Two unit lobes; the shoelace of the crossed ring is 0, the real covered area is 2 x 1.
        let geometry = Fixture.polygon([(0, 0), (2, 2), (2, 0), (0, 2)])
        let result = try engine.calculate(
            tool: .area,
            geometry: geometry,
            scale: Fixture.unitScale
        )
        #expect(result.hasWarning(.selfIntersectingPolygon))
        #expect(result.hasWarning(.polygonNormalized))
        // The crossing is at (1, 1), on the clipper lattice: the normalised area is exactly 2.
        #expect(try #require(result[.planArea]).value == 2)
    }

    @Test("Strict options reject a self-intersecting ring instead of normalising it")
    func bowtieRejected() {
        let strict = MeasurementEngine(options: .strict)
        let geometry = Fixture.polygon([(0, 0), (2, 2), (2, 0), (0, 2)])
        #expect(throws: MeasurementEngineError.measurement(.selfIntersectingPolygon)) {
            try strict.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale)
        }
    }

    // MARK: - Slope (spec 12.8)

    @Test("run == 0 is a vertical result, never an infinity")
    func verticalSlope() throws {
        let result = try engine.calculate(
            tool: .slope,
            geometry: MeasurementGeometry(pageID: Fixture.pageID),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                slope: .uniformPlane(.riseOverRun(rise: 3, run: 0))
            )
        )
        #expect(result.hasWarning(.verticalSlopeUndefinedRun))
        #expect(result[.slopeRatio] == nil)
        #expect(result[.slopePercent] == nil)
        let angle = Fixture.double(try #require(result[.slopeAngle]).value)
        #expect(abs(angle - Double.pi / 2) < 1e-12)
        for quantity in result.values.values {
            #expect(Fixture.double(quantity.value).isFinite)
        }
    }

    @Test("True sloped length: 100 m plan at 1:2 gives 100 * sqrt(1.25)")
    func trueSlopedLength() throws {
        let result = try engine.calculate(
            tool: .trueSlopedLength,
            geometry: Fixture.polyline([(0, 0), (100, 0)]),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                slope: .uniformPlane(
                    .decimalRatio(Decimal(string: "0.5")!),
                    azimuth: SlopeAzimuth(degrees: 0)
                )
            )
        )
        let expected = 100 * (1.25 as Double).squareRoot()
        let value = Fixture.double(try #require(result[.trueLength]).value)
        // Closed form: QUALITY_BAR M-A1 is 1e-9 relative; the per-segment rule is exact here.
        #expect(abs(value - expected) / expected < 1e-12)
        #expect(Fixture.double(try #require(result[.slopePercent]).value) == 50)
    }

    @Test("Rise/drop per segment is longer than the same total applied once, unless proportional")
    func riseDropModes() throws {
        let geometry = Fixture.polyline([(0, 0), (30, 0), (60, 0)])
        let perSegment = try engine.calculate(
            tool: .riseDrop,
            geometry: geometry,
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                slope: .perSegment([4, 0])
            )
        )
        let total = try engine.calculate(
            tool: .riseDrop,
            geometry: geometry,
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .total(4))
        )
        // All 4 m of fall in the first segment: sqrt(900 + 16) + 30 = 60.2655...
        // The same fall spread over the whole run: sqrt(3600 + 16) = 60.1332...
        let perSegmentValue = Fixture.double(try #require(perSegment[.trueLength]).value)
        let totalValue = Fixture.double(try #require(total[.trueLength]).value)
        #expect(abs(perSegmentValue - ((916.0).squareRoot() + 30)) < 1e-9)
        #expect(abs(totalValue - (3616.0).squareRoot()) < 1e-9)
        #expect(perSegmentValue > totalValue)

        // Proportional fall is the equality case: the polyline is then a plane of constant slope.
        let proportional = try engine.calculate(
            tool: .riseDrop,
            geometry: geometry,
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                slope: .perSegment([2, 2])
            )
        )
        let proportionalValue = Fixture.double(try #require(proportional[.trueLength]).value)
        #expect(abs(proportionalValue - totalValue) < 1e-9)
    }

    @Test("A short rise/drop list is padded with zero and warns")
    func riseDropMismatch() throws {
        let result = try engine.calculate(
            tool: .riseDrop,
            geometry: Fixture.polyline([(0, 0), (30, 0), (60, 0)]),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                slope: .perSegment([2])
            )
        )
        #expect(result.hasWarning(.riseDropCountMismatch))
        let value = Fixture.double(try #require(result[.trueLength]).value)
        #expect(abs(value - ((904.0).squareRoot() + 30)) < 1e-9)
    }

    // MARK: - Ellipse

    /// Ramanujan's second approximation, kept here only as a cross-check of the quadrature the
    /// engine now uses (T-074): `C ≈ π(a + b)[1 + 3h / (10 + √(4 − 3h))]`, `h = ((a − b)/(a + b))²`.
    static func ramanujanCircumference(semiMajor a: Double, semiMinor b: Double) -> Double {
        let sum = a + b
        guard sum > 0 else { return 0 }
        let difference = a - b
        let h = (difference * difference) / (sum * sum)
        return Double.pi * sum * (1 + (3 * h) / (10 + (max(4 - 3 * h, 0)).squareRoot()))
    }

    @Test("Ramanujan II stays inside its measured error bound; the engine's quadrature is exact")
    func ramanujanBound() {
        // Degenerate limit b -> 0: true perimeter is 4a, the formula gives (14/11) pi a.
        let degenerate = Self.ramanujanCircumference(semiMajor: 1, semiMinor: 0)
        let relative = abs(degenerate - 4) / 4
        #expect(relative < 4.1e-4)
        #expect(relative > 4.0e-4)
        // A circle is exact.
        let circle = Self.ramanujanCircumference(semiMajor: 3, semiMinor: 3)
        #expect(abs(circle - 2 * Double.pi * 3) < 1e-12)
        // The engine's circumference is the quadrature: 4a exactly in the degenerate limit, 2πr
        // for a circle, and Ramanujan's measured shortfall at 2:1 (4.56e-10) and 10:1 (1.156e-5)
        // is the whole difference between the two.
        let unit = Fixture.unitScale
        #expect(abs(EllipseMath.circumference(pageSemiAxisX: 1, pageSemiAxisY: 0, scale: unit) - 4) < 1e-13)
        #expect(abs(EllipseMath.circumference(pageSemiAxisX: 3, pageSemiAxisY: 3, scale: unit) - 6 * Double.pi) < 1e-13)
        for (b, shortfall) in [(0.5, 4.5596e-10), (0.1, 1.15577e-5)] {
            let exact = EllipseMath.circumference(pageSemiAxisX: 1, pageSemiAxisY: b, scale: unit)
            let ramanujan = Self.ramanujanCircumference(semiMajor: 1, semiMinor: b)
            #expect(abs((exact - ramanujan) / exact - shortfall) < 1e-3 * shortfall, "b = \(b)")
        }
    }

    @Test("Ellipse under a separate-XY scale gets the right semi-axes")
    func ellipseSeparateXY() throws {
        // 20 x 10 page-space box, x scaled 2 m/pt and y scaled 3 m/pt: semi-axes 20 m and 15 m.
        let geometry = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: Fixture.points([(0, 0), (20, 10)])
        )
        let result = try engine.calculate(
            tool: .ellipseArea,
            geometry: geometry,
            scale: Fixture.separateXY(x: 2, y: 3)
        )
        let area = Fixture.double(try #require(result[.planArea]).value)
        #expect(abs(area - Double.pi * 20 * 15) / (Double.pi * 300) < 1e-9)
    }

    // MARK: - Volume and wall area

    @Test("volume = netArea * depth, in cubic metres")
    func volume() throws {
        let result = try engine.calculate(
            tool: .volume,
            geometry: Fixture.polygon(
                [(0, 0), (10, 0), (10, 10), (0, 10)],
                holes: [[(1, 1), (3, 1), (3, 3), (1, 3)]]
            ),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(depth: .length(Decimal(string: "0.25")!))
        )
        let volume = try #require(result[.volume])
        #expect(volume.dimension == .volume)
        #expect(volume.value == 24)
    }

    @Test("A depth in the wrong dimension is a typed error, not a coerced number")
    func depthDimensionMismatch() {
        #expect(throws: (any Error).self) {
            try engine.calculate(
                tool: .volume,
                geometry: Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)]),
                scale: Fixture.unitScale,
                parameters: MeasurementParameters(depth: .area(4))
            )
        }
    }

    @Test("netWallArea = perimeter * height - openings")
    func wallArea() throws {
        let result = try engine.calculate(
            tool: .wallArea,
            geometry: Fixture.polygon([(0, 0), (10, 0), (10, 6), (0, 6)]),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                height: .length(3),
                openingAreas: [2, Decimal(string: "1.6")!]
            )
        )
        // perimeter 32 m, height 3 m -> 96 m^2, minus 3.6 m^2 of openings.
        #expect(Fixture.double(try #require(result[.wallArea]).value) == 96)
        #expect(Fixture.double(try #require(result[.netWallArea]).value) == 92.4)
    }

    // MARK: - Circles and angles

    @Test("Three-point circle rejects collinear input with a typed error")
    func collinearRejected() {
        let geometry = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: Fixture.points([(0, 0), (5, 0), (10, 0)])
        )
        #expect(throws: MeasurementEngineError.measurement(.nearlyCollinearPoints)) {
            try engine.calculate(
                tool: .threePointCircle,
                geometry: geometry,
                scale: Fixture.unitScale
            )
        }
    }

    @Test("Angle is measured in real space, so a separate-XY scale changes it")
    func angleUnderSeparateXY() throws {
        let geometry = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: Fixture.points([(10, 0), (0, 0), (0, 10)])
        )
        let square = try engine.calculate(
            tool: .angle,
            geometry: geometry,
            scale: Fixture.unitScale
        )
        #expect(abs(Fixture.double(try #require(square[.angle]).value) - Double.pi / 2) < 1e-12)

        // A 45-degree page-space angle under a 2:1 scale is atan(2) in the real world.
        let diagonal = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: Fixture.points([(10, 0), (0, 0), (10, 10)])
        )
        let skewed = try engine.calculate(
            tool: .angle,
            geometry: diagonal,
            scale: Fixture.separateXY(x: 1, y: 2)
        )
        let expected = Foundation.atan(2.0)
        #expect(abs(Fixture.double(try #require(skewed[.angle]).value) - expected) < 1e-12)
    }

    @Test("Radius under a non-uniform scale is refused rather than guessed")
    func radiusNonUniform() {
        let geometry = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: Fixture.points([(0, 0), (5, 0)])
        )
        #expect(throws: (any Error).self) {
            try engine.calculate(
                tool: .radius,
                geometry: geometry,
                scale: Fixture.separateXY(x: 1, y: 2)
            )
        }
    }

    // MARK: - Warnings and determinism

    @Test("An extreme scale warns on every tool that uses it")
    func extremeScale() throws {
        let extreme = ScaleTransform(
            id: Fixture.scaleID,
            version: 1,
            matrix: AffineScaleMatrix(a: 100_000, b: 0, c: 0, d: 100_000),
            units: .metric,
            source: .preset
        )
        let result = try engine.calculate(
            tool: .length,
            geometry: Fixture.polyline([(0, 0), (1, 0)]),
            scale: extreme
        )
        #expect(result.hasWarning(.extremeScale))
    }

    @Test("A stale scale version warns when the engine knows the current one")
    func staleScaleVersion() throws {
        let engine = MeasurementEngine(
            options: MeasurementEngineOptions(expectedScaleVersion: 4)
        )
        let result = try engine.calculate(
            tool: .length,
            geometry: Fixture.polyline([(0, 0), (1, 0)]),
            scale: Fixture.unitScale
        )
        #expect(result.hasWarning(.staleScaleVersion))
    }

    @Test("Duplicate vertices are collapsed with a warning")
    func duplicateCollapse() throws {
        let result = try engine.calculate(
            tool: .area,
            geometry: Fixture.polygon([(0, 0), (0, 0), (10, 0), (10, 10), (0, 10)]),
            scale: Fixture.unitScale
        )
        #expect(result.hasWarning(.duplicatePointsCollapsed))
        #expect(Fixture.double(try #require(result[.planArea]).value) == 100)
    }

    @Test("A degenerate ring warns rather than returning a bare zero")
    func degenerateArea() throws {
        let result = try engine.calculate(
            tool: .area,
            geometry: Fixture.polygon([(0, 0), (10, 0), (5, 0)]),
            scale: Fixture.unitScale
        )
        #expect(result.hasWarning(.degenerateArea))
    }

    @Test("Every result carries the contract's formula version")
    func formulaVersion() throws {
        let result = try engine.calculate(
            tool: .length,
            geometry: Fixture.polyline([(0, 0), (3, 4)]),
            scale: Fixture.unitScale
        )
        #expect(result.formulaVersion == ContractVersion.measurementFormulaVersion)
        #expect(Fixture.double(try #require(result[.planLength]).value) == 5)
    }

    @Test("The same input gives byte-identical results, warnings included")
    func determinism() throws {
        let geometry = Fixture.polygon(
            [(0, 0), (12, 0), (12, 9), (0, 9)],
            holes: [[(1, 1), (4, 1), (4, 4), (1, 4)], [(3, 3), (6, 3), (6, 6), (3, 6)]]
        )
        let first = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale)
        let second = try engine.calculate(tool: .area, geometry: geometry, scale: Fixture.unitScale)
        #expect(first == second)
    }

    @Test("Every produced value's dimension matches its field")
    func dimensionsValidated() throws {
        let parameters = MeasurementParameters(
            depth: .length(2),
            height: .length(3),
            slope: .uniformPlane(.percent(25), azimuth: SlopeAzimuth(degrees: 90)),
            volumeDepthReference: .verticalDepth,
            openingAreas: [1]
        )
        let geometry = MeasurementGeometry(
            pageID: Fixture.pageID,
            points: Fixture.points([(0, 0), (10, 0), (10, 10)]),
            polygons: [PolygonGeometry(outer: Fixture.ring([(0, 0), (10, 0), (10, 10), (0, 10)]))],
            circles: [CircleGeometry(center: PDFPoint(x: 5, y: 5), radius: 2)],
            countPoints: []
        )
        // Every tool either measures this geometry or refuses it for a reason named here. A
        // `try? … continue` used to skip any tool that threw for *any* reason, so the sweep
        // proved nothing about the tools that mattered (CR-34).
        let refusals: [MeasurementTool: MeasurementEngineError] = [
            .dimension: .unsupportedGeometry(tool: .dimension, expected: .exactlyOneSegment),
            .riseDrop: .measurement(.missingParameter(.perSegmentRiseDrop))
        ]
        for tool in MeasurementTool.allCases {
            if let refusal = refusals[tool] {
                #expect(throws: refusal, "\(tool)") {
                    try engine.calculate(
                        tool: tool, geometry: geometry, scale: Fixture.unitScale, parameters: parameters
                    )
                }
                continue
            }
            do {
                let result = try engine.calculate(
                    tool: tool, geometry: geometry, scale: Fixture.unitScale, parameters: parameters
                )
                try result.validateDimensions()
                #expect(!result.values.isEmpty, "\(tool) produced no value")
                for (field, quantity) in result.values {
                    #expect(quantity.isFinite, "\(tool).\(field.rawValue) is not finite")
                }
            } catch {
                Issue.record("\(tool) refused this geometry: \(error)")
            }
        }
    }

    // MARK: - Code review 2026-08-31 regressions

    /// Under `outerPlusCutoutEdges` the old code summed the outer ring and every hole's FULL
    /// boundary from the un-unioned hole list. Old outputs on a 10 x 10 parent: two overlapping
    /// 4 x 4 holes 40 + 16 + 16 = 72 (the net region's boundary is 40 + 24 = 64); a 2 x 2 hole
    /// flush on the bottom edge 40 + 8 = 48 (true 44: the shared edge is not there twice); a
    /// hole hanging over a corner 40 + 24 = 64 (true 40) (CR-21).
    @Test("Cutout-edge perimeter is the boundary of the net region (CR-21)")
    func cutoutEdgePerimeterIsNetBoundary() throws {
        func perimeter(_ holes: [[(Double, Double)]], _ policy: PerimeterPolicy) throws -> Decimal {
            let result = try engine.calculate(
                tool: .area,
                geometry: Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)], holes: holes),
                scale: Fixture.unitScale,
                parameters: MeasurementParameters(perimeterPolicy: policy)
            )
            return try #require(result[.perimeter]).value
        }
        let overlapping = [[(1.0, 1.0), (5, 1), (5, 5), (1, 5)], [(3.0, 3.0), (7, 3), (7, 7), (3, 7)]]
        let flush = [[(4.0, 0.0), (6, 0), (6, 2), (4, 2)]]
        let overhanging = [[(8.0, 8.0), (14, 8), (14, 14), (8, 14)]]
        let interior = [[(2.0, 2.0), (4, 2), (4, 4), (2, 4)]]
        #expect(try perimeter(overlapping, .outerPlusCutoutEdges) == 64)
        #expect(try perimeter(flush, .outerPlusCutoutEdges) == 44)
        #expect(try perimeter(overhanging, .outerPlusCutoutEdges) == 40)
        #expect(try perimeter(interior, .outerPlusCutoutEdges) == 48)
        // P12: outerOnly is the drawn boundary and no cutout changes it.
        for holes in [overlapping, flush, overhanging, interior] {
            #expect(try perimeter(holes, .outerOnly) == 40)
        }
    }

    /// Old output: `rise 6 m, run 12 m` for a 6:12 pitch — a `riseOverRun` pair is "in the
    /// same length unit" and that unit is unknown, so it must not be written as metres (CR-22).
    @Test("A pitch's rise and run are not stored as metres (CR-22)")
    func pitchIsNotMetres() throws {
        let pitch = try engine.calculate(
            tool: .slope,
            geometry: MeasurementGeometry(pageID: Fixture.pageID),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .uniformPlane(.pitch(6)))
        )
        #expect(pitch[.rise] == nil)
        #expect(pitch[.run] == nil)
        #expect(try #require(pitch[.slopeRatio]).value == Decimal(string: "0.5"))
        #expect(try #require(pitch[.slopeRatio]).dimension == .ratio)
        #expect(try #require(pitch[.slopePercent]).value == 50)
        // Rise and run in metres come from a rise/drop measurement, where they are metres.
        let riseDrop = try engine.calculate(
            tool: .riseDrop,
            geometry: Fixture.polyline([(0, 0), (30, 0)]),
            scale: Fixture.unitScale,
            parameters: MeasurementParameters(slope: .total(4))
        )
        #expect(try #require(riseDrop[.rise]).value == 4)
        #expect(try #require(riseDrop[.run]).value == 30)
    }

    /// Significant decimal digits of a stored value, from its canonical description.
    private static func significantDigits(_ value: Decimal) -> Int {
        "\(value)".filter(\.isNumber).drop { $0 == "0" }.count
    }

    /// 283.465 pt = 5 m: the calibrated factor is a 38-digit Decimal quotient. Old outputs: a
    /// true area carrying 30 significant digits, volumes and wall areas 16-17 — values the
    /// ledger's exact-or-refuse addition refuses where the net areas of the same rows add
    /// (CR-23).
    @Test("True area, volume and wall area are normalised to the policy significance (CR-23)")
    func derivedProductsAreNormalised() throws {
        let scale = try ScaleTransform.calibratedTwoPoint(
            id: Fixture.scaleID,
            first: .zero,
            second: PDFPoint(x: 283.465, y: 0),
            knownLength: 5,
            knownLengthUnit: .metre,
            units: .metric
        )
        let square = Fixture.polygon([(0, 0), (100, 0), (100, 100), (0, 100)])
        let half = Decimal(string: "0.5")!
        let depth = DecimalQuantity.length(Decimal(string: "0.37")!)
        let trueArea = try #require(try engine.calculate(
            tool: .trueSlopedArea, geometry: square, scale: scale,
            parameters: MeasurementParameters(slope: .uniformPlane(.decimalRatio(half)))
        )[.trueArea]).value
        let volume = try #require(try engine.calculate(
            tool: .volume, geometry: square, scale: scale,
            parameters: MeasurementParameters(depth: depth)
        )[.volume]).value
        let perpendicular = try #require(try engine.calculate(
            tool: .volume, geometry: square, scale: scale,
            parameters: MeasurementParameters(
                depth: depth,
                slope: .uniformPlane(.decimalRatio(half)),
                volumeDepthReference: .perpendicularThickness
            )
        )[.volume]).value
        let wall = try engine.calculate(
            tool: .wallArea, geometry: square, scale: scale,
            parameters: MeasurementParameters(
                height: .length(Decimal(string: "2.7")!),
                openingAreas: [Decimal(string: "0.13")!]
            )
        )
        let stored: [(String, Decimal)] = [
            ("trueArea", trueArea),
            ("volume", volume),
            ("perpendicular volume", perpendicular),
            ("planWallArea", try #require(wall[.planWallArea]).value),
            ("wallArea", try #require(wall[.wallArea]).value),
            ("netWallArea", try #require(wall[.netWallArea]).value)
        ]
        for (name, value) in stored {
            #expect(Self.significantDigits(value) <= NumericPolicy.defaultSignificantDigits,
                    "\(name) = \(value) carries more digits than the policy allows")
            #expect(try EngineNumerics.normalised(value) == value, "\(name) is not at policy significance")
        }
        // The values are still right to the policy's precision.
        let factor = 5.0 / 283.465
        let expectedTrueArea = 10_000 * factor * factor * (1.25).squareRoot()
        #expect(abs(Fixture.double(trueArea) - expectedTrueArea) / expectedTrueArea < 1e-12)
        let expectedVolume = 10_000 * factor * factor * 0.37
        #expect(abs(Fixture.double(volume) - expectedVolume) / expectedVolume < 1e-12)
        #expect(abs(Fixture.double(perpendicular) - expectedVolume * (1.25).squareRoot()) / expectedVolume < 1e-12)
    }

    /// Old output: `volume = planArea x thickness` with a `riseDropCountMismatch` warning —
    /// 11.8 % short on a 6:12 roof, flagged for something else (CR-25).
    @Test("A perpendicular thickness needs a uniform plane; rise/drop markups are refused (CR-25)")
    func perpendicularThicknessNeedsAPlane() throws {
        let square = Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        let depth = DecimalQuantity.length(Decimal(string: "0.2")!)
        for slope in [SlopeSpecification.total(4), .perSegment([1, 1, 1, 1])] {
            #expect(throws: MeasurementEngineError.measurement(.missingParameter(.riseRun))) {
                try engine.calculate(
                    tool: .volume, geometry: square, scale: Fixture.unitScale,
                    parameters: MeasurementParameters(
                        depth: depth, slope: slope, volumeDepthReference: .perpendicularThickness
                    )
                )
            }
            // A vertical depth on the same markup is the plan volume, with no misleading warning
            // and no true area.
            let vertical = try engine.calculate(
                tool: .volume, geometry: square, scale: Fixture.unitScale,
                parameters: MeasurementParameters(
                    depth: depth, slope: slope, volumeDepthReference: .verticalDepth
                )
            )
            #expect(try #require(vertical[.volume]).value == 20)
            #expect(vertical[.trueArea] == nil)
            #expect(!vertical.hasWarning(.riseDropCountMismatch))
        }
        // On a uniform plane the perpendicular volume is the true area times the thickness.
        let plane = try engine.calculate(
            tool: .volume, geometry: square, scale: Fixture.unitScale,
            parameters: MeasurementParameters(
                depth: depth,
                slope: .uniformPlane(.decimalRatio(Decimal(string: "0.75")!)),
                volumeDepthReference: .perpendicularThickness
            )
        )
        #expect(try #require(plane[.trueArea]).value == 125)
        #expect(try #require(plane[.volume]).value == 25)
    }

    /// `acos(clamp(dot / |u||v|))` loses half its digits at 0 and pi: the cosine of a 1e-9 rad
    /// corner rounds to exactly 1.0, so the old output was 0; near pi it was pi. The contract
    /// says `atan2(|cross|, dot)` (spec 12.10, CR-26).
    @Test("Angle is conditioned at 0 and pi (CR-26)")
    func angleConditioning() throws {
        let acute = try engine.calculate(
            tool: .angle,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(1e6, 0), (0, 0), (1e6, 1e-3)])),
            scale: Fixture.unitScale
        )
        let acuteAngle = Fixture.double(try #require(acute[.angle]).value)
        #expect(acuteAngle > 0)
        #expect(abs(acuteAngle - Foundation.atan(1e-9)) < 1e-21)

        let obtuse = try engine.calculate(
            tool: .angle,
            geometry: MeasurementGeometry(pageID: Fixture.pageID, points: Fixture.points([(1e6, 0), (0, 0), (-1e6, 1e-3)])),
            scale: Fixture.unitScale
        )
        let obtuseAngle = Fixture.double(try #require(obtuse[.angle]).value)
        #expect(obtuseAngle < Double.pi)
        #expect(abs(obtuseAngle - (Double.pi - 1e-9)) < 1e-12)
    }

    /// Old output: `netWallArea = -60 m²` stored as a value for 40 m² of wall with 100 m² of
    /// openings. QUALITY_BAR P11: a negative net area is a typed error (CR-27).
    @Test("Openings larger than the wall are a typed error, never a negative area (CR-27)")
    func negativeNetWallAreaIsRefused() throws {
        let square = Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
        #expect(throws: MeasurementEngineError.measurement(.negativeNetArea(.netWallArea))) {
            try engine.calculate(
                tool: .wallArea, geometry: square, scale: Fixture.unitScale,
                parameters: MeasurementParameters(height: .length(1), openingAreas: [100])
            )
        }
        // Openings that exactly consume the wall are a legitimate, flagged zero.
        let consumed = try engine.calculate(
            tool: .wallArea, geometry: square, scale: Fixture.unitScale,
            parameters: MeasurementParameters(height: .length(1), openingAreas: [30, 10])
        )
        #expect(try #require(consumed[.netWallArea]).value == 0)
        #expect(consumed.hasWarning(.degenerateArea))
    }

    /// Old outputs: radius -1 m, diameter -2 m, an arc length of -5 m (CR-28).
    @Test("A negative radius is refused on every tool (CR-28)")
    func negativeRadiusIsRefused() throws {
        let circle = MeasurementGeometry(
            pageID: Fixture.pageID,
            circles: [CircleGeometry(center: .zero, radius: -1)]
        )
        for tool in [MeasurementTool.radius, .diameter, .ellipseArea, .temporaryMeasure] {
            #expect(throws: MeasurementEngineError.unsupportedGeometry(tool: tool, expected: .positiveRadius)) {
                try engine.calculate(tool: tool, geometry: circle, scale: Fixture.unitScale)
            }
        }
        let arc = MeasurementGeometry(
            pageID: Fixture.pageID,
            arcs: [ArcGeometry(center: .zero, radius: -5, startAngle: 0, sweepAngle: 1)]
        )
        #expect(throws: MeasurementEngineError.unsupportedGeometry(tool: .arcLength, expected: .positiveRadius)) {
            try engine.calculate(tool: .arcLength, geometry: arc, scale: Fixture.unitScale)
        }
        // A positive radius on the same arc measures 5 m.
        let positive = MeasurementGeometry(
            pageID: Fixture.pageID,
            arcs: [ArcGeometry(center: .zero, radius: 5, startAngle: 0, sweepAngle: 1)]
        )
        let measured = try engine.calculate(tool: .arcLength, geometry: positive, scale: Fixture.unitScale)
        #expect(try #require(measured[.arcLength]).value == 5)
    }

    /// Old output: `count 0` with no warning for polygon-only geometry (CR-30).
    @Test("The count tool refuses geometry that counts nothing (CR-30)")
    func countRefusesPolygonOnlyGeometry() throws {
        #expect(throws: MeasurementEngineError.unsupportedGeometry(tool: .count, expected: .countPoints)) {
            try engine.calculate(
                tool: .count,
                geometry: Fixture.polygon([(0, 0), (10, 0), (10, 10), (0, 10)]),
                scale: Fixture.unitScale
            )
        }
        let counted = try engine.calculate(
            tool: .count,
            geometry: Fixture.polyline([(0, 0), (1, 1), (2, 2)]),
            scale: Fixture.unitScale
        )
        #expect(try #require(counted[.count]).value == 3)
        #expect(try #require(counted[.count]).dimension == .count)
    }

    /// Old output: `planArea 100 + 4 pi`, `netArea 96` — the circle was added to one and not the
    /// other (CR-31).
    @Test("Temporary measure adds circle areas to the net area as well as the plan area (CR-31)")
    func temporaryMeasureCircleNetArea() throws {
        let mixed = MeasurementGeometry(
            pageID: Fixture.pageID,
            polygons: [PolygonGeometry(
                outer: Fixture.ring([(0, 0), (10, 0), (10, 10), (0, 10)]),
                holes: [Fixture.ring([(2, 2), (4, 2), (4, 4), (2, 4)])]
            )],
            circles: [CircleGeometry(center: PDFPoint(x: 20, y: 20), radius: 2)]
        )
        let result = try engine.calculate(tool: .temporaryMeasure, geometry: mixed, scale: Fixture.unitScale)
        let circleArea = Double.pi * 4
        #expect(abs(Fixture.double(try #require(result[.planArea]).value) - (100 + circleArea)) < 1e-9)
        #expect(abs(Fixture.double(try #require(result[.netArea]).value) - (96 + circleArea)) < 1e-9)

        let circleOnly = MeasurementGeometry(
            pageID: Fixture.pageID,
            circles: [CircleGeometry(center: PDFPoint(x: 20, y: 20), radius: 2)]
        )
        let alone = try engine.calculate(tool: .temporaryMeasure, geometry: circleOnly, scale: Fixture.unitScale)
        #expect(try #require(alone[.planArea]).value == (try #require(alone[.netArea]).value))
        #expect(abs(Fixture.double(try #require(alone[.netArea]).value) - circleArea) < 1e-9)
    }

    /// Old output for [+2, -2] over 60 m: rise 0 and slope 0 %, for a run whose true length is
    /// 2 sqrt(904) (CR-32). The rise is the gross vertical travel with the net sign, so a
    /// monotone run agrees with the total mode exactly.
    @Test("Per-segment rise is the gross vertical travel with the net sign (CR-32)")
    func perSegmentRiseIsGrossTravel() throws {
        let geometry = Fixture.polyline([(0, 0), (30, 0), (60, 0)])
        func riseDrop(_ slope: SlopeSpecification) throws -> MeasurementResult {
            try engine.calculate(
                tool: .riseDrop, geometry: geometry, scale: Fixture.unitScale,
                parameters: MeasurementParameters(slope: slope)
            )
        }
        let upDown = try riseDrop(.perSegment([2, -2]))
        #expect(try #require(upDown[.rise]).value == 4)
        #expect(try #require(upDown[.slopeRatio]).value == Decimal(string: "0.0666666666666667"))
        #expect(abs(Fixture.double(try #require(upDown[.trueLength]).value) - 2 * (904.0).squareRoot()) < 1e-9)

        let down = try riseDrop(.perSegment([-2, -2]))
        let total = try riseDrop(.total(-4))
        #expect(try #require(down[.rise]).value == -4)
        #expect(try #require(total[.rise]).value == -4)
        #expect(down[.slopeRatio] == total[.slopeRatio])
        #expect(try #require(down[.slopeRatio]).value < 0)
    }
}
