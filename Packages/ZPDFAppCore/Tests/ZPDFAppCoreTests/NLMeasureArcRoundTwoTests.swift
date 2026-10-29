import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation

/// NL-MEASURE-05 remaining parts on committed markups (ADR-0030 §5.6): insert and remove on arcs,
/// Split and Merge of areas with arcs through the session, and the Scale Region cut of a chain
/// whose arc crosses a boundary and of an area. Every expected value is hand-derived; rel ≤ 1e-12.
@Suite("Arc segments, round two: edits, split, merge, region cut (NL-MEASURE-05)")
struct NLMeasureArcRoundTwoTests {

    static let page = PageID(UUID())
    static let quarter = Foundation.tan(Double.pi / 8)

    static func near(_ values: [Double]?, _ expected: [Double]) -> Bool {
        guard let values, values.count == expected.count else { return false }
        return zip(values, expected).allSatisfy { Swift.abs($0 - $1) <= 1e-12 }
    }

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    /// The golden area: 10 × 5, right side an outward semicircle (bulge 1).
    static let golden = MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
        points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 5), PDFPoint(x: 0, y: 5)],
        isClosed: true,
        bulges: [0, 1, 0, 0]
    ))])

    // MARK: Insert and remove

    /// Insert near the apex splits the semicircle into quarter arcs (tan(π/8) each); removing that
    /// vertex joins them back into the one arc, bulge tan(π/4) = 1. The arc's two ends touch a
    /// straight edge each, so removing either is refused — no single bulge describes a straight edge
    /// and an arc as one edge.
    @Test("Insert on an arc splits it; removing the cut joins it; an arc's corner is not removed")
    func insertAndRemove() throws {
        let split = try #require(MarkupTopologyEditing.inserting(PDFPoint(x: 13, y: 2.5), afterVertex: 1, in: Self.golden, tool: .area))
        #expect(Self.near(split.polygons.first?.outer.bulges, [0, Self.quarter, Self.quarter, 0, 0]))
        let joined = try #require(MarkupTopologyEditing.removing(vertexAt: 2, in: split, tool: .area))
        #expect(Self.near(joined.polygons.first?.outer.bulges, [0, 1, 0, 0]))
        #expect(joined.polygons.first?.outer.points.count == 4)
        #expect(MarkupTopologyEditing.removing(vertexAt: 1, in: split, tool: .area) == nil)
        #expect(MarkupTopologyEditing.removing(vertexAt: 3, in: split, tool: .area) == nil)

        // Two arcs of different circles meeting at a vertex: (0,0) ⌒ (10,0) ⌒ (20,0) with bulges
        // 1 and 0.5 — radii 5 and 10 / (2·sin(2·atan 0.5)) = 10 / 1.6 = 6.25, not one circle: refused.
        let chain = MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 20, y: 0)], pointBulges: [1, 0.5, 0])
        #expect(MarkupTopologyEditing.removing(vertexAt: 1, in: chain, tool: .polylength) == nil)
        // Removing an end of an open chain removes its one edge, arc or not: the last vertex goes
        // with the 0.5 arc, the first with the semicircle.
        let withoutLast = try #require(MarkupTopologyEditing.removing(vertexAt: 2, in: chain, tool: .polylength))
        #expect(Self.near(withoutLast.pointBulges, [1, 0]))
        let withoutFirst = try #require(MarkupTopologyEditing.removing(vertexAt: 0, in: chain, tool: .polylength))
        #expect(Self.near(withoutFirst.pointBulges, [0.5, 0]))
    }

    // MARK: Split and merge through the session

    private func makeSession() async throws -> (TakeoffSession, DocumentID) {
        let documentID = DocumentID(UUID())
        let descriptor = ZPDFContracts.PageDescriptor(id: Self.page, documentID: documentID, index: 0, label: "A",
                                                      boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [descriptor])
        // 100 pt = 100 m: 1 m per point, so page numbers are metres.
        _ = try await session.calibrate(page: Self.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        return (session, documentID)
    }

    private func area(_ geometry: MeasurementGeometry, documentID: DocumentID) -> ZPDFContracts.MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 0)
        return ZPDFContracts.MarkupRecord(id: MarkupID(UUID()), documentID: documentID, pageID: Self.page, kind: .measurement,
                                          tool: .area, subject: "Bay", author: "t", geometry: geometry, createdAt: stamp, modifiedAt: stamp)
    }

    private func value(_ session: TakeoffSession, _ id: MarkupID, _ field: ZPDFContracts.MeasurementField) async -> Double {
        NSDecimalNumber(decimal: await session.markup(id)?.measurement?[field]?.value ?? 0).doubleValue
    }

    /// Split along y = 2.5 through the arc's apex: two parts of 25 + 1.5625π m² (a 10 × 2.5
    /// rectangle and a quarter disc π·2.5²/4), perimeters 25 + 1.25π; they sum to 50 + 3.125π, the
    /// parent is gone, and one undo brings it back.
    @Test("Split through the session: two exact halves with quarter arcs; one undo restores")
    func splitThroughSession() async throws {
        let (session, documentID) = try await makeSession()
        let record = area(Self.golden, documentID: documentID)
        _ = try await session.apply(.addMarkup(record))
        let commands = try await session.splitCommands(markup: record.id, along: [PDFPoint(x: -5, y: 2.5), PDFPoint(x: 20, y: 2.5)])
        var inverses: [DocumentCommandInverse] = []
        for command in commands { inverses.append(try await session.apply(command).inverse) }
        let parts = await session.orderedMarkups.filter { $0.id != record.id }
        #expect(parts.count == 2)
        #expect(await session.markup(record.id) == nil)
        var sum = 0.0
        for part in parts {
            let netArea = await value(session, part.id, .netArea)
            sum += netArea
            #expect(Self.rel(netArea, 25 + 1.5625 * .pi) <= 1e-12)
            #expect(Self.rel(await value(session, part.id, .perimeter), 25 + 1.25 * .pi) <= 1e-12)
            #expect(part.geometry?.polygons.first?.outer.validBulges?.filter { $0 != 0 }.count == 1)
        }
        #expect(Self.rel(sum, 50 + 3.125 * .pi) <= 1e-12)
        for inverse in inverses.reversed() { _ = try await session.revert(inverse) }
        #expect(Self.rel(await value(session, record.id, .netArea), 50 + 3.125 * .pi) <= 1e-12)
    }

    /// Merge the golden area with the rectangle [0,10]×[5,8] above it: 80 + 3.125π m², perimeter
    /// 31 + 2.5π, the semicircle kept whole (bulge 1) on the merged boundary.
    @Test("Merge through the session keeps the arc exact: 80 + 3.125π")
    func mergeThroughSession() async throws {
        let (session, documentID) = try await makeSession()
        let first = area(Self.golden, documentID: documentID)
        let second = area(MeasurementGeometry(pageID: Self.page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 5), PDFPoint(x: 10, y: 5), PDFPoint(x: 10, y: 8), PDFPoint(x: 0, y: 8)
        ]))]), documentID: documentID)
        _ = try await session.apply(.addMarkup(first))
        _ = try await session.apply(.addMarkup(second))
        for command in try await session.mergePlan(markups: [first.id, second.id]).commands { _ = try await session.apply(command) }
        #expect(await session.markup(second.id) == nil)
        #expect(Self.rel(await value(session, first.id, .netArea), 80 + 3.125 * .pi) <= 1e-12)
        #expect(Self.rel(await value(session, first.id, .perimeter), 31 + 2.5 * .pi) <= 1e-12)
        #expect(await session.markup(first.id)?.geometry?.polygons.first?.outer.validBulges?.filter { $0 != 0 }.count == 1)
    }

    // MARK: Scale Region cut

    private static func square(_ x: Double, _ y: Double, _ side: Double) -> PolygonRing {
        PolygonRing(points: [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y), PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)])
    }

    /// The exact area cut refuses what it cannot do honestly: a region wholly inside the area
    /// (the bare-sheet piece would need a hole, and a hole is a cutout), and two regions that
    /// overlap inside the area (the shared piece would be counted twice). The chain cut of an
    /// arc that stays inside one region is no cut at all.
    @Test("Area cut refusals: a region inside the area, overlapping regions; an arc inside one region is not cut")
    func areaCutRefusals() throws {
        let area = PolygonGeometry(outer: Self.square(0, 0, 100))
        let inner = ScaleRegion(id: ScaleRegionID(UUID()), pageID: Self.page, scaleID: ScaleID(UUID()), boundary: Self.square(40, 40, 20))
        #expect(ScaleRegionSplitter.split(area: area, resolver: try ScaleRegionResolver(pageID: Self.page, regions: [inner])) == nil)

        let left = ScaleRegion(id: ScaleRegionID(UUID()), pageID: Self.page, scaleID: ScaleID(UUID()), boundary: Self.square(-50, -50, 110))
        let right = ScaleRegion(id: ScaleRegionID(UUID()), pageID: Self.page, scaleID: ScaleID(UUID()), boundary: Self.square(50, -50, 110))
        #expect(ScaleRegionSplitter.split(area: area, resolver: try ScaleRegionResolver(pageID: Self.page, regions: [left, right])) == nil)

        // Two regions that abut at x = 50 tile the square: 50 × 100 each, exactly.
        let west = ScaleRegion(id: ScaleRegionID(UUID()), pageID: Self.page, scaleID: ScaleID(UUID()),
                               boundary: PolygonRing(points: [PDFPoint(x: -50, y: -50), PDFPoint(x: 50, y: -50), PDFPoint(x: 50, y: 150), PDFPoint(x: -50, y: 150)]))
        let east = ScaleRegion(id: ScaleRegionID(UUID()), pageID: Self.page, scaleID: ScaleID(UUID()),
                               boundary: PolygonRing(points: [PDFPoint(x: 50, y: -50), PDFPoint(x: 150, y: -50), PDFPoint(x: 150, y: 150), PDFPoint(x: 50, y: 150)]))
        let tiles = try #require(ScaleRegionSplitter.split(area: area, resolver: try ScaleRegionResolver(pageID: Self.page, regions: [west, east])))
        #expect(tiles.count == 2)
        #expect(tiles.allSatisfy { Swift.abs(Swift.abs($0.polygon?.outer.exactSignedArea ?? 0) - 5_000) <= 1e-9 })

        let chain = MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 20, y: 10)], pointBulges: [1, 0])
        #expect(ScaleRegionSplitter.split(geometry: chain, resolver: try ScaleRegionResolver(pageID: Self.page, regions: [west])) == nil)
    }

    @MainActor
    private struct RegionFixture {
        let environment: AppCoreEnvironment
        let session: TakeoffSession
        let documentID: DocumentID
        let pageID: PageID
        let detail: ScaleRegionDefinition
    }

    /// Page scale 100 pt = 10 m (0.1 m/pt); a Detail region, the square [300, 500] × [0, 200], at
    /// 100 pt = 1 m (0.01 m/pt).
    @MainActor
    private func regionFixture() async throws -> RegionFixture {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000)))
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                 knownLength: 10, knownLengthUnit: .metre)
        let detailScaleID = ScaleID(UUID())
        try await environment.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                 knownLength: 1, knownLengthUnit: .metre, scaleID: detailScaleID)
        let detail = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page.id, name: "Detail",
            boundary: [PDFPoint(x: 300, y: 0), PDFPoint(x: 500, y: 0), PDFPoint(x: 500, y: 200), PDFPoint(x: 300, y: 200)],
            scaleID: detailScaleID, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )
        try await environment.commands.perform(.setScaleRegions([detail]))
        return RegionFixture(environment: environment, session: session, documentID: documentID, pageID: page.id, detail: detail)
    }

    @MainActor
    private func commitAndSplit(_ fixture: RegionFixture, tool: MeasurementTool, geometry: MeasurementGeometry) async throws -> [ZPDFContracts.MarkupRecord] {
        var asked: [PendingScaleRegionCrossing] = []
        fixture.environment.onScaleRegionCrossing = { asked.append($0) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        await fixture.environment.commit(
            ZPDFContracts.MarkupRecord(id: MarkupID(UUID()), documentID: fixture.documentID, pageID: fixture.pageID, kind: .measurement,
                                       tool: tool, subject: "S", label: "S A", author: "test", geometry: geometry,
                                       createdAt: stamp, modifiedAt: stamp),
            family: .measurement
        )
        let crossing = try #require(asked.first, "every vertex is outside the region; only the arc bulges into it")
        #expect(crossing.canSplitAtBoundary)
        await fixture.environment.resolveScaleRegionCrossing(id: crossing.id, outcome: .splitAtBoundary)
        return await fixture.session.orderedMarkups
    }

    /// A polylength (100,50) → (280,50) then a semicircle (280,50) ⌒ (280,150), bulge 1: centre
    /// (280,100), r = 50, reaching x = 330. It crosses the Detail boundary x = 300 where
    /// cos φ = 20/50 = 0.4, at φ = ±acos 0.4. Pieces:
    ///   • bare sheet: 180 pt straight + the arc from −π/2 to −acos 0.4, 50·(π/2 − acos 0.4) pt,
    ///     at 0.1 m/pt: 18 + 5·(π/2 − acos 0.4) m;
    ///   • Detail: the arc from −acos 0.4 to +acos 0.4, 100·acos 0.4 pt, at 0.01 m/pt: acos 0.4 m;
    ///   • bare sheet: the arc from acos 0.4 to π/2, 50·(π/2 − acos 0.4) pt: 5·(π/2 − acos 0.4) m.
    @Test("A chain whose arc crosses a Scale Region boundary: each piece at its own scale")
    @MainActor
    func chainArcAcrossRegion() async throws {
        let fixture = try await regionFixture()
        let chain = MeasurementGeometry(
            pageID: fixture.pageID,
            points: [PDFPoint(x: 100, y: 50), PDFPoint(x: 280, y: 50), PDFPoint(x: 280, y: 150)],
            pointBulges: [0, 1, 0]
        )
        let pieces = try await commitAndSplit(fixture, tool: .polylength, geometry: chain)
        #expect(pieces.count == 3)
        let a = Foundation.acos(0.4)
        let side = 5 * (Double.pi / 2 - a)
        var expected: [(ScaleRegionID?, Double)] = [(nil, 18 + side), (fixture.detail.id, a), (nil, side)]
        for piece in pieces {
            let length = NSDecimalNumber(decimal: piece.measurement?[.planLength]?.value ?? 0).doubleValue
            let match = expected.firstIndex { $0.0 == piece.scaleRegionID && Self.rel(length, $0.1) <= 1e-12 }
            #expect(match != nil, "unexpected piece \(String(describing: piece.scaleRegionID)) \(length)")
            if let match { expected.remove(at: match) }
            #expect(piece.geometry?.validPointBulges != nil, "every piece keeps an arc")
        }
        #expect(expected.isEmpty)
    }

    /// An area: the rectangle [100,280] × [50,150] whose right side is the same semicircle. The
    /// Detail piece is the circular segment beyond the chord x = 300, d = 20 from the centre:
    /// r²·acos(d/r) − d·√(r² − d²) = 2500·acos 0.4 − 20·√2100 pt², at (0.01 m/pt)²; the bare-sheet
    /// piece is the rest, 18 000 + 1250π − (2500·acos 0.4 − 20·√2100) pt², at (0.1 m/pt)².
    @Test("An area whose arc crosses a Scale Region boundary: each piece at its own scale")
    @MainActor
    func areaArcAcrossRegion() async throws {
        let fixture = try await regionFixture()
        let geometry = MeasurementGeometry(pageID: fixture.pageID, polygons: [PolygonGeometry(outer: PolygonRing(
            points: [PDFPoint(x: 100, y: 50), PDFPoint(x: 280, y: 50), PDFPoint(x: 280, y: 150), PDFPoint(x: 100, y: 150)],
            isClosed: true,
            bulges: [0, 1, 0, 0]
        ))])
        let pieces = try await commitAndSplit(fixture, tool: .area, geometry: geometry)
        #expect(pieces.count == 2)
        let segment = 2500 * Foundation.acos(0.4) - 20 * 2100.0.squareRoot()
        let bare = (18_000 + 1250 * Double.pi - segment) * 0.01
        let detail = segment * 0.0001
        for piece in pieces {
            let netArea = NSDecimalNumber(decimal: piece.measurement?[.netArea]?.value ?? 0).doubleValue
            if piece.scaleRegionID == fixture.detail.id {
                #expect(Self.rel(netArea, detail) <= 1e-12, "\(netArea) vs \(detail)")
            } else {
                #expect(piece.scaleRegionID == nil)
                #expect(Self.rel(netArea, bare) <= 1e-12, "\(netArea) vs \(bare)")
            }
            #expect(piece.geometry?.polygons.first?.outer.validBulges != nil, "both pieces keep a piece of the arc")
        }
    }
}
