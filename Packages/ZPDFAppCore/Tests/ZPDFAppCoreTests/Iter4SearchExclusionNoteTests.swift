import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// U-081: the Search panel says so when the query held
/// an exclusion the index cannot run, instead of searching for the excluded word.
@Suite("Iter4 search: dropped exclusions")
@MainActor
struct Iter4SearchExclusionNoteTests {

    @Test("U-081: 'FLOOR OR NOT SCREED' finds FLOOR, never searches for SCREED, and the status says the exclusion was not run")
    func droppedExclusionIsReported() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it4-exclusion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("Floors.pdf")
        // Page n says "FLOOR n SCREED".
        try Iter1AppCorePresenterTests.writeTextPDF(pages: 2, to: pdf)
        let documentUUID = UUID()
        let pages = DocumentSearchIndexTests.pages(count: 2, documentID: DocumentID(documentUUID))
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"), drawingAt: pdf, displayName: "Floors", pages: pages
        )
        _ = try await index.indexDrawingText()
        let presenter = AppSearchPresenter(
            service: index.service, projectID: index.projectKey,
            identity: index.identityMap(documentUUID: documentUUID, documentTitle: "Floors", pages: pages, currentPageIndex: 0),
            scope: SearchScope(location: .currentDocument)
        )
        presenter.debounce = .zero
        func search(_ text: String, expecting summary: String) async {
            presenter.query = text
            presenter.runSearch()
            _ = await Iter1AppCorePresenterTests.wait(upTo: 3) { !presenter.isSearching && presenter.resultSummary == summary }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let note = AppSearchPresenter.droppedExclusionNote(["SCREED"])
        #expect(note == "“SCREED” was not excluded: put NOT between two words, as in room NOT corridor")

        // Old output: the query compiled to "FLOOR" OR "SCREED" and the status read "2 results"
        // with nothing to say that SCREED had been searched for rather than excluded.
        await search("FLOOR OR NOT SCREED", expecting: "2 results — " + note)
        #expect(presenter.hits.count == 2)
        #expect(presenter.resultSummary == "2 results — " + note)

        // Old output: "NOT SCREED" compiled to "SCREED" and listed both pages as hits.
        await search("NOT SCREED", expecting: "0 results — " + note)
        #expect(presenter.hits.isEmpty)
        #expect(presenter.resultSummary == "0 results — " + note)

        // An exclusion the index can run carries no note: every page says SCREED, so none is left.
        await search("FLOOR NOT SCREED", expecting: "0 results")
        #expect(presenter.hits.isEmpty)
        #expect(presenter.resultSummary == "0 results")
    }
}
