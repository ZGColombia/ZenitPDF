import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 5, render-extract-search (V-079): the privacy promise says the search index can be
/// deleted and rebuilt, and nothing in the product deleted it or the text recognised into it.
/// The Search options now offer Delete Search Index and Recognised Text…, which the document
/// confirms through `ZenitModalPresenter`.
///
/// `.serialized`: the scratch index root is one process-wide override (see
/// `SearchAndOCRWiringTests`).
@MainActor
@Suite("Search options: delete the index and its recognised text (V-079)", .appTierSerialised, .serialized)
struct Iter5SearchIndexDeletionTests {

    /// Old output: `canDeleteIndex` did not exist, and no product path reached
    /// `TextIndexer.removeProjectIndexReportingTokens` — recognised words stayed on the Mac for
    /// as long as the container did.
    @Test("V-079: confirming deletes the recognised words, search keeps working on the drawing's own text, and a note says so")
    func confirmedDeletionRemovesRecognisedText() async throws {
        try await SearchAndOCRWiringTests.withScratchIndexRoot {
            let (document, url) = try await SearchAndOCRWiringTests.openIndexedDocument()
            defer {
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            let presenter = try #require(document.searchPresenter as? AppSearchPresenter)
            presenter.debounce = .milliseconds(1)
            // What the Search options read to offer the control.
            #expect((document.searchPresenter as any SearchPresenting).canDeleteIndex)

            // Recognise the page, text layer or not, so there are recognised words to delete.
            var finished = false
            var runFailure: (any Error)?
            let firstPage = try #require(document.drawing?.pages.first).id.rawValue
            document.runTextRecognition(
                pageIDs: [firstPage], languageIDs: ["en-US"], skipsPagesWithText: false,
                onPage: { _, _ in }, onFinish: { finished = true; runFailure = $0 }
            )
            #expect(await AppTestSupport.wait(upTo: 120) { finished })
            #expect(runFailure == nil)
            let index = try #require(document.searchIndex)
            #expect(!((try await index.recognisedWords())[0] ?? []).isEmpty, "recognition stored words")

            // Cancel deletes nothing.
            let cancelled = ZenitModalPresenter.answering({ _ in .button(1) }) { presenter.requestIndexDeletion() }
            #expect(cancelled.map(\.identifier) == [ZenitPDFProjectDocument.deleteSearchIndexIdentifier])
            try await Task.sleep(for: .milliseconds(200))
            #expect(!((try await index.recognisedWords())[0] ?? []).isEmpty, "Cancel kept the recognised words")

            // Delete.
            let asked = ZenitModalPresenter.answering({ _ in .button(0) }) { presenter.requestIndexDeletion() }
            let request = try #require(asked.first)
            #expect(request.buttons == ["Delete", "Cancel"])
            #expect(request.detail.contains("text recognised on scanned sheets"))
            let core = try #require(document.core)
            #expect(await AppTestSupport.wait(upTo: 60) {
                core.document.warnings.contains { $0.id == ZenitPDFProjectDocument.searchIndexDeletedNoteID }
            })
            let note = try #require(core.document.warnings.first { $0.id == ZenitPDFProjectDocument.searchIndexDeletedNoteID })
            #expect(note.severity == .info)
            #expect(note.title == "Search index deleted.")
            #expect(note.message.contains("recognised words and the drawings' text index were removed from this Mac"))
            #expect((try await index.recognisedWords()).values.allSatisfy(\.isEmpty), "no recognised word is left")

            // Recognised text finds nothing now; the drawing's own text was indexed again.
            presenter.scope = SearchScope(location: .currentDocument, sources: [.ocrText])
            presenter.query = "SCREED"
            presenter.runSearch()
            _ = await AppTestSupport.wait(upTo: 20) { !presenter.isSearching }
            #expect(presenter.hits.isEmpty, "a recognised hit survived the deletion")
            presenter.scope = SearchScope(location: .currentDocument, sources: [.pdfText])
            await SearchAndOCRWiringTests.search(presenter, for: "SCREED")
            #expect(presenter.hits.first?.source == .pdfText, "search stopped working on the drawing's own text")
        }
    }

    @Test("V-079: a Search panel with no index offers no deletion; a person-less run deletes nothing")
    func noIndexOffersNoControl() async throws {
        let unavailable = UnavailableSearchPresenter(reason: "Search is unavailable.")
        #expect(!(unavailable as any SearchPresenting).canDeleteIndex)

        try await SearchAndOCRWiringTests.withScratchIndexRoot {
            let (document, url) = try await SearchAndOCRWiringTests.openIndexedDocument()
            defer {
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            #expect(document.searchIndex != nil)
            ZenitModalPresenter.reset()
            defer { ZenitModalPresenter.reset() }
            // No handler and no bundle: the alert's person-less answer is Cancel.
            document.confirmSearchIndexDeletion()
            #expect(ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.deleteSearchIndexIdentifier))
            try await Task.sleep(for: .milliseconds(200))
            let core = try #require(document.core)
            #expect(!core.document.warnings.contains { $0.id == ZenitPDFProjectDocument.searchIndexDeletedNoteID })
        }
    }
}
