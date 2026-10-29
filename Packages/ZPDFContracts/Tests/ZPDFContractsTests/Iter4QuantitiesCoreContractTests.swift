import Foundation
import Testing
@testable import ZPDFContracts

/// U-093: one rule for the box an ellipse tool
/// is drawn inscribed in.
@Suite("U-093 — the box an ellipse is inscribed in (contracts)")
struct Iter4QuantitiesCoreContractTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-000000000093")!)

    static func record(tool: MeasurementTool?, kind: MarkupKind = .measurement, geometry: MeasurementGeometry) -> MarkupRecord {
        let stamp = Date(timeIntervalSince1970: 0)
        return MarkupRecord(
            id: MarkupID(UUID(uuidString: "00000000-0000-4000-8000-000000000094")!),
            documentID: DocumentID(UUID(uuidString: "00000000-0000-4000-8000-000000000095")!),
            pageID: page, kind: kind, tool: tool, subject: "U-093", author: "A. Berg",
            geometry: geometry, createdAt: stamp, modifiedAt: stamp
        )
    }

    /// Each shape an ellipse tool can be stored as, with its box by hand: a circle about (50, 50)
    /// of radius 10 is (40, 40)–(60, 60); two points are opposite corners (100, 200)–(300, 100)
    /// read as (100, 100)–(300, 200); four points are bounded; a segment is its box; a ring is
    /// its box. The record's inscribed box is the geometry's `ellipseBox` for both ellipse tools.
    @Test("U-093: MeasurementGeometry.ellipseBox is the box, and the record reads it")
    func ellipseBoxRule() throws {
        let circle = MeasurementGeometry(pageID: Self.page, circles: [CircleGeometry(center: PDFPoint(x: 50, y: 50), radius: 10)])
        #expect(circle.ellipseBox == PDFRect(x: 40, y: 40, width: 20, height: 20))
        let corners = MeasurementGeometry(pageID: Self.page, points: [PDFPoint(x: 100, y: 200), PDFPoint(x: 300, y: 100)])
        #expect(corners.ellipseBox == PDFRect(x: 100, y: 100, width: 200, height: 100))
        let four = MeasurementGeometry(pageID: Self.page, points: [
            PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 200), PDFPoint(x: 100, y: 200)
        ])
        #expect(four.ellipseBox == PDFRect(x: 100, y: 100, width: 200, height: 100))
        let segment = MeasurementGeometry(pageID: Self.page, segments: [SegmentGeometry(start: PDFPoint(x: 0, y: 10), end: PDFPoint(x: 20, y: 0))])
        #expect(segment.ellipseBox == PDFRect(x: 0, y: 0, width: 20, height: 10))
        let ring = MeasurementGeometry(pageID: Self.page, polygons: [PolygonGeometry(outer: PolygonRing(points: four.points))])
        #expect(ring.ellipseBox == PDFRect(x: 100, y: 100, width: 200, height: 100))
        #expect(MeasurementGeometry(pageID: Self.page).ellipseBox == nil)

        // The two stored corners plus a stray segment far away: the box is the corners', never
        // the union of every collection (which `TakeoffSession.cutoutRings` used to read).
        var stray = corners
        stray.segments = [SegmentGeometry(start: PDFPoint(x: 900, y: 900), end: PDFPoint(x: 950, y: 950))]
        #expect(stray.ellipseBox == PDFRect(x: 100, y: 100, width: 200, height: 100))
        #expect(stray.bounds == PDFRect(x: 100, y: 100, width: 850, height: 850))
        for tool in [MeasurementTool.ellipseArea, .ellipseCutout] {
            for geometry in [circle, corners, four, segment, ring, stray] {
                #expect(Self.record(tool: tool, geometry: geometry).inscribedEllipseBox == geometry.ellipseBox)
            }
        }
        #expect(Self.record(tool: .area, geometry: corners).inscribedEllipseBox == nil)
    }
}
