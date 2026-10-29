import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// Feature 33 — searching every open drawing at once.
///
/// Each open drawing owns its index, so a project-wide search is a fan-out rather than one
/// query over one database. Three things can go wrong quietly and all three are asserted here:
/// a hit from another drawing arriving unlabelled and reading as a hit on the drawing in front;
/// the toggle being off and drawings being searched anyway; and a slow drawing's reply landing
/// on top of the results the active document already produced.
@MainActor
struct ProjectWideSearchTests {

    // MARK: - Fixtures

    /// A presenter over a real index of a real one-page drawing whose text layer says
    /// `SCREED BAY 7`, already indexed, so the active document genuinely has hits of its own.
    private static func makePresenter() async throws -> (
        presenter: AppSearchPresenter,
        index: DocumentSearchIndex,
        pages: [ZPDFContracts.PageDescriptor],
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-project-search-\(UUID().uuidString)", isDirectory: true)
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
            identity: index.identityMap(
                documentUUID: documentUUID,
                documentTitle: "Plan",
                pages: pages,
                currentPageIndex: 0
            ),
            scope: SearchScope(location: .entireProject)
        )
        // No debounce: the tests drive `runSearch()` directly and must not race a timer.
        presenter.debounce = .zero
        return (presenter, index, pages, directory)
    }

    private static func tearDown(_ index: DocumentSearchIndex, _ directory: URL) async {
        await index.shutDown()
        try? FileManager.default.removeItem(at: directory)
    }

    /// A hit that is unmistakably not from the active document.
    private static func foreignHit(snippet: String) -> ZPDFUIPresentation.SearchHit {
        ZPDFUIPresentation.SearchHit(
            id: UUID(),
            documentID: UUID(),
            documentTitle: "unused",
            pageID: UUID(),
            pageIndex: 0,
            pageLabel: "A-201",
            source: .pdfText,
            snippet: snippet
        )
    }

    /// A source that answers immediately.
    private static func source(
        title: String,
        snippet: String,
        counter: QueryCounter
    ) -> ProjectSearchSource {
        ProjectSearchSource(documentID: UUID(), title: title) { text, _ in
            counter.record(text)
            return [foreignHit(snippet: "\(snippet) \(text)")]
        }
    }

    /// A source that takes 200 ms to answer — a drawing whose index is still filling.
    private static func slowSource(
        title: String,
        snippet: String,
        counter: QueryCounter
    ) -> ProjectSearchSource {
        ProjectSearchSource(documentID: UUID(), title: title) { text, _ in
            counter.record(text)
            try? await Task.sleep(for: .milliseconds(200))
            return [foreignHit(snippet: "\(snippet) \(text)")]
        }
    }

    /// Counts what each source was asked, so "queries none" can be asserted as *no call was
    /// made*, not merely as *no hit was shown*.
    @MainActor
    final class QueryCounter {
        private(set) var queries: [String] = []
        func record(_ text: String) { queries.append(text) }
        var callCount: Int { queries.count }
    }

    /// Polls the main actor until `condition` holds or the budget runs out.
    ///
    /// The presenter answers on tasks it owns; there is no completion handler to await. The
    /// budget is generous because the 200 ms source is deliberately slower than any of the
    /// others.
    private static func wait(
        upTo seconds: Double = 5,
        for condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - The seam

    @Test("With the toggle on, hits from every open drawing arrive, each labelled with its drawing")
    func allDrawingsGathersLabelledHits() async throws {
        let (presenter, index, _, directory) = try await Self.makePresenter()
        defer { Task { await Self.tearDown(index, directory) } }

        let firstCounter = QueryCounter()
        let secondCounter = QueryCounter()
        presenter.externalSources = [
            Self.source(title: "Level 2", snippet: "screed on two", counter: firstCounter),
            Self.source(title: "Level 3", snippet: "screed on three", counter: secondCounter)
        ]
        presenter.searchesAllDrawings = true
        presenter.query = "SCREED"
        presenter.runSearch()

        // Both halves, not whichever is quicker: the external sources answer synchronously
        // while this drawing's index is a database away, so a wait on the foreign hits alone
        // is a wait that finishes before the active document has spoken.
        let arrived = await Self.wait {
            presenter.hits.filter({ $0.sourceDocumentID != nil }).count == 2
                && presenter.hits.contains { $0.sourceDocumentID == nil }
        }
        #expect(arrived, "both external drawings and this one should have contributed hits")

        #expect(firstCounter.callCount == 1)
        #expect(secondCounter.callCount == 1)
        #expect(firstCounter.queries == ["SCREED"], "the source is asked the trimmed query")

        let titles = Set(presenter.hits.compactMap(\.sourceDocumentTitle))
        #expect(titles == ["Level 2", "Level 3"], "every foreign hit names the drawing it came from")

        // Labelling is the safety property: a hit with no source document means "this drawing",
        // and a foreign hit that lost its label would be indistinguishable from one.
        for hit in presenter.hits where hit.sourceDocumentID != nil {
            #expect(hit.sourceDocumentID != nil)
            let title = try #require(hit.sourceDocumentTitle)
            #expect(!title.isEmpty)
            #expect(hit.accessibilityLabel.contains(title),
                    "VoiceOver must name the drawing a foreign hit came from")
        }

        // And the drawing in front is never labelled — it is the one being looked at.
        #expect(presenter.hits.contains { $0.sourceDocumentID == nil },
                "the active document's own hits must still be in the list")
        #expect(presenter.hits.allSatisfy { $0.sourceDocumentID != nil || $0.sourceDocumentTitle == nil })
    }

    @Test("With the toggle off, no other drawing is queried at all")
    func thisDrawingQueriesNothingElse() async throws {
        let (presenter, index, _, directory) = try await Self.makePresenter()
        defer { Task { await Self.tearDown(index, directory) } }

        let counter = QueryCounter()
        presenter.externalSources = [
            Self.source(title: "Level 2", snippet: "screed on two", counter: counter)
        ]
        #expect(!presenter.searchesAllDrawings, "the scope is this drawing until somebody widens it")

        presenter.query = "SCREED"
        presenter.runSearch()
        _ = await Self.wait { !presenter.isSearching && !presenter.hits.isEmpty }

        // Not "no foreign hit was shown" — no foreign drawing was *asked*. A search that read
        // thirty indexes and then hid the answers would still have done thirty searches.
        #expect(counter.callCount == 0)
        // Non-vacuous: this drawing really did answer, and every answer is its own.
        #expect(!presenter.hits.isEmpty)
        #expect(presenter.hits.allSatisfy { $0.sourceDocumentID == nil })
    }

    @Test("A slow drawing never costs the active document its own hits")
    func slowSourceDoesNotDropOwnHits() async throws {
        let (presenter, index, _, directory) = try await Self.makePresenter()
        defer { Task { await Self.tearDown(index, directory) } }

        let counter = QueryCounter()
        presenter.externalSources = [
            Self.slowSource(title: "Level 9", snippet: "screed on nine", counter: counter)
        ]
        presenter.searchesAllDrawings = true
        presenter.query = "SCREED"
        presenter.runSearch()

        // The active document answers first and its hits must be on screen while the slow
        // drawing is still thinking. This is the regression the two-store split exists for.
        let ownArrived = await Self.wait {
            presenter.hits.contains { $0.sourceDocumentID == nil }
        }
        #expect(ownArrived, "this drawing's hits must not wait on another drawing's index")
        let ownCountWhileWaiting = presenter.hits.filter { $0.sourceDocumentID == nil }.count
        #expect(ownCountWhileWaiting > 0)

        // …and they are still there once the slow drawing finally answers.
        let slowArrived = await Self.wait {
            presenter.hits.contains(where: { $0.sourceDocumentID != nil })
        }
        #expect(slowArrived, "the slow drawing's hits should arrive, late but present")
        #expect(counter.callCount == 1)

        let ownAfter = presenter.hits.filter { $0.sourceDocumentID == nil }
        #expect(ownAfter.count == ownCountWhileWaiting,
                "the late reply appended; it did not replace the active document's results")
        #expect(presenter.hits.filter({ $0.sourceDocumentID != nil }).count == 1)

        // Ordering: this drawing first, so the revealed hit does not jump to another drawing
        // the moment a fan-out lands.
        let foreignIndex = presenter.hits.firstIndex { $0.sourceDocumentID != nil }
        let firstForeign = try #require(foreignIndex)
        #expect(presenter.hits[..<firstForeign].allSatisfy { $0.sourceDocumentID == nil })
        #expect(presenter.activeHitID == presenter.hits.first?.id)
    }

    /// Old behaviour: when another drawing answered before this one (an instant source, or a
    /// loaded machine), its hit became the active hit, and it stayed active after this
    /// drawing's own hits arrived and sorted in front of it — the revealed hit sat on another
    /// drawing. `ProjectWideSearchTests` saw this intermittently under load.
    @Test("A foreign drawing that answers first does not keep the active hit from this drawing")
    func foreignFirstDoesNotKeepActiveHit() async throws {
        let (presenter, index, _, directory) = try await Self.makePresenter()
        defer { Task { await Self.tearDown(index, directory) } }

        presenter.externalSources = [
            ProjectSearchSource(documentID: UUID(), title: "Level 2") { text, _ in
                [Self.foreignHit(snippet: "screed on two \(text)")]
            }
        ]
        presenter.searchesAllDrawings = true
        presenter.query = "SCREED"
        presenter.runSearch()

        let bothArrived = await Self.wait {
            presenter.hits.contains(where: { $0.sourceDocumentID != nil })
                && presenter.hits.contains { $0.sourceDocumentID == nil }
        }
        #expect(bothArrived)
        #expect(presenter.hits.first.map { $0.sourceDocumentID == nil } == true, "this drawing's hits sort first")
        #expect(presenter.activeHitID == presenter.hits.first?.id,
                "the default active hit follows the ordering, not whichever drawing answered first")

        // A hit the person picked is kept, whatever arrives afterwards.
        let firstForeignHit = presenter.hits.first(where: { $0.sourceDocumentID != nil })
        let foreign = try #require(firstForeignHit)
        presenter.selectHit(id: foreign.id)
        presenter.runSearch()
        _ = await Self.wait { presenter.hits.contains(where: { $0.sourceDocumentID != nil }) }
        #expect(presenter.activeHitID == foreign.id || presenter.hits.contains { $0.id == presenter.activeHitID })
    }

    @Test("Clearing the query drops every drawing's hits, foreign ones included")
    func clearDropsForeignHits() async throws {
        let (presenter, index, _, directory) = try await Self.makePresenter()
        defer { Task { await Self.tearDown(index, directory) } }

        let counter = QueryCounter()
        presenter.externalSources = [
            Self.source(title: "Level 2", snippet: "screed on two", counter: counter)
        ]
        presenter.searchesAllDrawings = true
        presenter.query = "SCREED"
        presenter.runSearch()
        _ = await Self.wait { presenter.hits.contains(where: { $0.sourceDocumentID != nil }) }

        presenter.clear()
        #expect(presenter.hits.isEmpty)
        #expect(presenter.activeHitID == nil)

        // A late reply from the cancelled run must not resurrect the list.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(presenter.hits.isEmpty, "a reply to a cancelled query must not repopulate the panel")
    }
}
