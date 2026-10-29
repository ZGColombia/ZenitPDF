import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// Hatch glyphs drawn across a hip line of the synthetic roof plan's sedum annex
/// (`SyntheticRoofPlan`): the faces either side of the hip must stay two faces.
///
/// # The defect
///
/// With three glyphs on the upper hip, an ⌥-click on the upper face traced the upper and the
/// middle face as one ring, 331 800 pt² = 88 200 + 243 600, with no hip in it. The chain of
/// events, each step derived from the coordinates below:
///
/// 1. Glyph A's right stroke, from (484, 1275) to (486.125, 1276.25), crosses the hip
///    x + y = 1760 where −1 + 3.375·t = 0, at (484.630, 1275.370) — 0.730 pt from A's base,
///    inside the 0.75 pt join tolerance. The crossing snaps onto the base, so the hip runs
///    through (484, 1275), 0.707 pt off its line.
/// 2. Glyph C's base (535, 1225) lies on the hip, so the hip's next node is there, and the bent
///    piece from (484, 1275) to (535, 1225) passes exactly through glyph B's right tip
///    (528.625, 1231.25): 1275 − 50 × 44.625 / 51 = 1231.25.
/// 3. Bridging found that tip, a loose end, at distance zero from the piece and joined it to a
///    foot at its own position: an edge of length zero, whose angle `atan2(0, 0)` filed it due
///    east in the node's fan. The face walk left the tip on the wrong side of the hip, and the
///    two faces became one.
///
/// Three rules now hold, each tested below:
///
/// - the arrangement merges the two nodes of any edge too short to have a direction, so a
///   stroke that ends on a line meets it at one node, on its own side;
/// - a node sits at the one of its points that the longest drawn lines run through, so the
///   crossing of A's stroke stays on the hip and A's base moves onto it, not the hip onto the
///   base (with glyph A alone the upper face was 88 396.11 pt², 0.22 % too large);
/// - a hatch cell that only a bridge closes against a face's boundary is part of the face, not
///   a hole in it (each glyph's bridged cells were cut out, up to 0.14 % of a sedum face).
///
/// Every expected value is derived by hand from the fixture's coordinates; none was read back
/// from the engine.
@Suite("Trace: hatch glyphs across a hip line")
struct HatchAcrossHipTraceTests {

    typealias Fixtures = RegionTracerTests
    typealias Plan = SyntheticRoofPlan

    /// One glyph of the annex hatch: three strokes from `base`, to the left, up and to the right
    /// (`SyntheticRoofPlan.glyphProngs`).
    static func glyph(firstID: UInt64, base: PDFPoint) -> [VectorPrimitive] {
        Plan.glyphProngs.enumerated().map { index, prong in
            Fixtures.line(firstID + UInt64(index), base.x, base.y, base.x + prong.x, base.y + prong.y)
        }
    }

    /// The annex outline 460…880 × 300…1300, its two hip lines, and glyphs A, B and C at
    /// (484, 1275), (526.5, 1230) and (535, 1225). With u = x + y − 1760 (the upper hip at u = 0,
    /// the upper face at u > 0) the bases sit at u = −1, −3.5 and 0: A's up and right strokes end
    /// at u = +1.5 and +2.375, across the hip; B's right tip ends at u = −0.125, 0.088 pt short of
    /// it; C stands on the hip with its up and right strokes in the upper face.
    static func annexWithGlyphsOnTheUpperHip() -> [VectorPrimitive] {
        Fixtures.walls(from: 1, minX: 460, minY: 300, maxX: 880, maxY: 1300) + [
            Fixtures.line(5, 460, 300, 880, 720),
            Fixtures.line(6, 460, 1300, 880, 880)
        ]
            + glyph(firstID: 100, base: PDFPoint(x: 484, y: 1275))
            + glyph(firstID: 110, base: PDFPoint(x: 526.5, y: 1230))
            + glyph(firstID: 120, base: PDFPoint(x: 535, y: 1225))
    }

    /// The three faces' clicks — the ones `RoofPlanSheetTraceTests` uses, between two hatch rows.
    static let lowerClick = PDFPoint(x: 800, y: 418.75)
    static let upperClick = PDFPoint(x: 800, y: 1178.75)
    static let middleClick = PDFPoint(x: 600, y: 798.75)
    static var clicks: [PDFPoint] { [lowerClick, upperClick, middleClick] }

    static let lowerHip = (PDFPoint(x: 460, y: 300), PDFPoint(x: 880, y: 720))
    static let upperHip = (PDFPoint(x: 460, y: 1300), PDFPoint(x: 880, y: 880))

    /// The join tolerance: how far snapping may move a node, so how far across a hip a face's
    /// ring may reach.
    static let joinTolerance = TraceOptions.standard.joinTolerance

    /// `true` when every vertex of `ring` stays on the side of the hips its face lies on, give or
    /// take the join tolerance. Left of the lower hip (460,300)→(880,720) is the middle face's
    /// side; left of the upper hip (460,1300)→(880,880) is the upper face's.
    static func staysOnItsSide(_ ring: [PDFPoint], click: PDFPoint) -> Bool {
        let side = RoofPlanSheetTraceTests.side(of:from:to:)
        let slack = joinTolerance
        switch click {
        case lowerClick:
            return ring.allSatisfy { side($0, lowerHip.0, lowerHip.1) <= slack }
        case upperClick:
            return ring.allSatisfy { side($0, upperHip.0, upperHip.1) >= -slack }
        default:
            return ring.allSatisfy {
                side($0, lowerHip.0, lowerHip.1) >= -slack && side($0, upperHip.0, upperHip.1) <= slack
            }
        }
    }

    // MARK: - The minimal reproduction

    @Test("Glyphs crossing a hip line do not merge the faces either side of it")
    func glyphsOnTheHipKeepTheFacesApart() throws {
        let prepared = RegionTracer.prepare(primitives: Self.annexWithGlyphsOnTheUpperHip())

        // Old output: `.traced`, 331 800 pt² — the ring (460,300) (880,720) (880,1300) (460,1300),
        // the upper face and the middle face with the hip left out.
        let upper = try #require(RegionTracer.trace(prepared, click: Self.upperClick).region)
        // The upper face, (460,1300) (880,880) (880,1300): a right triangle with legs 420 and 420,
        // 420² / 2 = 88 200 pt². The hip stays straight and the glyph cells bridged against it
        // are part of the face, so the ring is the triangle.
        #expect(Swift.abs(upper.area - 88_200) <= 1e-6, "upper face: \(upper.area) pt²")
        #expect(Swift.abs(Fixtures.fanArea(upper.ring) - upper.area) <= 1e-9 * upper.area)
        #expect(!RoofPlanSheetTraceTests.encloses(upper.ring, Self.middleClick), "the upper face leaked into the middle face")
        #expect(Self.staysOnItsSide(upper.ring, click: Self.upperClick), "\(upper.ring)")
        #expect(Set(upper.ring).count == upper.ring.count && !RoofPlanSheetTraceTests.selfCrosses(upper.ring))

        let middle = try #require(RegionTracer.trace(prepared, click: Self.middleClick).region)
        // The middle face, (460,300) (880,720) (880,880) (460,1300): parallel sides x = 460
        // (1000 long) and x = 880 (160 long), 420 apart: 420 × (1000 + 160) / 2 = 243 600 pt².
        #expect(Swift.abs(middle.area - 243_600) <= 1e-6, "middle face: \(middle.area) pt²")
        #expect(!RoofPlanSheetTraceTests.encloses(middle.ring, Self.upperClick), "the middle face leaked into the upper face")
        #expect(Self.staysOnItsSide(middle.ring, click: Self.middleClick), "\(middle.ring)")

        // The lower face has no glyph near its hip: exactly the triangle (460,300) (880,300)
        // (880,720), 420² / 2 = 88 200 pt².
        let lower = try #require(RegionTracer.trace(prepared, click: Self.lowerClick).region)
        #expect(Swift.abs(lower.area - 88_200) <= 1e-6, "lower face: \(lower.area) pt²")
        #expect(Swift.abs(Fixtures.fanArea(lower.ring) - 88_200) <= 1e-6)
    }

    @Test("Detect Rooms on the same glyphs proposes the faces either side of the hip apart")
    func detectRoomsKeepsTheFacesApart() throws {
        let prepared = RegionTracer.prepare(primitives: Self.annexWithGlyphsOnTheUpperHip())
        // Old output: a room of 331 800 pt² holding the upper and the middle click.
        guard case .rooms(let rooms, let truncated) = RoomDetector.detect(
            prepared, options: RoofPlanSheetTraceTests.roomOptions
        ) else {
            Issue.record("expected rooms")
            return
        }
        #expect(!truncated)
        try Self.expectOneRoomPerFace(rooms, bounds: [1e-6, 1e-6, 1e-6])
    }

    @Test("A glyph whose stroke crosses a hip just beside its base does not bend the hip")
    func oneGlyphDoesNotBendTheHip() throws {
        // Glyph A alone. Its right stroke crosses the hip at (484.630, 1275.370), 0.730 pt from its
        // base (484, 1275) — inside the 0.75 pt join tolerance, so the two are one node. That node
        // sits on the hip: the hip, 593.97 pt long, runs through the crossing, while only A's
        // strokes, 2.47 pt each, run through the base.
        let primitives = Fixtures.walls(from: 1, minX: 460, minY: 300, maxX: 880, maxY: 1300) + [
            Fixtures.line(5, 460, 300, 880, 720),
            Fixtures.line(6, 460, 1300, 880, 880)
        ] + Self.glyph(firstID: 100, base: PDFPoint(x: 484, y: 1275))
        let prepared = RegionTracer.prepare(primitives: primitives)
        // Old output: 88 396.11 pt², 0.22 % over — the node sat at A's base, 1/√2 = 0.707 pt below
        // the hip, and the face's ring ran from there straight to (880, 880), 559 pt away: a
        // sliver of about ½ × 0.707 × 559 ≈ 198 pt² across the hip line, less what A's bridged
        // cells cut out.
        let upper = try #require(RegionTracer.trace(prepared, click: Self.upperClick).region)
        // The triangle (460,1300) (880,880) (880,1300): 420² / 2 = 88 200 pt².
        #expect(Swift.abs(upper.area - 88_200) <= 1e-6, "upper face: \(upper.area) pt²")
        #expect(Swift.abs(Fixtures.fanArea(upper.ring) - 88_200) <= 1e-6)
        #expect(upper.ring.count == 3, "\(upper.ring)")
        // Every vertex on the hip line or on the face's side of it, to rounding.
        #expect(upper.ring.allSatisfy {
            RoofPlanSheetTraceTests.side(of: $0, from: Self.upperHip.0, to: Self.upperHip.1) >= -1e-9
        }, "\(upper.ring)")
        let middle = try #require(RegionTracer.trace(prepared, click: Self.middleClick).region)
        // 420 × (1000 + 160) / 2 = 243 600 pt².
        #expect(Swift.abs(middle.area - 243_600) <= 1e-6, "middle face: \(middle.area) pt²")
    }

    // MARK: - Which cells are part of the face

    @Test("A hatch cell a bridge closes against a wall is part of the room; a room behind a bridge, and a shape drawn against the wall, are not")
    func onlyBridgeClosedHatchCellsAreAbsorbed() throws {
        let room = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        let click = PDFPoint(x: 50, y: 40)

        // A hatch mark ∩ from (40, 1) up to (40, 3), across to (42, 3) and down to (42, 1): both
        // feet stop 1 pt short of the bottom wall and are bridged to it, closing a 2 × 3 = 6 pt²
        // cell — under the island floor, 0.1 % of the room, 8 pt². Old output: 8000 − 6 = 7994.
        let mark = [
            Fixtures.line(10, 40, 1, 40, 3), Fixtures.line(11, 40, 3, 42, 3), Fixtures.line(12, 42, 3, 42, 1)
        ]
        let hatched = try #require(RegionTracer.trace(primitives: room + mark, click: click).region)
        // The room, 100 × 80 = 8000, its ring the four corners, along no bridge.
        #expect(Swift.abs(hatched.area - 8000) <= 1e-9, "\(hatched.area)")
        #expect(Swift.abs(Fixtures.fanArea(hatched.ring) - 8000) <= 1e-9)
        #expect(hatched.ring.count == 4, "\(hatched.ring)")
        #expect(hatched.bridgedGapCount == 0)

        // The same mark drawn down to the wall: closed by drawn lines alone, it is a shape on the
        // wall, cut out as a pilaster is: 8000 − 6 = 7994.
        let drawn = [
            Fixtures.line(10, 40, 0, 40, 3), Fixtures.line(11, 40, 3, 42, 3), Fixtures.line(12, 42, 3, 42, 0)
        ]
        let pilaster = try #require(RegionTracer.trace(primitives: room + drawn, click: click).region)
        #expect(Swift.abs(pilaster.area - 7994) <= 1e-9, "\(pilaster.area)")
        #expect(Swift.abs(Fixtures.fanArea(pilaster.ring) - 7994) <= 1e-9)

        // A 10 × 10 closet in the corner whose wall has a 2 pt gap at x 94…96, bridged: 100 pt²,
        // above the floor of 0.1 % of the room, so a room of its own. The room is 8000 − 100 =
        // 7900, its ring running along the bridge, and the closet traces alone.
        let closet = [
            Fixtures.line(20, 90, 0, 90, 10), Fixtures.line(21, 90, 10, 94, 10), Fixtures.line(22, 96, 10, 100, 10)
        ]
        let prepared = RegionTracer.prepare(primitives: room + closet)
        let main = try #require(RegionTracer.trace(prepared, click: click).region)
        #expect(Swift.abs(main.area - 7900) <= 1e-9, "\(main.area)")
        #expect(Swift.abs(Fixtures.fanArea(main.ring) - 7900) <= 1e-9)
        #expect(main.bridgedGapCount == 1)
        #expect(Swift.abs(main.largestBridgedGap - 2) <= 1e-12)
        let small = try #require(RegionTracer.trace(prepared, click: PDFPoint(x: 95, y: 5)).region)
        #expect(Swift.abs(small.area - 100) <= 1e-9, "\(small.area)")
    }

    // MARK: - The whole sheet, with the hatch drawn across both hips

    /// The synthetic roof plan with the 57 lattice glyphs its generator leaves out — the ones
    /// within 0.5 pt of a hip line, or across one (`SyntheticRoofPlan.glyphIsDrawn`) — drawn back
    /// in, as a CAD hatch that is not clipped to its boundary draws them. The fixture's bytes are
    /// untouched: the glyphs are added to its extracted primitives.
    static func roofPlanWithHatchAcrossTheHips() async throws -> (primitives: [VectorPrimitive], lower: Int, upper: Int) {
        let handle = try ZPDFFixtures.shared(.syntheticRoofPlan)
        let extraction = try await VectorExtractor().extract(documentAt: handle.url, pageIndex: 0)
        var primitives = extraction.primitives
        var id = (primitives.map(\.id).max() ?? 0) + 1
        var onLower = 0
        var onUpper = 0
        for row in 0..<Plan.glyphRowCount {
            let y = 305 + 5 * Double(row)
            let x0 = row % 2 == 0 ? 467.0 : 475.5
            for column in 0..<Plan.glyphsPerRow {
                let x = x0 + 17 * Double(column)
                guard !Plan.glyphIsDrawn(FixturePoint(x, y)) else { continue }
                // The generator's own rule: s = x − y − 160 for the lower hip, u = x + y − 1760 for
                // the upper; left out when −1.5 ≤ s ≤ 4 or −4 ≤ u ≤ 1.5.
                let s = x - y - 160
                if s >= -1.5 && s <= 4 { onLower += 1 } else { onUpper += 1 }
                primitives += glyph(firstID: id, base: PDFPoint(x: x, y: y))
                id += 3
            }
        }
        return (primitives, onLower, onUpper)
    }

    @Test("On the roof plan with hatch drawn across both hips, ⌥-clicks and Detect Rooms keep the annex's three faces apart")
    func sheetWithHatchAcrossTheHips() async throws {
        let sheet = try await Self.roofPlanWithHatchAcrossTheHips()
        // 4 752 lattice points less the 4 695 drawn (`SyntheticRoofPlan.glyphCount`).
        #expect(sheet.lower + sheet.upper == 4_752 - 4_695)
        let prepared = RegionTracer.prepare(primitives: sheet.primitives)
        // The takeoff bar of `QUALITY_BAR` M-B, 0.10 % of each face: 88.2, 88.2 and 243.6 pt². What
        // a glyph may still cut out is a cell closed by its own strokes and the hip, with no
        // bridge in it — a shape drawn on the line.
        let bounds = [88.2, 88.2, 243.6]

        // Old output: the upper and the middle click both traced 331 719 pt², one ring round the
        // two faces. With the faces apart, before nodes kept the hips straight and bridged cells
        // joined their faces: lower 88 143.91, upper 88 249.88 and middle 243 321.07 pt², the
        // middle face 0.11 % short.
        var rings: [PDFPoint: [PDFPoint]] = [:]
        for (click, (area, bound)) in zip(Self.clicks, zip([88_200.0, 88_200, 243_600], bounds)) {
            let outcome = RegionTracer.traceProposingClosures(
                prepared, click: click, maximumClosureWidth: 2.5 / RoofPlanSheetTraceTests.metresPerPoint
            )
            guard case .traced(let face) = outcome else {
                Issue.record("click \(click): \(outcome)")
                continue
            }
            rings[click] = face.ring
            #expect(Swift.abs(face.area - area) <= bound, "click \(click): \(face.area) pt², hand \(area) ± \(bound)")
            #expect(Swift.abs(Fixtures.fanArea(face.ring) - face.area) <= 1e-9 * face.area)
            #expect(RoofPlanSheetTraceTests.encloses(face.ring, click))
            for other in Self.clicks where other != click {
                #expect(!RoofPlanSheetTraceTests.encloses(face.ring, other), "click \(click) leaked to \(other)")
            }
            #expect(Self.staysOnItsSide(face.ring, click: click), "click \(click) reaches across a hip")
            #expect(Set(face.ring).count == face.ring.count && !RoofPlanSheetTraceTests.selfCrosses(face.ring))
        }

        // Old output: one room of 331 719 pt² for the upper and the middle face.
        guard case .rooms(let rooms, let truncated) = RoomDetector.detect(
            prepared, options: RoofPlanSheetTraceTests.roomOptions
        ) else {
            Issue.record("expected rooms")
            return
        }
        #expect(!truncated)
        let found = try Self.expectOneRoomPerFace(rooms, bounds: bounds)
        // The detector and the click agree on every face.
        for (click, room) in zip(Self.clicks, found) {
            #expect(room.region.ring == rings[click], "click \(click)")
        }
    }

    /// Requires exactly one room round each face's click, holding no other face's click, its area
    /// within `bounds` (lower, upper, middle) of the hand-derived value. Returns those rooms.
    @discardableResult
    static func expectOneRoomPerFace(_ rooms: [RoomDetector.Room], bounds: [Double]) throws -> [RoomDetector.Room] {
        var result: [RoomDetector.Room] = []
        for (click, (area, bound)) in zip(clicks, zip([88_200.0, 88_200, 243_600], bounds)) {
            let holding = rooms.filter { RoofPlanSheetTraceTests.encloses($0.region.ring, click) }
            #expect(holding.count == 1, "click \(click): \(holding.map(\.region.area))")
            let room = try #require(holding.first)
            for other in clicks where other != click {
                #expect(!RoofPlanSheetTraceTests.encloses(room.region.ring, other), "the room round \(click) holds \(other)")
            }
            #expect(Swift.abs(room.region.area - area) <= bound, "click \(click): \(room.region.area) pt²")
            #expect(room.closures.isEmpty)
            result.append(room)
        }
        return result
    }
}
