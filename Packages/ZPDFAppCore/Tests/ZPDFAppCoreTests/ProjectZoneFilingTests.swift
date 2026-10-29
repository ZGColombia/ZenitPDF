import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// L-92: a zone drawn round markups already on the sheet files the ones it encloses.
@Suite("Project Zone filing on creation (L-92)")
struct ProjectZoneFilingTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)
    static let document = DocumentID(UUID(uuidString: "00000000-0000-4000-8000-0000000000D9")!)
    static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000000A9")!)
    static let otherPage = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!)

    static func record(
        _ tool: MeasurementTool, on page: PageID = page, zone: ZoneID? = nil, locked: Bool = false,
        _ geometry: (PageID) -> MeasurementGeometry
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()), documentID: document, pageID: page, kind: .measurement, tool: tool,
            subject: "\(tool)", author: "A. Berg", zoneID: zone, locked: locked,
            geometry: geometry(page), createdAt: stamp, modifiedAt: stamp
        )
    }

    static func counts(_ points: [PDFPoint], on page: PageID = page, zone: ZoneID? = nil) -> MarkupRecord {
        record(.count, on: page, zone: zone) { page in
            MeasurementGeometry(pageID: page, countPoints: points.map { CountPoint(id: CountPointID(UUID()), position: $0) })
        }
    }

    static func polylength(_ points: [PDFPoint], on page: PageID = page, zone: ZoneID? = nil, locked: Bool = false) -> MarkupRecord {
        record(.polylength, on: page, zone: zone, locked: locked) { page in MeasurementGeometry(pageID: page, points: points) }
    }

    /// The boundary the manual test drew: a square 100…300 × 100…300 on the page.
    static func zone(_ name: String, parent: ZoneID? = nil, boundary: [PDFPoint]? = nil, page: PageID? = page) -> ProjectZoneDefinition {
        ProjectZoneDefinition(
            id: ZoneID(UUID()), name: name, kind: .room, parentID: parent, pageID: page,
            boundary: boundary ?? [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100), PDFPoint(x: 300, y: 300), PDFPoint(x: 100, y: 300)],
            sortOrder: 0, colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        )
    }

    @Test("Four count marks and a polylength inside the boundary are filed; what is outside, across the edge, elsewhere or locked is not")
    func enclosedMarkupsAreFiled() {
        let floor = Self.zone("Floor 2", boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1000, y: 0), PDFPoint(x: 1000, y: 1000), PDFPoint(x: 0, y: 1000)])
        let sibling = Self.zone("Stair", boundary: [PDFPoint(x: 500, y: 500), PDFPoint(x: 600, y: 500), PDFPoint(x: 600, y: 600)])
        let room = Self.zone("Room 1", parent: floor.id)

        let fourMarks = Self.counts([PDFPoint(x: 120, y: 120), PDFPoint(x: 280, y: 120), PDFPoint(x: 280, y: 280), PDFPoint(x: 120, y: 280)])
        let run = Self.polylength([PDFPoint(x: 150, y: 150), PDFPoint(x: 250, y: 150), PDFPoint(x: 250, y: 250)])
        // A vertex exactly on the boundary still lies in the zone.
        let onEdge = Self.polylength([PDFPoint(x: 100, y: 200), PDFPoint(x: 200, y: 200)])
        // Filed in the zone the new one is drawn inside: the room refines it.
        let inParent = Self.polylength([PDFPoint(x: 160, y: 260), PDFPoint(x: 240, y: 260)], zone: floor.id)

        let straddling = Self.polylength([PDFPoint(x: 200, y: 200), PDFPoint(x: 350, y: 200)])
        let outside = Self.counts([PDFPoint(x: 50, y: 50)])
        let otherSheet = Self.counts([PDFPoint(x: 200, y: 200)], on: Self.otherPage)
        let locked = Self.polylength([PDFPoint(x: 150, y: 180), PDFPoint(x: 250, y: 180)], locked: true)
        let filedElsewhere = Self.polylength([PDFPoint(x: 150, y: 220), PDFPoint(x: 250, y: 220)], zone: sibling.id)

        let markups = [fourMarks, outside, run, straddling, onEdge, otherSheet, locked, filedElsewhere, inParent]
        let filed = ProjectZoneFiling.markupsEnclosed(by: room, among: markups, zones: [floor, sibling, room])
        // Old behaviour: creating the zone filed nothing; the zone showed 0.
        #expect(filed == [fourMarks.id, run.id, onEdge.id, inParent.id])
    }

    @Test("A zone without a boundary encloses nothing")
    func noBoundaryNoFiling() {
        let markups = [Self.counts([PDFPoint(x: 200, y: 200)])]
        #expect(ProjectZoneFiling.markupsEnclosed(by: Self.zone("Phase 2", boundary: [], page: nil), among: markups, zones: []).isEmpty)
    }

}
