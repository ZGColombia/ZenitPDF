import Foundation
import ZPDFContracts

/// Fall-line azimuths for the roof cases, in page space, counter-clockwise from +x.
///
/// The four compass constants are exact by construction — ``SlopeAzimuth/direction`` answers the
/// axis cases from the degrees alone and never calls `cos`/`sin` — which is what lets an eave
/// come out at *exactly* its plan length instead of within a tolerance of it.
public enum GoldenFallLine: Sendable {
    /// Uphill towards +x.
    public static let east = SlopeAzimuth(degrees: 0)
    /// Uphill towards +y.
    public static let north = SlopeAzimuth(degrees: 90)
    /// Uphill towards -x.
    public static let west = SlopeAzimuth(degrees: 180)
    /// Uphill towards -y.
    public static let south = SlopeAzimuth(degrees: 270)

    /// Uphill towards an arbitrary page-space direction. `atan2(dy, dx)` in degrees.
    public static func towards(dx: Double, dy: Double) -> SlopeAzimuth {
        if dy == 0 { return SlopeAzimuth(degrees: dx >= 0 ? 0 : 180) }
        if dx == 0 { return SlopeAzimuth(degrees: dy > 0 ? 90 : 270) }
        let degrees = Foundation.atan2(dy, dx) / AngleUnit.degree.radiansPerUnit
        let normalised = degrees < 0 ? degrees + 360 : degrees
        return SlopeAzimuth(degrees: (try? NumericPolicy.decimal(from: normalised)) ?? 0)
    }
}

/// The pitches the roof cases use, all exactly `1/2` as a `Decimal`.
///
/// `6:12`, `1:2`, `0.5` and `50 %` are four ways of writing one number, and ADR-0004 §3 requires
/// them to round-trip exactly — not to within a tolerance — so the corpus states all four and the
/// gate proves they give bit-identical results.
public enum GoldenPitch: Sendable {
    /// `6:12`, the imperial roofing form. rise 6, run 12.
    public static let sixOverTwelve = SlopeExpression.riseOverRun(rise: 6, run: 12)
    /// `1:2`, the same slope written as one-in-n.
    public static let oneToTwo = SlopeExpression.ratioOneToN(2)
    /// `0.5`, the bare decimal ratio.
    public static let half = SlopeExpression.decimalRatio(Decimal(sign: .plus, exponent: -1, significand: 5))
    /// `50 %`.
    public static let fiftyPercent = SlopeExpression.percent(50)
    /// `n:1` with n = 0.5 — the pitch form.
    public static let nToOne = SlopeExpression.ratioNToOne(Decimal(sign: .plus, exponent: -1, significand: 5))

    /// Every exact spelling of a 6:12 pitch.
    public static let allSpellings: [SlopeExpression] = [
        sixOverTwelve, oneToTwo, half, fiftyPercent, nToOne
    ]

    /// `sqrt(1 + 0.5^2) = sqrt(1.25) = 1.118033988749895...`
    ///
    /// The *area* factor, and the length factor for an edge running straight up the fall line —
    /// and for no other edge. That distinction is what ADR-0004 exists to enforce.
    public static let factor = (1.25 as Double).squareRoot()
}

/// The directional-slope cases of ADR-0004.
///
/// Every number below is written as the arithmetic that produces it, at 1 metre per PDF point,
/// so the page coordinates *are* metres and a reader checks the case by reading it.
///
/// The one formula under test:
///
/// ```text
/// |d_true| = sqrt( |d|^2 + ( s * (d . u) )^2 )      per segment, summed
/// ```
///
/// against the formula it replaces:
///
/// ```text
/// trueLength = planLength * sqrt(1 + s^2)           scalar model, wrong off the fall line
/// ```
extension GoldenCorpus {
    public static let directionalSlope: [GoldenCase] = gable + hip + shed + slopedAreas + slopedWalls + pitchSpellings

    // MARK: - Symmetric gable (ADR-0004: eaves and ridge do not elongate; rakes do)

    /// One plane of a symmetric gable roof, 12 m of ridge over a 4 m half-span, at 6:12.
    ///
    /// ```text
    /// ring        (0,0) -> (12,0) -> (12,4) -> (0,4)          eave, rake, ridge, rake
    /// u           (0, 1)      uphill towards the ridge
    /// s           0.5         6:12
    ///
    /// eave   d = (12, 0)   d.u = 0    true = sqrt(144 + 0)   = 12          unchanged
    /// rake   d = ( 0, 4)   d.u = 4    true = sqrt( 16 + 4)   = sqrt(20)    = 4.472135954999580
    /// ridge  d = (-12, 0)  d.u = 0    true = 12                            unchanged
    /// rake   d = ( 0,-4)   d.u = -4   true = sqrt( 16 + 4)   = sqrt(20)
    ///
    /// planPerimeter = 12 + 4 + 12 + 4                 = 32
    /// truePerimeter = 24 + 2 * sqrt(20)               = 32.944271909999160
    /// scalar model  = 32 * sqrt(1.25)                 = 35.777087639996640
    /// difference    = 24 * (sqrt(1.25) - 1)           =  2.832815729997478  <- 8.5988 % too long
    /// ```
    ///
    /// The eaves and the ridge are most of the perimeter of a real roof, and the scalar
    /// formula stretches all of them. That 2.83 m on a 33 m boundary is the reason ADR-0004
    /// exists; `DirectionalSlopeTests.gableDiffersFromTheScalarModel` asserts the number itself so
    /// a regression to `planLength * sqrt(1 + s^2)` fails loudly rather than quietly.
    static let gable: [GoldenCase] = [
        GoldenCase(
            id: "DS01",
            title: "Gable plane at 6:12: eaves and ridge unchanged, rakes sqrt(20); perimeter 24 + 2 sqrt(20)",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 4)),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north)
            ),
            expected: [
                .perimeter: 32,
                .truePerimeter: 24 + 2 * (20.0 as Double).squareRoot(),
                .planArea: 12 * 4,
                .netArea: 12 * 4,
                .trueArea: 12 * 4 * GoldenPitch.factor,
                .slopeRatio: 0.5
            ],
            forbiddenWarnings: [.slopeAzimuthMissingForBoundary]
        ),
        GoldenCase(
            id: "DS02",
            title: "Whole gable footprint at 6:12: two eaves stay 12, two full-span rakes give 8 sqrt(1.25)",
            derivation: .handDerived,
            tool: .perimeter,
            // Ridge along y = 0, eaves at y = -4 and y = +4, so the short edges cross the ridge.
            // A rake folded over the ridge climbs s*4 and falls s*4; its true length is
            // 2 * sqrt(16 + 4) = 8.944271909999159, which is exactly what the per-segment rule
            // gives for the unfolded span: sqrt(64 + (0.5 * 8)^2) = sqrt(80).
            geometry: GoldenGeometry.polygon([(0, -4), (12, -4), (12, 4), (0, 4)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north)
            ),
            expected: [
                // 12 + 8 + 12 + 8
                .perimeter: 40,
                // 24 + 2 * sqrt(80) = 24 + 17.888543819998318
                .truePerimeter: 24 + 2 * (80.0 as Double).squareRoot(),
                .planArea: 12 * 8,
                .trueArea: 12 * 8 * GoldenPitch.factor
            ]
        )
    ]

    // MARK: - Hip roof (ADR-0004: four planes, three different elongations, none of them the scalar)

    /// A 24 x 12 hip roof at 6:12, ridge along y = 6 from x = 6 to x = 18. Four planes, each with
    /// its own fall line, measured one at a time the way a takeoff actually works.
    ///
    /// ```text
    /// eave    perpendicular to u      factor 1                     (24 m and 12 m edges)
    /// ridge   perpendicular to u      factor 1                     (12 m edge)
    /// hip     45 deg in plan          sqrt(72 + 9) / sqrt(72)
    ///                                 = 9 / 8.485281374238570 = 1.060660171779821
    /// scalar model applies            sqrt(1.25) = 1.118033988749895  to all of them
    /// ```
    ///
    /// Three distinct factors, and the scalar equals none of them. The hips come out at exactly
    /// 9 m, which is what makes this case checkable in the head: `sqrt(6^2 + 6^2 + 3^2) = 9`.
    static let hip: [GoldenCase] = [
        GoldenCase(
            id: "DS03",
            title: "Hip roof south plane (0,0)-(24,0)-(18,6)-(6,6): 24 + 9 + 12 + 9 = 54 m of true edge",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon([(0, 0), (24, 0), (18, 6), (6, 6)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north)
            ),
            expected: [
                // 24 + sqrt(72) + 12 + sqrt(72) = 52.970562748477136
                .perimeter: 36 + 2 * (72.0 as Double).squareRoot(),
                // eave 24, hip sqrt(72 + 9) = 9, ridge 12, hip 9
                .truePerimeter: 54,
                // trapezoid ((24 + 12) / 2) * 6
                .planArea: 108,
                .trueArea: 108 * GoldenPitch.factor
            ]
        ),
        GoldenCase(
            id: "DS04",
            title: "Hip roof north plane, mirrored about y = 6: the same 54 m, fall line reversed",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon([(0, 12), (6, 6), (18, 6), (24, 12)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.south)
            ),
            expected: [
                .perimeter: 36 + 2 * (72.0 as Double).squareRoot(),
                .truePerimeter: 54,
                .planArea: 108,
                .trueArea: 108 * GoldenPitch.factor
            ]
        ),
        GoldenCase(
            id: "DS05",
            title: "Hip roof west end triangle (0,0)-(6,6)-(0,12): 9 + 9 + 12 = 30 m of true edge",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon([(0, 0), (6, 6), (0, 12)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.east)
            ),
            expected: [
                // sqrt(72) + sqrt(72) + 12 = 28.970562748477140
                .perimeter: 12 + 2 * (72.0 as Double).squareRoot(),
                // hip 9, hip 9, gable-end eave 12 (perpendicular to the fall line, unchanged)
                .truePerimeter: 30,
                // (12 * 6) / 2
                .planArea: 36,
                .trueArea: 36 * GoldenPitch.factor
            ]
        ),
        GoldenCase(
            id: "DS06",
            title: "Hip roof east end triangle (24,0)-(24,12)-(18,6): the same 30 m, fall line reversed",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon([(24, 0), (24, 12), (18, 6)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.west)
            ),
            expected: [
                .perimeter: 12 + 2 * (72.0 as Double).squareRoot(),
                .truePerimeter: 30,
                .planArea: 36,
                .trueArea: 36 * GoldenPitch.factor
            ]
        )
    ]

    // MARK: - Shed roof, measured across and along the fall

    static let shed: [GoldenCase] = [
        GoldenCase(
            id: "DS07",
            title: "Shed roof measured ALONG the fall: 10 m of plan is 10 sqrt(1.25) = sqrt(125) m",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.east)
            ),
            // d = (10, 0), u = (1, 0), d.u = 10, rise = 5, true = sqrt(100 + 25) = sqrt(125)
            expected: [.planLength: 10, .trueLength: (125.0 as Double).squareRoot()]
        ),
        GoldenCase(
            id: "DS08",
            title: "The same shed measured ACROSS the fall: 10 m of plan is 10 m of roof, exactly",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (0, 10)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.east)
            ),
            // d = (0, 10), u = (1, 0), d.u = 0, rise = 0, true = sqrt(100 + 0) = 10
            expected: [.planLength: 10, .trueLength: 10]
        ),
        GoldenCase(
            id: "DS09",
            title: "Contour-parallel polyline at 6:12: 30 m of plan is 30 m of surface, bit-for-bit",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (13, 0), (30, 0)]),
            scale: GoldenScale.metric50,
            parameters: MeasurementParameters(
                // The fall line runs up the page; every segment runs across it.
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north)
            ),
            // 30 pt at 50 mm/pt = 1.5 m; d.u = 0 on both segments, so hypot(|d|, 0) = |d| exactly.
            // `DirectionalSlopeTests.contourParallelIsExact` asserts the Decimal equality, which
            // is stronger than the gate's 0.05 % length tolerance.
            expected: [.planLength: 1.5, .trueLength: 1.5]
        )
    ]

    // MARK: - Sloped areas

    static let slopedAreas: [GoldenCase] = [
        GoldenCase(
            id: "DS10",
            title: "Sloped roof plane with two openings: the factor multiplies the NET area, once",
            derivation: .handDerived,
            tool: .trueSlopedArea,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 20, height: 15),
                holes: [
                    GoldenGeometry.rectangle(x: 2, y: 2, width: 3, height: 2),
                    GoldenGeometry.rectangle(x: 10, y: 5, width: 4, height: 2.5)
                ]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north)
            ),
            // plan  20 * 15                      = 300
            // holes 3 * 2 + 4 * 2.5              =  16
            // net   300 - 16                     = 284
            // true  284 * sqrt(1.25)             = 317.521652804970130
            // WRONG 300 * sqrt(1.25) - 16        = 319.410196624968500  (factor before cutouts)
            expected: [
                .planArea: 300,
                .cutoutArea: 16,
                .netArea: 284,
                .trueArea: 284 * GoldenPitch.factor
            ]
        ),
        GoldenCase(
            id: "DS17",
            title: "Perimeter policy outerPlusCutoutEdges on a slope: the hole boundary obeys the same rule",
            derivation: .handDerived,
            tool: .perimeter,
            geometry: GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 4),
                holes: [GoldenGeometry.rectangle(x: 4, y: 1, width: 3, height: 2)]
            ),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north),
                perimeterPolicy: .outerPlusCutoutEdges
            ),
            // outer  12 + 4 + 12 + 4                            = 32   -> 24 + 2 sqrt(20)
            // hole    3 + 2 +  3 + 2                            = 10   ->  6 + 2 sqrt(5)
            //         the hole's horizontal edges run along the contour and do not elongate
            //         either; only its two 2 m verticals do, each to sqrt(4 + 1) = sqrt(5).
            // plan   32 + 10                                    = 42
            // true   30 + 6 sqrt(5)                             = 43.416407864998739
            // scalar     42 * sqrt(1.25)                        = 46.957427527495590
            expected: [
                .perimeter: 42,
                .truePerimeter: 30 + 6 * (5.0 as Double).squareRoot(),
                .planArea: 48,
                .netArea: 48 - 6,
                .trueArea: (48 - 6) * GoldenPitch.factor
            ]
        ),
        GoldenCase(
            id: "DS11",
            title: "Volume, depth measured VERTICALLY: 10 x 8 m plan, 0.2 m plumb depth = 16 m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 8)),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                depth: .length(Decimal(sign: .plus, exponent: -1, significand: 2)),
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north),
                volumeDepthReference: .verticalDepth
            ),
            // The projection cancels: 80 m2 of plan under 0.2 m of plumb depth is 16 m3, and the
            // slope does not enter the answer at all.
            expected: [.planArea: 80, .netArea: 80, .volume: 16]
        ),
        GoldenCase(
            id: "DS12",
            title: "The same geometry, depth PERPENDICULAR to the surface: 16 sqrt(1.25) = 17.888543... m3",
            derivation: .handDerived,
            tool: .volume,
            geometry: GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 10, height: 8)),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                depth: .length(Decimal(sign: .plus, exponent: -1, significand: 2)),
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.north),
                volumeDepthReference: .perpendicularThickness
            ),
            // 80 * sqrt(1.25) * 0.2 = 17.888543819998318. Exactly sqrt(1.25) times DS11, which is
            // 11.8 % more concrete on the same drawing, chosen by a mode and never by a guess.
            expected: [
                .planArea: 80,
                .netArea: 80,
                .trueArea: 80 * GoldenPitch.factor,
                .volume: 16 * GoldenPitch.factor
            ]
        ),
        GoldenCase(
            id: "DS13",
            title: "A 150 % slope is accepted and flagged: 10 m along the fall is sqrt(325) m",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(.percent(150), azimuth: GoldenFallLine.east)
            ),
            // s = 1.5, d.u = 10, rise = 15, true = sqrt(100 + 225) = sqrt(325) = 18.027756377319946
            expected: [.planLength: 10, .trueLength: (325.0 as Double).squareRoot(), .slopeRatio: 1.5],
            expectedWarnings: [.slopeMagnitudeAboveOneHundredPercent]
        )
    ]

    // MARK: - Sloped walls

    static let slopedWalls: [GoldenCase] = [
        GoldenCase(
            id: "DS14",
            title: "Gable wall with a sloping top edge: trapezoid (2.4 + 4.0) / 2 x 10 = 32 m2",
            derivation: .handDerived,
            tool: .wallArea,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                height: .length(Decimal(string: "2.4") ?? 0),
                heightAtEnd: .length(4)
            ),
            // A slope factor on the 2.4 m wall would give 10 * 2.4 * sqrt(1 + 0.16^2) = 24.31 m2,
            // which is not the area of anything. The wall is a trapezoid: 10 * (2.4 + 4) / 2 = 32.
            expected: [.planLength: 10, .planWallArea: 32, .wallArea: 32, .netWallArea: 32]
        ),
        GoldenCase(
            id: "DS15",
            title: "Wall following the fall line at 6:12: base 10 sqrt(1.25) m, area x 2.4 m",
            derivation: .handDerived,
            tool: .wallArea,
            geometry: GoldenGeometry.polyline([(0, 0), (10, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                height: .length(Decimal(string: "2.4") ?? 0),
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.east)
            ),
            // trueLength = sqrt(100 + 25) = 11.180339887498949; 11.180339887498949 * 2.4 =
            // 26.832815729997478. The plan wall area, 24, is stored beside it and not replaced.
            expected: [
                .planLength: 10,
                .trueLength: (125.0 as Double).squareRoot(),
                .planWallArea: 24,
                .wallArea: (125.0 as Double).squareRoot() * 2.4
            ]
        ),
        GoldenCase(
            id: "DS16",
            title: "The same wall following the contour: true base 10 m, so plan and true area agree",
            derivation: .handDerived,
            tool: .wallArea,
            geometry: GoldenGeometry.polyline([(0, 0), (0, 10)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                height: .length(Decimal(string: "2.4") ?? 0),
                slope: .uniformPlane(GoldenPitch.sixOverTwelve, azimuth: GoldenFallLine.east)
            ),
            expected: [
                .planLength: 10,
                .trueLength: 10,
                .planWallArea: 24,
                .wallArea: 24
            ]
        )
    ]

    // MARK: - One pitch, five spellings

    /// A 6:12 pitch written every exact way ADR-0004 §3 accepts, over one geometry.
    ///
    /// All five reduce to the `Decimal` `0.5` — `6/12`, `1/2`, `0.5`, `50/100`, `0.5` — so the
    /// engine must produce not merely close answers but identical ones.
    /// `DirectionalSlopeTests.pitchSpellingsAgreeExactly` asserts full `MeasurementResult`
    /// equality across the five, which no tolerance can paper over.
    static let pitchSpellings: [GoldenCase] = GoldenPitch.allSpellings.enumerated().map { index, expression in
        GoldenCase(
            id: String(format: "DS2%d", index),
            title: "6:12 spelling \(index + 1) of 5: 20 m along the fall is 20 sqrt(1.25) m",
            derivation: .handDerived,
            tool: .trueSlopedLength,
            geometry: GoldenGeometry.polyline([(0, 0), (20, 0)]),
            scale: GoldenScale.unit,
            parameters: MeasurementParameters(
                slope: .uniformPlane(expression, azimuth: GoldenFallLine.east)
            ),
            expected: [
                .planLength: 20,
                .trueLength: 20 * GoldenPitch.factor,
                .slopeRatio: 0.5,
                .slopePercent: 50
            ]
        )
    }
}
