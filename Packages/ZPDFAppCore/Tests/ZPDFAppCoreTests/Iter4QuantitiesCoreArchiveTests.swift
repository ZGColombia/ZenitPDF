import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence

/// U-084: arc edges survive save and reopen.
///
/// Page scale 100 pt = 100 m, so page numbers are metres. Every expected value is hand-derived in
/// the comment beside it.
@Suite("Iteration 4 — arcs through the archive (U-084)")
struct Iter4QuantitiesCoreArchiveTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    static func rel(_ value: Double, _ expected: Double) -> Double {
        Swift.abs(value - expected) / Swift.abs(expected)
    }

    static func number(_ record: ZPDFContracts.MarkupRecord?, _ field: ZPDFContracts.MeasurementField) -> Double? {
        guard let value = record?.measurement?[field]?.value else { return nil }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    static func record(
        on page: ZPDFContracts.PageDescriptor,
        tool: MeasurementTool,
        geometry: MeasurementGeometry
    ) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: tool,
            subject: "Arc", author: "A. Berg", geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    /// A 10 × 5 slab (100, 100)–(110, 105) whose right side (110, 100) → (110, 105) is a semicircle
    /// (bulge tan(π/4) = 1) bulging outwards: 50 + π·2.5²/2 = 50 + 3.125π m². A round opening of
    /// radius 1 about (104, 102.5), drawn as a Polygon Cutout of four quarter arcs (bulge
    /// tan(π/8)), removes π: net 50 + 2.125π. A Length (100, 120) → (110, 120) bent into a
    /// semicircle (bulges [1, 0]) is 5π m.
    ///
    /// Old output after write → read → hydrate: the blob-only codec wrote x and y and dropped every
    /// bulge, so the slab reopened as its 10 × 5 chord rectangle, the opening as the 2 m² square of
    /// its four vertices (net 48 instead of 56.68), and the Length as its 10 m chord instead of
    /// 15.71 m.
    @Test("Bulged areas, cutouts and lengths reopen with their arcs and their values")
    func arcsSurviveSaveAndReopen() async throws {
        let directory = try Iter1AppCoreArchiveTests.workspace("it4-arcs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let page = fixture.firstPage
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages, units: .metric)
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 100, knownLengthUnit: .metre)

        let slabRing = PolygonRing(
            points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 110, y: 100), PDFPoint(x: 110, y: 105), PDFPoint(x: 100, y: 105)],
            isClosed: true,
            bulges: [0, 1, 0, 0]
        )
        let slab = Self.record(on: page, tool: .area, geometry: MeasurementGeometry(
            pageID: page.id, polygons: [PolygonGeometry(outer: slabRing)]
        ))
        _ = try await session.apply(.addMarkup(slab))
        #expect(Self.rel(try #require(Self.number(await session.markup(slab.id), .netArea)), 50 + 3.125 * Double.pi) <= 1e-12)

        let quarter = tan(Double.pi / 8)
        let openingRing = PolygonRing(
            points: [PDFPoint(x: 105, y: 102.5), PDFPoint(x: 104, y: 103.5), PDFPoint(x: 103, y: 102.5), PDFPoint(x: 104, y: 101.5)],
            isClosed: true,
            bulges: [quarter, quarter, quarter, quarter]
        )
        let opening = Self.record(on: page, tool: .polygonCutout, geometry: MeasurementGeometry(
            pageID: page.id, polygons: [PolygonGeometry(outer: openingRing)]
        ))
        _ = try await session.apply(.addCutout(parent: slab.id, cutout: opening))

        let wall = Self.record(on: page, tool: .length, geometry: MeasurementGeometry(
            pageID: page.id, points: [PDFPoint(x: 100, y: 120), PDFPoint(x: 110, y: 120)], pointBulges: [1, 0]
        ))
        _ = try await session.apply(.addMarkup(wall))

        let net = 50 + 2.125 * Double.pi
        let length = 5 * Double.pi
        #expect(Self.rel(try #require(Self.number(await session.markup(slab.id), .netArea)), net) <= 1e-12)
        #expect(Self.rel(try #require(Self.number(await session.markup(opening.id), .cutoutArea)), Double.pi) <= 1e-12)
        #expect(Self.rel(try #require(Self.number(await session.markup(wall.id), .planLength)), length) <= 1e-12)

        let restored = try await Iter1AppCoreArchiveTests.reopen(session, fixture: fixture, in: directory)

        let reopenedSlab = try #require(await restored.markup(slab.id))
        #expect(reopenedSlab.geometry?.polygons.first?.outer.bulges == [0, 1, 0, 0])
        let reopenedOpening = try #require(await restored.markup(opening.id))
        #expect(reopenedOpening.geometry?.polygons.first?.outer.bulges == [quarter, quarter, quarter, quarter])
        let reopenedWall = try #require(await restored.markup(wall.id))
        #expect(reopenedWall.geometry?.pointBulges == [1, 0])

        let slabNet = try #require(Self.number(reopenedSlab, .netArea))
        #expect(Self.rel(slabNet, net) <= 1e-12, "net \(slabNet) for \(net); old 48")
        #expect(Self.rel(try #require(Self.number(reopenedOpening, .cutoutArea)), Double.pi) <= 1e-12)
        let wallLength = try #require(Self.number(reopenedWall, .planLength))
        #expect(Self.rel(wallLength, length) <= 1e-12, "length \(wallLength) for \(length); old 10")
    }

    /// Straight shapes keep the bit-exact blob-only path: no JSON sidecar is written for them.
    @Test("Straight polylines and polygons still go through the blob alone")
    func straightShapesStayBlobOnly() throws {
        let page = PageID(UUID())
        let line = MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 3, y: 4)])
        #expect(try TakeoffGeometryCodec.encode(line).json == nil)
        let square = MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
            points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1), PDFPoint(x: 0, y: 1)]
        ))])
        #expect(try TakeoffGeometryCodec.encode(square).json == nil)
        // Old output: `json == nil` for both of these too, so the bulges were lost.
        let bentLine = MeasurementGeometry(pageID: page, points: line.points, pointBulges: [0.5, 0])
        let bentSquare = MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
            points: square.polygons[0].outer.points, isClosed: true, bulges: [0, 0.25, 0, 0]
        ))])
        for geometry in [bentLine, bentSquare] {
            let encoded = try TakeoffGeometryCodec.encode(geometry)
            #expect(encoded.json != nil)
            let decoded = try TakeoffGeometryCodec.decode(blob: encoded.blob, json: encoded.json, pageID: page, tool: nil)
            #expect(decoded == geometry)
        }
    }
}
