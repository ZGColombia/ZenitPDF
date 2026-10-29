import Foundation
import Testing
import ZPDFContracts
import ZPDFTestingSupport
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Revealing a markup that lives on another sheet takes the document there.
///
/// Clicking a measurement in the summary list must bring up its sheet when it is on another one
/// (reported 2026-08-26).
///
/// `zoomTo(markupID:)` moved this presenter's own `viewport.pageID` and stopped. The canvas draws
/// `AppDocumentPresenter.currentPage`, so the viewport pointed at one sheet while another stayed
/// on screen, and clicking a row for a markup on sheet 3 looked like it did nothing at all. The
/// search path worked only because `ZenitPDFProjectDocument.reveal(_:)` changed the page by hand
/// first — one caller remembering what every caller needed.
@MainActor
struct RevealAcrossPagesTests {

    private func makeWorkspace(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-reveal-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A canvas presenter over a real multi-sheet document, plus two markups placed on two of
    /// its sheets.
    private func makeCanvas() async throws -> (AppCanvasPresenter, MarkupSummary, MarkupSummary) {
        let workspace = try makeWorkspace("canvas")
        let fixture = try await OpenedFixture.open(.mixedPageSizes, in: workspace)
        #expect(fixture.pages.count >= 3, "the fixture must have at least three sheets")
        let session = try TakeoffSession(
            documentID: fixture.documentID,
            pages: fixture.pages,
            units: .metric
        )
        let canvas = AppCanvasPresenter(
            session: session,
            pageID: fixture.pages[0].id.rawValue,
            pageIndex: 0
        )

        let sample = ZenitSampleProject.shared.markups
        var here = sample[0]
        here.pageID = fixture.pages[0].id.rawValue
        here.pageIndex = 0
        var elsewhere = sample[1]
        elsewhere.pageID = fixture.pages[2].id.rawValue
        elsewhere.pageIndex = 2
        canvas.adoptMarkupsForTesting([here, elsewhere])
        return (canvas, here, elsewhere)
    }

    @Test("A markup on another sheet asks the document to go there")
    func revealRaisesAPageRequest() async throws {
        let (canvas, _, elsewhere) = try await makeCanvas()
        var requested: [ZPDFUIPresentation.PageDescriptor.ID] = []
        canvas.onRequestPage = { requested.append($0) }

        canvas.zoomTo(markupID: elsewhere.id)

        #expect(requested == [elsewhere.pageID], "the document was never asked to change page")
        #expect(canvas.viewport.pageID == elsewhere.pageID)
        #expect(canvas.viewport.pageIndex == 2)
    }

    @Test("A markup on the sheet already shown asks for nothing")
    func samePageRaisesNothing() async throws {
        let (canvas, here, _) = try await makeCanvas()
        var requested: [ZPDFUIPresentation.PageDescriptor.ID] = []
        canvas.onRequestPage = { requested.append($0) }

        canvas.zoomTo(markupID: here.id)
        #expect(requested.isEmpty, "a reveal on the current sheet asked for a page change")
        #expect(canvas.selectedMarkupIDs == [here.id], "a reveal still selects what it revealed")
    }
}
