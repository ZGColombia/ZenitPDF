import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// One-click auto-trace: follow the boundary round a clicked point, or refuse and say where the
/// boundary stops.
///
/// Every expected area in this suite is hand-derived from the fixture's own coordinates and
/// written as a literal, and every area assertion is checked against a shoelace implemented in
/// this file — as a fan of triangles about the first vertex, which is a different expression
/// from the edge-crossing sum the engine uses. No assertion here reads its expected value from
/// the code under test.
@Suite("Region tracer")
struct RegionTracerTests {

    // MARK: - Fixtures

    /// A line primitive. Only the fields the tracer reads carry meaning; the rest are the
    /// neutral values the extractor emits for an ordinary stroked path.
    static func line(
        _ id: UInt64,
        _ x0: Double, _ y0: Double,
        _ x1: Double, _ y1: Double
    ) -> VectorPrimitive {
        let start = CGPoint(x: x0, y: y0)
        let end = CGPoint(x: x1, y: y1)
        return VectorPrimitive(
            id: id,
            parentID: nil,
            kind: .lineSegment,
            geometry: .line(VectorLine(start: start, end: end)),
            bounds: VectorBounds(point: start).union(end),
            sourceObjectID: id,
            subpathIndex: 0,
            nestingDepth: 0,
            paint: .stroked,
            strokeWidth: 0.5,
            strokeIsDashed: false,
            clipRelation: .unclipped,
            clipBounds: nil,
            confidence: 1.0,
            layerID: nil
        )
    }

    /// A `re` rectangle primitive, the way the extractor stores one: four transformed corners.
    static func rectangle(
        _ id: UInt64,
        x: Double, y: Double, width: Double, height: Double
    ) -> VectorPrimitive {
        let quad = VectorQuad(
            c0: CGPoint(x: x, y: y),
            c1: CGPoint(x: x + width, y: y),
            c2: CGPoint(x: x + width, y: y + height),
            c3: CGPoint(x: x, y: y + height)
        )
        return VectorPrimitive(
            id: id,
            parentID: nil,
            kind: .rectangle,
            geometry: .rectangle(quad),
            bounds: quad.bounds,
            sourceObjectID: id,
            subpathIndex: 0,
            nestingDepth: 0,
            paint: .stroked,
            strokeWidth: 0.5,
            strokeIsDashed: false,
            clipRelation: .unclipped,
            clipBounds: nil,
            confidence: 1.0,
            layerID: nil
        )
    }

    /// A cubic whose control points sit on its own chord, so it is geometrically a straight
    /// segment and the flattener returns the chord exactly. That keeps the closed-form area of
    /// the fixture exact while still exercising the curve path through the collector.
    static func straightCubic(
        _ id: UInt64,
        _ x0: Double, _ y0: Double,
        _ x1: Double, _ y1: Double
    ) -> VectorPrimitive {
        let p0 = CGPoint(x: x0, y: y0)
        let p3 = CGPoint(x: x1, y: y1)
        let p1 = CGPoint(x: x0 + (x1 - x0) / 3, y: y0 + (y1 - y0) / 3)
        let p2 = CGPoint(x: x0 + 2 * (x1 - x0) / 3, y: y0 + 2 * (y1 - y0) / 3)
        let cubic = VectorCubic(p0: p0, p1: p1, p2: p2, p3: p3)
        return VectorPrimitive(
            id: id,
            parentID: nil,
            kind: .cubicCurve,
            geometry: .cubic(cubic),
            bounds: cubic.bounds,
            sourceObjectID: id,
            subpathIndex: 0,
            nestingDepth: 0,
            paint: .stroked,
            strokeWidth: 0.5,
            strokeIsDashed: false,
            clipRelation: .unclipped,
            clipBounds: nil,
            confidence: 1.0,
            layerID: nil
        )
    }

    /// The four walls of an axis-aligned room, as four independent strokes.
    static func walls(
        from base: UInt64,
        minX: Double, minY: Double, maxX: Double, maxY: Double
    ) -> [VectorPrimitive] {
        [
            line(base, minX, minY, maxX, minY),
            line(base + 1, maxX, minY, maxX, maxY),
            line(base + 2, maxX, maxY, minX, maxY),
            line(base + 3, minX, maxY, minX, minY)
        ]
    }

    // MARK: - Independent geometry, written here rather than borrowed

    /// Shoelace as a fan of triangles about the first vertex.
    static func fanArea(_ ring: [PDFPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        let origin = ring[0]
        var total = 0.0
        for index in 1..<(ring.count - 1) {
            let a = ring[index]
            let b = ring[index + 1]
            total += (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
        }
        return abs(total) / 2
    }

    static func contains(_ ring: [PDFPoint], _ point: PDFPoint, tolerance: Double = 1e-12) -> Bool {
        ring.contains { abs($0.x - point.x) <= tolerance && abs($0.y - point.y) <= tolerance }
    }

    // MARK: - The plain case

    @Test("A rectangle of four strokes traces to its four corners")
    func plainRectangle() throws {
        let primitives = Self.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))

        let region = try #require(result.region, "expected a traced region, got \(result)")
        #expect(region.ring.count == 4)
        // 100 x 80 = 8000 square page points, by hand.
        #expect(abs(region.area - 8000) <= 1e-9)
        #expect(abs(Self.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(abs(region.perimeter - 360) <= 1e-9)
        #expect(region.bridgedGapCount == 0)
        #expect(region.largestBridgedGap == 0)

        for corner in [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
                       PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)] {
            #expect(Self.contains(region.ring, corner), "corner \(corner) missing from ring")
        }
        // Canonical: lexicographically smallest vertex first, counter-clockwise after it.
        #expect(region.ring[0] == PDFPoint(x: 0, y: 0))
        #expect(region.ring[1] == PDFPoint(x: 100, y: 0))
    }

    @Test("A rectangle stored as one `re` primitive traces to the same ring")
    func rectanglePrimitive() throws {
        let result = RegionTracer.trace(
            primitives: [Self.rectangle(1, x: 10, y: 20, width: 60, height: 40)],
            click: PDFPoint(x: 40, y: 40)
        )
        let region = try #require(result.region, "expected a traced region, got \(result)")
        #expect(region.ring.count == 4)
        // 60 x 40 = 2400.
        #expect(abs(region.area - 2400) <= 1e-9)
        #expect(abs(Self.fanArea(region.ring) - 2400) <= 1e-9)
        #expect(region.ring[0] == PDFPoint(x: 10, y: 20))
    }

    @Test("A Bézier circle traces as its outline, not as the square of its vertices (CR-36)")
    func bezierCircleTracesAsCircle() throws {
        // The extractor's five primitives for a four-Bézier circle of radius 144 at
        // (306, 396): the closed subpath as a ring of its four axis vertices, marked as
        // containing curves, and the four cubics as its children.
        let centre = CGPoint(x: 306, y: 396)
        let r = 144.0
        let k = 4.0 / 3.0 * (2.0.squareRoot() - 1) * r
        let east = CGPoint(x: centre.x + r, y: centre.y)
        let north = CGPoint(x: centre.x, y: centre.y + r)
        let west = CGPoint(x: centre.x - r, y: centre.y)
        let south = CGPoint(x: centre.x, y: centre.y - r)
        let cubics = [
            VectorCubic(p0: east, p1: CGPoint(x: centre.x + r, y: centre.y + k), p2: CGPoint(x: centre.x + k, y: centre.y + r), p3: north),
            VectorCubic(p0: north, p1: CGPoint(x: centre.x - k, y: centre.y + r), p2: CGPoint(x: centre.x - r, y: centre.y + k), p3: west),
            VectorCubic(p0: west, p1: CGPoint(x: centre.x - r, y: centre.y - k), p2: CGPoint(x: centre.x - k, y: centre.y - r), p3: south),
            VectorCubic(p0: south, p1: CGPoint(x: centre.x + k, y: centre.y - r), p2: CGPoint(x: centre.x + r, y: centre.y - k), p3: east)
        ]
        func primitive(_ id: UInt64, parentID: UInt64?, kind: VectorPrimitiveKind, geometry: VectorGeometry, bounds: VectorBounds) -> VectorPrimitive {
            VectorPrimitive(
                id: id, parentID: parentID, kind: kind, geometry: geometry, bounds: bounds,
                sourceObjectID: 1, subpathIndex: 0, nestingDepth: 0, paint: .stroked, strokeWidth: 0.5,
                strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil, confidence: 1, layerID: nil
            )
        }
        var primitives = [
            primitive(1, parentID: nil, kind: .closedSubpath,
                      geometry: .ring(VectorRing(vertices: [east, north, west, south], isClosed: true, containsCurves: true)),
                      bounds: VectorBounds(minX: centre.x - r, minY: centre.y - r, maxX: centre.x + r, maxY: centre.y + r))
        ]
        for (index, cubic) in cubics.enumerated() {
            primitives.append(primitive(UInt64(index + 2), parentID: 1, kind: .cubicCurve, geometry: .cubic(cubic), bounds: cubic.bounds))
        }

        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: centre.x, y: centre.y))
        guard case .traced(let region) = result else {
            Issue.record("expected a traced region, got \(result)")
            return
        }
        // The exact area inside the four-Bézier loop is r² (−3/5 K² + 12/5 K + 2) with
        // K = 4/3 (√2 − 1) — 65 144.9…, against πr² = 65 144.1… (the fixture manifest's
        // own closed form). The traced polygon is inscribed in the flattened curve, so it is
        // under that by at most perimeter × flatness ≈ 905 × 0.05 ≈ 45.
        let kk = 4.0 / 3.0 * (2.0.squareRoot() - 1)
        let bezierArea = r * r * (-0.6 * kk * kk + 2.4 * kk + 2.0)
        // Old output: area 41 472 — the inscribed square 2r², the four chords through the
        // vertices traced as the boundary while the arcs stood outside it.
        #expect(region.area <= bezierArea + 1e-6, "area \(region.area)" as Comment)
        #expect(region.area >= bezierArea - 60, "area \(region.area)" as Comment)
        #expect(region.bridgedGapCount == 0)
    }

    @Test("A wall stored as a cubic reaches the arrangement through the flattener")
    func cubicWall() throws {
        var primitives = [
            Self.line(1, 0, 0, 100, 0),
            Self.line(2, 100, 0, 100, 80),
            Self.line(3, 100, 80, 0, 80)
        ]
        // The fourth wall, drawn as a curve whose control points lie on its chord.
        primitives.append(Self.straightCubic(4, 0, 80, 0, 0))

        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))
        let region = try #require(result.region, "expected a traced region, got \(result)")
        #expect(abs(region.area - 8000) <= 1e-9)
        #expect(abs(Self.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(region.ring.count == 4)

        // Without the fourth wall the same click has no closed boundary — proof the curve is
        // what closed it, rather than the other three strokes closing by themselves.
        let withoutCurve = RegionTracer.trace(
            primitives: Array(primitives.prefix(3)),
            click: PDFPoint(x: 50, y: 40)
        )
        #expect(withoutCurve.isRefusal)
    }

    // MARK: - Crossings

    @Test("Dimension lines crossing the walls do not change the ring")
    func dimensionLinesCrossingWalls() throws {
        var primitives = Self.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        // Through the left wall at (0, 40), reaching 25 pt into the room.
        primitives.append(Self.line(10, -25, 40, 25, 40))
        // Through the top wall at (60, 80), reaching 15 pt into the room.
        primitives.append(Self.line(11, 60, 95, 60, 65))
        // Entirely outside, crossing nothing.
        primitives.append(Self.line(12, -40, -10, 140, -10))

        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))
        let region = try #require(result.region, "expected a traced region, got \(result)")

        #expect(region.ring.count == 4, "ring was \(region.ring)")
        #expect(abs(region.area - 8000) <= 1e-9)
        #expect(abs(Self.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(region.bridgedGapCount == 0)
        for corner in [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0),
                       PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)] {
            #expect(Self.contains(region.ring, corner))
        }
    }

    // MARK: - Neighbours

    @Test("Two rooms sharing a wall trace one room each, never their union")
    func adjacentRooms() throws {
        // Each room is drawn as its own four walls, so the shared wall at x = 100 is stroked
        // twice — the ordinary case in an exported plan.
        let primitives =
            Self.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
            + Self.walls(from: 10, minX: 100, minY: 0, maxX: 200, maxY: 80)

        let left = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))
        let right = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 150, y: 40))

        let leftRegion = try #require(left.region, "left click: \(left)")
        let rightRegion = try #require(right.region, "right click: \(right)")

        // 100 x 80 each; their union would be 16000 and is the failure this test exists for.
        #expect(abs(leftRegion.area - 8000) <= 1e-9)
        #expect(abs(rightRegion.area - 8000) <= 1e-9)
        #expect(abs(Self.fanArea(leftRegion.ring) - 8000) <= 1e-9)
        #expect(abs(Self.fanArea(rightRegion.ring) - 8000) <= 1e-9)

        #expect(leftRegion.ring.count == 4)
        #expect(rightRegion.ring.count == 4)
        #expect(leftRegion.ring[0] == PDFPoint(x: 0, y: 0))
        #expect(rightRegion.ring[0] == PDFPoint(x: 100, y: 0))
        #expect(Self.contains(leftRegion.ring, PDFPoint(x: 100, y: 80)))
        #expect(!Self.contains(leftRegion.ring, PDFPoint(x: 200, y: 80)))
        #expect(!Self.contains(rightRegion.ring, PDFPoint(x: 0, y: 0)))
    }

    // MARK: - The refusal

    @Test("A ten-point gap is refused, and the refusal points at the gap")
    func tenPointGapIsRefused() {
        var primitives = [
            Self.line(1, 0, 0, 45, 0),
            Self.line(2, 55, 0, 100, 0)
        ]
        primitives.append(Self.line(3, 100, 0, 100, 80))
        primitives.append(Self.line(4, 100, 80, 0, 80))
        primitives.append(Self.line(5, 0, 80, 0, 0))

        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))

        guard case .notClosed(let gap) = result else {
            Issue.record("a 10 pt break must be refused, got \(result)")
            return
        }
        guard let gap else {
            Issue.record("the refusal must name where the boundary stops")
            return
        }
        // The break spans (45, 0) to (55, 0); its middle is (50, 0).
        #expect(abs(gap.x - 50) <= 1e-9, "gap.x was \(gap.x)")
        #expect(abs(gap.y - 0) <= 1e-9, "gap.y was \(gap.y)")
    }

    @Test("A two-point join inside the tolerance closes; the same break outside it does not")
    func twoPointJoinClosesAndAWiderToleranceIsNotAssumed() throws {
        let primitives = [
            Self.line(1, 0, 0, 49, 0),
            Self.line(2, 51, 0, 100, 0),
            Self.line(3, 100, 0, 100, 80),
            Self.line(4, 100, 80, 0, 80),
            Self.line(5, 0, 80, 0, 0)
        ]

        // Default gap tolerance is 3 pt: a 2 pt break is a join, and the join is declared.
        let joined = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))
        let region = try #require(joined.region, "expected a traced region, got \(joined)")
        #expect(abs(region.area - 8000) <= 1e-9)
        #expect(abs(Self.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(region.ring.count == 4)
        #expect(region.bridgedGapCount == 1)
        #expect(abs(region.largestBridgedGap - 2) <= 1e-12)

        // Below the tolerance the same drawing is refused. Nothing about the geometry changed;
        // only the number the interface is showing the user did.
        let strict = TraceOptions(gapTolerance: 1.5)
        let refused = RegionTracer.trace(
            primitives: primitives,
            click: PDFPoint(x: 50, y: 40),
            options: strict
        )
        #expect(refused.isRefusal, "a 2 pt break under a 1.5 pt tolerance must be refused")
        if case .notClosed(let gap) = refused, let gap {
            #expect(abs(gap.x - 50) <= 1e-9)
            #expect(abs(gap.y) <= 1e-9)
        } else {
            Issue.record("expected a located refusal, got \(refused)")
        }
    }

    @Test("A door onto a corridor is refused, not traced as room plus corridor")
    func doorOntoACorridorIsRefused() throws {
        // A 25 pt door opening in the room's bottom wall, with a corridor on the other side of
        // it. There is no broken loop here to catch: room and corridor together *are* a closed
        // loop, of area 100 x 140 = 14000, and handing that back as the room is the worst
        // number this product could produce.
        let primitives = [
            Self.line(1, 0, 0, 37, 0),
            Self.line(2, 62, 0, 100, 0),
            Self.line(3, 100, 0, 100, 80),
            Self.line(4, 100, 80, 0, 80),
            Self.line(5, 0, 80, 0, 0),
            // The corridor below.
            Self.line(6, 0, -60, 100, -60),
            Self.line(7, 0, -60, 0, 0),
            Self.line(8, 100, -60, 100, 0)
        ]
        let click = PDFPoint(x: 50, y: 40)

        for tolerance in [1.0, 3.0, 10.0, 24.0] {
            let result = RegionTracer.trace(
                primitives: primitives,
                click: click,
                options: TraceOptions(gapTolerance: tolerance)
            )
            guard case .notClosed(let gap) = result else {
                Issue.record(
                    "a 25 pt opening must be refused at gapTolerance \(tolerance), got \(result)"
                )
                continue
            }
            let located = try #require(gap, "the refusal must name the opening")
            // The opening spans (37, 0) to (62, 0); its middle is (49.5, 0).
            #expect(abs(located.x - 49.5) <= 1e-9, "gap.x was \(located.x)")
            #expect(abs(located.y) <= 1e-9, "gap.y was \(located.y)")
        }

        // The tolerance is the only thing that changes the answer, and it says so: told that a
        // 26 pt break is a join, the same drawing traces the room alone and declares the 25 pt
        // distance it used.
        let permissive = RegionTracer.trace(
            primitives: primitives,
            click: click,
            options: TraceOptions(gapTolerance: 26)
        )
        let region = try #require(permissive.region, "expected a traced region, got \(permissive)")
        #expect(abs(region.area - 8000) <= 1e-9)
        #expect(abs(Self.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(region.bridgedGapCount == 1)
        #expect(abs(region.largestBridgedGap - 25) <= 1e-12)
    }

    @Test("A click outside every boundary is refused")
    func clickOutsideEverything() {
        let primitives = Self.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)

        // Far away: no ray from here crosses anything.
        let faraway = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 300, y: 300))
        #expect(faraway.isRefusal)
        #expect(faraway == .notClosed(gapAt: nil))

        // Just outside the left wall: rays do cross the room, and the walk lands on the
        // unbounded face rather than on the room.
        let beside = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: -20, y: 40))
        #expect(beside.isRefusal, "expected the outer face to be refused, got \(beside)")
        #expect(beside.region == nil)
    }

    @Test("An empty page is refused rather than guessed at")
    func emptyPage() {
        #expect(
            RegionTracer.trace(primitives: [], click: PDFPoint(x: 10, y: 10))
                == .notClosed(gapAt: nil)
        )
    }

    // MARK: - Limits

    @Test("A quarter of a million primitives is refused, quickly")
    func tooComplexPageIsRefusedFast() {
        var primitives: [VectorPrimitive] = []
        primitives.reserveCapacity(250_000)
        for index in 0..<250_000 {
            let y = Double(index % 500)
            let x = Double(index / 500)
            primitives.append(Self.line(UInt64(index + 1), x, y, x + 0.5, y + 0.5))
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 10, y: 10))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        #expect(result == .tooComplex(count: 250_000), "got \(result)")
        #expect(elapsed < 2.0, "refusal took \(elapsed) s")
    }

    @Test("A page under the cap is traced; the cap is what refuses, not the tracer giving up")
    func capIsTheOnlyThingThatRefusesALargePage() throws {
        // The same room, under a cap of four primitives and then under a cap of three.
        let primitives = Self.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)

        let allowed = RegionTracer.trace(
            primitives: primitives,
            click: PDFPoint(x: 50, y: 40),
            options: TraceOptions(maximumPrimitives: 4)
        )
        let region = try #require(allowed.region, "expected a traced region, got \(allowed)")
        #expect(abs(region.area - 8000) <= 1e-9)

        let refused = RegionTracer.trace(
            primitives: primitives,
            click: PDFPoint(x: 50, y: 40),
            options: TraceOptions(maximumPrimitives: 3)
        )
        #expect(refused == .tooComplex(count: 4))
    }

    @Test("Every work cap refuses rather than grinds")
    func everyCapRefuses() {
        let primitives = Self.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        let click = PDFPoint(x: 50, y: 40)

        // Segments, counted after curves are flattened and rings expanded.
        let segmentCapped = RegionTracer.trace(
            primitives: primitives,
            click: click,
            options: TraceOptions(maximumSegments: 2)
        )
        #expect(segmentCapped == .tooComplex(count: 3), "got \(segmentCapped)")

        // Crossing tests in the arrangement sweep.
        let pairCapped = RegionTracer.trace(
            primitives: primitives,
            click: click,
            options: TraceOptions(maximumPairTests: 1)
        )
        if case .tooComplex(let count) = pairCapped {
            #expect(count >= 1)
        } else {
            Issue.record("expected the pair-test cap to refuse, got \(pairCapped)")
        }

        // Darts followed by the face walk. The two spurs make this face ten darts round, so a
        // cap of eight has to stop it.
        var spurred = primitives
        spurred.append(Self.line(10, -25, 40, 25, 40))
        spurred.append(Self.line(11, 60, 95, 60, 65))
        #expect(RegionTracer.trace(primitives: spurred, click: click).region != nil)

        let walkCapped = RegionTracer.trace(
            primitives: spurred,
            click: click,
            options: TraceOptions(maximumWalkSteps: 8)
        )
        if case .tooComplex(let count) = walkCapped {
            #expect(count > 8)
        } else {
            Issue.record("expected the walk cap to refuse, got \(walkCapped)")
        }
    }

    // MARK: - Determinism

    @Test("The ring does not depend on the order the primitives arrived in")
    func ringIsIndependentOfPrimitiveOrder() throws {
        var primitives =
            Self.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
            + Self.walls(from: 10, minX: 100, minY: 0, maxX: 200, maxY: 80)
        primitives.append(Self.line(30, -25, 40, 25, 40))

        let click = PDFPoint(x: 50, y: 40)
        let reference = try #require(RegionTracer.trace(primitives: primitives, click: click).region)

        // A fixed shuffle rather than a random one, so a failure here reproduces.
        for step in 1...primitives.count {
            let pivot: Int = step % primitives.count
            let tail: [VectorPrimitive] = Array(primitives[pivot...])
            let head: [VectorPrimitive] = Array(primitives[..<pivot])
            let rotated: [VectorPrimitive] = tail + head
            let result = try #require(RegionTracer.trace(primitives: rotated, click: click).region)
            #expect(result.ring == reference.ring, "rotation \(step) produced \(result.ring)")
            #expect(result.area == reference.area)
        }

        let reversed = try #require(
            RegionTracer.trace(primitives: Array(primitives.reversed()), click: click).region
        )
        #expect(reversed.ring == reference.ring)
    }
}
