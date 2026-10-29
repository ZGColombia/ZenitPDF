import Foundation
import Testing
import ZPDFContracts
import ZPDFSearch
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// U-081: the batch sheet's search-term scope
/// says so when the term held an exclusion the index cannot run.
///
/// The compiler already leaves such a word out instead of searching for it. The Search panel
/// said so; the batch scope did not, so "ROOM OR NOT CORRIDOR" previewed the ROOM pages — the
/// ones that say CORRIDOR included — with nothing to tell the person that CORRIDOR was never
/// excluded, and "NOT CORRIDOR" previewed zero pages as if no sheet qualified. Driven against a
/// real FTS5 index over a real three-page drawing, like ``BatchScopeWiringTests``.
@Suite("Iter4R batch scope: dropped exclusions")
struct Iter4RBatchExclusionNoteTests {

    @Test("U-081: 'ROOM OR NOT CORRIDOR' resolves to the ROOM pages and carries CORRIDOR as not excluded")
    @MainActor
    func orNotReportsTheDroppedTerm() async throws {
        let fixture = try await Self.makeIndexedDrawing()
        defer { fixture.tearDown() }

        let resolved = await fixture.resolver.resolve(term: "ROOM OR NOT CORRIDOR")
        #expect(resolved.isAvailable)
        // Sheets one and three say ROOM; three also says CORRIDOR and is still counted,
        // because the exclusion was not run. That is the fact the sheet has to state.
        #expect(resolved.pageIDs == Set([fixture.pageIDs[0], fixture.pageIDs[2]]))
        // Old output: [] — the resolver never read results.query.droppedExclusions.
        #expect(resolved.droppedExclusions == ["CORRIDOR"])
        // Old output: nil — the preview showed "2 of 3" with nothing beside it.
        #expect(resolved.cautionSentence
            == "\u{201C}CORRIDOR\u{201D} was not excluded: put NOT between two words, as in room NOT corridor.")
        // One wording across the two surfaces: the Search panel's note is the same sentence.
        #expect(resolved.cautionSentence == AppSearchPresenter.droppedExclusionNote(["CORRIDOR"]) + ".")
    }

    @Test("U-081: 'NOT CORRIDOR' resolves to no page and says the exclusion was not run, not that no page qualified")
    @MainActor
    func leadingNotReportsTheDroppedTerm() async throws {
        let fixture = try await Self.makeIndexedDrawing()
        defer { fixture.tearDown() }

        let resolved = await fixture.resolver.resolve(term: "NOT CORRIDOR")
        #expect(resolved.isAvailable)
        #expect(resolved.pageIDs.isEmpty)
        #expect(resolved.droppedExclusions == ["CORRIDOR"])
        #expect((resolved.cautionSentence ?? "").contains("\u{201C}CORRIDOR\u{201D} was not excluded"))
    }

    @Test("U-081: an exclusion the index can run carries no note")
    @MainActor
    func runnableExclusionCarriesNoNote() async throws {
        let fixture = try await Self.makeIndexedDrawing()
        defer { fixture.tearDown() }

        let resolved = await fixture.resolver.resolve(term: "ROOM NOT CORRIDOR")
        // Only sheet one says ROOM without CORRIDOR.
        #expect(resolved.pageIDs == Set([fixture.pageIDs[0]]))
        #expect(resolved.droppedExclusions.isEmpty)
        #expect(resolved.cautionSentence == nil)
    }

    @Test("U-081: a dropped exclusion comes first and does not hide the result-limit caution")
    func dropNoteLeadsAndKeepsTheCap() {
        let resolution = BatchSearchScopeResolution(
            term: "ROOM OR NOT CORRIDOR",
            wasTruncated: true,
            droppedExclusions: ["CORRIDOR"]
        )
        let caution = resolution.cautionSentence ?? ""
        #expect(caution.hasPrefix("\u{201C}CORRIDOR\u{201D} was not excluded"))
        #expect(caution.contains("result limit"))
        // An unanswered search has no query to report on: its reason stands alone.
        let unavailable = BatchSearchScopeResolution(
            term: "NOT CORRIDOR", droppedExclusions: ["CORRIDOR"], unavailableReason: "No index."
        )
        #expect(unavailable.cautionSentence == "No index.")
    }

    // MARK: - Fixture

    /// A three-page drawing whose sheets say ROOM, CORRIDOR and ROOM + CORRIDOR, indexed, plus
    /// the resolver over it.
    @MainActor
    static func makeIndexedDrawing() async throws -> BatchScopeWiringTests.IndexedDrawing {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it4r-batchnot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("Rooms.pdf")
        try BatchScopeWiringTests.writeTextPDF(
            to: pdf, pageTexts: ["ROOM 101 OFFICE", "CORRIDOR C2 STAIR", "ROOM 102 CORRIDOR"]
        )

        let documentUUID = UUID()
        let documentID = DocumentID(documentUUID)
        let pages = (0..<3).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: "A-20\(index)",
                boxes: PageBoxes(
                    media: PDFRect(x: 0, y: 0, width: 595, height: 842),
                    crop: PDFRect(x: 0, y: 0, width: 595, height: 842)
                ),
                rotation: .degrees0
            )
        }
        let index = try await DocumentSearchIndex.open(
            databaseAt: directory.appendingPathComponent("search.sqlite"),
            drawingAt: pdf,
            displayName: "Rooms",
            pages: pages
        )
        _ = try await index.indexDrawingText()

        let resolver = await BatchSearchScopeResolver(
            service: index.service,
            projectID: index.projectKey,
            documentID: index.documentKey,
            identity: index.identityMap(
                documentUUID: documentUUID,
                documentTitle: "Rooms",
                pages: pages,
                currentPageIndex: 0
            )
        )
        return BatchScopeWiringTests.IndexedDrawing(
            index: index,
            resolver: resolver,
            pageIDs: pages.map(\.id.rawValue),
            directory: directory
        )
    }
}
