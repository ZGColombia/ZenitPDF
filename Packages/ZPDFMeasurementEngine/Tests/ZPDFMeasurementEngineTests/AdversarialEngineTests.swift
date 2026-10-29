import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry

@testable import ZPDFMeasurementEngine

/// The cutout and circle cases a takeoff actually hits, pinned against exact expected areas.
///
/// The interesting ones are the boundary-contact cases: a cutout whose edge lies exactly on the
/// parent's edge, two cutouts that share an edge, and two that overlap. All three are places
/// where a scalar `outerArea - sum(holeAreas)` gives the wrong answer, and where an
/// almost-correct clipper tolerance shows up as a square metre or two of error.
@Suite("Adversarial measurement engine")
struct AdversarialEngineTests {

    private static let pageID = PageID(UUID(uuidString: "00000000-0000-0000-0000-00000000A6E1")!)
    private static let scaleID = ScaleID(UUID(uuidString: "00000000-0000-0000-0000-00000005CA1E")!)

    private static func unitScale() throws -> ScaleTransform {
        try ScaleTransform.uniform(
            id: scaleID, metresPerPoint: 1, units: .metric, source: .preset
        )
    }

    private static func ring(_ points: [(Double, Double)]) -> PolygonRing {
        PolygonRing(points: points.map { PDFPoint(x: $0.0, y: $0.1) })
    }

    /// A 10x10 parent with a 2x2 cutout, placed six ways. The net area is the same 96 wherever
    /// the cutout sits inside the parent — including flush into a corner and sitting exactly on
    /// an edge, where the boolean has coincident vertices and collinear edges to resolve.
    @Test("A cutout touching the parent edge exactly removes exactly its own area")
    func cutoutsTouchingTheParentEdge() throws {
        let parent = Self.ring([(0, 0), (10, 0), (10, 10), (0, 10)])
        let engine = MeasurementEngine()
        let scale = try Self.unitScale()

        let cases: [(String, [PolygonRing], Decimal, Decimal, Bool)] = [
            ("corner flush",
             [Self.ring([(0, 0), (2, 0), (2, 2), (0, 2)])], 96, 4, false),
            ("flush on the bottom edge",
             [Self.ring([(4, 0), (6, 0), (6, 2), (4, 2)])], 96, 4, false),
            ("flush on the right edge",
             [Self.ring([(8, 4), (10, 4), (10, 6), (8, 6)])], 96, 4, false),
            ("wholly interior",
             [Self.ring([(4, 4), (6, 4), (6, 6), (4, 6)])], 96, 4, false),
            ("overhanging the corner: only the inside quarter counts",
             [Self.ring([(9, 9), (12, 9), (12, 12), (9, 12)])], 99, 1, true)
        ]

        for (name, holes, expectedNet, expectedCutout, expectWarning) in cases {
            let geometry = MeasurementGeometry(
                pageID: Self.pageID,
                polygons: [PolygonGeometry(outer: parent, holes: holes)]
            )
            let result = try engine.calculate(tool: .area, geometry: geometry, scale: scale)
            #expect(result[.planArea]?.value == 100, "\(name): plan area")
            #expect(result[.netArea]?.value == expectedNet, "\(name): net area")
            #expect(result[.cutoutArea]?.value == expectedCutout, "\(name): cutout area")
            #expect(
                result.hasWarning(.cutoutOutsideParent) == expectWarning,
                "\(name): containment warning"
            )
            try result.validateDimensions()
        }

        // Wholly outside: nothing to remove from, so it is refused rather than measured as a
        // correct-looking 100 with a footnote (QUALITY_BAR 2.5, CR-33). Old output: 100, 0, warned.
        #expect(throws: MeasurementEngineError.measurement(.cutoutOutsideParent(cutoutIndex: 0))) {
            try engine.calculate(
                tool: .area,
                geometry: MeasurementGeometry(
                    pageID: Self.pageID,
                    polygons: [PolygonGeometry(
                        outer: parent,
                        holes: [Self.ring([(20, 20), (22, 20), (22, 22), (20, 22)])]
                    )]
                ),
                scale: scale
            )
        }
    }

    /// Two cutouts that overlap share a region. Subtracting each one's own area would remove the
    /// shared part twice — the classic takeoff error the union exists to prevent.
    @Test("Overlapping cutouts are unioned before subtraction, never double counted")
    func overlappingCutoutsAreUnioned() throws {
        let parent = Self.ring([(0, 0), (10, 0), (10, 10), (0, 10)])
        let engine = MeasurementEngine()
        let scale = try Self.unitScale()

        // Two 2x2 squares overlapping in a 1x1 corner: union is 7, not 8.
        let overlapping = [
            Self.ring([(4, 4), (6, 4), (6, 6), (4, 6)]),
            Self.ring([(5, 5), (7, 5), (7, 7), (5, 7)])
        ]
        let overlapResult = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(
                pageID: Self.pageID,
                polygons: [PolygonGeometry(outer: parent, holes: overlapping)]
            ),
            scale: scale
        )
        #expect(overlapResult[.cutoutArea]?.value == 7)
        #expect(overlapResult[.netArea]?.value == 93)

        // Two 2x2 squares sharing the edge x == 6 exactly: union is the full 8, no seam lost.
        let adjacent = [
            Self.ring([(4, 4), (6, 4), (6, 6), (4, 6)]),
            Self.ring([(6, 4), (8, 4), (8, 6), (6, 6)])
        ]
        let adjacentResult = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(
                pageID: Self.pageID,
                polygons: [PolygonGeometry(outer: parent, holes: adjacent)]
            ),
            scale: scale
        )
        #expect(adjacentResult[.cutoutArea]?.value == 8)
        #expect(adjacentResult[.netArea]?.value == 92)

        // A cutout identical to its parent leaves nothing, and says the area is degenerate.
        let fullResult = try engine.calculate(
            tool: .area,
            geometry: MeasurementGeometry(
                pageID: Self.pageID,
                polygons: [PolygonGeometry(outer: parent, holes: [parent])]
            ),
            scale: scale
        )
        #expect(fullResult[.netArea]?.value == 0)
        #expect(fullResult.hasWarning(.degenerateArea))
    }

    /// Three points on a line describe no circle, and the engine must refuse rather than emit a
    /// radius of 1e8 with a shrug.
    @Test("A collinear three-point circle is refused")
    func collinearThreePointCircleIsRefused() throws {
        let engine = MeasurementEngine()
        let scale = try Self.unitScale()

        for points in [
            [PDFPoint(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0)],
            [PDFPoint(x: 0, y: 0), .init(x: 1, y: 1e-9), .init(x: 2, y: 0)],
            [PDFPoint(x: 0, y: 0), .init(x: 0, y: 0), .init(x: 1, y: 0)]
        ] {
            #expect(throws: (any Error).self) {
                try engine.calculate(
                    tool: .threePointCircle,
                    geometry: MeasurementGeometry(pageID: Self.pageID, points: points),
                    scale: scale
                )
            }
        }

        // A real circle still measures, exactly.
        let result = try engine.calculate(
            tool: .threePointCircle,
            geometry: MeasurementGeometry(
                pageID: Self.pageID,
                points: [.init(x: 1, y: 0), .init(x: 0, y: 1), .init(x: -1, y: 0)]
            ),
            scale: scale
        )
        #expect(result[.radius]?.value == 1)
        #expect(result[.diameter]?.value == 2)
        try result.validateDimensions()
    }

    /// A three-point circle that is *almost* collinear is accepted but must carry the warning,
    /// because the radius it implies is enormous and the user needs to be told before it lands
    /// in a total. This is the one place the engine reports a number it does not fully trust.
    @Test("A nearly collinear circle is warned about, not silently priced")
    func nearlyCollinearCircleWarns() throws {
        let result = try MeasurementEngine().calculate(
            tool: .threePointCircle,
            geometry: MeasurementGeometry(
                pageID: Self.pageID,
                points: [.init(x: 0, y: 0), .init(x: 1, y: 1e-6), .init(x: 2, y: 0)]
            ),
            scale: try Self.unitScale()
        )
        #expect(result.hasWarning(.nearlyCollinearPoints))
        #expect((result[.radius]?.value ?? 0) > 100_000)
    }

    /// A vertical slope has no rise/run, so there is no true length — but there *is* an angle.
    /// The engine must produce the angle, omit the length, and warn; never an infinity.
    @Test("A vertical slope yields an angle and a warning, never an infinite length")
    func verticalSlopeIsNeverInfinite() throws {
        let engine = MeasurementEngine()
        let scale = try Self.unitScale()
        let line = MeasurementGeometry(
            pageID: Self.pageID, points: [.init(x: 0, y: 0), .init(x: 100, y: 0)]
        )

        for slope in [
            SlopeExpression.riseOverRun(rise: 1, run: 0),
            .ratioOneToN(0),
            .degrees(90),
            .degrees(-90)
        ] {
            let result = try engine.calculate(
                tool: .trueSlopedLength,
                geometry: line,
                scale: scale,
                parameters: MeasurementParameters(
                    slope: .uniformPlane(slope, azimuth: SlopeAzimuth(degrees: 0))
                )
            )
            #expect(result[.planLength]?.value == 100)
            #expect(result[.trueLength] == nil, "a vertical slope produced a true length")
            #expect(result.hasWarning(.verticalSlopeUndefinedRun))
            for (_, quantity) in result.values { #expect(quantity.isFinite) }
        }

        // A steep-but-finite slope does produce a true length, and it is finite.
        let steep = try engine.calculate(
            tool: .trueSlopedLength,
            geometry: line,
            scale: scale,
            parameters: MeasurementParameters(
                slope: .uniformPlane(
                    .degrees(try #require(Decimal(string: "89.999999", locale: nil))),
                    azimuth: SlopeAzimuth(degrees: 0)
                )
            )
        )
        #expect(try #require(steep[.trueLength]).isFinite)
        #expect(try #require(steep[.trueLength]).value > 100)
    }

    /// Every value the engine emits must be finite and must match the dimension its field
    /// declares, across every tool that can run on a simple ring.
    @Test("No tool emits a non-finite or mis-dimensioned value")
    func noToolEmitsGarbage() throws {
        let engine = MeasurementEngine()
        let scale = try Self.unitScale()
        let geometry = MeasurementGeometry(
            pageID: Self.pageID,
            points: [.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 10, y: 10), .init(x: 0, y: 10)],
            polygons: [PolygonGeometry(
                outer: Self.ring([(0, 0), (10, 0), (10, 10), (0, 10)]),
                holes: [Self.ring([(4, 4), (6, 4), (6, 6), (4, 6)])]
            )]
        )
        let parameters = MeasurementParameters(
            depth: .length(2),
            height: .length(3),
            openingAreas: [1]
        )

        // Every tool either measures this geometry or refuses it for a reason named here; the
        // old `try? … continue` skipped any tool that threw, for any reason (CR-34).
        let refusals: [MeasurementTool: MeasurementEngineError] = [
            .dimension: .unsupportedGeometry(tool: .dimension, expected: .exactlyOneSegment),
            // Four points are not an arc (X-042); the first three used to be measured silently.
            .arcLength: .unsupportedGeometry(tool: .arcLength, expected: .threePoints),
            .slope: .measurement(.missingParameter(.riseRun)),
            .riseDrop: .measurement(.missingParameter(.perSegmentRiseDrop)),
            .trueSlopedLength: .measurement(.missingParameter(.riseRun)),
            .trueSlopedArea: .measurement(.missingParameter(.riseRun))
        ]
        for tool in MeasurementTool.allCases {
            if let refusal = refusals[tool] {
                #expect(throws: refusal, "\(tool)") {
                    try engine.calculate(tool: tool, geometry: geometry, scale: scale, parameters: parameters)
                }
                continue
            }
            do {
                let result = try engine.calculate(
                    tool: tool, geometry: geometry, scale: scale, parameters: parameters
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

    /// Identical input must give byte-identical output, warnings and order included.
    @Test("Results are deterministic")
    func resultsAreDeterministic() throws {
        let engine = MeasurementEngine()
        let scale = try Self.unitScale()
        let geometry = MeasurementGeometry(
            pageID: Self.pageID,
            polygons: [PolygonGeometry(
                outer: Self.ring([(0, 0), (10, 0), (10, 10), (0, 10)]),
                holes: [
                    Self.ring([(4, 4), (6, 4), (6, 6), (4, 6)]),
                    Self.ring([(9, 9), (12, 9), (12, 12), (9, 12)])
                ]
            )]
        )
        let first = try engine.calculate(tool: .area, geometry: geometry, scale: scale)
        for _ in 0..<8 {
            #expect(try engine.calculate(tool: .area, geometry: geometry, scale: scale) == first)
        }
    }
}
