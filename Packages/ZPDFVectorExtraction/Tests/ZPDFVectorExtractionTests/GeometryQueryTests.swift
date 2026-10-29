import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Searchable geometry, the engine half: ask one page's geometry a typed question, get highlights.
///
/// Every expected value below is derived by hand in the comment beside it. No expectation
/// is produced by the code under test — `QUALITY_BAR` 2.6.
///
/// The queries answer with **highlights, never quantities**. Nothing in this suite sums a
/// result or treats one as a measurement, because the invariant is that a search
/// result becomes a measurement only when a person commits it.
struct GeometryQueryTests {

    // MARK: - Hand-built segments

    /// A horizontal segment at `y`, running from `x0` to `x1`.
    static func horizontal(_ id: UInt64, y: Double, from x0: Double, to x1: Double) -> GeometryQuerySegment {
        GeometryQuerySegment(
            primitiveID: id,
            start: CGPoint(x: x0, y: y),
            end: CGPoint(x: x1, y: y)
        )
    }

    static func segment(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> GeometryQuerySegment {
        GeometryQuerySegment(
            primitiveID: id,
            start: CGPoint(x: x0, y: y0),
            end: CGPoint(x: x1, y: y1)
        )
    }

    // MARK: - Parallel pairs

    @Test("Two parallel lines 300 points apart are found at gap 300 and not at gap 200")
    func parallelPairAtThreeHundred() throws {
        // A: y = 100, x in [100, 500]. B: y = 400, same span.
        // Perpendicular separation = 400 - 100 = 300 exactly.
        // Projected overlap along A's direction = 500 - 100 = 400 exactly.
        let a = Self.horizontal(1, y: 100, from: 100, to: 500)
        let b = Self.horizontal(2, y: 400, from: 100, to: 500)
        let engine = try GeometryQueryEngine(segments: [a, b])

        let found = engine.parallelPairs(gap: 300, tolerance: 1)
        #expect(found.count == 1)
        #expect(found.status == .complete)
        #expect(!found.truncated)
        let pair = try #require(found.matches.first)
        #expect(pair.firstPrimitiveID == 1)
        #expect(pair.secondPrimitiveID == 2)
        #expect(abs(pair.separationPoints - 300) < 1e-9)
        #expect(abs(pair.overlapLengthPoints - 400) < 1e-9)
        #expect(abs(pair.angleDifferenceDegrees) < 1e-9)
        // The highlight's box is the facing span: x in [100, 500], y in [100, 400].
        #expect(abs(pair.bounds.minX - 100) < 1e-9)
        #expect(abs(pair.bounds.maxX - 500) < 1e-9)
        #expect(abs(pair.bounds.minY - 100) < 1e-9)
        #expect(abs(pair.bounds.maxY - 400) < 1e-9)

        let missed = engine.parallelPairs(gap: 200, tolerance: 1)
        #expect(missed.count == 0)
        #expect(missed.status == .complete)

        print(
            "parallelPairAtThreeHundred: gap 300 -> \(found.count) pair "
                + "(separation \(pair.separationPoints), overlap \(pair.overlapLengthPoints)), "
                + "gap 200 -> \(missed.count) pairs"
        )
    }

    @Test("A line 12 degrees off is excluded by the angle tolerance, not by its distance")
    func twelveDegreeLineExcludedByAngle() throws {
        // A: y = 0, x in [0, 400]. Direction +x, so its normal is +y.
        // D is A's mirror rotated 12 degrees about the point (200, 300), half-length 200:
        //   cos 12 deg = 0.9781476007338057, sin 12 deg = 0.20791169081775931
        //   D.start = (200 - 200*cos12, 300 - 200*sin12) = (4.370479853238852,   258.41766183644814)
        //   D.end   = (200 + 200*cos12, 300 + 200*sin12) = (395.62952014676115,  341.58233816355186)
        // Overlap along A: [4.370479853238852, 395.62952014676115], midpoint x = 200.
        // D's normal offset at that midpoint is (258.41766183644814 + 341.58233816355186)/2
        //   = 300 exactly. So the separation IS 300 and only the angle rule can reject it.
        let a = Self.segment(1, 0, 0, 400, 0)
        let d = Self.segment(2, 4.370479853238852, 258.41766183644814, 395.62952014676115, 341.58233816355186)
        let engine = try GeometryQueryEngine(segments: [a, d])

        let strict = engine.parallelPairs(gap: 300, tolerance: 1)
        #expect(strict.count == 0)

        // Widen the angle tolerance past 12 degrees and the same pair appears, at the
        // separation derived above. That is what proves the angle rule did the rejecting.
        let wide = engine.parallelPairs(gap: 300, tolerance: 1, angleToleranceDegrees: 15)
        #expect(wide.count == 1)
        let pair = try #require(wide.matches.first)
        #expect(abs(pair.separationPoints - 300) < 1e-9)
        #expect(abs(pair.angleDifferenceDegrees - 12) < 1e-9)

        print(
            "twelveDegreeLineExcludedByAngle: at 1.5 deg -> \(strict.count) pairs, "
                + "at 15 deg -> \(wide.count) pair with separation \(pair.separationPoints) "
                + "and angle \(pair.angleDifferenceDegrees) deg"
        )
    }

    @Test("Collinear-offset segments with no projected overlap are not a pair")
    func noProjectedOverlapIsNotAPair() throws {
        // E: y = 0, x in [0, 100]. F: y = 300, x in [200, 300].
        // Parallel, separation exactly 300 — and they never face each other:
        //   overlap = min(100, 300) - max(0, 200) = 100 - 200 = -100.
        let e = Self.horizontal(1, y: 0, from: 0, to: 100)
        let f = Self.horizontal(2, y: 300, from: 200, to: 300)
        let apart = try GeometryQueryEngine(segments: [e, f])
        let none = apart.parallelPairs(gap: 300, tolerance: 1)
        #expect(none.count == 0)

        // G overlaps E by exactly 10 points: min(100, 300) - max(0, 90) = 10.
        let g = Self.horizontal(3, y: 300, from: 90, to: 300)
        let touching = try GeometryQueryEngine(segments: [e, g])
        let any = touching.parallelPairs(gap: 300, tolerance: 1, minimumOverlap: 0)
        #expect(any.count == 1)
        #expect(abs(try #require(any.matches.first).overlapLengthPoints - 10) < 1e-9)

        let demanding = touching.parallelPairs(gap: 300, tolerance: 1, minimumOverlap: 50)
        #expect(demanding.count == 0)

        print(
            "noProjectedOverlapIsNotAPair: disjoint -> \(none.count) pairs, "
                + "10 pt overlap at minimumOverlap 0 -> \(any.count) pair, "
                + "at minimumOverlap 50 -> \(demanding.count) pairs"
        )
    }

    @Test("Query parameters read in real-world units through pointsPerUnit")
    func parametersReadInRealWorldUnits() throws {
        // A 1:50 drawing. One millimetre on the ground is 72/25.4/50 page points.
        // 300 mm of wall separation is therefore 17.00787401574803 page points.
        let pointsPerMillimetre = 72.0 / 25.4 / 50.0
        let gapInPoints = 300 * pointsPerMillimetre
        let a = Self.horizontal(1, y: 0, from: 0, to: 200)
        let b = Self.horizontal(2, y: gapInPoints, from: 0, to: 200)
        let engine = try GeometryQueryEngine(segments: [a, b], pointsPerUnit: pointsPerMillimetre)

        let found = engine.parallelPairs(gap: 300, tolerance: 1)
        #expect(found.count == 1)
        let pair = try #require(found.matches.first)
        // Geometry comes back in page points; the result converts it back for the caller.
        #expect(abs(pair.separationPoints - gapInPoints) < 1e-9)
        #expect(abs(found.units(fromPoints: pair.separationPoints) - 300) < 1e-9)

        let missed = engine.parallelPairs(gap: 200, tolerance: 1)
        #expect(missed.count == 0)

        print(
            "parametersReadInRealWorldUnits: 300 mm at 1:50 = \(gapInPoints) pt, "
                + "found \(found.count) pair, back-converted \(found.units(fromPoints: pair.separationPoints)) mm"
        )
    }

    // MARK: - Truncation

    @Test("A crowded page raises the truncation flag rather than shortening in silence")
    func crowdedPageTruncates() throws {
        // Forty horizontal lines at y = 0, 300, 600, ... 11 700, each spanning x in [0, 1000].
        // Consecutive lines are 300 apart and every other spacing is a multiple of 300,
        // so at gap 300 there are exactly 39 pairs.
        let lines = (0..<40).map { index in
            Self.horizontal(UInt64(index + 1), y: Double(index) * 300, from: 0, to: 1000)
        }
        let engine = try GeometryQueryEngine(segments: lines)

        let complete = engine.parallelPairs(gap: 300, tolerance: 1)
        #expect(complete.count == 39)
        #expect(complete.status == .complete)
        #expect(!complete.truncated)

        let capped = engine.parallelPairs(gap: 300, tolerance: 1, resultLimit: 10)
        #expect(capped.count == 10)
        #expect(capped.truncated)
        #expect(capped.truncationLimit == 10)
        #expect(capped.status == .truncated(limit: 10))

        // The boundary: a limit exactly equal to the number of matches is not a truncation.
        let exact = engine.parallelPairs(gap: 300, tolerance: 1, resultLimit: 39)
        #expect(exact.count == 39)
        #expect(!exact.truncated)

        print(
            "crowdedPageTruncates: 40 lines -> \(complete.count) pairs uncapped, "
                + "\(capped.count) capped at 10 (truncated \(capped.truncated)), "
                + "\(exact.count) capped at 39 (truncated \(exact.truncated))"
        )
    }

    @Test("A rejected parameter says which one, instead of returning an innocent empty list")
    func rejectedParametersAreNamed() throws {
        let engine = try GeometryQueryEngine(segments: [Self.horizontal(1, y: 0, from: 0, to: 10)])
        #expect(engine.parallelPairs(gap: -1, tolerance: 1).wasRejected)
        #expect(engine.segments(ofLength: 10, tolerance: -1).wasRejected)
        #expect(engine.circles(radius: 0, tolerance: 1).wasRejected)
        #expect(engine.parallelPairs(gap: 1, tolerance: 1, resultLimit: 0).wasRejected)
        #expect(throws: VectorExtractionError.self) {
            _ = try GeometryQueryEngine(segments: [], pointsPerUnit: 0)
        }
        print("rejectedParametersAreNamed: four rejected queries and one rejected engine")
    }

    // MARK: - Lengths

    @Test("The length query is exact, and a near miss falls outside a tight tolerance")
    func lengthQueryExactAndNearMiss() throws {
        // Lengths by construction: 100 exactly, 100.4 exactly, and a 300-400-500 triple.
        let hundred = Self.horizontal(1, y: 0, from: 0, to: 100)
        let nearMiss = Self.horizontal(2, y: 50, from: 0, to: 100.4)
        let fiveHundred = Self.segment(3, 0, 100, 300, 500)
        let engine = try GeometryQueryEngine(segments: [hundred, nearMiss, fiveHundred])

        let loose = engine.segments(ofLength: 100, tolerance: 0.5)
        #expect(loose.count == 2)
        #expect(loose.matches.map(\.primitiveID) == [1, 2])

        let tight = engine.segments(ofLength: 100, tolerance: 0.25)
        #expect(tight.count == 1)
        #expect(try #require(tight.matches.first).primitiveID == 1)
        #expect(abs(try #require(tight.matches.first).lengthPoints - 100) < 1e-9)

        let triple = engine.segments(ofLength: 500, tolerance: 1e-9)
        #expect(triple.count == 1)
        #expect(abs(try #require(triple.matches.first).lengthPoints - 500) < 1e-9)

        let nothing = engine.segments(ofLength: 250, tolerance: 0.5)
        #expect(nothing.count == 0)
        #expect(nothing.examinedCount == 3)

        print(
            "lengthQueryExactAndNearMiss: 100 +/- 0.5 -> \(loose.count), "
                + "100 +/- 0.25 -> \(tight.count), 500 +/- 1e-9 -> \(triple.count), "
                + "250 +/- 0.5 -> \(nothing.count)"
        )
    }

    // MARK: - Circles

    @Test("A four-cubic circle is found by radius, and another radius is not")
    func circleFoundByRadius() throws {
        // The standard four-arc cubic approximation of a circle of radius 144 at (306, 396),
        // control offset K*R with K = 4/3*(sqrt(2)-1) = 0.5522847498307935.
        // Its maximum radial deviation from the true circle is 2.725300074275516e-4 * R
        // = 0.03924432106956743 page points — the fixture manifest's own closed form.
        let centre = CGPoint(x: 306, y: 396)
        let radius = 144.0
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1) * radius
        let curves = Self.circleCurves(centre: centre, radius: radius, control: k)
        let engine = try GeometryQueryEngine(segments: [], curves: curves)

        let found = engine.circles(radius: 144, tolerance: 0.5)
        #expect(found.count == 1)
        let circle = try #require(found.matches.first)
        #expect(abs(circle.center.x - 306) < 0.05)
        #expect(abs(circle.center.y - 396) < 0.05)
        #expect(abs(circle.radiusPoints - 144) < 0.5)
        #expect(abs(circle.sweepRadians - 2 * .pi) < 1e-9)
        #expect(circle.maximumFitDeviationPoints < 0.05)
        #expect(circle.primitiveIDs.count == 4)

        let wrongRadius = engine.circles(radius: 100, tolerance: 0.5)
        #expect(wrongRadius.count == 0)

        print(
            "circleFoundByRadius: fitted radius \(circle.radiusPoints), "
                + "centre (\(circle.center.x), \(circle.center.y)), "
                + "sweep \(circle.sweepRadians) rad, deviation \(circle.maximumFitDeviationPoints) pt; "
                + "radius 100 -> \(wrongRadius.count) matches"
        )
    }

    @Test("A rounded rectangle's corner arcs do not fit one circle")
    func roundedRectangleIsNotACircle() throws {
        // Four quarter-circle arcs of radius 20, one at each corner of a 200 x 120 box.
        // They share a subpath but not a centre, so no single circle fits them.
        let r = 20.0
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1) * r
        var curves: [GeometryQueryCurve] = []
        let corners = [
            CGPoint(x: 20, y: 20), CGPoint(x: 180, y: 20),
            CGPoint(x: 180, y: 100), CGPoint(x: 20, y: 100)
        ]
        for (index, corner) in corners.enumerated() {
            let start = Double(index) * .pi / 2
            curves.append(
                GeometryQueryCurve(
                    primitiveID: UInt64(index + 1),
                    sourceObjectID: 1,
                    subpathIndex: 0,
                    cubic: Self.arc(centre: corner, radius: r, control: k, startAngle: start)
                )
            )
        }
        let engine = try GeometryQueryEngine(segments: [], curves: curves)
        let found = engine.circles(radius: 20, tolerance: 5)
        #expect(found.count == 0)
        #expect(found.examinedCount == 1)
        print("roundedRectangleIsNotACircle: \(found.examinedCount) chain examined, \(found.count) circles")
    }

    @Test("Exactly `resultLimit` circles is a complete answer, one more is truncated (CR-46)")
    func exactlyLimitCirclesIsComplete() throws {
        // Three four-cubic circles of radius 144, each its own subpath.
        let radius = 144.0
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1) * radius
        var curves: [GeometryQueryCurve] = []
        for circle in 0..<3 {
            let centre = CGPoint(x: 306 + Double(circle) * 400, y: 396)
            for index in 0..<4 {
                curves.append(
                    GeometryQueryCurve(
                        primitiveID: UInt64(circle * 10 + index + 1),
                        sourceObjectID: UInt64(circle + 1),
                        subpathIndex: 0,
                        cubic: Self.arc(
                            centre: centre, radius: radius, control: k,
                            startAngle: Double(index) * .pi / 2
                        )
                    )
                )
            }
        }
        let engine = try GeometryQueryEngine(segments: [], curves: curves)

        // Old output: `status == .truncated(limit: 3)` and `truncated == true` for a page
        // holding exactly three matches — the cap was declared reached after the third
        // append, whether or not a fourth existed.
        let exact = engine.circles(radius: 144, tolerance: 0.5, resultLimit: 3)
        #expect(exact.count == 3)
        #expect(!exact.truncated)
        #expect(exact.status == .complete)
        #expect(exact.examinedCount == 3)

        let capped = engine.circles(radius: 144, tolerance: 0.5, resultLimit: 2)
        #expect(capped.count == 2)
        #expect(capped.truncated)
        #expect(capped.status == .truncated(limit: 2))

        let roomy = engine.circles(radius: 144, tolerance: 0.5, resultLimit: 4)
        #expect(roomy.count == 3)
        #expect(!roomy.truncated)
        print(
            "exactlyLimitCirclesIsComplete: limit 3 -> \(exact.count) (truncated \(exact.truncated)), "
                + "limit 2 -> \(capped.count) (truncated \(capped.truncated))"
        )
    }

    /// One quarter-arc of a circle as a cubic, starting at `startAngle` and turning
    /// counter-clockwise. The standard construction: tangent control points at `control`
    /// from each endpoint.
    static func arc(centre: CGPoint, radius: Double, control: Double, startAngle: Double) -> VectorCubic {
        let endAngle = startAngle + .pi / 2
        let p0 = CGPoint(x: centre.x + radius * cos(startAngle), y: centre.y + radius * sin(startAngle))
        let p3 = CGPoint(x: centre.x + radius * cos(endAngle), y: centre.y + radius * sin(endAngle))
        let p1 = CGPoint(x: p0.x - control * sin(startAngle), y: p0.y + control * cos(startAngle))
        let p2 = CGPoint(x: p3.x + control * sin(endAngle), y: p3.y - control * cos(endAngle))
        return VectorCubic(p0: p0, p1: p1, p2: p2, p3: p3)
    }

    static func circleCurves(centre: CGPoint, radius: Double, control: Double) -> [GeometryQueryCurve] {
        (0..<4).map { index in
            GeometryQueryCurve(
                primitiveID: UInt64(index + 1),
                sourceObjectID: 1,
                subpathIndex: 0,
                cubic: arc(
                    centre: centre,
                    radius: radius,
                    control: control,
                    startAngle: Double(index) * .pi / 2
                )
            )
        }
    }

    // MARK: - Over a real extraction

    @Test("Over the extracted rectangle fixture, both facing pairs are found once each")
    func rectangleFixtureThroughTheEngine() async throws {
        // The fixture is 288 x 180 at (72, 72), stroked. Extraction emits four
        // `.lineSegment` children plus one `.closedSubpath` parent, so an engine that read
        // edges off the parent as well would report every wall twice.
        let (extraction, _, directory) = try await ExtractionTestSupport.extract(.rectangle)
        defer { ExtractionTestSupport.remove(directory) }
        #expect(extraction.availability == .available)

        let engine = try GeometryQueryEngine(page: extraction)
        #expect(engine.segments.count == 4)
        #expect(engine.curves.isEmpty)

        // Bottom y = 72 and top y = 252: separation 180, facing span 288.
        let short = engine.parallelPairs(gap: 180, tolerance: 1e-6)
        #expect(short.count == 1)
        let shortPair = try #require(short.matches.first)
        #expect(abs(shortPair.separationPoints - 180) < 1e-9)
        #expect(abs(shortPair.overlapLengthPoints - 288) < 1e-9)

        // Left x = 72 and right x = 360: separation 288, facing span 180.
        let long = engine.parallelPairs(gap: 288, tolerance: 1e-6)
        #expect(long.count == 1)
        let longPair = try #require(long.matches.first)
        #expect(abs(longPair.separationPoints - 288) < 1e-9)
        #expect(abs(longPair.overlapLengthPoints - 180) < 1e-9)

        // Two edges of length 288 and two of length 180.
        #expect(engine.segments(ofLength: 288, tolerance: 1e-9).count == 2)
        #expect(engine.segments(ofLength: 180, tolerance: 1e-9).count == 2)
        #expect(engine.circles(radius: 100, tolerance: 50).count == 0)

        print(
            "rectangleFixtureThroughTheEngine: \(extraction.primitives.count) primitives -> "
                + "\(engine.segments.count) segments; gap 180 -> \(short.count), gap 288 -> \(long.count)"
        )
    }

    @Test("Over the extracted Bezier-circle fixture, the fitted radius is 144")
    func bezierCircleFixtureThroughTheEngine() async throws {
        // Manifest closed form: centre (306, 396), radius 144, drawn as the four-cubic
        // approximation whose maximum radial deviation is 0.03924432106956743 points.
        let (extraction, _, directory) = try await ExtractionTestSupport.extract(.bezierCircle)
        defer { ExtractionTestSupport.remove(directory) }
        #expect(extraction.availability == .available)

        let engine = try GeometryQueryEngine(page: extraction)
        #expect(engine.curves.count == 4)

        let found = engine.circles(radius: 144, tolerance: 0.5)
        #expect(found.count == 1)
        let circle = try #require(found.matches.first)
        #expect(abs(circle.center.x - 306) < 0.05)
        #expect(abs(circle.center.y - 396) < 0.05)
        #expect(abs(circle.radiusPoints - 144) < 0.5)
        #expect(circle.maximumFitDeviationPoints < 0.05)
        #expect(engine.circles(radius: 72, tolerance: 0.5).count == 0)

        print(
            "bezierCircleFixtureThroughTheEngine: \(engine.curves.count) cubics -> "
                + "radius \(circle.radiusPoints) at (\(circle.center.x), \(circle.center.y)), "
                + "deviation \(circle.maximumFitDeviationPoints) pt"
        )
    }
}
