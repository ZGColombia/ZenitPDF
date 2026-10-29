import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFUIPresentation

/// Review fixes to the arc-segment work on committed markups (ADR-0030 §5.7): merge,
/// split, the traced union, Curve an Edge, vertex refusals, snapping and Remove Last Point. Every
/// expected quantity is hand-derived; 1 m per page point.
@MainActor
@Suite("Arc segments, review fixes (ADR-0030 §5.7)")
struct ArcReviewFixSessionTests {

    static let page = PageID(UUID())

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    static func ring(_ points: [(Double, Double)], bulges: [Double]? = nil) -> PolygonGeometry {
        PolygonGeometry(outer: PolygonRing(points: points.map { PDFPoint(x: $0.0, y: $0.1) }, isClosed: true, bulges: bulges))
    }

    /// The golden area: 10 × 5, its right side an outward semicircle (bulge 1).
    static let golden = ring([(0, 0), (10, 0), (10, 5), (0, 5)], bulges: [0, 1, 0, 0])

    private func makeSession(side: Double = 1000) async throws -> (TakeoffSession, DocumentID) {
        let documentID = DocumentID(UUID())
        let descriptor = ZPDFContracts.PageDescriptor(id: Self.page, documentID: documentID, index: 0, label: "A",
                                                      boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: side, height: side)))
        let session = try TakeoffSession(documentID: documentID, pages: [descriptor])
        // 100 pt = 100 m: page numbers are metres.
        _ = try await session.calibrate(page: Self.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        return (session, documentID)
    }

    private func record(_ polygon: PolygonGeometry, tool: MeasurementTool = .area, documentID: DocumentID) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 0)
        return ZPDFContracts.MarkupRecord(id: MarkupID(UUID()), documentID: documentID, pageID: Self.page, kind: .measurement,
                                          tool: tool, subject: "Bay", author: "t",
                                          geometry: MeasurementGeometry(pageID: Self.page, polygons: [polygon]),
                                          createdAt: stamp, modifiedAt: stamp)
    }

    private func value(_ session: TakeoffSession, _ id: MarkupID, _ field: ZPDFContracts.MeasurementField) async -> Double {
        NSDecimalNumber(decimal: await session.markup(id)?.measurement?[field]?.value ?? 0).doubleValue
    }

    // MARK: Merge keeps the arc in the quantity (findings 1 and 5)

    /// A Rectangle Area [0,10]×[5,8] added first, then the golden area, same subject. The merged
    /// record keeps the Rectangle Area's tool and the semicircle: area 30 + 50 + π·2.5²/2 =
    /// 80 + 3.125π, perimeter 10 + 2.5π + 3 + 10 + 8 = 31 + 2.5π.
    ///
    /// Old output: tool rectangleArea, bulges [0, 0, 0, 0, 1], netArea 80.0 and perimeter 36.0 —
    /// the whole circular segment (10.9 %) missing while the canvas drew it.
    @Test("Merging an arc area into a Rectangle Area keeps the arc in the quantity: 80 + 3.125π")
    func mergeIntoRectangleArea() async throws {
        let (session, documentID) = try await makeSession()
        let rectangle = record(Self.ring([(0, 5), (10, 5), (10, 8), (0, 8)]), tool: .rectangleArea, documentID: documentID)
        let arc = record(Self.golden, documentID: documentID)
        _ = try await session.apply(.addMarkup(rectangle))
        _ = try await session.apply(.addMarkup(arc))
        _ = try await session.applyBatch(try await session.mergePlan(markups: [rectangle.id, arc.id]).commands)
        #expect(await session.markup(rectangle.id)?.tool == .rectangleArea)
        #expect(await session.markup(rectangle.id)?.geometry?.polygons.first?.outer.hasArcs == true)
        #expect(Self.rel(await value(session, rectangle.id, .netArea), 80 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(await value(session, rectangle.id, .perimeter), 31 + 2.5 * .pi) <= 1e-12)
    }

    // MARK: A merge that encloses a gap keeps it as a cutout (finding 6, K-10)

    /// A U (0,0) → (30,0) → (30,30) → (20,30) → (20,10) → (10,10) → (10,30) → (0,30), its bottom
    /// edge an outward semicircle of r = 15 (bulge 1): 900 − 200 + π·15²/2 = 700 + 112.5π. A bar
    /// [0,30]×[30,40], 300, closes it around the 10 × 20 gap [10,20]×[10,30] (200).
    ///
    /// Coordinator decision K-10: the gap becomes a cutout of the merged area in the same batch.
    /// Merged: outline 1200 + 112.5π, cutout 200, net 1000 + 112.5π (straight: 1200, 200, 1000);
    /// one undo gives back both areas and removes the cutout. Before finding 6 the hole was stored
    /// and erased by the recompute (1200 + 112.5π); from finding 6 until K-10 the merge was refused.
    @Test("A merge that encloses a gap keeps it as a cutout, exactly, with arcs and without")
    func mergeEnclosingAGapKeepsACutout() async throws {
        for bulges in [[1.0, 0, 0, 0, 0, 0, 0, 0], nil] {
            let (session, documentID) = try await makeSession()
            let u = record(Self.ring([(0, 0), (30, 0), (30, 30), (20, 30), (20, 10), (10, 10), (10, 30), (0, 30)], bulges: bulges), documentID: documentID)
            let bar = record(Self.ring([(0, 30), (30, 30), (30, 40), (0, 40)]), documentID: documentID)
            _ = try await session.apply(.addMarkup(u))
            _ = try await session.apply(.addMarkup(bar))
            let arc = bulges == nil ? 0 : 112.5 * Double.pi
            #expect(Self.rel(await value(session, u.id, .netArea), 700 + arc) <= 1e-12)
            let plan = try await session.mergePlan(markups: [u.id, bar.id])
            #expect(plan.keptGaps == 1)
            let outcome = try await session.applyBatch(plan.commands)
            #expect(Self.rel(await value(session, u.id, .planArea), 1200 + arc) <= 1e-12)
            #expect(Self.rel(await value(session, u.id, .netArea), 1000 + arc) <= 1e-12, "the gap is not area")
            #expect(Self.rel(await value(session, u.id, .cutoutArea), 200) <= 1e-12)
            #expect(await session.markup(bar.id) == nil)
            let cutouts = await session.markup(u.id)?.cutoutMarkupIDs ?? []
            #expect(cutouts.count == 1)
            let cutoutID = try #require(cutouts.first)
            let cutout = try #require(await session.markup(cutoutID))
            #expect(cutout.tool == .polygonCutout && cutout.parentMarkupID == u.id)
            #expect(cutout.comment == AreaMergePlan.gapNote)
            // One undo: both areas back as they were, and no cutout.
            _ = try await session.revert(outcome.inverse)
            #expect(Self.rel(await value(session, u.id, .netArea), 700 + arc) <= 1e-12)
            #expect(await session.markup(bar.id) != nil)
            #expect(await session.markup(cutout.id) == nil)
            #expect(await session.markup(u.id)?.cutoutMarkupIDs.isEmpty == true)
        }
    }

    /// The same U with its inner bottom edge (20,10) → (10,10) an arc of r = 5 bulging into the gap
    /// (bulge 1): the U is 700 + π·5²/2 = 700 + 12.5π, the gap 200 − 12.5π, bounded by that arc.
    /// Merged with the bar: outline 1200 (straight), net 1200 − (200 − 12.5π) = 1000 + 12.5π, the
    /// U plus the bar exactly. The cutout's arc is removed at its exact area (ADR-0034 §2); the
    /// flattened boolean it used before is 1e-7-ish off, far outside 1e-12.
    @Test("A gap bounded by an arc is removed at its exact area: 1000 + 12.5π")
    func gapBoundedByAnArcIsExact() async throws {
        let (session, documentID) = try await makeSession()
        let u = record(Self.ring([(0, 0), (30, 0), (30, 30), (20, 30), (20, 10), (10, 10), (10, 30), (0, 30)],
                                 bulges: [0, 0, 0, 0, 1, 0, 0, 0]), documentID: documentID)
        let bar = record(Self.ring([(0, 30), (30, 30), (30, 40), (0, 40)]), documentID: documentID)
        _ = try await session.apply(.addMarkup(u))
        _ = try await session.apply(.addMarkup(bar))
        #expect(Self.rel(await value(session, u.id, .netArea), 700 + 12.5 * .pi) <= 1e-12)
        _ = try await session.applyBatch(try await session.mergePlan(markups: [u.id, bar.id]).commands)
        #expect(Self.rel(await value(session, u.id, .planArea), 1200) <= 1e-12)
        #expect(Self.rel(await value(session, u.id, .netArea), 1000 + 12.5 * .pi) <= 1e-12)
        #expect(Self.rel(await value(session, u.id, .cutoutArea), 200 - 12.5 * .pi) <= 1e-12)
    }

    /// Five areas: a bottom bar [0,30]×[0,10] whose bottom edge is an outward semicircle (r = 15,
    /// 300 + 112.5π), a left and a right post [0,10]×[10,30] and [20,30]×[10,30] (200 each), a top
    /// bar [0,30]×[30,40] (300), and a square [30,40]×[30,40] (100) against the top bar's end. The
    /// exact fold closes around the gap [10,20]×[10,30] with the square still to join; the gap is
    /// kept: outline 1300 + 112.5π, net 1100 + 112.5π. With the square far away instead, the
    /// merge is two shapes and is refused as such.
    @Test("A merge whose fold closes around a gap mid-way keeps the gap, and refuses a far area")
    func foldClosingAroundAGap() async throws {
        for far in [false, true] {
            let (session, documentID) = try await makeSession()
            let square = far ? [(100.0, 100.0), (110, 100), (110, 110), (100, 110)] : [(30.0, 30.0), (40, 30), (40, 40), (30, 40)]
            let parts = [
                record(Self.ring([(0, 0), (30, 0), (30, 10), (0, 10)], bulges: [1, 0, 0, 0]), documentID: documentID),
                record(Self.ring([(0, 10), (10, 10), (10, 30), (0, 30)]), documentID: documentID),
                record(Self.ring([(20, 10), (30, 10), (30, 30), (20, 30)]), documentID: documentID),
                record(Self.ring([(0, 30), (30, 30), (30, 40), (0, 40)]), documentID: documentID),
                record(Self.ring(square), documentID: documentID)
            ]
            for part in parts { _ = try await session.apply(.addMarkup(part)) }
            if far {
                await #expect(throws: AreaSplitRefusal.areasApart) {
                    _ = try await session.mergePlan(markups: parts.map(\.id)).commands
                }
                continue
            }
            let plan = try await session.mergePlan(markups: parts.map(\.id))
            #expect(plan.keptGaps == 1)
            _ = try await session.applyBatch(plan.commands)
            let merged = parts[0].id
            #expect(Self.rel(await value(session, merged, .planArea), 1300 + 112.5 * .pi) <= 1e-12)
            #expect(Self.rel(await value(session, merged, .netArea), 1100 + 112.5 * .pi) <= 1e-12)
            #expect(await session.markup(merged)?.geometry?.polygons.first?.outer.hasArcs == true, "the semicircle is kept")
        }
    }

    /// The traced union (⇧⌥-click) closing the same straight U with the traced bar: the plan keeps
    /// the gap as a cutout of a plan area (K-10) and refuses it for a perimeter, which has no
    /// cutouts to keep it in. An arc area whose exact union
    /// cannot be resolved says so, instead of claiming the selection is not an area. Old output: a
    /// command carrying the hole; `.notAnArea`.
    @Test("The traced union refuses a gap, and names a curved-edge refusal as one")
    func tracedUnionRefusals() throws {
        let documentID = DocumentID(UUID())
        let u = record(Self.ring([(0, 0), (30, 0), (30, 30), (20, 30), (20, 10), (10, 10), (10, 30), (0, 30)]), documentID: documentID)
        let bar = [PDFPoint(x: 0, y: 30), PDFPoint(x: 30, y: 30), PDFPoint(x: 30, y: 40), PDFPoint(x: 0, y: 40)]
        // A perimeter has no cutouts to keep a gap in, so its union refuses one.
        var perimeter = u
        perimeter.tool = .perimeter
        #expect(throws: TracedUnion.Refusal.enclosesGap) { _ = try TracedUnion.plan(adding: bar, to: perimeter) }
        // K-10: the plan the canvas applies keeps the gap as a cutout of the grown area.
        let plan = try TracedUnion.plan(adding: bar, to: u)
        #expect(plan.keptGaps == 1)
        #expect(plan.commands.count == 2)
        if case .addCutout(let parent, let cutout) = plan.commands.last {
            #expect(parent == u.id)
            #expect(Swift.abs(cutout.geometry?.polygons.first?.outer.exactSignedArea ?? 0) == 200, "the 10 × 20 gap")
        } else {
            Issue.record("no cutout for the gap")
        }
        // A traced ring that crosses itself cannot be unioned exactly with an arc area.
        let arc = record(Self.golden, documentID: documentID)
        let bowTie = [PDFPoint(x: 0, y: 0), PDFPoint(x: 5, y: 5), PDFPoint(x: 5, y: 0), PDFPoint(x: 0, y: 5)]
        #expect(throws: TracedUnion.Refusal.curvedEdgeNotExact) { _ = try TracedUnion.plan(adding: bowTie, to: arc) }
    }

    // MARK: Split of a small arc area at a sheet position (finding 2)

    /// The rounded-corner shape (0,0),(10,0),(10,6) ⌒ (6,10),(0,10) (quarter arc r = 4, bulge
    /// tan(π/8)) scaled by 0.2 — area 0.04·(84 + 4π) — and moved to (3000.37, 2000.61) on a 5000 pt
    /// sheet, split along its diagonal of symmetry: two halves of 0.02·(84 + 4π) each.
    ///
    /// Old output: `AreaSplitRefusal.partsDoNotSum` — the re-check's raw-coordinate shoelace was
    /// 7.6e-10 off against a tolerance of 6.18e-11.
    @Test("A small arc area far from the origin splits into two exact halves")
    func splitAtSheetPosition() async throws {
        let (session, documentID) = try await makeSession(side: 5000)
        let (dx, dy) = (3000.37, 2000.61)
        let shape = PolygonGeometry(outer: PolygonRing(
            points: [(0.0, 0.0), (10, 0), (10, 6), (6, 10), (0, 10)].map { PDFPoint(x: 0.2 * $0.0 + dx, y: 0.2 * $0.1 + dy) },
            isClosed: true,
            bulges: [0, 0, Foundation.tan(Double.pi / 8), 0, 0]
        ))
        let parent = record(shape, documentID: documentID)
        _ = try await session.apply(.addMarkup(parent))
        let whole = await value(session, parent.id, .netArea)
        #expect(Self.rel(whole, 0.04 * (84 + 4 * .pi)) <= 1e-9)
        let commands = try await session.splitCommands(markup: parent.id, along: [
            PDFPoint(x: dx - 0.2, y: dy - 0.2), PDFPoint(x: dx + 2.2, y: dy + 2.2)
        ])
        _ = try await session.applyBatch(commands)
        let parts = await session.orderedMarkups.filter { $0.id != parent.id }
        #expect(parts.count == 2)
        var sum = 0.0
        for part in parts {
            let area = await value(session, part.id, .netArea)
            sum += area
            #expect(Self.rel(area, 0.02 * (84 + 4 * .pi)) <= 1e-9)
        }
        #expect(Self.rel(sum, whole) <= 1e-12)
    }

    // MARK: Curve an Edge on cutouts (finding 8, then C-08)

    /// Finding 8 refused to bend a cutout while its hole was subtracted by the flattened boolean
    /// (the parent lost 557.0590 for an exact curved hole of 557.0796). Since C-08 (ADR-0037) the
    /// engine subtracts a cutout on its arcs, so a Polygon Cutout bends like an area; an Ellipse
    /// Cutout has no edge to bend. The exact loss through the session is asserted in
    /// `Iter3QuantitiesCoreArcCutoutTests.curvedCutoutEdge`.
    /// Old output (before C-08): `bending(tool: .polygonCutout)` was nil and
    /// `allowsArcEdges(.polygonCutout)` false.
    @Test("Curve an Edge bends a Polygon Cutout and an area, never an Ellipse Cutout")
    func curveEdgeRefusesCutouts() {
        let square = MeasurementGeometry(pageID: Self.page, polygons: [Self.ring([(40, 40), (60, 40), (60, 60), (40, 60)])])
        #expect(MarkupTopologyEditing.bending(edgeAfter: 0, through: PDFPoint(x: 50, y: 30), in: square, tool: .polygonCutout) != nil)
        #expect(MarkupTopologyEditing.bending(edgeAfter: 0, through: PDFPoint(x: 50, y: 30), in: square, tool: .ellipseCutout) == nil)
        #expect(MarkupTopologyEditing.bending(edgeAfter: 0, through: PDFPoint(x: 50, y: 30), in: square, tool: .area) != nil)
        #expect(MarkupTopologyEditing.allowsArcEdges(.polygonCutout) && !MarkupTopologyEditing.allowsArcEdges(.ellipseCutout))
        #expect(MarkupTopologyEditing.allowsArcEdges(.area) && MarkupTopologyEditing.allowsArcEdges(.polylength))
    }

    // MARK: Vertex edits name their refusal (findings 9 and 16)

    /// The golden area split at its apex has quarter arcs meeting at (12.5, 2.5); their outer ends
    /// meet straight edges. Removing such an end, or inserting on an arc's end, cannot be exact.
    @Test("Vertex insert and remove say why they were refused")
    func topologyRefusalReasons() throws {
        let golden = MeasurementGeometry(pageID: Self.page, polygons: [Self.golden])
        let split = try #require(MarkupTopologyEditing.inserting(PDFPoint(x: 13, y: 2.5), afterVertex: 1, in: golden, tool: .area))
        #expect(MarkupTopologyEditing.removal(vertexAt: 1, in: split, tool: .area) == .failure(.curvedEdgeNotExact))
        // A click that projects onto the arc's start (10, 0) cuts nothing.
        #expect(MarkupTopologyEditing.insertion(PDFPoint(x: 10, y: -1), afterVertex: 1, in: golden, tool: .area) == .failure(.curvedEdgeNotExact))
        let triangle = MeasurementGeometry(pageID: Self.page, polygons: [Self.ring([(0, 0), (10, 0), (0, 10)])])
        #expect(MarkupTopologyEditing.removal(vertexAt: 0, in: triangle, tool: .area) == .failure(.atMinimum))
        let length = MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0)])
        #expect(MarkupTopologyEditing.insertion(PDFPoint(x: 5, y: 0), afterVertex: 0, in: length, tool: .length) == .failure(.fixedShape))
        // What succeeds is what `inserting`/`removing` return.
        #expect(try MarkupTopologyEditing.removal(vertexAt: 2, in: split, tool: .area).get() == MarkupTopologyEditing.removing(vertexAt: 2, in: split, tool: .area))
    }

    // MARK: Snapping follows edits (finding 12)

    /// The page's snap index is built first, as the app builds it at open; then the golden shape at
    /// ×20 — (100,100) → (300,100) ⌒ (300,200) → (100,200), centre (300,150), r = 50 — is added. A
    /// pointer 2 pt outside the arc at 30° snaps to (300 + 50·cos 30°, 150 + 50·sin 30°). Removing
    /// the markup takes it out of the index; undoing the removal puts it back.
    ///
    /// Old output: no winner — the index only knew the markups that existed when it was built.
    @Test("A markup added, removed or restored after the index was built snaps accordingly")
    func snapIndexFollowsEdits() async throws {
        let (session, documentID) = try await makeSession()
        let descriptor = try #require(await session.pageDescriptors.first { $0.id == Self.page })
        _ = try await session.buildSnapIndex(page: descriptor, extraction: nil)
        let bay = record(Self.ring([(100, 100), (300, 100), (300, 200), (100, 200)], bulges: [0, 1, 0, 0]), documentID: documentID)
        _ = try await session.apply(.addMarkup(bay))
        let angle = Double.pi / 6
        let pointer = PDFPoint(x: 300 + 52 * Foundation.cos(angle), y: 150 + 52 * Foundation.sin(angle))
        let layout = PageViewLayout(zoom: 1, backingScale: 2)
        let snapped = try await session.resolveSnap(pageID: Self.page, pagePoint: pointer, layout: layout)
        let winner = try #require(snapped.winner)
        #expect(winner.kind == .markupEdge)
        #expect(Swift.abs(winner.position.x - (300 + 50 * Foundation.cos(angle))) <= 1e-9)
        #expect(Swift.abs(winner.position.y - (150 + 50 * Foundation.sin(angle))) <= 1e-9)

        let removal = try await session.apply(.removeMarkup(bay.id))
        let gone = try await session.resolveSnap(pageID: Self.page, pagePoint: pointer, layout: layout, sequence: 1)
        #expect(gone.winner?.kind != .markupEdge)
        _ = try await session.revert(removal.inverse)
        let back = try await session.resolveSnap(pageID: Self.page, pagePoint: pointer, layout: layout, sequence: 2)
        #expect(back.winner?.kind == .markupEdge)
    }

    // MARK: Presenter: Remove Last Point and boundary captures (findings 19, 10 and 18)

    private func makePresenter() async throws -> AppMeasurementToolPresenter {
        let (session, documentID) = try await makeSession()
        return AppMeasurementToolPresenter(session: session, documentID: documentID, pageID: Self.page)
    }

    private func place(_ presenter: AppMeasurementToolPresenter, _ x: Double, _ y: Double) async {
        presenter.placePoint(PDFPointValue(x: x, y: y))
        await presenter.settlePlacements()
    }

    /// Measure ▸ Remove Last Point reaches `removeLastPoint()`. With an arc's through point placed it
    /// takes the through point back first — the arc stays armed — then the last vertex.
    ///
    /// Old output: the vertex (10, 0) went, and the through point (12.5, 2.5) stayed armed, now
    /// hanging from (0, 0).
    @Test("Remove Last Point takes back a placed through point before the vertex it hangs from")
    func removeLastPointTakesTheThroughPointFirst() async throws {
        let presenter = try await makePresenter()
        presenter.activate(kind: .polylength)
        await place(presenter, 0, 0)
        await place(presenter, 10, 0)
        presenter.setArcNextSegment(true)
        presenter.placeArcThroughPoint(PDFPointValue(x: 12.5, y: 2.5))
        await presenter.settlePlacements()
        #expect(presenter.arcThroughPoint != nil)
        presenter.removeLastPoint()
        #expect(presenter.placedPoints.count == 2)
        #expect(presenter.arcThroughPoint == nil)
        #expect(presenter.isArcNextSegment, "the arc stays armed for a new through point")
        presenter.removeLastPoint()
        #expect(presenter.placedPoints == [PDFPointValue(x: 0, y: 0)])
    }

    /// A Scale Region or Project Zone boundary is drawn with straight edges, so the presenter tells
    /// its host that A cannot arm an arc there; an ordinary Area can.
    @Test("A boundary capture draws no arcs; an ordinary area does")
    func boundaryCaptureDrawsNoArcs() async throws {
        let presenter = try await makePresenter()
        presenter.beginBoundaryCapture(.scaleRegion)
        await place(presenter, 0, 0)
        #expect(!presenter.drawsArcSegments)
        presenter.setArcNextSegment(true)
        #expect(!presenter.isArcNextSegment)
        presenter.activate(kind: .area)
        await place(presenter, 0, 0)
        #expect(presenter.drawsArcSegments)
    }
}
