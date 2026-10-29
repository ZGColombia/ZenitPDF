import Foundation
import GoldenMeasurements
import Testing
import ZPDFContracts
import ZPDFMeasurementEngine

/// Six roof quantities derived by hand, in feet, before the implementation was read.
///
/// These duplicate nothing from `GoldenCorpus`: the corpus works at 1 m/pt with metric spans, and
/// these work at 1 ft/pt on a 24 ft x 40 ft building, so a shared error in the corpus's arithmetic
/// cannot hide here. The scale is the international foot, 0.3048 m exactly, so every expectation
/// below is `<feet figure> * 0.3048`.
///
/// The building: 24 ft across the span, 40 ft along the ridge, 6:12 pitch (`s = 1/2`). One plane
/// runs from the eave at `x = 0` uphill to the ridge at `x = 12`, so the fall line is `+x` and
/// the plane's plan footprint is 12 x 40 ft.
///
/// ```text
/// slope factor  sqrt(1 + 1/4) = sqrt(1.25) = 1.118033988749894848...
/// rake          d = (12, 0)   d.u = 12   sqrt(144 + 0.25*144)      = sqrt(180) = 13.416407864998739 ft
/// eave          d = (0, 40)   d.u = 0    sqrt(1600 + 0)            = 40 ft, exactly
/// hip           d = (12, 12)  d.u = 12   sqrt(288 + 36)            = sqrt(324) = 18 ft, exactly
/// true area     480 sqrt(1.25)                                     = 536.65631459994949 sq ft
/// perimeter     see `perimeterWithHole`                            = 127.71342874781858 ft
/// volume        480 * 0.25 = 120 cu ft plumb; x sqrt(1.25) square to the surface
/// ```
@Suite("Adversarial roof derivations")
struct AdversarialRoofTests {

    static let metresPerFoot = 0.3048
    static let engine = MeasurementEngine()
    /// sqrt(1 + (6/12)^2).
    static let slopeFactor = (1.25 as Double).squareRoot()
    /// 6:12, stated as the rise/run pair so the Decimal is exactly 1/2.
    static let pitch = SlopeExpression.riseOverRun(rise: 6, run: 12)
    /// Uphill towards +x: the fall line of the plane whose eave lies along the y axis.
    static let uphillEast = SlopeAzimuth(degrees: 0)

    static func run(
        tool: MeasurementTool,
        _ geometry: MeasurementGeometry,
        _ parameters: MeasurementParameters,
        scale: ScaleTransform = GoldenScale.imperialFoot
    ) throws -> MeasurementResult {
        try engine.calculate(tool: tool, geometry: geometry, scale: scale, parameters: parameters)
    }

    static func value(_ result: MeasurementResult, _ field: MeasurementField) throws -> Double {
        let quantity = try #require(result[field], "no value for \(field.rawValue)")
        #expect(quantity.dimension == field.dimension)
        return NumericPolicy.double(from: quantity.value)
    }

    /// Relative agreement at 1e-12: these are closed forms, not tolerances on a fixture.
    static func expectClose(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        relative: Double = 1e-12,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let error = abs(actual - expected) / max(abs(expected), 1e-300)
        #expect(
            error <= relative,
            "\(label): expected \(expected), got \(actual), relative error \(error)",
            sourceLocation: sourceLocation
        )
    }

    static let slopedPlane = MeasurementParameters(
        slope: .uniformPlane(pitch, azimuth: uphillEast)
    )

    // MARK: - 1. Rake on a 6:12 gable

    /// The rake runs straight up the fall line, so it takes the full factor: 12 ft of run becomes
    /// `sqrt(180) = 13.416407864998739 ft`. This is the one edge for which the scalar model's
    /// blanket `planLength * sqrt(1 + s^2)` is right.
    @Test("Rake on a 6:12 gable: 12 ft of run is sqrt(180) ft of rake")
    func rake() throws {
        let result = try Self.run(
            tool: .trueSlopedLength,
            GoldenGeometry.polyline([(0, 0), (12, 0)]),
            Self.slopedPlane
        )
        let expected = (180.0 as Double).squareRoot() * Self.metresPerFoot
        Self.expectClose(try Self.value(result, .trueLength), expected, "rake")
        Self.expectClose(try Self.value(result, .planLength), 12 * Self.metresPerFoot, "rake plan")
        // The blanket factor happens to agree here, and only here.
        Self.expectClose(
            try Self.value(result, .trueLength),
            12 * Self.slopeFactor * Self.metresPerFoot,
            "rake equals the scalar factor"
        )
    }

    // MARK: - 2. Eave on the same roof

    /// The eave runs along the contour, `d.u == 0`, so it does not elongate **at all**. Not to
    /// within a tolerance: at 1 m/pt the true length must be the bit-identical plan length, which
    /// is what `hypot(x, 0) == |x|` buys. The scalar formula would add 11.8 % of pure error.
    @Test("Eave on the same roof: 40 ft stays 40 ft, bit for bit")
    func eave() throws {
        let result = try Self.run(
            tool: .trueSlopedLength,
            GoldenGeometry.polyline([(0, 0), (0, 40)]),
            Self.slopedPlane,
            scale: GoldenScale.unit
        )
        let plan = try Self.value(result, .planLength)
        let trueLength = try Self.value(result, .trueLength)
        #expect(plan == 40.0)
        #expect(trueLength == 40.0, "an eave must not elongate at all, got \(trueLength)")
        // What the discarded scalar model would have claimed.
        #expect(40.0 * Self.slopeFactor > 44.7)
    }

    // MARK: - 3. Hip on a square hip roof

    /// A 24 x 24 ft hip roof at 6:12. The hip climbs from the corner `(0, 0)` to the apex over the
    /// centre `(12, 12)`, on the plane whose eave lies along the y axis. Half of its plan run is
    /// along the fall line and half across it:
    ///
    /// ```text
    /// |d|^2 = 144 + 144 = 288      (s (d.u))^2 = (0.5 * 12)^2 = 36
    /// true  = sqrt(324) = 18 ft exactly;  plan = 12 sqrt(2) = 16.97056274847714 ft
    /// ```
    ///
    /// The blanket factor would give `16.97056 * 1.118034 = 18.973666 ft`, 5.4 % long on every hip
    /// in the drawing.
    @Test("Hip on a square 6:12 hip roof: exactly 18 ft over a 12 ft half-span")
    func hip() throws {
        let result = try Self.run(
            tool: .trueSlopedLength,
            GoldenGeometry.polyline([(0, 0), (12, 12)]),
            Self.slopedPlane
        )
        Self.expectClose(try Self.value(result, .trueLength), 18 * Self.metresPerFoot, "hip")
        Self.expectClose(
            try Self.value(result, .planLength),
            12 * (2.0 as Double).squareRoot() * Self.metresPerFoot,
            "hip plan"
        )
        // 1.5 per foot of run is the roofer's hip/valley factor for 6:12; the engine must match it
        // and must not match the rake factor.
        let scalarClaim = 12 * (2.0 as Double).squareRoot() * Self.slopeFactor * Self.metresPerFoot
        #expect(try Self.value(result, .trueLength) < scalarClaim * 0.96)
    }

    // MARK: - 4. True area of one plane

    /// Projection scales every planar region by `cos(theta)`, so the area factor is the scalar one
    /// and no azimuth is needed to get it right: `480 sqrt(1.25) = 536.65631459994949 sq ft`.
    @Test("True area of one 12 x 40 ft plane: 480 sqrt(1.25) sq ft")
    func planeArea() throws {
        let squareMetresPerSquareFoot = Self.metresPerFoot * Self.metresPerFoot
        let result = try Self.run(
            tool: .trueSlopedArea,
            GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 40)),
            Self.slopedPlane
        )
        Self.expectClose(
            try Self.value(result, .planArea),
            480 * squareMetresPerSquareFoot,
            "plan area",
            relative: 1e-10
        )
        Self.expectClose(
            try Self.value(result, .trueArea),
            480 * Self.slopeFactor * squareMetresPerSquareFoot,
            "true area",
            relative: 1e-10
        )
    }

    /// The area factor must not depend on the fall line, and the true area must be reported even
    /// when no azimuth has been established — with the boundary warning saying the perimeter is
    /// the part that could not be answered.
    @Test("True area is identical for four fall lines and needs no azimuth at all")
    func areaIsDirectionIndependent() throws {
        let geometry = GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 40))
        var areas: Set<Decimal> = []
        for degrees: Decimal in [0, 90, 180, 270, 37] {
            let result = try Self.run(
                tool: .trueSlopedArea,
                geometry,
                MeasurementParameters(
                    slope: .uniformPlane(Self.pitch, azimuth: SlopeAzimuth(degrees: degrees))
                )
            )
            areas.insert(try #require(result[.trueArea]).value)
        }
        #expect(areas.count == 1, "the area factor must not depend on the fall line: \(areas)")

        let noAzimuth = try Self.run(
            tool: .trueSlopedArea,
            geometry,
            MeasurementParameters(slope: .uniformPlane(Self.pitch))
        )
        #expect(noAzimuth[.trueArea] != nil)
        #expect(noAzimuth.hasWarning(.slopeAzimuthMissingForBoundary))
        #expect(noAzimuth[.truePerimeter] == nil, "no azimuth means no true perimeter, not a guess")
    }

    /// A length, unlike an area, may not fall back to the scalar factor: without a fall line the
    /// engine has to refuse.
    @Test("A sloped length without a fall line is a typed refusal, never a scalar guess")
    func lengthWithoutAzimuthRefuses() {
        #expect(throws: MeasurementEngineError.self) {
            _ = try Self.run(
                tool: .trueSlopedLength,
                GoldenGeometry.polyline([(0, 0), (12, 0)]),
                MeasurementParameters(slope: .uniformPlane(Self.pitch))
            )
        }
    }

    // MARK: - 5. Perimeter of a sloped polygon with a hole

    /// The 12 x 40 ft plane with a rhombic skylight whose diagonals are 6 and 8 ft, centred on
    /// `(4, 14)`, so that none of its four edges is axis-aligned and each has to be elongated on
    /// its own component:
    ///
    /// ```text
    /// outer   2 rakes  2 sqrt(180)                          = 26.832815729997478
    ///         2 eaves  2 * 40                               = 80
    /// hole    4 edges, each d = (+-3, +-4), |d| = 5, d.u = +-3
    ///                  4 sqrt(25 + 2.25) = 4 sqrt(27.25)    = 20.880613017821100
    /// plan    104 + 20                                      = 124 ft
    /// true                                                  = 127.71342874781858 ft
    /// area    480 - (6 * 8 / 2) = 456 sq ft plan, 456 sqrt(1.25) true
    /// ```
    ///
    /// The blanket factor would claim `124 * 1.118034 = 138.636 ft`, 8.6 % long.
    ///
    /// The hole's boundary only counts under ``PerimeterPolicy/outerPlusCutoutEdges``; the default
    /// is `outerOnly`, and `outerOnlyPerimeterExcludesTheHole` below pins that the two policies
    /// really do differ by exactly the hole's four elongated edges rather than by a rounding.
    @Test("Perimeter of a sloped plane with a rhombic hole: 127.71342874781858 ft")
    func perimeterWithHole() throws {
        let result = try Self.run(
            tool: .perimeter,
            GoldenGeometry.polygon(
                GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 40),
                holes: [[(4, 10), (7, 14), (4, 18), (1, 14)]]
            ),
            MeasurementParameters(
                slope: .uniformPlane(Self.pitch, azimuth: Self.uphillEast),
                perimeterPolicy: .outerPlusCutoutEdges
            )
        )
        let outerTrue = 2 * (180.0 as Double).squareRoot() + 80
        let holeTrue = 4 * (27.25 as Double).squareRoot()
        let expected = (outerTrue + holeTrue) * Self.metresPerFoot

        Self.expectClose(try Self.value(result, .perimeter), 124 * Self.metresPerFoot, "plan perimeter")
        Self.expectClose(try Self.value(result, .truePerimeter), expected, "true perimeter", relative: 1e-11)

        let squareMetresPerSquareFoot = Self.metresPerFoot * Self.metresPerFoot
        Self.expectClose(
            try Self.value(result, .netArea),
            456 * squareMetresPerSquareFoot,
            "net area",
            relative: 1e-10
        )
        // The factor is applied to the *net* area, not to the outline with plan holes taken off it.
        Self.expectClose(
            try Self.value(result, .trueArea),
            456 * Self.slopeFactor * squareMetresPerSquareFoot,
            "true area",
            relative: 1e-10
        )
        #expect(try Self.value(result, .truePerimeter) < 124 * Self.slopeFactor * Self.metresPerFoot * 0.93)
    }

    /// The default policy is `outerOnly`, and the difference between the two policies must be
    /// exactly the hole's four elongated edges — `4 sqrt(27.25) ft` — not a rounding and not the
    /// hole's *plan* perimeter.
    @Test("outerOnly drops exactly the hole's four elongated edges")
    func outerOnlyPerimeterExcludesTheHole() throws {
        let geometry = GoldenGeometry.polygon(
            GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 40),
            holes: [[(4, 10), (7, 14), (4, 18), (1, 14)]]
        )
        let outerOnly = try Self.run(tool: .perimeter, geometry, Self.slopedPlane)
        let withCutouts = try Self.run(
            tool: .perimeter,
            geometry,
            MeasurementParameters(
                slope: .uniformPlane(Self.pitch, azimuth: Self.uphillEast),
                perimeterPolicy: .outerPlusCutoutEdges
            )
        )
        Self.expectClose(
            try Self.value(outerOnly, .perimeter),
            104 * Self.metresPerFoot,
            "outerOnly plan perimeter"
        )
        Self.expectClose(
            try Self.value(outerOnly, .truePerimeter),
            (2 * (180.0 as Double).squareRoot() + 80) * Self.metresPerFoot,
            "outerOnly true perimeter",
            relative: 1e-11
        )
        let difference = try Self.value(withCutouts, .truePerimeter) - Self.value(outerOnly, .truePerimeter)
        Self.expectClose(
            difference,
            4 * (27.25 as Double).squareRoot() * Self.metresPerFoot,
            "the hole's elongated boundary",
            relative: 1e-10
        )
        // Not the hole's plan perimeter: the hole's edges are sloped too.
        #expect(difference > 20 * Self.metresPerFoot * 1.04)
    }

    // MARK: - 6. Volume in both depth modes

    /// 480 sq ft of plan under 3 in of cover. Plumb depth and square-to-the-surface thickness are
    /// different volumes on the same drawing, and the ratio is exactly the slope factor.
    ///
    /// ```text
    /// verticalDepth           480 * 0.25                    = 120 cu ft
    /// perpendicularThickness  480 * sqrt(1.25) * 0.25       = 134.16407864998737 cu ft
    /// ```
    @Test("Volume, both depth modes: 120 cu ft plumb vs 134.16407864998737 cu ft square to the surface")
    func volumeBothDepthModes() throws {
        let cubicMetresPerCubicFoot = Self.metresPerFoot * Self.metresPerFoot * Self.metresPerFoot
        let geometry = GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 40))
        // 0.25 ft = 0.0762 m exactly.
        let depth = DecimalQuantity.length(Decimal(sign: .plus, exponent: -4, significand: 762))

        let plumb = try Self.run(
            tool: .volume,
            geometry,
            MeasurementParameters(
                depth: depth,
                slope: .uniformPlane(Self.pitch, azimuth: Self.uphillEast),
                volumeDepthReference: .verticalDepth
            )
        )
        Self.expectClose(
            try Self.value(plumb, .volume),
            120 * cubicMetresPerCubicFoot,
            "plumb volume",
            relative: 1e-10
        )

        let square = try Self.run(
            tool: .volume,
            geometry,
            MeasurementParameters(
                depth: depth,
                slope: .uniformPlane(Self.pitch, azimuth: Self.uphillEast),
                volumeDepthReference: .perpendicularThickness
            )
        )
        Self.expectClose(
            try Self.value(square, .volume),
            120 * Self.slopeFactor * cubicMetresPerCubicFoot,
            "perpendicular volume",
            relative: 1e-10
        )

        // The two modes differ by exactly sqrt(1.25); the ratio is the whole reason the mode is
        // mandatory rather than defaulted.
        let ratio = try Self.value(square, .volume) / Self.value(plumb, .volume)
        Self.expectClose(ratio, Self.slopeFactor, "mode ratio", relative: 1e-10)
    }

    /// A vertical plane has no finite `sqrt(1 + s^2)`, so `perpendicularThickness` has no true
    /// area to lay the thickness over and `VolumeCalculator` falls back to the plan area — which
    /// is the `verticalDepth` answer under a different name.
    ///
    /// That fallback must not be silent: the result has to carry the vertical warning, and it must
    /// not report a `trueArea` it could not compute. A vertical plane is degenerate input rather
    /// than a real roof, but "the number changed meaning and nothing said so" is the exact failure
    /// mode ADR-0004 exists to remove, so it is pinned here.
    /// A vertical plane has no finite length factor and therefore no true area, so a thickness
    /// measured square to that surface has nothing to be laid over. Until BH-558 this case
    /// returned the *plan* volume — 12 × 40 × 0.0762 = 36.576 m³ — with a warning about the
    /// slope being vertical and none about the fallback, which is the silent substitution the
    /// CR-25 rule refuses for the rise/drop modes. The refusal names the field the mode needed.
    @Test("A vertical plane cannot supply a perpendicular thickness, and refuses rather than guessing")
    func verticalPlaneVolumeIsRefused() throws {
        let geometry = GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 40))
        let depth = DecimalQuantity.length(Decimal(sign: .plus, exponent: -4, significand: 762))
        #expect(throws: MeasurementEngineError.measurement(.unsupportedField(.trueArea))) {
            try Self.run(
                tool: .volume,
                geometry,
                MeasurementParameters(
                    depth: depth,
                    slope: .uniformPlane(.riseOverRun(rise: 1, run: 0), azimuth: Self.uphillEast),
                    volumeDepthReference: .perpendicularThickness
                )
            )
        }
        // A plumb depth on the same markup is still the plan volume, at the suite's 1 ft/pt:
        // 12 × 40 = 480 ft² = 480 × 0.09290304 = 44.5934592 m²; × 0.0762 m = 3.39802159104 m³,
        // flagged as vertical and carrying no true area.
        let plumb = try Self.run(
            tool: .volume,
            geometry,
            MeasurementParameters(
                depth: depth,
                slope: .uniformPlane(.riseOverRun(rise: 1, run: 0), azimuth: Self.uphillEast),
                volumeDepthReference: .verticalDepth
            )
        )
        #expect(plumb.hasWarning(.verticalSlopeUndefinedRun))
        #expect(plumb[.trueArea] == nil, "a true area was reported for a plane with no finite factor")
        #expect(try #require(plumb[.volume]).value == Decimal(string: "3.39802159104")!)
    }

    /// On a sloped markup there is no default. Omitting the mode is a typed error, not a guess.
    @Test("A sloped volume with no depth reference is refused")
    func volumeWithoutDepthReferenceRefuses() {
        #expect(throws: MeasurementEngineError.self) {
            _ = try Self.run(
                tool: .volume,
                GoldenGeometry.polygon(GoldenGeometry.rectangle(x: 0, y: 0, width: 12, height: 40)),
                MeasurementParameters(
                    depth: .length(Decimal(sign: .plus, exponent: -4, significand: 762)),
                    slope: .uniformPlane(Self.pitch, azimuth: Self.uphillEast)
                )
            )
        }
    }

    // MARK: - Cross-cutting

    /// QUALITY_BAR **P7**, on the sloped path: rotating the vertex list by any `k` and reversing
    /// it must change no unsigned measurement, **exactly** — not to within a tolerance.
    ///
    /// This is the regression fixture for the P7 violation found on 2026-08-23. Both `pairwiseSum`
    /// and `kahanSum` are functions of the term *sequence*, so a rotated vertex list produced a
    /// different last bit: at 1 ft/pt this 5-gon measured 15.9845047319568 m from one starting
    /// vertex and 15.9845047319567 m from another. It runs at a non-unit scale on purpose — at
    /// 1 m/pt the terms happened to sum identically and the bug was invisible.
    @Test(
        "P7: a sloped ring measures identically from every starting vertex and in both directions",
        arguments: [5, 9, 71]
    )
    func loopIsRotationInvariant(sides: Int) throws {
        // A non-convex ring at 71 sides also crosses NumericPolicy's 64-term threshold, so the
        // Kahan branch is covered as well as the pairwise one.
        let base: [(Double, Double)] = (0..<sides).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(sides)
            let radius = 17.0 + 4.0 * Foundation.cos(3 * angle)
            return (radius * Foundation.cos(angle), radius * Foundation.sin(angle))
        }
        var truePerimeters: Set<Decimal> = []
        var planPerimeters: Set<Decimal> = []
        var netAreas: Set<Decimal> = []
        for rotation in 0..<base.count {
            let rotated = Array(base[rotation...] + base[..<rotation])
            for ring in [rotated, Array(rotated.reversed())] {
                let result = try Self.run(tool: .perimeter, GoldenGeometry.polygon(ring), Self.slopedPlane)
                truePerimeters.insert(try #require(result[.truePerimeter]).value)
                planPerimeters.insert(try #require(result[.perimeter]).value)
                netAreas.insert(try #require(result[.netArea]).value)
            }
        }
        #expect(truePerimeters.count == 1, "P7: true perimeter varies with vertex order: \(truePerimeters)")
        #expect(planPerimeters.count == 1, "P7: plan perimeter varies with vertex order: \(planPerimeters)")

        // Area is the one quantity P7 does *not* require to be exactly rotation-invariant, and it
        // is not. `PolygonMath.signedArea` anchors its origin shift at `points[0]`, so rotating
        // the vertex list moves the anchor and the shoelace terms are genuinely different numbers
        // — P7 says "exact equality ... **at fixed origin-shift anchor**", and this anchor is not
        // fixed. Measured spread on a 9-gon at 1 ft/pt: 76.58695376572813818048 against
        // 76.58695376572804527744, a relative 1.2e-15, about 5 ulp and four orders inside the
        // 0.10 % area tolerance. Pinned here at 1e-14 rather than left unstated, so that if
        // someone later anchors the shift at the lexicographically smallest vertex (which would
        // make it exact) the change is a visible tightening rather than a silent one.
        let areas = netAreas.map { NumericPolicy.double(from: $0) }
        let spread = (areas.max() ?? 0) - (areas.min() ?? 0)
        #expect(
            spread / (areas.max() ?? 1) <= 1e-14,
            "net area spread over vertex orders is \(spread): \(netAreas)"
        )
    }


    /// Reversing the fall line cannot change a length: `d.u` is squared. The arrow is for the UI.
    @Test("Reversing the fall line changes no length")
    func oppositeAzimuthAgrees() throws {
        let geometry = GoldenGeometry.polyline([(0, 0), (7, 5)])
        let uphill = try Self.run(tool: .trueSlopedLength, geometry, Self.slopedPlane)
        let downhill = try Self.run(
            tool: .trueSlopedLength,
            geometry,
            MeasurementParameters(slope: .uniformPlane(Self.pitch, azimuth: Self.uphillEast.opposite))
        )
        #expect(uphill[.trueLength] == downhill[.trueLength])
    }

    /// Every spelling of a 6:12 pitch is the same `Decimal`, so every one gives a bit-identical
    /// hip. `26.565051177077994 degrees` goes through `tan`, so it is checked at tolerance rather
    /// than for equality.
    @Test("6:12, 1:2, 0.5 and 50 % give a bit-identical hip")
    func pitchSpellingsAgree() throws {
        let geometry = GoldenGeometry.polyline([(0, 0), (12, 12)])
        var lengths: Set<Decimal> = []
        for spelling: SlopeExpression in [
            .riseOverRun(rise: 6, run: 12),
            .ratioOneToN(2),
            .decimalRatio(Decimal(sign: .plus, exponent: -1, significand: 5)),
            .percent(50),
            .ratioNToOne(Decimal(sign: .plus, exponent: -1, significand: 5))
        ] {
            let result = try Self.run(
                tool: .trueSlopedLength,
                geometry,
                MeasurementParameters(slope: .uniformPlane(spelling, azimuth: Self.uphillEast))
            )
            lengths.insert(try #require(result[.trueLength]).value)
        }
        #expect(lengths.count == 1, "pitch spellings disagree: \(lengths)")
    }
}
