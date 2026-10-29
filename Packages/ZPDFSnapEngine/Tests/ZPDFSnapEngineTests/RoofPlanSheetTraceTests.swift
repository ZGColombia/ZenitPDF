import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// L-73 / L-73b: ⌥-click tracing and Detect Rooms on a heavy A1 roof plan — the Synthetic Roof
/// Plan of `ZPDFTestingSupport` (16 341 vector primitives, a sedum annex drawn as 14 085 short
/// strokes, and dash-dot grid axes written one stroke per dash), which reproduces the structure
/// of a CAD-exported sheet of that kind.
///
/// Two defects stood between such a sheet and a traced room, and each test below states what the
/// old engine answered on a CAD-exported sheet of the same structure:
///
/// 1. **The bridging step drained the pair budget.** Every edge bridging appended was then tested
///    linearly by every later loose end. Over a sedum hatch whose glyph tips sit 2.47 pt apart
///    that is thousands of bridges, quadratic, so any window that reached the hatch came back
///    "too complex" and Detect Rooms refused the whole sheet.
/// 2. **A dash-dot axis read as a wall with a door.** The dash crossing each wall hangs into the
///    room as a spur; the two spur ends are collinear and face each other, which is the opening
///    signature, so every room an axis crossed was refused as not closed.
///
/// The re-check of that fix found three more, each stated where it is tested: a closed shape tied
/// to the boundary by one line was deducted from the area without a word; the traced note
/// quoted every join in the window instead of the ring's; and a split point that snapping moved
/// off its line let the face walk through the sedum roof's hip lines.
///
/// Every expected value is derived by hand in the comments from the coordinates the fixture is
/// built from (`SyntheticRoofPlan`); none was read back from the engine.
@Suite("Trace on a heavy A1 roof plan (L-73, L-73b)")
struct RoofPlanSheetTraceTests {

    /// Page 0 of the synthetic roof plan, generated into the shared fixture cache.
    static func roofPlan() async throws -> PreparedTrace {
        let handle = try ZPDFFixtures.shared(.syntheticRoofPlan)
        let extraction = try await VectorExtractor().extract(documentAt: handle.url, pageIndex: 0)
        // The hand-counted primitives (`FIXTURES.md`): the sheet the caps are meant for.
        #expect(extraction.primitives.count == 16_341, "\(extraction.primitives.count) primitives")
        return RegionTracer.prepare(primitives: extraction.primitives)
    }

    /// The sheet's printed scale, SKALA 1:50: one point is 50 × 0.0254 / 72 = 1.27 / 72 m.
    static let metresPerPoint = 1.27 / 72

    /// The app's room band at that scale (`ProjectWindowController.roomOptions`): 1 to 400 m²,
    /// at least 0.6 m wide, openings up to 2.5 m (`AutoTraceService.maximumClosureWidth`).
    static var roomOptions: RoomDetector.Options {
        let m = metresPerPoint
        return RoomDetector.Options(
            minimumArea: 1 / (m * m), maximumArea: 400 / (m * m),
            minimumWidth: 0.6 / m, maximumClosureWidth: 2.5 / m
        )
    }

    /// Even-odd containment, written here rather than borrowed from the engine.
    static func encloses(_ ring: [PDFPoint], _ point: PDFPoint) -> Bool {
        var inside = false
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + ring.count - 1) % ring.count]
            if (a.y > point.y) != (b.y > point.y),
               point.x < a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y) {
                inside.toggle()
            }
        }
        return inside
    }

    /// A click inside the east facet of the hip roof, between grid axes B and C, 14 pt east of
    /// axis 2.
    static let eastFacetClick = PDFPoint(x: 1420, y: 960)

    /// The east facet's ring, traced.
    static func eastFacet(_ prepared: PreparedTrace) throws -> TracedRegion {
        let outcome = RegionTracer.traceProposingClosures(
            prepared, click: eastFacetClick, maximumClosureWidth: 2.5 / metresPerPoint
        )
        guard case .traced(let region) = outcome else {
            Issue.record("expected the east facet traced, got \(outcome)")
            throw CancellationError()
        }
        return region
    }

    @Test("⌥-click inside a roof facet of the heavy sheet traces it closed, to the hand-derived area")
    func altClickTracesTheEastFacet() async throws {
        let prepared = try await Self.roofPlan()
        // Old output on a CAD-exported sheet of this structure, before the bridging grid:
        // `.refused(.tooComplex)` — the 1 536 pt window reached the sedum hatch and bridging
        // drained the 12 million pair tests. Here the same window, [1420 ± 768], reaches the annex's hatch at x 652…880.
        // With the grid but before the dashed-line rule: `.refused(.notClosed)` in the middle of
        // a grid axis, between the dash on the ridge and the dash on the eave.
        let region = try Self.eastFacet(prepared)

        // Hand-derived from the fixture's corners: the ridge foot (1200, 600), the eave corners
        // (1500, 300) and (1500, 1300), the hip kink (1340, 1120) and the ridge head (1200, 1000).
        // Over x = 1200…1500 the facet lies between the lower hip and the kinked upper hip:
        //   under the upper hip: 140 × (1000 + 1120) / 2 + 160 × (1120 + 1300) / 2
        //                      = 148 400 + 193 600 = 342 000
        //   under the lower hip: 300 × (600 + 300) / 2 = 135 000
        //   facet = 342 000 − 135 000 = 207 000 pt²
        // Axes A, B and C cross it with dashes on the hip, the ridge and the eave; none may cut it.
        #expect(Swift.abs(region.area - 207_000) <= 1e-6, "traced \(region.area) pt²")
        #expect(Swift.abs(RegionTracerTests.fanArea(region.ring) - 207_000) <= 1e-6)
        // At 1:50: 207 000 × (1.27 / 72)² = 207 000 × 1.6129 / 5184 = 64.403993 m².
        let squareMetres = region.area * Self.metresPerPoint * Self.metresPerPoint
        #expect(Swift.abs(squareMetres - 64.403_993_055) <= 1e-6, "\(squareMetres) m²")
        // The ring is the facet and nothing else: ridge foot, eave corners, hip kink, ridge head.
        // The nodes where the stub and the axis dashes meet the boundary are collinear and drop out.
        #expect(region.ring.count == 5, "\(region.ring)")
        for corner in [
            PDFPoint(x: 1200, y: 600), PDFPoint(x: 1500, y: 300), PDFPoint(x: 1500, y: 1300),
            PDFPoint(x: 1340, y: 1120), PDFPoint(x: 1200, y: 1000)
        ] {
            #expect(RegionTracerTests.contains(region.ring, corner, tolerance: 1e-6), "missing corner \(corner)")
        }
        // The snow guard, tied to the eave by its 14 pt stub at y = 620, is offered as a cutout,
        // never deducted (NL-AUTO-10): (1486 − 1483) × (760 − 480) = 3 × 280 = 840 pt².
        #expect(region.islands.count == 1, "\(region.islands)")
        let guardStrip = try #require(region.islands.first)
        #expect(guardStrip.count == 4, "\(guardStrip)")
        for corner in [
            PDFPoint(x: 1483, y: 480), PDFPoint(x: 1486, y: 480),
            PDFPoint(x: 1486, y: 760), PDFPoint(x: 1483, y: 760)
        ] {
            #expect(RegionTracerTests.contains(guardStrip, corner, tolerance: 1e-6), "missing guard corner \(corner)")
        }
        #expect(Swift.abs(RegionTracerTests.fanArea(guardStrip) - 840) <= 1e-6)
        // The ring runs along no bridged gap. Old output on a CAD-exported sheet: every join in
        // the window — the sedum hatch next door — quoted as the facet's.
        #expect(region.bridgedGapCount == 0)
        #expect(region.largestBridgedGap == 0)
    }

    /// The other clicks: the north, west and south facets of the hip roof, and the annex's three
    /// sedum faces. The annex clicks sit at y = 303.75 + 5·r, between two lattice rows of the
    /// hatch (rows span y = 305 + 5·r … + 2.5), so none lands inside a glyph.
    static let acrossTheSheet = [
        PDFPoint(x: 1250, y: 1250), PDFPoint(x: 950, y: 760), PDFPoint(x: 1200, y: 400),
        PDFPoint(x: 800, y: 418.75), PDFPoint(x: 800, y: 1178.75), PDFPoint(x: 600, y: 798.75)
    ]

    @Test("⌥-clicks across the sheet trace the facets and the sedum roof; none is refused")
    func altClicksAcrossTheSheet() async throws {
        let prepared = try await Self.roofPlan()
        let cap = 2.5 / Self.metresPerPoint
        var traced: [PDFPoint: TracedRegion] = [:]
        for click in Self.acrossTheSheet {
            let outcome = RegionTracer.traceProposingClosures(prepared, click: click, maximumClosureWidth: cap)
            // Old output on a CAD-exported sheet for the facets and the sedum roof:
            // `.refused(.tooComplex)` or, once the budget held, `.refused(.notClosed)` at a grid axis.
            guard case .traced(let region) = outcome else {
                Issue.record("click \(click): \(outcome)")
                continue
            }
            traced[click] = region
            #expect(Self.encloses(region.ring, click), "the ring must enclose its click \(click)")
            // One simple boundary: no vertex visited twice and no edge crossing another. Old
            // output: rings that walked round tied shapes and back, revisiting vertices.
            #expect(Set(region.ring).count == region.ring.count, "click \(click) revisits a vertex")
            #expect(!Self.selfCrosses(region.ring), "click \(click): the ring crosses itself")
            // The area is the ring's own, by an independent shoelace: nothing inside is deducted,
            // and every shape inside is offered instead.
            #expect(Swift.abs(RegionTracerTests.fanArea(region.ring) - region.area) <= 1e-9 * region.area)
            for island in region.islands {
                #expect(island.allSatisfy { Self.encloses(region.ring, $0) || region.ring.contains($0) },
                        "click \(click): an island outside its ring")
            }
            let squareMetres = region.area * Self.metresPerPoint * Self.metresPerPoint
            #expect(squareMetres > 0.3 && squareMetres < 120, "click \(click): \(squareMetres) m²")
        }

        // The hip roof's other facets, hand-derived from the fixture's corners:
        //   north (1200,1000) (1340,1120) (1500,1300) (900,1300): 600 × 1300 under y = 1300, less
        //     300 × (1300 + 1000) / 2 = 345 000 under the north-west hip and 342 000 under the kinked
        //     hip: 780 000 − 345 000 − 342 000 = 93 000 pt²
        //   west (900,300) (1200,600) (1200,1000) (900,1300): parallel sides 1000 and 400, 300
        //     apart: 300 × (1000 + 400) / 2 = 210 000 pt²
        //   south (900,300) (1500,300) (1200,600): 600 × 300 / 2 = 90 000 pt²
        for (click, area) in [
            (PDFPoint(x: 1250, y: 1250), 93_000.0), (PDFPoint(x: 950, y: 760), 210_000.0),
            (PDFPoint(x: 1200, y: 400), 90_000.0)
        ] {
            let facet = try #require(traced[click])
            #expect(Swift.abs(facet.area - area) <= 1e-6, "click \(click): \(facet.area)")
        }

        // The annex is three faces between two hip lines drawn from its west corners. Each face
        // carries hatch glyphs whose tips the tracer bridges into small closed cells. The cells
        // inside a face are below the island floor and are neither offered nor deducted; the
        // cells a bridge closes against a hip line are part of the face (`absorbingBridgedCells`),
        // so every face is exactly its hand-derived polygon. Old output, before that rule: the
        // lower face 88 146.90 and the middle face 243 548.59, each short by the cells along its
        // hips.
        let lower = (PDFPoint(x: 460, y: 300), PDFPoint(x: 880, y: 720))
        let upper = (PDFPoint(x: 460, y: 1300), PDFPoint(x: 880, y: 880))
        //   the middle face (460,300) (880,720) (880,880) (460,1300): parallel sides x = 460
        //   (1000 long) and x = 880 (160 long), 420 apart: 420 × (1000 + 160) / 2 = 243 600 pt².
        // Old output on a CAD-exported sheet: a ring that also enclosed points on either side of
        // the hips, one face on either side. A split point of a hip line had snapped 0.56 pt off
        // it, a hatch stroke beside it crossed the line between two nodes, and the face walk ran
        // through.
        let middle = try #require(traced[PDFPoint(x: 600, y: 798.75)])
        #expect(!Self.encloses(middle.ring, PDFPoint(x: 800, y: 418.75)))
        #expect(!Self.encloses(middle.ring, PDFPoint(x: 800, y: 1178.75)))
        // No vertex further across either hip line than the join tolerance (0.75 pt).
        #expect(middle.ring.allSatisfy { Self.side(of: $0, from: lower.0, to: lower.1) >= -0.75 })
        #expect(middle.ring.allSatisfy { Self.side(of: $0, from: upper.0, to: upper.1) <= 0.75 })
        #expect(Swift.abs(middle.area - 243_600) <= 1e-6, "\(middle.area)")
        #expect(middle.bridgedGapCount == 0, "the ring runs along the hips, not along the hatch's joins")
        //   the lower and upper faces: right triangles with legs 420 and 420, 420² / 2 = 88 200 pt².
        for click in [PDFPoint(x: 800, y: 418.75), PDFPoint(x: 800, y: 1178.75)] {
            let face = try #require(traced[click])
            #expect(Swift.abs(face.area - 88_200) <= 1e-6, "click \(click): \(face.area)")
            #expect(!Self.encloses(face.ring, PDFPoint(x: 600, y: 798.75)), "click \(click) leaked into the middle face")
        }
    }

    /// Signed distance of `point` from the line through `a` and `b`, positive on its left.
    static func side(of point: PDFPoint, from a: PDFPoint, to b: PDFPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx * (point.y - a.y) - dy * (point.x - a.x)) / (dx * dx + dy * dy).squareRoot()
    }

    /// `true` when two non-adjacent edges of the closed ring cross properly — written here rather
    /// than borrowed from the engine.
    static func selfCrosses(_ ring: [PDFPoint]) -> Bool {
        func cross(_ o: PDFPoint, _ a: PDFPoint, _ b: PDFPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let n = ring.count
        guard n > 3 else { return false }
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            for j in stride(from: i + 2, to: n, by: 1) where !(i == 0 && j == n - 1) {
                let c = ring[j], d = ring[(j + 1) % n]
                let d1 = cross(a, b, c), d2 = cross(a, b, d), d3 = cross(c, d, a), d4 = cross(c, d, b)
                if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
                    return true
                }
            }
        }
        return false
    }

    @Test("Detect Rooms reads the heavy sheet, and the east facet it proposes is the ⌥-click's ring")
    func detectRoomsOnTheHeavySheet() async throws {
        let prepared = try await Self.roofPlan()
        let result = RoomDetector.detect(prepared, options: Self.roomOptions)
        // Old output on a CAD-exported sheet: `.tooComplex` — "This sheet is too complex to read all
        // rooms at once. Use ⌥-click to trace them one by one."
        guard case .rooms(let rooms, let truncated) = result else {
            Issue.record("expected rooms, got \(result)")
            return
        }
        #expect(!truncated)
        // At least the hip roof's four facets and the annex's three faces, each inside the band:
        // 64.40, 28.94, 65.34 and 28.00 m², and about 75.79, 27.44 and 27.44 m².
        #expect(rooms.count >= 7, "\(rooms.map { $0.region.area * Self.metresPerPoint * Self.metresPerPoint })")
        let facet = try Self.eastFacet(prepared)
        #expect(rooms.contains { $0.region.ring == facet.ring }, "the detector and the click must agree on the east facet")
        for area in [93_000.0, 210_000.0, 90_000.0] {
            #expect(rooms.contains { Swift.abs($0.region.area - area) <= 1e-6 }, "no room of \(area) pt²")
        }
        // Every room is a room: inside the band, its seed inside its ring, one simple boundary, and
        // its area its ring's own.
        for room in rooms {
            let squareMetres = room.region.area * Self.metresPerPoint * Self.metresPerPoint
            #expect(squareMetres >= 1 && squareMetres <= 400, "\(squareMetres) m²")
            #expect(Self.encloses(room.region.ring, room.seed))
            #expect(Set(room.region.ring).count == room.region.ring.count)
            #expect(Swift.abs(RegionTracerTests.fanArea(room.region.ring) - room.region.area) <= 1e-9 * room.region.area)
        }
    }
}

/// The two engine rules behind L-73, on fixtures small enough to derive by hand.
@Suite("Trace: dashed lines and dense hatch (L-73)")
struct DashedLineAndHatchTraceTests {

    typealias Fixtures = RegionTracerTests

    /// A dash-dot line along y = `y` from x = `from` to x = `to`, one stroke per dash, the way a
    /// CAD export writes a grid axis: 19.8 pt dashes and 4.9 pt dots with 3.6 pt gaps, period
    /// 31.9 pt — a common dash-dot linetype at 1:50.
    static func dashDotAxis(firstID: UInt64, y: Double, from: Double, to: Double) -> [VectorPrimitive] {
        var result: [VectorPrimitive] = []
        var id = firstID
        var x = from
        var long = true
        while x < to {
            let length = long ? 19.8 : 4.9
            result.append(Fixtures.line(id, x, y, Swift.min(x + length, to), y))
            id += 1
            x += length + 3.6
            long.toggle()
        }
        return result
    }

    @Test("A room crossed by a dash-dot axis traces whole; the axis is not a broken wall")
    func dashDotAxisIsNotAnOpening() throws {
        // Room 0…200 × 0…100; the axis at y = 50 runs from x = −40 to 240, so the dash
        // −8.1…11.7 crosses the west wall and the dash 183.3…203.1 crosses the east wall.
        let primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 200, maxY: 100)
            + Self.dashDotAxis(firstID: 100, y: 50, from: -40, to: 240)
        let prepared = RegionTracer.prepare(primitives: primitives)
        let click = PDFPoint(x: 100, y: 75)
        // Old output: `.notClosed(gapAt: (97.5, 50))` — the spur ends at x = 11.7 and x = 183.3
        // face each other along y = 50, and the 171.6 pt between them read as a door.
        let region = try #require(RegionTracer.trace(prepared, click: click).region)
        // The whole room: 200 × 100 = 20 000.
        #expect(Swift.abs(region.area - 20_000) <= 1e-9, "\(region.area)")
        #expect(Swift.abs(Fixtures.fanArea(region.ring) - 20_000) <= 1e-9)
        // Below the axis the same room, the same ring.
        let below = try #require(RegionTracer.trace(prepared, click: PDFPoint(x: 100, y: 25)).region)
        #expect(below.ring == region.ring)
    }

    /// A guard on the dashed-line rule rather than a regression: the old engine answered the same.
    @Test("A doorway with one short mark on the wall line is still an opening")
    func sparseMarkInADoorwayIsStillAnOpening() throws {
        // The 25 pt door (x 37…62) of AutomationTraceTests.strokeDoor, with a 4 pt mark at x 48…52
        // on the wall line: 4 of 25 pt covered, under half, so the gap is a doorway.
        let primitives = AutomationTraceTests.strokeDoor + [Fixtures.line(9, 48, 0, 52, 0)]
        let prepared = RegionTracer.prepare(primitives: primitives)
        let click = PDFPoint(x: 50, y: 40)
        #expect(RegionTracer.trace(prepared, click: click).isRefusal, "the room must not leak into the corridor")
        guard case .closesOpenings(let proposal) = RegionTracer.traceProposingClosures(
            prepared, click: click, maximumClosureWidth: 60
        ) else {
            Issue.record("expected the door proposed")
            return
        }
        #expect(proposal.closures.map(\.width) == [25])
        // The room behind the door: 100 × 80 = 8000.
        #expect(Swift.abs(proposal.region.area - 8000) <= 1e-9)
    }

    /// The leaf or threshold lines drawn on the wall line of AutomationTraceTests.strokeDoor's
    /// 25 pt doorway (x 37…62): a threshold stopping 4 pt short of each jamb, and a closed double
    /// leaf, 4 pt short of each jamb with 1 pt between the leaves.
    static let doorwayMarks: [(name: String, lines: [VectorPrimitive])] = [
        ("threshold", [Fixtures.line(9, 41, 0, 58, 0)]),
        ("double leaf", [Fixtures.line(9, 41, 0, 49, 0), Fixtures.line(10, 50, 0, 58, 0)])
    ]

    @Test("A threshold or a closed leaf on the wall line, short of each jamb, is still an opening (L-73 re-check)",
          arguments: [0, 1])
    func thresholdInADoorwayIsStillAnOpening(_ index: Int) throws {
        let mark = Self.doorwayMarks[index]
        let prepared = RegionTracer.prepare(primitives: AutomationTraceTests.strokeDoor + mark.lines)
        let click = PDFPoint(x: 50, y: 40)
        // Old output for the threshold, after the first fix: `.traced`, 14 000 pt² — the room
        // 100 × 80 = 8000 and the corridor 100 × 60 = 6000 as one area. 17 of the doorway's 25 pt
        // lie on drawn lines with no gap over 12 pt, which the dashed-line rule alone read as a
        // dash-dot axis; the double leaf, 16 of 25, passed the same way.
        #expect(RegionTracer.trace(prepared, click: click) == .notClosed(gapAt: PDFPoint(x: 49.5, y: 0)), "\(mark.name)")

        guard case .closesOpenings(let room) = RegionTracer.traceProposingClosures(
            prepared, click: click, maximumClosureWidth: 60
        ) else {
            Issue.record("\(mark.name): expected the door proposed")
            return
        }
        #expect(room.closures == [ProposedClosure(start: PDFPoint(x: 37, y: 0), end: PDFPoint(x: 62, y: 0))])
        // The room behind the door: 100 × 80 = 8000.
        #expect(Swift.abs(room.region.area - 8000) <= 1e-9, "\(mark.name): \(room.region.area)")
        #expect(Swift.abs(Fixtures.fanArea(room.region.ring) - 8000) <= 1e-9)

        guard case .closesOpenings(let corridor) = RegionTracer.traceProposingClosures(
            prepared, click: PDFPoint(x: 50, y: -30), maximumClosureWidth: 60
        ) else {
            Issue.record("\(mark.name): expected the door proposed from the corridor")
            return
        }
        #expect(corridor.closures == room.closures)
        // The corridor: 100 × 60 = 6000.
        #expect(Swift.abs(corridor.region.area - 6000) <= 1e-9, "\(mark.name): \(corridor.region.area)")
    }

    @Test("Detect Rooms keeps a doorway with a threshold as two rooms, each closed across the door (L-73b re-check)")
    func detectRoomsSplitsAThresholdDoorway() {
        let prepared = RegionTracer.prepare(primitives: AutomationTraceTests.strokeDoor + Self.doorwayMarks[0].lines)
        let result = RoomDetector.detect(prepared, options: AutomationTraceTests.roomOptions)
        // Old output, after the first fix: one room of 14 000 pt² with no closure — the face was
        // judged closed because the threshold made the doorway a "dashed line".
        guard case .rooms(let rooms, let truncated) = result else {
            Issue.record("expected rooms, got \(result)")
            return
        }
        #expect(!truncated)
        // The room 100 × 80 = 8000 and the corridor 100 × 60 = 6000, never one of 14 000.
        #expect(rooms.map(\.region.area).sorted() == [6000, 8000], "\(rooms.map(\.region.area))")
        let door = ProposedClosure(start: PDFPoint(x: 37, y: 0), end: PDFPoint(x: 62, y: 0))
        #expect(rooms.allSatisfy { $0.closures == [door] }, "\(rooms.map(\.closures))")
    }

    /// A guard on the dashed-line rule rather than a regression: an axis that meets a slanted
    /// wall in one of its gaps, a shape grid axes on a hip roof take, which no rule may refuse.
    @Test("An axis whose dashes stop short of a slanted wall either side, bridged to it, is not an opening")
    func axisBridgedShortOfASlantedWallIsNotAnOpening() throws {
        // Room (0,0) (200,0) (200,100) (100,100): its west wall runs at 45°. The axis at y = 50
        // meets that wall at x = 50 in one of its gaps: the dot 44.81…49.71 stops 0.21 pt short of
        // the wall and the dash 53.31…73.11 starts 2.34 pt short of it, each bridged to its own
        // foot, so no stroke crosses the wall. At the east wall the dash 180.91…200.71 crosses it.
        let primitives = [
            Fixtures.line(1, 0, 0, 200, 0), Fixtures.line(2, 200, 0, 200, 100),
            Fixtures.line(3, 200, 100, 100, 100), Fixtures.line(4, 100, 100, 0, 0)
        ] + Self.dashDotAxis(firstID: 100, y: 50, from: -42.39, to: 260)
        let prepared = RegionTracer.prepare(primitives: primitives)
        let above = try #require(RegionTracer.trace(prepared, click: PDFPoint(x: 150, y: 75)).region)
        // 200 × 100 − ½ × 100 × 100 = 15 000.
        #expect(Swift.abs(above.area - 15_000) <= 1e-9, "\(above.area)")
        #expect(Swift.abs(Fixtures.fanArea(above.ring) - 15_000) <= 1e-9)
        let below = try #require(RegionTracer.trace(prepared, click: PDFPoint(x: 150, y: 25)).region)
        #expect(below.ring == above.ring)
    }

    @Test("A traced region reports the joins its ring runs along, not every join in the window (L-73 re-check)")
    func onlyTheRingsJoinsAreReported() throws {
        // The hatched room below: 6 320 joins inside the hatch, none on the room's walls. The old
        // count was the window's, and the app's note quoted it ("Traced. 6320 small gap(s)...").
        let hatched = try #require(
            RegionTracer.trace(RegionTracer.prepare(primitives: Self.hatchedRoom()), click: PDFPoint(x: 10, y: 200)).region
        )
        #expect(hatched.bridgedGapCount == 0)
        #expect(hatched.largestBridgedGap == 0)

        // A room whose bottom wall has a 2 pt join at x 49…51, and a row of ten 2 pt strokes
        // 2.5 pt apart at y = 40 inside it: nine joins of 2.5 pt off the ring, one of 2 pt on it.
        var primitives = [
            Fixtures.line(1, 0, 0, 49, 0), Fixtures.line(2, 51, 0, 100, 0),
            Fixtures.line(3, 100, 0, 100, 80), Fixtures.line(4, 100, 80, 0, 80), Fixtures.line(5, 0, 80, 0, 0)
        ]
        for k in 0..<10 {
            let x = 20 + 4.5 * Double(k)
            primitives.append(Fixtures.line(UInt64(10 + k), x, 40, x + 2, 40))
        }
        let region = try #require(RegionTracer.trace(RegionTracer.prepare(primitives: primitives), click: PDFPoint(x: 50, y: 60)).region)
        // 100 × 80 = 8000.
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        #expect(region.bridgedGapCount == 1)
        #expect(Swift.abs(region.largestBridgedGap - 2) <= 1e-12)
    }

    /// A 16 pt square of the synthetic roof plan's sedum annex, in the sheet's own coordinates
    /// (`SyntheticRoofPlan`): the lower hip line from (880, 720) to (460, 300), the lattice glyph
    /// whose base (484, 325) sits 1/√2 = 0.707 pt above it — inside the 0.75 pt join tolerance —
    /// and whose right tip (486.125, 326.25) comes within 0.125/√2 = 0.088 pt of it, and the right
    /// strokes of the two glyphs at x = 475.5, which cross the square's west wall. Framed by four
    /// walls, 476…492 × 318…334.
    static func sedumCorner() -> [VectorPrimitive] {
        Fixtures.walls(from: 1, minX: 476, minY: 318, maxX: 492, maxY: 334) + [
            Fixtures.line(100, 484, 325, 481.875, 326.25),
            Fixtures.line(101, 484, 325, 484, 327.5),
            Fixtures.line(102, 484, 325, 486.125, 326.25),
            Fixtures.line(103, 475.5, 320, 477.625, 321.25),
            Fixtures.line(104, 475.5, 330, 477.625, 331.25),
            Fixtures.line(108, 880, 720, 460, 300)
        ]
    }

    @Test("A crossing that snapping leaves without a node is mended: no click beside a drawn line traces across it (L-73 re-check)")
    func snappedCrossingIsMended() {
        let prepared = RegionTracer.prepare(primitives: Self.sedumCorner())
        let a = PDFPoint(x: 460, y: 300)
        let b = PDFPoint(x: 880, y: 720)
        // Old output, measured on a CAD-exported sheet's corner before the mend: 390 of the 400
        // clicks traced a ring enclosing points more than 1 pt across the hip line. A split point
        // of the line snapped off it towards a glyph base inside the join tolerance, the glyph's
        // stroke then crossed the line between two nodes, and the face walk ran through.
        var leaks: [PDFPoint] = []
        var traced = 0
        for i in 0..<20 {
            for j in 0..<20 {
                let click = PDFPoint(x: 476 + 0.8 * (Double(i) + 0.5), y: 318 + 0.8 * (Double(j) + 0.5))
                let side = RoofPlanSheetTraceTests.side(of: click, from: a, to: b)
                // A click within the join tolerance of the line may land on either side of it.
                guard Swift.abs(side) > 1 else { continue }
                guard let region = RegionTracer.trace(prepared, click: click).region else { continue }
                traced += 1
                if region.ring.contains(where: {
                    let other = RoofPlanSheetTraceTests.side(of: $0, from: a, to: b)
                    return other * side < 0 && Swift.abs(other) > 1
                }) {
                    leaks.append(click)
                }
            }
        }
        // The band |side| ≤ 1 round the 14√2 = 19.8 pt of line inside the square covers about
        // 2 × 19.8 = 40 of its 256 pt², so some 62 of the 400 clicks are skipped; the floor keeps
        // the test from passing on a grid that traced nothing.
        #expect(traced > 300, "\(traced)")
        #expect(leaks.isEmpty, "\(leaks.count) clicks traced across the line: \(leaks.prefix(4))")
    }

    /// Room 0…400 × 0…400 with a hatch inside: 80 rows, 4.5 pt apart from y = 20, each 80 strokes
    /// 2 pt long with 2.5 pt gaps from x = 20 — every gap bridgeable (≤ 3 pt), no row within
    /// bridging reach of a wall or of the next row.
    static func hatchedRoom() -> [VectorPrimitive] {
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 400, maxY: 400)
        var id: UInt64 = 10
        for row in 0..<80 {
            let y = 20 + Double(row) * 4.5
            for column in 0..<80 {
                let x = 20 + Double(column) * 4.5
                primitives.append(Fixtures.line(id, x, y, x + 2, y))
                id += 1
            }
        }
        return primitives
    }

    @Test("A room full of bridgeable hatch strokes traces within the default work caps")
    func denseHatchDoesNotDrainThePairBudget() throws {
        let primitives = Self.hatchedRoom()
        #expect(primitives.count == 6_404)
        // 79 bridges per row × 80 rows = 6 320 edges appended while bridging, tested by every
        // later loose end of 12 800: about 40 million tests against a budget of 12 million.
        // Old output: `.tooComplex(count: 11300)` once the window reached the whole room.
        let result = RegionTracer.trace(RegionTracer.prepare(primitives: primitives), click: PDFPoint(x: 10, y: 200))
        let region = try #require(result.region, "\(result)")
        // The whole room — the hatch rows are open polylines floating in it: 400 × 400 = 160 000.
        #expect(Swift.abs(region.area - 160_000) <= 1e-9, "\(region.area)")
        #expect(region.islands.isEmpty)
    }

    /// Nine rooms of AutomationTraceTests.ninePlan, and far away a 60 × 60 lattice of crossing
    /// strokes: 3 600 crossings, over a pair budget of 1 000 for the whole sheet but nowhere near
    /// the rooms.
    @Test("A sheet over a cap as a whole is read in tiles: the rooms away from the dense part are found, and the result says it stopped short")
    func detectRoomsFallsBackToTiles() throws {
        var primitives = AutomationTraceTests.ninePlan()
        var id: UInt64 = 1_000
        for index in 0..<60 {
            let at = 1_500 + Double(index) * 1.5
            primitives.append(Fixtures.line(id, 1_500, at, 1_590, at)); id += 1
            primitives.append(Fixtures.line(id, at, 1_500, at, 1_590)); id += 1
        }
        let prepared = RegionTracer.prepare(primitives: primitives, options: TraceOptions(maximumPairTests: 1_000))
        let result = RoomDetector.detect(prepared, options: AutomationTraceTests.roomOptions)
        // Old output: `.tooComplex(count: 1001)` — one arrangement for the whole sheet, over the
        // cap, and nothing read.
        guard case .rooms(let rooms, let truncated) = result else {
            Issue.record("expected rooms from the tiles, got \(result)")
            return
        }
        #expect(truncated, "the dense corner was not read, and the result must say so")
        // The nine rooms, each 100 × 80 = 8000, the door closed rather than merged — exactly what
        // the whole-sheet read gives without the lattice (AutomationTraceTests.detectsNineRooms).
        #expect(rooms.count == 9, "\(rooms.map(\.region.area))")
        #expect(rooms.allSatisfy { Swift.abs($0.region.area - 8000) <= 1e-9 })
        #expect(rooms.filter { !$0.closures.isEmpty }.count == 2)
    }
}
