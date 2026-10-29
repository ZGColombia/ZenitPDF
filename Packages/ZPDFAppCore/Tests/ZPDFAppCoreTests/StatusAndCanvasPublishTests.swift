import Foundation
import Observation
import os
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// CR-9 and CR-18: what the status bar and the canvas publish, and what they must not.
@MainActor
struct StatusAndCanvasPublishTests {

    // MARK: CR-9

    @Test("A raster page displays Vector Snap as unavailable without flipping the setting off")
    func rasterPageDoesNotFlipTheSetting() {
        let presenter = AppStatusPresenter(units: .metric)
        // The empty bar starts on an un-indexed page; a vector sheet arrives first.
        presenter.updateGeometryIndex(.ready)
        presenter.setVectorSnapEnabled(true)
        #expect(presenter.snapshot.vectorSnapEnabled)
        #expect(AppStatusPresenter.snapSourceText(presenter.snapshot).contains("Vector"))

        presenter.updateGeometryIndex(.unavailable)
        // Old state: `vectorSnapEnabled == false` — and nothing ever set it back.
        #expect(presenter.snapshot.vectorSnapEnabled, "the setting is the person's; the page is not")
        #expect(presenter.snapshot.geometryIndexStatus == .unavailable)
        #expect(!AppStatusPresenter.snapSourceText(presenter.snapshot).contains("Vector"),
                "the segment says what the next click will do on this page")

        presenter.updateGeometryIndex(.ready)
        // Old output: no "Vector" — the toggle had been switched off by the raster page.
        #expect(presenter.snapshot.vectorSnapEnabled)
        #expect(AppStatusPresenter.snapSourceText(presenter.snapshot).contains("Vector"))
    }

    // MARK: CR-18

    @Test("Adopting an unchanged snapshot publishes neither the viewport nor the selection")
    func unchangedSnapshotPublishesNothing() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: documentID,
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let canvas = AppCanvasPresenter(session: session, pageID: page.id.rawValue, pageIndex: 0)
        let snapshot = try await session.snapshot()
        canvas.adopt(snapshot)

        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = canvas.viewport
            _ = canvas.selectedMarkupIDs
            _ = canvas.activeScale
        } onChange: {
            fired.withLock { $0 = true }
        }

        canvas.adopt(snapshot)
        // Old behaviour: `viewport.pageIndex = page.index` and `selectedMarkupIDs = …` were
        // assigned on every adopt, and `@Observable` fires on assignment — `fired == true`.
        #expect(fired.withLock { $0 } == false)

        // A real change still publishes.
        canvas.showPage(try #require(snapshot.pages.first))
        canvas.select(markupIDs: [UUID()], additive: false)
    }
}
