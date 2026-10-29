import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// Regressions in the one-click auto-trace (BH-034, BH-035, BH-217, IM-010).
///
/// Every expected area, perimeter and gap location is hand-derived from the fixture's own
/// coordinates in a comment. Areas are cross-checked with `RegionTracerTests.fanArea`, which is
/// a different shoelace expression from the engine's.
@Suite("Region tracer regressions")
struct RegionTracerRegressionTests {

    typealias Fixtures = RegionTracerTests

    // MARK: - BH-034: islands inside the room

    @Test("A closed island hit first by the ray does not make the room 'not closed' (BH-034)")
    func closedIslandInsideRoom() throws {
        // Room 0..100 x 0..80; a fixture rectangle x 40..60, y 10..20 drawn as four strokes.
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        primitives += Fixtures.walls(from: 10, minX: 40, minY: 10, maxX: 60, maxY: 20)

        // From (30, 15) the first ray (7 degrees) meets the island's left edge at x = 40,
        // y = 15 + 10 tan(7 deg) = 16.2, inside the island's y range, before any wall.
        for click in [PDFPoint(x: 30, y: 15), PDFPoint(x: 70, y: 15), PDFPoint(x: 50, y: 50)] {
            let result = RegionTracer.trace(primitives: primitives, click: click)
            // Old output for (30, 15): notClosed(gapAt: nil) — the island's boundary was walked
            // clockwise, its signed area was negative, and the closed room was refused.
            let region = try #require(result.region, "click \(click): \(result)")
            // 100 x 80 = 8000; the island is not part of the outer boundary.
            #expect(region.ring.count == 4, "ring \(region.ring)" as Comment)
            #expect(Swift.abs(region.area - 8000) <= 1e-9)
            #expect(Swift.abs(Fixtures.fanArea(region.ring) - 8000) <= 1e-9)
            #expect(Swift.abs(region.perimeter - 360) <= 1e-9)
            #expect(region.bridgedGapCount == 0)
        }

        // A click inside the island traces the island: 20 x 10 = 200.
        let inside = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 15))
        let island = try #require(inside.region, "\(inside)")
        #expect(Swift.abs(island.area - 200) <= 1e-9)
        #expect(island.ring[0] == PDFPoint(x: 40, y: 10))
    }

    @Test("An island drawn as one `re` primitive, and an open glyph-like outline, are skipped (BH-034)")
    func rectangleAndOpenIslands() throws {
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        // A fixture as a single rectangle primitive.
        primitives.append(Fixtures.rectangle(10, x: 40, y: 10, width: 20, height: 10))
        // A room label drawn as an open "C"-shaped outline: three strokes at x 40..50, y 50..60,
        // open on the right, between the click and the right wall.
        primitives.append(Fixtures.line(20, 50, 60, 40, 60))
        primitives.append(Fixtures.line(21, 40, 60, 40, 50))
        primitives.append(Fixtures.line(22, 40, 50, 50, 50))

        for click in [PDFPoint(x: 30, y: 15), PDFPoint(x: 30, y: 55)] {
            let result = RegionTracer.trace(primitives: primitives, click: click)
            // Old output: notClosed(gapAt: nil) for (30, 15) and notClosed(gapAt: (40, 55))
            // for (30, 55) — the glyph's two loose ends were reported as the room's gap.
            let region = try #require(result.region, "click \(click): \(result)")
            #expect(region.ring.count == 4, "ring \(region.ring)" as Comment)
            #expect(Swift.abs(region.area - 8000) <= 1e-9)
            #expect(Swift.abs(Fixtures.fanArea(region.ring) - 8000) <= 1e-9)
        }
    }

    @Test("An island inside a room larger than the first window still lets the window grow (BH-034)")
    func islandInLargeRoom() throws {
        // Room 0..600 x 0..500, far larger than the 192 pt initial window; a 10 x 10 island
        // right beside the click so the first window holds nothing but the island.
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 600, maxY: 500)
        primitives += Fixtures.walls(from: 10, minX: 310, minY: 245, maxX: 320, maxY: 255)
        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 300, y: 250))
        // Old output: notClosed(gapAt: nil). Expected: 600 x 500 = 300 000.
        let region = try #require(result.region, "\(result)")
        #expect(region.ring.count == 4)
        #expect(Swift.abs(region.area - 300_000) <= 1e-6)
        #expect(Swift.abs(Fixtures.fanArea(region.ring) - 300_000) <= 1e-6)
    }

    @Test("A broken room still refuses, and names its own gap, with an island in the way (BH-034)")
    func brokenRoomWithIsland() throws {
        // The ten-point-gap room of RegionTracerTests with a fixture rectangle in front of the
        // click. The refusal must survive the island and point at the wall's break, not at the
        // island.
        var primitives = [
            Fixtures.line(1, 0, 0, 45, 0),
            Fixtures.line(2, 55, 0, 100, 0),
            Fixtures.line(3, 100, 0, 100, 80),
            Fixtures.line(4, 100, 80, 0, 80),
            Fixtures.line(5, 0, 80, 0, 0)
        ]
        primitives += Fixtures.walls(from: 10, minX: 40, minY: 30, maxX: 60, maxY: 50)
        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 30, y: 40))
        guard case .notClosed(let gap) = result else {
            Issue.record("a 10 pt break must be refused, got \(result)")
            return
        }
        let located = try #require(gap)
        // The break spans (45, 0) to (55, 0); its middle is (50, 0).
        #expect(Swift.abs(located.x - 50) <= 1e-9, "gap \(located)" as Comment)
        #expect(Swift.abs(located.y) <= 1e-9)
    }

    // MARK: - BH-035: openings in capped walls

    /// Walls drawn as `re` rectangles 10 pt thick: room interior 0..100 x 0..80, corridor
    /// interior 0..100 x -70..-10, and the partition between them in two pieces that leave a
    /// 25 pt cased opening at x 37..62. Every node on the room-and-corridor face has degree
    /// two: the jambs are the rectangles' end caps, not loose ends.
    static func cappedWalls(openingWidth: Double?) -> [VectorPrimitive] {
        var primitives = [
            Fixtures.rectangle(1, x: -10, y: -80, width: 10, height: 170),
            Fixtures.rectangle(2, x: 100, y: -80, width: 10, height: 170),
            Fixtures.rectangle(3, x: 0, y: 80, width: 100, height: 10),
            Fixtures.rectangle(4, x: 0, y: -80, width: 100, height: 10)
        ]
        if let openingWidth {
            let left = 37.0
            primitives.append(Fixtures.rectangle(5, x: 0, y: -10, width: left, height: 10))
            primitives.append(
                Fixtures.rectangle(6, x: left + openingWidth, y: -10, width: 100 - left - openingWidth, height: 10)
            )
        } else {
            primitives.append(Fixtures.rectangle(5, x: 0, y: -10, width: 100, height: 10))
        }
        return primitives
    }

    @Test("An opening between capped walls is refused, not traced as room plus corridor (BH-035)")
    func cappedOpeningIsRefused() throws {
        let primitives = Self.cappedWalls(openingWidth: 25)
        // Room 100 x 80 = 8000, the opening's channel 25 x 10 = 250, corridor 100 x 60 = 6000:
        // the union is 14 250, and that is the number this test exists to forbid.
        for click in [PDFPoint(x: 50, y: 40), PDFPoint(x: 50, y: -40)] {
            for tolerance in [1.0, 3.0, 10.0, 24.0, 26.0] {
                let result = RegionTracer.trace(
                    primitives: primitives,
                    click: click,
                    options: TraceOptions(gapTolerance: tolerance)
                )
                // Old output: traced 12 vertices, area 14250 (every tolerance, both clicks).
                guard case .notClosed(let gap) = result else {
                    Issue.record("click \(click), tolerance \(tolerance): expected a refusal, got \(result)")
                    continue
                }
                let located = try #require(gap, "the refusal must name the opening")
                // The jambs are the caps at x = 37 and x = 62 across y -10..0; their midpoints
                // are (37, -5) and (62, -5), and the opening's middle is (49.5, -5).
                #expect(Swift.abs(located.x - 49.5) <= 1e-9, "gap.x was \(located.x)")
                #expect(Swift.abs(located.y + 5) <= 1e-9, "gap.y was \(located.y)")
            }
        }
    }

    @Test("The same capped walls with the partition closed trace the room alone (BH-035)")
    func cappedWallsClosedRoom() throws {
        let primitives = Self.cappedWalls(openingWidth: nil)
        let room = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))
        let region = try #require(room.region, "\(room)")
        // The inner faces of the wall rectangles: 100 x 80 = 8000.
        #expect(region.ring.count == 4, "ring \(region.ring)" as Comment)
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        #expect(Swift.abs(Fixtures.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(region.ring[0] == PDFPoint(x: 0, y: 0))

        let corridor = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: -40))
        let below = try #require(corridor.region, "\(corridor)")
        // 100 x 60 = 6000.
        #expect(Swift.abs(below.area - 6000) <= 1e-9)
        #expect(Swift.abs(Fixtures.fanArea(below.ring) - 6000) <= 1e-9)
    }

    @Test("A pilaster on one wall is not mistaken for an opening (BH-035)")
    func pilasterIsNotAnOpening() throws {
        // A room of four strokes with a 10 x 8 pilaster protruding from the bottom wall at
        // x 45..55: its top edge is a reflex-reflex edge just like a jamb, but nothing faces it.
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        primitives.append(Fixtures.line(10, 45, 0, 45, 8))
        primitives.append(Fixtures.line(11, 45, 8, 55, 8))
        primitives.append(Fixtures.line(12, 55, 8, 55, 0))
        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 50, y: 40))
        let region = try #require(result.region, "\(result)")
        // 8000 minus the pilaster 10 x 8 = 80: 7920.
        #expect(Swift.abs(region.area - 7920) <= 1e-9)
        #expect(Swift.abs(Fixtures.fanArea(region.ring) - 7920) <= 1e-9)
        #expect(region.ring.count == 8)
    }

    // MARK: - IM-010: closed shapes collected once

    /// A `re` rectangle exactly as the extractor emits it: the parent `.rectangle` primitive
    /// and its four child `.lineSegment` primitives with `parentID` set.
    static func extractedRectangle(_ id: UInt64, x: Double, y: Double, width: Double, height: Double) -> [VectorPrimitive] {
        var result = [Fixtures.rectangle(id, x: x, y: y, width: width, height: height)]
        let corners = [
            CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
            CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)
        ]
        for i in 0..<4 {
            let start = corners[i]
            let end = corners[(i + 1) % 4]
            result.append(
                VectorPrimitive(
                    id: id * 10 + UInt64(i + 1),
                    parentID: id,
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
            )
        }
        return result
    }

    @Test("A parent shape with children is collected once, so the segment cap counts real edges (IM-010)")
    func parentShapesAreCollectedOnce() throws {
        // 1 000 disjoint rectangles on a 40 x 25 grid, each emitted as parent plus four
        // children: 4 000 real edges. Old output: 8 000 segments collected, so a cap of 4 000
        // refused the page with tooComplex(count: 4001); now it traces.
        var primitives: [VectorPrimitive] = []
        for index in 0..<1000 {
            let column = Double(index % 40)
            let row = Double(index / 40)
            primitives += Self.extractedRectangle(
                UInt64(index + 1), x: column * 30, y: row * 30, width: 20, height: 20
            )
        }
        let capped = TraceOptions(maximumSegments: 4000)
        let click = PDFPoint(x: 30 * 17 + 10, y: 30 * 9 + 10)
        let result = RegionTracer.trace(primitives: primitives, click: click, options: capped)
        let region = try #require(result.region, "\(result)")
        // 20 x 20 = 400.
        #expect(Swift.abs(region.area - 400) <= 1e-9)
        #expect(region.ring.count == 4)

        // One fewer edge than the cap and the same page is refused by the cap, not the tracer.
        let tighter = TraceOptions(maximumSegments: 3999)
        #expect(RegionTracer.trace(primitives: primitives, click: click, options: tighter) == .tooComplex(count: 4000))

        // Parents without children are still collected: the same rectangles without their
        // child segments trace to the identical ring.
        let parentsOnly = primitives.filter { $0.parentID == nil }
        let alone = try #require(RegionTracer.trace(primitives: parentsOnly, click: click, options: capped).region)
        #expect(alone.ring == region.ring)

        // And children without their parent trace to it too.
        let childrenOnly = primitives.filter { $0.parentID != nil }
        let children = try #require(RegionTracer.trace(primitives: childrenOnly, click: click, options: capped).region)
        #expect(children.ring == region.ring)
    }

    // MARK: - BH-667: loose-end bridging cost

    @Test("Loose ends are bridged against nearby edges only, not charged the whole window (BH-667)")
    func looseEndsDoNotDrainThePairBudget() throws {
        // Room 0..100 x 0..80 clicked at (50, 40). The first window is 212 points wide
        // (4 x 40 nearest distance + 4 x 13 margin) and also holds 540 closed 2 x 2 squares above
        // the room (2 160 edges, no loose end) and 36 one-point strokes below it, 5 points apart
        // (72 loose ends, none within the 3-point gap tolerance of anything but itself).
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        var id: UInt64 = 100
        for i in 0..<45 {
            for j in 0..<12 {
                primitives += Fixtures.walls(
                    from: id, minX: -40 + 4 * Double(i), minY: 86 + 4 * Double(j),
                    maxX: -38 + 4 * Double(i), maxY: 88 + 4 * Double(j)
                )
                id += 4
            }
        }
        for k in 0..<36 {
            primitives.append(Fixtures.line(id, -40 + 5 * Double(k), -30, -39 + 5 * Double(k), -30))
            id += 1
        }
        // Old output: tooComplex(count: 2200) — every loose end was charged every edge of the
        // arrangement, 72 x ~2 200 = 158 000 against a budget of 100 000.
        let result = RegionTracer.trace(
            primitives: primitives,
            click: PDFPoint(x: 50, y: 40),
            options: TraceOptions(maximumPairTests: 100_000)
        )
        let region = try #require(result.region, "\(result)")
        // 100 x 80 = 8000; the strokes are too far apart to bridge.
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        #expect(region.bridgedGapCount == 0)
    }

    @Test("Bridging to the middle of a wall still finds the nearest foot (BH-667)")
    func bridgeToWallStillWorks() throws {
        // The two-point-join room of RegionTracerTests, plus a stroke that stops 2 points short
        // of the right wall's middle: the stroke end at (98, 40) bridges to the foot (100, 40).
        var primitives = [
            Fixtures.line(1, 0, 0, 49, 0),
            Fixtures.line(2, 51, 0, 100, 0),
            Fixtures.line(3, 100, 0, 100, 80),
            Fixtures.line(4, 100, 80, 0, 80),
            Fixtures.line(5, 0, 80, 0, 0)
        ]
        primitives.append(Fixtures.line(6, 60, 40, 98, 40))
        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 30, y: 40))
        let region = try #require(result.region, "\(result)")
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        // Two bridges are made: the 2-point join at (49..51, 0) and the stroke end to the wall.
        // Only the join is on the ring; the stroke is a spur the ring does not run along, so the
        // region reports one (L-73 re-check: the count is the ring's, not the window's).
        #expect(region.bridgedGapCount == 1)
        #expect(Swift.abs(region.largestBridgedGap - 2) <= 1e-12)

        // A partition that stops 2 points short of the bottom wall's middle bridges to the foot
        // (50, 0), and that bridge is on the left room's ring: 50 × 80 = 4000, one bridge, 2 pt.
        let partitioned = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
            + [Fixtures.line(9, 50, 2, 50, 80)]
        let left = try #require(RegionTracer.trace(primitives: partitioned, click: PDFPoint(x: 25, y: 40)).region)
        #expect(Swift.abs(left.area - 4000) <= 1e-9)
        #expect(Swift.abs(Fixtures.fanArea(left.ring) - 4000) <= 1e-9)
        #expect(left.bridgedGapCount == 1)
        #expect(Swift.abs(left.largestBridgedGap - 2) <= 1e-12)
    }

    // MARK: - BH-217: a spur across the ring's wrap

    @Test("A spur whose tip is the last walked node is collapsed (BH-217)")
    func spurAcrossTheWrap() throws {
        // The dimensionLinesCrossingWalls fixture: room 0..100 x 0..80, a dimension line through
        // the left wall reaching to (25, 40), and one through the top wall reaching down to
        // (60, 65). Clicked at (10, 75): the 7-degree ray meets the top wall on the edge whose
        // walk starts at (60, 80), so the walk ends ..., (100, 80), (60, 80), (60, 65) and the
        // spur (60, 80) -> (60, 65) -> (60, 80) straddles the wrap.
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        primitives.append(Fixtures.line(10, -25, 40, 25, 40))
        primitives.append(Fixtures.line(11, 60, 95, 60, 65))
        primitives.append(Fixtures.line(12, -40, -10, 140, -10))

        let result = RegionTracer.trace(primitives: primitives, click: PDFPoint(x: 10, y: 75))
        let region = try #require(result.region, "\(result)")
        // Old output: 7 vertices with a spike to (60, 65), perimeter 390 (360 + 2 * 15).
        #expect(region.ring.count == 4, "ring \(region.ring)" as Comment)
        #expect(Swift.abs(region.perimeter - 360) <= 1e-9, "perimeter \(region.perimeter)" as Comment)
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        #expect(!Fixtures.contains(region.ring, PDFPoint(x: 60, y: 65)))
        #expect(!Fixtures.contains(region.ring, PDFPoint(x: 25, y: 40)))
    }
}
