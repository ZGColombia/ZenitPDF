import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-16, import half: measurement annotations become live measurements, measured again
/// by Zenit at the page's scale, with the file's number kept beside it.
@Suite("Measurement annotations import as measurements (NL-MEASURE-16)")
struct NLMeasureAnnotationImportTests {

    /// 100 pt = 5 m (0.05 m/pt). A LineDimension from (0,0) to (200,0) is 10 m by Zenit's scale;
    /// the file said "9.80 m" — kept in the note, never used. A PolygonDimension 100 × 60 pt is
    /// 5 × 3 = 15 m². A plain Square stays a rectangle markup; a page with no scale stays a markup.
    @Test("LineDimension and PolygonDimension import as a Length and an Area measured by Zenit")
    func importsAsMeasurements() async throws {
        let documentID = DocumentID(UUID())
        let pages = (0..<2).map {
            ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: $0, label: "A-\($0)",
                                         boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        _ = try await session.calibrate(page: pages[0].id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 5, knownLengthUnit: .metre)
        let rect = PDFRect(x: 0, y: 0, width: 200, height: 60)
        let annotations = [
            ImportedAnnotation(index: 0, pageIndex: 0, subtype: "Line", contents: "9.80 m", rect: rect,
                               points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0)], intent: "LineDimension"),
            ImportedAnnotation(index: 1, pageIndex: 0, subtype: "Polygon", contents: "15.00 sq m", rect: rect,
                               points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 60), PDFPoint(x: 0, y: 60)],
                               intent: "PolygonDimension"),
            ImportedAnnotation(index: 2, pageIndex: 0, subtype: "Square", rect: rect),
            ImportedAnnotation(index: 3, pageIndex: 1, subtype: "Line", contents: "3 m", rect: rect,
                               points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0)], intent: "LineDimension")
        ]
        let plan = AnnotationImportPlanner.plan(
            annotations: annotations, pages: pages, documentID: documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: "abc"
        )
        let converted = MeasuredAnnotationImport.converting(plan, annotations: annotations, fileDigest: "abc", calibratedPages: [pages[0].id])
        #expect(converted.newMarkups.count == 4)
        let line = try #require(converted.newMarkups.first { $0.tool == .length })
        #expect(line.kind == .measurement)
        #expect(line.comment.contains("9.80 m"))
        let area = try #require(converted.newMarkups.first { $0.tool == .area })
        #expect(converted.newMarkups.filter { $0.tool == nil }.count == 2, "the Square and the unscaled page's line stay markups")

        _ = try await session.applyBatch(converted.newMarkups.map { .addMarkup($0) })
        #expect(await session.markup(line.id)?.measurement?[.planLength]?.value == 10, "Zenit's number, not the file's 9.80")
        #expect(await session.markup(area.id)?.measurement?[.netArea]?.value == 15)
    }
}
