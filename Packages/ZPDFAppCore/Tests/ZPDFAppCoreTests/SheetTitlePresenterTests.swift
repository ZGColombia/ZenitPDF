import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// The document presenter lays the drawing's outline titles onto its pages — outline entry
/// first, then the page's own label, else no title.
@Suite("Sheet titles on the document presenter")
struct SheetTitlePresenterTests {

    @MainActor
    private func makeEnvironment(labels: [String]) async throws -> (AppCoreEnvironment, [ZPDFContracts.PageDescriptor]) {
        let documentID = DocumentID(UUID())
        let pages = labels.enumerated().map { index, label in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: label,
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 2592, height: 1728))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, pages)
    }

    @Test("The bridge resolves own label (when a name), then outline, then nothing")
    func bridgeResolution() {
        let page = ZPDFContracts.PageDescriptor(
            id: PageID(UUID()),
            documentID: DocumentID(UUID()),
            index: 0,
            label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
        #expect(ZPDFUIPresentation.PageDescriptor(domain: page).sheetTitle == "A-101")
        // The named label wins; this used
        // to expect "Floor Plan", which lost the sheet number.
        #expect(ZPDFUIPresentation.PageDescriptor(domain: page, outlineTitle: "Floor Plan").sheetTitle == "A-101")
        #expect(ZPDFUIPresentation.PageDescriptor(domain: page, outlineTitle: "A-101 Floor Plan").sheetTitle == "A-101 Floor Plan")
    }

    @MainActor
    @Test("An outline-titled page carries its title; a page without one falls back, and survives a refresh")
    func presenterAppliesOutlineTitles() async throws {
        let (environment, pages) = try await makeEnvironment(labels: ["1", "2", "S-201"])
        let presenter = environment.document
        // Before any outline arrives: bare numbers are no title, a real label is.
        #expect(presenter.pages.map(\.sheetTitle) == [nil, nil, "S-201"])

        presenter.sheetOutlineTitles = [pages[0].id.rawValue: "A1.01 - Floor Plan"]
        #expect(presenter.pages.map(\.sheetTitle) == ["A1.01 - Floor Plan", nil, "S-201"])

        // Every later snapshot is retitled the same way.
        presenter.adopt(try await environment.session.snapshot())
        #expect(presenter.pages.map(\.sheetTitle) == ["A1.01 - Floor Plan", nil, "S-201"])
    }
}
