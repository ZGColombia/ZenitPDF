import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// Automation: the trace filter (NL-AUTO-01, NL-AUTO-11) and openings a person may close
/// (NL-AUTO-07).
///
/// Every expected area is hand-derived from the fixture coordinates in a comment and
/// cross-checked with `RegionTracerTests.fanArea`, a different shoelace expression from the
/// engine's.
@Suite("Automation: trace filter and proposed closures")
struct AutomationTraceTests {

    typealias Fixtures = RegionTracerTests

    /// A primitive with the attributes a filter reads.
    static func styled(
        _ id: UInt64,
        _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
        layer: String? = nil,
        paint: VectorPaintRole = .stroked,
        width: Double = 0.5,
        dashed: Bool = false,
        confidence: Float = 1
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
            paint: paint,
            strokeWidth: paint.contains(.stroked) ? width : 0,
            strokeIsDashed: dashed,
            clipRelation: .unclipped,
            clipBounds: nil,
            confidence: confidence,
            layerID: layer
        )
    }

    /// Room 0..100 x 0..80 (area 8000) split down the middle at x = 50 by `splitter`.
    static func splitRoom(_ splitter: VectorPrimitive) -> [VectorPrimitive] {
        Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80) + [splitter]
    }

    // MARK: - NL-AUTO-01: hidden layers are structurally absent

    @Test("A line on a hidden layer no longer splits the room it crosses")
    func hiddenLayerLineDoesNotSplit() throws {
        let primitives = Self.splitRoom(Self.styled(20, 50, 0, 50, 80, layer: "MC7"))
        let click = PDFPoint(x: 25, y: 40)

        // Old behaviour (the app passed the unfiltered page): the hidden line splits the room,
        // left half 50 x 80 = 4000.
        let unfiltered = RegionTracer.trace(RegionTracer.prepare(primitives: primitives), click: click)
        #expect(Swift.abs((unfiltered.region?.area ?? 0) - 4000) <= 1e-9, "\(unfiltered)")

        let prepared = RegionTracer.prepare(
            primitives: primitives,
            filter: TraceFilter(hiddenLayerIDs: ["MC7"])
        )
        let region = try #require(RegionTracer.trace(prepared, click: click).region)
        // The whole room: 100 x 80 = 8000.
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        #expect(Swift.abs(Fixtures.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(prepared.filter.hiddenLayerIDs == ["MC7"])
        // Four walls, the splitter gone.
        #expect(prepared.segmentCount == 4)
    }

    @Test("A visible layer and unlayered linework still split the room")
    func visibleLayerStillSplits() throws {
        let primitives = Self.splitRoom(Self.styled(20, 50, 0, 50, 80, layer: "MC7"))
        let prepared = RegionTracer.prepare(
            primitives: primitives,
            filter: TraceFilter(hiddenLayerIDs: ["MC2"])
        )
        let region = try #require(RegionTracer.trace(prepared, click: PDFPoint(x: 25, y: 40)).region)
        #expect(Swift.abs(region.area - 4000) <= 1e-9)
    }

    // MARK: - NL-AUTO-11: choices the person makes

    @Test("Ignoring fills drops a fill-only band; left alone it still splits")
    func fillOnlyIsExcludedOnRequest() throws {
        let band = Self.styled(20, 50, 0, 50, 80, paint: .filled)
        let primitives = Self.splitRoom(band)
        let click = PDFPoint(x: 25, y: 40)
        let off = RegionTracer.trace(RegionTracer.prepare(primitives: primitives, filter: .none), click: click)
        #expect(Swift.abs((off.region?.area ?? 0) - 4000) <= 1e-9)
        let on = RegionTracer.trace(
            RegionTracer.prepare(primitives: primitives, filter: TraceFilter(excludesFillOnly: true)),
            click: click
        )
        #expect(Swift.abs((on.region?.area ?? 0) - 8000) <= 1e-9)
    }

    @Test("A minimum stroke width drops thin hatch strokes, and never a filled wall")
    func thinStrokesAreExcludedOnRequest() throws {
        // Three 0.1 pt hatch strokes across the room at x = 20, 50, 80.
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        primitives += [20.0, 50, 80].enumerated().map { index, x in
            Self.styled(UInt64(30 + index), x, 0, x, 80, width: 0.1)
        }
        let click = PDFPoint(x: 60, y: 40)
        let off = RegionTracer.trace(RegionTracer.prepare(primitives: primitives), click: click)
        // Between the hatch strokes at 50 and 80: 30 x 80 = 2400.
        #expect(Swift.abs((off.region?.area ?? 0) - 2400) <= 1e-9)
        let filter = TraceFilter(minimumStrokeWidth: 0.25)
        let on = RegionTracer.trace(RegionTracer.prepare(primitives: primitives, filter: filter), click: click)
        #expect(Swift.abs((on.region?.area ?? 0) - 8000) <= 1e-9)
        // A filled-and-stroked thin path is a wall with a fill, not hatch.
        #expect(filter.admits(Self.styled(1, 0, 0, 1, 1, paint: [.stroked, .filled], width: 0.1)))
        #expect(!filter.admits(Self.styled(1, 0, 0, 1, 1, width: 0.1)))
    }

    @Test("Dashed and low-confidence geometry are dropped only on request, and every choice is stated")
    func dashedAndConfidence() {
        let dashed = Self.styled(1, 0, 0, 1, 1, dashed: true)
        let shaky = Self.styled(2, 0, 0, 1, 1, confidence: 0.3)
        #expect(TraceFilter.none.admits(dashed))
        #expect(TraceFilter.none.admits(shaky))
        #expect(!TraceFilter.none.isActive)
        let filter = TraceFilter(
            hiddenLayerIDs: ["A", "B"],
            excludesDashed: true,
            excludesFillOnly: true,
            minimumStrokeWidth: 0.2,
            minimumConfidence: 0.5
        )
        #expect(!filter.admits(dashed))
        #expect(!filter.admits(shaky))
        #expect(filter.activeDescriptions == [
            .hiddenLayers(count: 2), .ignoresDashed, .ignoresFills,
            .ignoresThinnerThan(points: 0.2), .ignoresLowConfidence(below: Double(Float(0.5)))
        ])
        // Nonsense values are neutralised, never trusted.
        let clamped = TraceFilter(minimumStrokeWidth: -.infinity, minimumConfidence: .nan)
        #expect(!clamped.isActive)
    }

    // MARK: - NL-AUTO-07: openings a person may close

    /// A 25 pt door opening in the room's bottom wall (x 37..62), corridor below.
    static let strokeDoor: [VectorPrimitive] = [
        Fixtures.line(1, 0, 0, 37, 0),
        Fixtures.line(2, 62, 0, 100, 0),
        Fixtures.line(3, 100, 0, 100, 80),
        Fixtures.line(4, 100, 80, 0, 80),
        Fixtures.line(5, 0, 80, 0, 0),
        Fixtures.line(6, 0, -60, 100, -60),
        Fixtures.line(7, 0, -60, 0, 0),
        Fixtures.line(8, 100, -60, 100, 0)
    ]

    @Test("A door between stroked walls is proposed as one closing line, and the room behind it is exact")
    func strokeDoorProposesOneClosure() throws {
        let prepared = RegionTracer.prepare(primitives: Self.strokeDoor)
        let click = PDFPoint(x: 50, y: 40)
        // The plain trace still refuses: nothing changed about what is committed unasked.
        #expect(RegionTracer.trace(prepared, click: click).isRefusal)

        let outcome = RegionTracer.traceProposingClosures(prepared, click: click, maximumClosureWidth: 60)
        guard case .closesOpenings(let proposal) = outcome else {
            Issue.record("expected a proposal, got \(outcome)")
            return
        }
        #expect(proposal.closures == [ProposedClosure(start: PDFPoint(x: 37, y: 0), end: PDFPoint(x: 62, y: 0))])
        #expect(Swift.abs((proposal.closures.map(\.width).max() ?? 0) - 25) <= 1e-12)
        // The room alone: 100 x 80 = 8000.
        #expect(Swift.abs(proposal.region.area - 8000) <= 1e-9)
        #expect(Swift.abs(Fixtures.fanArea(proposal.region.ring) - 8000) <= 1e-9)

        // Accepting inserts exactly that segment and yields the same ring.
        let accepted = RegionTracer.trace(prepared, click: click, closures: proposal.closures)
        #expect(accepted.region == proposal.region)

        // From the corridor side the same opening closes the corridor: 100 x 60 = 6000.
        let corridor = RegionTracer.traceProposingClosures(prepared, click: PDFPoint(x: 50, y: -30), maximumClosureWidth: 60)
        guard case .closesOpenings(let below) = corridor else {
            Issue.record("expected a corridor proposal, got \(corridor)")
            return
        }
        #expect(Swift.abs(below.region.area - 6000) <= 1e-9)
    }

    @Test("A cased opening between capped walls closes on the face that looks at the click")
    func cappedOpeningClosesOnTheClickFace() throws {
        let prepared = RegionTracer.prepare(primitives: RegionTracerRegressionTests.cappedWalls(openingWidth: 25))

        // Room click: the room face is y = 0, so the closure runs (37, 0) to (62, 0) and the room
        // is the inner faces 100 x 80 = 8000 — not the 14 250 union BH-035 forbids.
        let room = RegionTracer.traceProposingClosures(prepared, click: PDFPoint(x: 50, y: 40), maximumClosureWidth: 60)
        guard case .closesOpenings(let roomProposal) = room else {
            Issue.record("expected a room proposal, got \(room)")
            return
        }
        #expect(roomProposal.closures == [ProposedClosure(start: PDFPoint(x: 37, y: 0), end: PDFPoint(x: 62, y: 0))])
        #expect(Swift.abs(roomProposal.region.area - 8000) <= 1e-9)
        #expect(Swift.abs(Fixtures.fanArea(roomProposal.region.ring) - 8000) <= 1e-9)

        // Corridor click: its face is y = -10; corridor 100 x 60 = 6000.
        let corridor = RegionTracer.traceProposingClosures(prepared, click: PDFPoint(x: 50, y: -40), maximumClosureWidth: 60)
        guard case .closesOpenings(let corridorProposal) = corridor else {
            Issue.record("expected a corridor proposal, got \(corridor)")
            return
        }
        #expect(corridorProposal.closures == [ProposedClosure(start: PDFPoint(x: 37, y: -10), end: PDFPoint(x: 62, y: -10))])
        #expect(Swift.abs(corridorProposal.region.area - 6000) <= 1e-9)
    }

    @Test("An opening wider than the cap is refused exactly as the plain trace refuses it")
    func openingOverTheCapIsRefused() throws {
        let prepared = RegionTracer.prepare(primitives: Self.strokeDoor)
        let click = PDFPoint(x: 50, y: 40)
        let plain = RegionTracer.trace(prepared, click: click)
        let outcome = RegionTracer.traceProposingClosures(prepared, click: click, maximumClosureWidth: 20)
        #expect(outcome == .refused(plain))
    }

    @Test("A missing wall is never proposed as a door")
    func missingWallIsNotADoor() {
        // Three walls; the right side is simply absent — 80 pt of nothing.
        let primitives = [
            Fixtures.line(1, 0, 0, 100, 0),
            Fixtures.line(2, 100, 80, 0, 80),
            Fixtures.line(3, 0, 80, 0, 0)
        ]
        let outcome = RegionTracer.traceProposingClosures(
            RegionTracer.prepare(primitives: primitives), click: PDFPoint(x: 50, y: 40), maximumClosureWidth: 60
        )
        guard case .refused = outcome else {
            Issue.record("a missing wall must not be closed, got \(outcome)")
            return
        }
    }

    @Test("A 900 mm door at 1:50 closes to the hand polygon within the area bar")
    func nineHundredMillimetreDoorAtOneToFifty() throws {
        // 1:50: one real millimetre is 1/50 mm of paper, and one paper millimetre is 72/25.4 pt.
        let pointsPerRealMillimetre = 72.0 / 25.4 / 50.0
        func pt(_ millimetres: Double) -> Double { millimetres * pointsPerRealMillimetre }
        // Room 4000 x 3000 mm, door 900 mm wide from x = 1000 to 1900 mm in the bottom wall,
        // a 1500 mm corridor below.
        let primitives = [
            Fixtures.line(1, 0, 0, pt(1000), 0),
            Fixtures.line(2, pt(1900), 0, pt(4000), 0),
            Fixtures.line(3, pt(4000), 0, pt(4000), pt(3000)),
            Fixtures.line(4, pt(4000), pt(3000), 0, pt(3000)),
            Fixtures.line(5, 0, pt(3000), 0, 0),
            Fixtures.line(6, 0, -pt(1500), pt(4000), -pt(1500)),
            Fixtures.line(7, 0, -pt(1500), 0, 0),
            Fixtures.line(8, pt(4000), -pt(1500), pt(4000), 0)
        ]
        let prepared = RegionTracer.prepare(primitives: primitives)
        // Cap: 2.5 m at 1:50.
        let outcome = RegionTracer.traceProposingClosures(
            prepared, click: PDFPoint(x: pt(2000), y: pt(1500)), maximumClosureWidth: pt(2500)
        )
        guard case .closesOpenings(let proposal) = outcome else {
            Issue.record("expected a proposal, got \(outcome)")
            return
        }
        let closure = try #require(proposal.closures.first)
        #expect(proposal.closures.count == 1)
        // The closing line is the opening: 900 mm.
        #expect(Swift.abs(closure.width / pointsPerRealMillimetre - 900) <= 1e-9)
        // The hand polygon closed at the wall line is the room rectangle: 4 m x 3 m = 12 m².
        let squareMetresPerSquarePoint = (1 / pointsPerRealMillimetre / 1000) * (1 / pointsPerRealMillimetre / 1000)
        let measured = proposal.region.area * squareMetresPerSquarePoint
        #expect(Swift.abs(measured - 12) / 12 <= 0.001, "measured \(measured) m²")
        #expect(Swift.abs(Fixtures.fanArea(proposal.region.ring) * squareMetresPerSquarePoint - 12) / 12 <= 0.001)
    }

    @Test("A room with two doors closes both, one closing line each")
    func twoDoors() throws {
        // Room 0..100 x 0..80 with a 20 pt door in the bottom wall (x 20..40) and one in the top
        // wall (x 60..80); corridors above and below.
        let primitives = [
            Fixtures.line(1, 0, 0, 20, 0), Fixtures.line(2, 40, 0, 100, 0),
            Fixtures.line(3, 100, 0, 100, 80),
            Fixtures.line(4, 100, 80, 80, 80), Fixtures.line(5, 60, 80, 0, 80),
            Fixtures.line(6, 0, 80, 0, 0),
            Fixtures.line(7, 0, -50, 100, -50), Fixtures.line(8, 0, -50, 0, 0), Fixtures.line(9, 100, -50, 100, 0),
            Fixtures.line(10, 0, 130, 100, 130), Fixtures.line(11, 0, 80, 0, 130), Fixtures.line(12, 100, 80, 100, 130)
        ]
        let outcome = RegionTracer.traceProposingClosures(
            RegionTracer.prepare(primitives: primitives), click: PDFPoint(x: 50, y: 40), maximumClosureWidth: 60
        )
        guard case .closesOpenings(let proposal) = outcome else {
            Issue.record("expected a proposal, got \(outcome)")
            return
        }
        #expect(Set(proposal.closures) == [
            ProposedClosure(start: PDFPoint(x: 20, y: 0), end: PDFPoint(x: 40, y: 0)),
            ProposedClosure(start: PDFPoint(x: 60, y: 80), end: PDFPoint(x: 80, y: 80))
        ])
        #expect(Swift.abs(proposal.region.area - 8000) <= 1e-9)
    }

    @Test("A closed room is traced as before, with no proposal in the way")
    func closedRoomIsUntouched() throws {
        let primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        let outcome = RegionTracer.traceProposingClosures(
            RegionTracer.prepare(primitives: primitives), click: PDFPoint(x: 50, y: 40), maximumClosureWidth: 60
        )
        guard case .traced(let region) = outcome else {
            Issue.record("expected a plain trace, got \(outcome)")
            return
        }
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
    }

    // MARK: - NL-AUTO-10: islands offered as cutouts

    @Test("A column inside the room comes back as an island, not deducted; a letter-sized outline and an inner outline do not")
    func islandsAreOfferedNotDeducted() throws {
        var primitives = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
        // Column 40…60 × 30…50: 400 pt², 5 % of the room.
        primitives += Fixtures.walls(from: 10, minX: 40, minY: 30, maxX: 60, maxY: 50)
        // A detail inside the column 45…55 × 35…45: the column's own face, not the room's.
        primitives += Fixtures.walls(from: 20, minX: 45, minY: 35, maxX: 55, maxY: 45)
        // A 1 × 1 outline: under the floor of 0.1 % × 8000 = 8 pt².
        primitives += Fixtures.walls(from: 30, minX: 10, minY: 10, maxX: 11, maxY: 11)
        let result = RegionTracer.trace(RegionTracer.prepare(primitives: primitives), click: PDFPoint(x: 20, y: 60))
        let region = try #require(result.region, "\(result)")
        // The room's area is the outer ring's: 100 × 80 = 8000, the column not deducted.
        #expect(abs(region.area - 8000) <= 1e-9)
        #expect(region.islands.count == 1, "\(region.islands)")
        let island = try #require(region.islands.first)
        #expect(Set(island) == [PDFPoint(x: 40, y: 30), PDFPoint(x: 60, y: 30), PDFPoint(x: 60, y: 50), PDFPoint(x: 40, y: 50)])
        #expect(abs(Fixtures.fanArea(island) - 400) <= 1e-9)
    }

    @Test("A closed shape tied to the wall by a line, or touching it at a corner, is offered as an island and not deducted (L-73 re-check)")
    func tiedShapesAreOfferedNotDeducted() throws {
        // Tied by a line: column 60…70 × 30…50 joined to the east wall by a stroke along y = 40.
        // Before this rule the walk went out along the stroke, round the column and back, and the
        // shoelace over the walk came to 8000 − 200 = 7800 with no island offered — a roof
        // facet loses a snow guard tied to its eave the same way (RoofPlanSheetTraceTests).
        let tied = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)
            + Fixtures.walls(from: 10, minX: 60, minY: 30, maxX: 70, maxY: 50)
            + [Fixtures.line(20, 70, 40, 100, 40)]
        let region = try #require(RegionTracer.trace(RegionTracer.prepare(primitives: tied), click: PDFPoint(x: 20, y: 40)).region)
        // The room is its outer ring: 100 × 80 = 8000.
        #expect(abs(region.area - 8000) <= 1e-9, "\(region.area)")
        #expect(abs(Fixtures.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(Set(region.ring) == [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80), PDFPoint(x: 0, y: 80)])
        // The column is offered: 10 × 20 = 200.
        #expect(region.islands.count == 1, "\(region.islands)")
        let column = try #require(region.islands.first)
        #expect(Set(column) == [PDFPoint(x: 60, y: 30), PDFPoint(x: 70, y: 30), PDFPoint(x: 70, y: 50), PDFPoint(x: 60, y: 50)])
        #expect(abs(Fixtures.fanArea(column) - 200) <= 1e-9)

        // Touching at a corner: a diamond whose east vertex lies on the east wall at (100, 40).
        // Its diagonals are 10 and 10: 10 × 10 / 2 = 50, never deducted from the room's 8000.
        let pinched = Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80) + [
            Fixtures.line(30, 90, 40, 95, 35), Fixtures.line(31, 95, 35, 100, 40),
            Fixtures.line(32, 100, 40, 95, 45), Fixtures.line(33, 95, 45, 90, 40)
        ]
        let room = try #require(RegionTracer.trace(RegionTracer.prepare(primitives: pinched), click: PDFPoint(x: 20, y: 40)).region)
        #expect(abs(room.area - 8000) <= 1e-9, "\(room.area)")
        #expect(abs(Fixtures.fanArea(room.ring) - 8000) <= 1e-9)
        #expect(room.islands.count == 1, "\(room.islands)")
        let diamond = try #require(room.islands.first)
        #expect(Set(diamond) == [PDFPoint(x: 90, y: 40), PDFPoint(x: 95, y: 35), PDFPoint(x: 100, y: 40), PDFPoint(x: 95, y: 45)])
        #expect(abs(Fixtures.fanArea(diamond) - 50) <= 1e-9)
    }

    @Test("A room with nothing inside offers no islands")
    func noIslands() throws {
        let result = RegionTracer.trace(
            RegionTracer.prepare(primitives: Fixtures.walls(from: 1, minX: 0, minY: 0, maxX: 100, maxY: 80)),
            click: PDFPoint(x: 50, y: 40)
        )
        #expect(try #require(result.region).islands.isEmpty)
    }

    // MARK: - NL-AUTO-08: every room on the sheet

    /// Nine rooms, 100 × 80 pt each, between walls drawn as 6 pt rectangles; a 30 pt door joins
    /// the bottom-left room to its neighbour. Rooms: x ∈ [6,106], [112,212], [218,318],
    /// y ∈ [6,86], [92,172], [178,258].
    static func ninePlan() -> [VectorPrimitive] {
        var walls: [VectorPrimitive] = []
        var id: UInt64 = 1
        for y in [0.0, 86, 172, 258] {
            walls.append(Fixtures.rectangle(id, x: 0, y: y, width: 324, height: 6)); id += 1
        }
        for x in [0.0, 212, 318] {
            walls.append(Fixtures.rectangle(id, x: x, y: 0, width: 6, height: 264)); id += 1
        }
        // The wall at x = 106 with the door y 30…60.
        walls.append(Fixtures.rectangle(id, x: 106, y: 0, width: 6, height: 30)); id += 1
        walls.append(Fixtures.rectangle(id, x: 106, y: 60, width: 6, height: 204))
        return walls
    }

    static let roomOptions = RoomDetector.Options(
        minimumArea: 1_000, maximumArea: 50_000, minimumWidth: 20, maximumClosureWidth: 60
    )

    @Test("Nine rooms: nine proposed, each 100 × 80 = 8000, no wall slivers, the door closed not merged")
    func detectsNineRooms() throws {
        let result = RoomDetector.detect(RegionTracer.prepare(primitives: Self.ninePlan()), options: Self.roomOptions)
        guard case .rooms(let rooms, let truncated) = result else {
            Issue.record("expected rooms, got \(result)")
            return
        }
        #expect(!truncated)
        #expect(rooms.count == 9, "\(rooms.map(\.region.area))")
        #expect(rooms.allSatisfy { abs($0.region.area - 8000) <= 1e-9 }, "\(rooms.map { ($0.region.area, $0.region.ring, $0.closures) })")
        #expect(rooms.allSatisfy { abs(Fixtures.fanArea($0.region.ring) - 8000) <= 1e-9 })
        // The two rooms joined by the door each close it on their own face.
        let closed = rooms.filter { !$0.closures.isEmpty }
        #expect(closed.count == 2)
        #expect(Set(closed.flatMap(\.closures).map(\.width)) == [30])
    }

    @Test("A sheet over the cap is refused, not half-read")
    func tooComplexSheet() {
        let tight = RegionTracer.prepare(primitives: Self.ninePlan(), options: TraceOptions(maximumPairTests: 1))
        if case .rooms = RoomDetector.detect(tight, options: Self.roomOptions) {
            Issue.record("a sheet over the pair-test cap must be refused")
        }
    }
}

/// NL-MEASURE-11: fence lines a person draws across an opening.
@Suite("Trace with fence lines (NL-MEASURE-11)")
struct FenceTraceTests {

    /// The 25 pt door (x 37..62) in the bottom wall of the 100 × 80 room. A fence across it closes
    /// the room: 100 × 80 = 8000, traced — not proposed — and the fence is named as used.
    @Test("A fence across the door closes the room, and is named as used")
    func fenceClosesTheDoor() throws {
        let prepared = RegionTracer.prepare(primitives: AutomationTraceTests.strokeDoor)
        let click = PDFPoint(x: 50, y: 40)
        // No fence: the plain trace refuses (the opening is only proposed).
        #expect(RegionTracer.trace(prepared, click: click).isRefusal)

        let fence = ProposedClosure(start: PDFPoint(x: 37, y: 0), end: PDFPoint(x: 62, y: 0))
        let result = RegionTracer.trace(prepared, click: click, fences: [fence], maximumClosureWidth: 0)
        guard case .traced(let region) = result.outcome else {
            Issue.record("expected a trace, got \(result.outcome)")
            return
        }
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        #expect(Swift.abs(RegionTracerTests.fanArea(region.ring) - 8000) <= 1e-9)
        #expect(result.fencesUsed == [fence])

        // A fence elsewhere on the page closes nothing and is not named.
        let stray = ProposedClosure(start: PDFPoint(x: 200, y: 0), end: PDFPoint(x: 220, y: 0))
        let unused = RegionTracer.trace(prepared, click: click, fences: [stray], maximumClosureWidth: 0)
        #expect(unused.outcome == .refused(RegionTracer.trace(prepared, click: click)))
        #expect(unused.fencesUsed.isEmpty)
    }

    /// Drawn the other way round, jamb to jamb, it is the same wall: 8000, used.
    @Test("A fence drawn in the other direction closes the same room")
    func reversedFence() throws {
        let prepared = RegionTracer.prepare(primitives: AutomationTraceTests.strokeDoor)
        let fence = ProposedClosure(start: PDFPoint(x: 62, y: 0), end: PDFPoint(x: 37, y: 0))
        let result = RegionTracer.trace(prepared, click: PDFPoint(x: 50, y: 40), fences: [fence], maximumClosureWidth: 0)
        let region = try #require({ if case .traced(let r) = result.outcome { return r } else { return nil } }())
        #expect(Swift.abs(region.area - 8000) <= 1e-9)
        #expect(result.fencesUsed == [fence])
        #expect(RegionTracer.fencesUsed(ring: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 80)], fences: [fence]) == [fence],
                "a ring edge merged with the walls on either side still runs along the fence")
    }
}
