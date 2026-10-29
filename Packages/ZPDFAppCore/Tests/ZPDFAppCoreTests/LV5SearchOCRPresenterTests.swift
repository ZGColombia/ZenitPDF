import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// L-20, at the presenter: recognised text is in the scope a presenter starts with,
/// another drawing's recognised hit carries the search-aid disclaimer, and the Look In boxes
/// decide which of another drawing's hits are listed.
///
/// The end-to-end half — a scanned drawing, a real recognition run, a search that never touched
/// the scope — is `SearchAndOCRWiringTests` in the application package.
@Suite("Search presenter and recognised text (L-20)")
@MainActor
struct LV5SearchOCRPresenterTests {

    /// A presenter made the way the app makes it — no scope argument — over a real index of a
    /// one-page drawing whose text layer says `SCREED BAY 7`.
    private static func makePresenter() async throws -> (AppSearchPresenter, DocumentSearchIndex, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-lv5-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("Plan.pdf")
        try DocumentSearchIndexTests.writeTextPDF(to: pdf)
        let documentUUID = UUID()
        let pages = DocumentSearchIndexTests.pages(count: 1, documentID: DocumentID(documentUUID))
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"),
            drawingAt: pdf,
            displayName: "Plan",
            pages: pages
        )
        _ = try await index.indexDrawingText()
        let presenter = AppSearchPresenter(
            service: index.service,
            projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Plan", pages: pages, currentPageIndex: 0)
        )
        presenter.debounce = .zero
        return (presenter, index, directory)
    }

    private static func foreignHit(_ source: SearchSource, _ snippet: String) -> ZPDFUIPresentation.SearchHit {
        ZPDFUIPresentation.SearchHit(
            id: UUID(), documentID: UUID(), documentTitle: "unused", pageID: UUID(),
            pageIndex: 0, pageLabel: "B-1", source: source, snippet: snippet
        )
    }

    private static func wait(upTo seconds: Double = 10, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("L-20: a presenter starts with recognised text in its scope")
    func presenterStartsWithRecognisedText() async throws {
        let (presenter, index, directory) = try await Self.makePresenter()
        defer { Task { await index.shutDown(); try? FileManager.default.removeItem(at: directory) } }
        // Old: the presenter's default scope was `[.pdfText, .markups, .comments, .labels]`, so
        // the engine was never asked for `.ocr` rows.
        #expect(presenter.scope.sources.contains(.ocrText))
        #expect(presenter.scope == SearchScope.default)
    }

    @Test("L-20: another drawing's recognised hit is listed with the disclaimer; the Look In boxes filter the fan-out")
    func externalRecognisedHitsAndSourceFilter() async throws {
        let (presenter, index, directory) = try await Self.makePresenter()
        defer { Task { await index.shutDown(); try? FileManager.default.removeItem(at: directory) } }

        presenter.externalSources = [
            ProjectSearchSource(documentID: UUID(), title: "Scan B") { text, _ in
                [Self.foreignHit(.ocrText, "\(text) read off scan B"), Self.foreignHit(.customFields, "\(text) in a column")]
            }
        ]
        presenter.searchesAllDrawings = true
        presenter.query = "SCREED"
        presenter.runSearch()
        let arrived = await Self.wait {
            presenter.hits.contains { $0.sourceDocumentID == nil }
                && presenter.hits.contains { $0.sourceDocumentID != nil }
        }
        #expect(arrived, "this drawing and the scan should both answer")

        let foreign = presenter.hits.filter { $0.sourceDocumentID != nil }
        #expect(foreign.map(\.source) == [.ocrText], "custom fields are not in the default scope")
        // Old: the disclaimer followed this drawing's own answer only, and this drawing has no
        // recognised hit, so another drawing's recognised word was listed without it.
        #expect(presenter.showsOCRDisclaimer, "a listed recognised hit carries the search-aid disclaimer")

        // Unticking OCR Text keeps another drawing's recognised words out too. Old: only the
        // location was applied to the fan-out, so they stayed listed.
        presenter.scope = SearchScope(location: .currentDocument, sources: [.pdfText])
        presenter.runSearch()
        let narrowed = await Self.wait {
            !presenter.isSearching && presenter.hits.contains { $0.sourceDocumentID == nil }
                && !presenter.hits.contains { $0.source == .ocrText }
        }
        #expect(narrowed)
        #expect(presenter.hits.allSatisfy { $0.sourceDocumentID == nil }, "\(presenter.hits.map(\.source))")
        #expect(!presenter.showsOCRDisclaimer)
    }
}
