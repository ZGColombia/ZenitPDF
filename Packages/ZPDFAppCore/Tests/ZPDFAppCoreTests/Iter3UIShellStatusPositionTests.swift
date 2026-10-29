import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// T-032: the status snapshot's page position is the
/// page's place in the set, not its PDF page index (ADR-0022).
@MainActor
struct Iter3UIShellStatusPositionTests {

    /// Three sheets, `A-101`…`A-103` at PDF indexes 0…2, with the set reordered so the third
    /// PDF page leads: `[A-103, A-101, A-102]`.
    private func reorderedSnapshot() async throws -> DocumentSnapshot {
        let documentID = DocumentID(UUID())
        let pages = (0..<3).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: "A-10\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let base = try await session.snapshot()
        let reordered = [base.pages[2], base.pages[0], base.pages[1]]
        return DocumentSnapshot(
            documentID: base.documentID,
            pages: reordered,
            firstPageScale: nil,
            markups: [],
            ledger: base.ledger,
            units: base.units
        )
    }

    private func viewport(on page: ZPDFUIPresentation.PageDescriptor) -> ViewportSnapshot {
        ViewportSnapshot(
            pageID: page.id,
            pageIndex: page.index,
            zoom: 1,
            visiblePageRect: PDFRectValue(x: 0, y: 0, width: 612, height: 792)
        )
    }

    /// Old output: `pageIndex == 2` for A-103 moved to the front — its PDF index — so the canvas
    /// bar read `· 3 / 3` beside a Navigator that numbered it 1 and a Previous arrow that was
    /// disabled, and typing `3` went to A-102.
    @Test("T-032: after a reorder the bar publishes the page's set position")
    func publishesTheSetPosition() async throws {
        let document = try await reorderedSnapshot()
        let lead = document.pages[0]
        #expect(lead.label == "A-103" && lead.index == 2, "fixture: the PDF's third page leads the set")

        let presenter = AppStatusPresenter()
        presenter.adopt(
            document: document,
            viewport: viewport(on: lead),
            scale: nil,
            geometryIndex: .unavailable,
            snapToggles: SnapSourceToggles(),
            reuseToolEnabled: false
        )
        #expect(presenter.snapshot.pageLabel == "A-103")
        #expect(presenter.snapshot.pageIndex == 0)
        #expect(presenter.snapshot.pageCount == 3)
        #expect(presenter.snapshot.pageIndicatorText == "A-103 · 1 of 3")

        // The last sheet in the set is PDF page 1 (A-102): position 2, not index 1.
        let last = document.pages[2]
        presenter.adopt(
            document: document,
            viewport: viewport(on: last),
            scale: nil,
            geometryIndex: .unavailable,
            snapToggles: SnapSourceToggles(),
            reuseToolEnabled: false
        )
        #expect(presenter.snapshot.pageLabel == "A-102")
        #expect(presenter.snapshot.pageIndex == 2, "old output: 1, the PDF index")
    }

    @Test("T-032: a viewport on a page the snapshot does not list falls back to the viewport's index")
    func unknownPageFallsBack() async throws {
        let document = try await reorderedSnapshot()
        let presenter = AppStatusPresenter()
        presenter.adopt(
            document: document,
            viewport: ViewportSnapshot(
                pageID: UUID(), pageIndex: 1, zoom: 1,
                visiblePageRect: PDFRectValue(x: 0, y: 0, width: 1, height: 1)
            ),
            scale: nil,
            geometryIndex: .unavailable,
            snapToggles: SnapSourceToggles(),
            reuseToolEnabled: false
        )
        #expect(presenter.snapshot.pageLabel == "")
        #expect(presenter.snapshot.pageIndex == 1)
    }
}
