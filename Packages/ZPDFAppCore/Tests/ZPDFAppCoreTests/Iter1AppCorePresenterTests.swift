import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// Presenter wiring (R-048, R-049).
@Suite("Iteration 1 — presenters")
@MainActor
struct Iter1AppCorePresenterTests {

    static func wait(upTo seconds: Double = 10, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A PDF of `count` A4 pages; page n (one-based) says `FLOOR n SCREED`.
    static func writeTextPDF(pages count: Int, to url: URL) throws {
        var objects: [Data] = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)]
        let kids = (0..<count).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(count) >>".utf8))
        let font = 3 + 2 * count
        for page in 0..<count {
            let content = Data("BT /F1 18 Tf 72 700 Td (FLOOR \(page + 1) SCREED) Tj ET\n".utf8)
            objects.append(Data("""
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents \(4 + 2 * page) 0 R \
            /Resources << /Font << /F1 \(font) 0 R >> >> >>
            """.utf8))
            var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
            stream.append(content)
            stream.append(Data("\nendstream".utf8))
            objects.append(stream)
        }
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))
        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
    }

    // MARK: R-048

    /// Old output: every "Current Page" search listed the hit on page 1 — the scope's page key
    /// was fixed at `currentPageIndex: 0` and nothing moved it.
    @Test("The Search panel's Current Page scope follows the sheet on screen")
    func currentPageFollowsTheSheet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it1-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("Floors.pdf")
        try Self.writeTextPDF(pages: 3, to: pdf)
        let documentUUID = UUID()
        let pages = DocumentSearchIndexTests.pages(count: 3, documentID: DocumentID(documentUUID))
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"), drawingAt: pdf, displayName: "Floors", pages: pages
        )
        _ = try await index.indexDrawingText()
        let presenter = AppSearchPresenter(
            service: index.service, projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Floors", pages: pages, currentPageIndex: 0),
            scope: SearchScope(location: .currentPage)
        )
        presenter.debounce = .zero

        // The environment is what moves it: a page turn reaches the attached presenter.
        let session = try TakeoffSession(documentID: DocumentID(documentUUID), pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: DocumentID(documentUUID))
        environment.attachSearch(presenter)
        #expect(presenter.currentPageID == pages[0].id.rawValue)
        environment.document.goToPage(id: pages[2].id.rawValue)
        #expect(presenter.currentPageID == pages[2].id.rawValue)

        presenter.query = "SCREED"
        presenter.runSearch()
        #expect(await Self.wait { !presenter.isSearching && !presenter.hits.isEmpty })
        #expect(presenter.hits.map(\.pageID) == [pages[2].id.rawValue], "only page 3's hit")
        #expect(presenter.hits.first?.snippet.contains("3") == true)

        // A sheet of another drawing: nothing of this drawing's index, and another drawing's hit
        // on that sheet is kept while its hits elsewhere are not.
        let foreignSheet = UUID()
        presenter.setCurrentPage(foreignSheet)
        func foreignHit(on page: UUID) -> ZPDFUIPresentation.SearchHit {
            ZPDFUIPresentation.SearchHit(id: UUID(), documentID: UUID(), documentTitle: "B", pageID: page,
                                         pageIndex: 0, pageLabel: "B-1", source: .pdfText, snippet: "SCREED on B")
        }
        presenter.externalSources = [ProjectSearchSource(documentID: UUID(), title: "B") { _, _ in
            [foreignHit(on: foreignSheet), foreignHit(on: UUID())]
        }]
        presenter.searchesAllDrawings = true
        presenter.runSearch()
        #expect(await Self.wait { !presenter.isSearching && presenter.hits.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(presenter.hits.map(\.pageID) == [foreignSheet], "the other drawing's hit on the sheet on screen only")

        await index.shutDown()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: R-049

    /// Sheet 2 is on screen and is removed from the set. Old output: the document fell back to
    /// sheet 1 without a page change, so the markup tool stayed on sheet 2's page id (the next
    /// cloud or text landed on a sheet outside the set) and `afterPageChange` never ran.
    @Test("When the sheet on screen leaves the set, the fallback is a page change")
    func removedSheetMovesTheTools() async throws {
        let documentID = DocumentID(UUID())
        let pages = DocumentSearchIndexTests.pages(count: 3, documentID: documentID)
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        var turnedTo: [UUID] = []
        environment.afterPageChange = { page in turnedTo.append(page.id) }
        environment.document.goToPage(id: pages[1].id.rawValue)
        #expect(environment.markup.pageID == pages[1].id)
        turnedTo = []

        try await environment.commands.perform(.setPagesExcluded([pages[1].id], excluded: true))
        await environment.refresh()
        #expect(environment.document.currentPageID == pages[0].id.rawValue)
        #expect(turnedTo == [pages[0].id.rawValue], "the fallback ran the page-change wiring once")
        #expect(environment.markup.pageID == pages[0].id, "the markup tool follows the sheet on screen")
        #expect(environment.canvas.viewport.pageID == pages[0].id.rawValue)

        // An ordinary refresh with the sheet still in the set is not a page change.
        turnedTo = []
        await environment.refresh()
        #expect(turnedTo.isEmpty)
    }
}
