import Foundation
import Testing
import ZPDFContracts
import ZPDFSearch
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// LT-10 and LT-11: what the interactive search paths actually ask the index.
///
/// `ZPDFSearch` grew ``SearchQueryOptions/findAsYouType`` — the last bare word of a query
/// compiles as a prefix — and every one of its own tests passed while the shipping panel kept
/// sending `.standard`. That is the defect shape this file exists to make impossible: an
/// option that is correct in the package it lives in and unreachable from the application.
/// Nothing here uses a stub compiler or a fake service. Every assertion runs a real FTS5
/// query over a real drawing whose text layer was really read, because "the panel finds the
/// word" is a claim about the query that reaches SQLite, not about a preset being spelled
/// somewhere.
///
/// The fixture text is ASCII on purpose. The Swedish case behind this —
/// `Storkök` missing `Storkökskonsult` — is asserted on the compiler itself in
/// `ZPDFSearchTests/TrailingPrefixQueryTests`; writing `ö` into a minimal Type1/Helvetica
/// content stream would test this repository's PDF byte-writer's encoding rather than the
/// search path, and a fixture that fails for the wrong reason proves nothing.
@MainActor
@Suite("Interactive search: find-as-you-type, whole word, and the all-drawings fan-out")
struct InteractiveSearchAdoptionTests {

    // MARK: - Fixtures

    /// One open drawing: a real index, the presenter behind its Search panel, and the batch
    /// sheet's scope resolver over the same index — the three things the app tier builds
    /// side by side in `attachSearchIndex`.
    struct Drawing {
        let index: DocumentSearchIndex
        let presenter: AppSearchPresenter
        let resolver: BatchSearchScopeResolver
        let pages: [ZPDFContracts.PageDescriptor]
        let documentID: UUID
        let directory: URL

        func tearDown() async {
            await index.shutDown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func makeDrawing(
        named name: String,
        pageTexts: [String]
    ) async throws -> Drawing {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-interactive-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("\(name).pdf")
        try BatchScopeWiringTests.writeTextPDF(to: pdf, pageTexts: pageTexts)

        let documentUUID = UUID()
        let documentID = DocumentID(documentUUID)
        let pages = pageTexts.indices.map { position in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: position,
                label: "\(name)-10\(position)",
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
            displayName: name,
            pages: pages
        )
        // Awaited rather than polled. The whole point of these assertions is what a finished
        // index answers; a timeout would turn every one of them into a coin flip.
        _ = try await index.indexDrawingText()

        let identity = index.identityMap(
            documentUUID: documentUUID,
            documentTitle: name,
            pages: pages,
            currentPageIndex: 0
        )
        let presenter = AppSearchPresenter(
            service: index.service,
            projectID: index.projectKey,
            identity: identity,
            scope: ZPDFUIPresentation.SearchScope(location: .entireProject)
        )
        // No debounce: these tests drive `runSearch()` directly and must not race a timer.
        presenter.debounce = .zero

        return Drawing(
            index: index,
            presenter: presenter,
            resolver: BatchSearchScopeResolver(
                service: index.service,
                projectID: index.projectKey,
                documentID: index.documentKey,
                identity: identity
            ),
            pages: pages,
            documentID: documentUUID,
            directory: directory
        )
    }

    /// Polls the main actor until `condition` holds or the budget runs out. The presenter
    /// answers on tasks it owns; there is no completion handler to await.
    private static func wait(
        upTo seconds: Double = 10,
        for condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Waits for one complete run of the presenter's own query, hits or no hits.
    ///
    /// `performSearch` sets `isSearching` synchronously, and `apply`/`applyFailure` clear it
    /// together with a result summary. Waiting on both is what makes "no results" assertable
    /// as an *answer* rather than as "the query had not landed yet".
    private static func settle(_ presenter: AppSearchPresenter) async -> Bool {
        await wait { !presenter.isSearching && !presenter.resultSummary.isEmpty }
    }

    /// Counts what a fan-out source was asked, so "the other drawing was queried" is a call
    /// that was made, not merely a hit that appeared.
    @MainActor
    final class QueryCounter {
        private(set) var queries: [String] = []
        func record(_ text: String) { queries.append(text) }
        var callCount: Int { queries.count }
    }

    // MARK: - LT-10: the panel

    @Test("The panel finds the compound the estimator is still halfway through typing")
    func panelMatchesTheWordBeingTyped() async throws {
        let drawing = try await Self.makeDrawing(
            named: "PlanA",
            pageTexts: ["STORKOKSKONSULT AB", "SCREED BAY 7"]
        )
        defer { Task { await drawing.tearDown() } }
        let presenter = drawing.presenter

        presenter.query = "STORKOK"
        presenter.runSearch()
        #expect(await Self.settle(presenter))

        #expect(!presenter.hits.isEmpty, "the half-typed compound must find the whole word")
        let hit = try #require(presenter.hits.first)
        #expect(hit.snippet.uppercased().contains("STORKOKSKONSULT"))
        #expect(hit.pageID == drawing.pages[0].id.rawValue,
                "and it must point at the sheet the word is actually on")

        // Non-vacuous: the token `STORKOK` is genuinely absent from the index. The same
        // service, the same text, the options the app sent before LT-10 was fixed — nothing.
        // So the hit above came from the implied prefix and from nothing else.
        let wholeToken = try await drawing.index.service.search(
            SearchRequest(
                text: "STORKOK",
                scope: .project(projectId: drawing.index.projectKey),
                sources: .all,
                queryOptions: .standard,
                confidence: .standard
            )
        )
        #expect(wholeToken.hits.isEmpty,
                "the index holds no token spelled STORKOK; only a prefix query can match it")
    }

    @Test("A finished word is still an exact word: earlier terms are not widened")
    func onlyTheLastBareWordIsAPrefix() async throws {
        let drawing = try await Self.makeDrawing(
            named: "PlanB",
            pageTexts: ["STORKOKSKONSULT UTRUSTNING", "STORKOKSKONSULT SCREED"]
        )
        defer { Task { await drawing.tearDown() } }
        let presenter = drawing.presenter

        // `UTRUS` is the word being typed and matches as a prefix; `STORKOKSKONSULT` was
        // finished and stays an exact token. Only the first sheet satisfies both.
        presenter.query = "STORKOKSKONSULT UTRUS"
        presenter.runSearch()
        #expect(await Self.settle(presenter))

        #expect(!presenter.hits.isEmpty)
        #expect(presenter.hits.allSatisfy { $0.pageID == drawing.pages[0].id.rawValue },
                "the finished term must not have been widened into the second sheet")
    }

    @Test("A whole-word query stays exact — the implied prefix never overrides it")
    func wholeWordRefusesThePrefix() async throws {
        let drawing = try await Self.makeDrawing(
            named: "PlanC",
            pageTexts: ["STORKOKSKONSULT AB"]
        )
        defer { Task { await drawing.tearDown() } }
        let presenter = drawing.presenter

        presenter.scope.isWholeWord = true
        presenter.query = "STORKOK"
        presenter.runSearch()
        #expect(await Self.settle(presenter))
        #expect(presenter.hits.isEmpty,
                "whole word means exactly this token; a scope that widened it would be a lie")

        // The fixture is not simply barren: the same presenter, the same query string, whole
        // word switched off, finds the compound. The empty answer above is the option.
        presenter.scope.isWholeWord = false
        presenter.runSearch()
        #expect(await Self.wait { !presenter.hits.isEmpty })
        #expect(presenter.hits.first?.snippet.uppercased().contains("STORKOKSKONSULT") == true)

        // And whole word does not break exact searching: the full token still matches.
        presenter.scope.isWholeWord = true
        presenter.query = "STORKOKSKONSULT"
        presenter.runSearch()
        #expect(await Self.wait { !presenter.hits.isEmpty })
    }

    // MARK: - LT-10: the batch sheet's scope preview

    @Test("The batch scope preview counts the same pages the panel lists")
    func batchScopeAgreesWithThePanel() async throws {
        let drawing = try await Self.makeDrawing(
            named: "PlanD",
            pageTexts: ["STORKOKSKONSULT AB", "SCREED BAY 7", "STORKOKSUTRUSTNING"]
        )
        defer { Task { await drawing.tearDown() } }
        let presenter = drawing.presenter

        presenter.query = "STORKOK"
        presenter.runSearch()
        #expect(await Self.settle(presenter))
        let panelPages = Set(presenter.hits.map(\.pageID))
        #expect(panelPages == Set([drawing.pages[0].id.rawValue, drawing.pages[2].id.rawValue]))

        // The sheet re-previews on every keystroke, so it is the same kind of field and must
        // give the same answer. A preview that disagreed with the panel about the same term
        // is the number a person checks before placing hundreds of stamps.
        let resolved = await drawing.resolver.resolve(term: "STORKOK")
        #expect(resolved.isAvailable)
        #expect(resolved.pageIDs == panelPages,
                "the scope preview and the Search panel must not disagree about one term")
        #expect(resolved.pageIDs.count == 2)

        // And it is still a search, not a match-everything: the third sheet is excluded by a
        // term that does not begin it.
        let narrower = await drawing.resolver.resolve(term: "SCREE")
        #expect(narrower.pageIDs == Set([drawing.pages[1].id.rawValue]))
    }

    // MARK: - LT-11: the all-drawings fan-out

    @Test("A drawing wired up after its presenter already searched still gains the fan-out")
    func lateSourcesWidenALiveResultSet() async throws {
        // Two real drawings, two real indexes — the fan-out is asked through
        // `hitsForProjectSearch`, exactly as `ZenitPDFProjectDocument.projectSearchSource()`
        // asks it. Nothing here is a stub, so a foreign hit that appears was produced by the
        // other drawing's own FTS5 database.
        let front = try await Self.makeDrawing(named: "FrontPlan", pageTexts: ["STORKOKSKONSULT AB"])
        let other = try await Self.makeDrawing(named: "OtherPlan", pageTexts: ["STORKOKSUTRUSTNING SCHEDULE"])
        defer {
            Task { await front.tearDown() }
            Task { await other.tearDown() }
        }

        let presenter = front.presenter
        // The state the window leaves a drawing in whenever it pushes the open set before the
        // other drawing's presenter exists: the toggle is on, and there is nothing to fan out
        // to. LT-11 is this state never being left.
        presenter.searchesAllDrawings = true
        #expect(presenter.externalSources.isEmpty)

        presenter.query = "STORKOK"
        presenter.runSearch()
        #expect(await Self.settle(presenter))
        #expect(!presenter.hits.isEmpty, "the drawing in front answers for itself")
        #expect(presenter.hits.allSatisfy { $0.sourceDocumentID == nil })
        let ownCount = presenter.hits.count

        // Now the other drawing's presenter becomes ready and the window re-pushes. The
        // person has not touched the field — the result set must widen on its own, because
        // "turn the toggle on, then wait for another drawing to finish opening" is the
        // ordinary case, not the exotic one.
        let counter = QueryCounter()
        #expect(counter.callCount == 0)
        presenter.externalSources = [
            ZPDFUIPresentation.ProjectSearchSource(
                documentID: other.documentID,
                title: "OtherPlan"
            ) { [weak otherPresenter = other.presenter] text, options in
                counter.record(text)
                return await otherPresenter?.hitsForProjectSearch(text, options: options) ?? []
            }
        ]

        #expect(await Self.wait { presenter.hits.contains(where: { $0.sourceDocumentID != nil }) },
                "the drawing wired up late was never queried")
        #expect(counter.queries == ["STORKOK"], "and it was asked the query already on screen")

        let foreign = presenter.hits.filter({ $0.sourceDocumentID != nil })
        #expect(foreign.count == 1)
        let hit = try #require(foreign.first)
        // The snippet names a word that exists only in the other drawing, so the hit cannot
        // have come from the front drawing's index by any route.
        #expect(hit.snippet.uppercased().contains("SCHEDULE"))
        #expect(hit.snippet.uppercased().contains("STORKOKSUTRUSTNING"),
                "the fan-out must match prefixes too, or All Drawings answers by a second rule")
        #expect(hit.sourceDocumentID == other.documentID)
        #expect(hit.sourceDocumentTitle == "OtherPlan")
        #expect(hit.pageID == other.pages[0].id.rawValue,
                "and it points at the other drawing's own page, mapped by its own identity map")

        // The front drawing's own results survived the widening, and stayed first.
        let ownAfter = presenter.hits.filter { $0.sourceDocumentID == nil }
        #expect(ownAfter.count == ownCount)
        let foreignIndex = presenter.hits.firstIndex { $0.sourceDocumentID != nil }
        let firstForeign = try #require(foreignIndex)
        #expect(presenter.hits[..<firstForeign].allSatisfy { $0.sourceDocumentID == nil })
    }

    /// R-153. Old output: every hit `hitsForProjectSearch` returned carried
    /// `boundsInPageSpace`, because its request left `resolvesBounds` at `true` and the engine
    /// ran a PDFKit page search (up to sixteen for a trailing prefix) for every text hit of
    /// every other open drawing on each keystroke, before any result could appear.
    @Test("R-153: the fan-out answers without rectangles, and the owning drawing locates a hit when it is revealed")
    func fanOutDefersBoundsToTheReveal() async throws {
        let other = try await Self.makeDrawing(named: "OtherR153", pageTexts: ["STORKOKSUTRUSTNING SCHEDULE"])
        defer { Task { await other.tearDown() } }

        let answered = await other.presenter.hitsForProjectSearch("STORKOK", options: ProjectSearchOptions())
        let hit = try #require(answered.first)
        #expect(answered.allSatisfy { $0.boundsInPageSpace == nil }, "no page search before the list")

        // The window forwards the revealed hit to its owner, which asks its presenter.
        let bounds = try #require(await other.presenter.projectSearchBounds(forHit: hit.id))
        #expect(bounds.size.width > 0 && bounds.size.height > 0)
        #expect(bounds.origin.x >= 0 && bounds.origin.x + bounds.size.width <= 595)
        #expect(bounds.origin.y >= 0 && bounds.origin.y + bounds.size.height <= 842)
        // A hit this presenter never answered has nothing to resolve.
        #expect(await other.presenter.projectSearchBounds(forHit: UUID()) == nil)
    }

    @Test("Sources that arrive while the toggle is off cost nothing, and work the moment it is on")
    func sourcesArrivingBeforeTheToggleAreNotLost() async throws {
        let front = try await Self.makeDrawing(named: "FrontB", pageTexts: ["STORKOKSKONSULT AB"])
        let other = try await Self.makeDrawing(named: "OtherB", pageTexts: ["STORKOKSUTRUSTNING SCHEDULE"])
        defer {
            Task { await front.tearDown() }
            Task { await other.tearDown() }
        }

        let presenter = front.presenter
        let counter = QueryCounter()
        // The other order: the window wires the open set up first, and the person widens the
        // search afterwards. Installing a source must not search anything by itself.
        presenter.externalSources = [
            ZPDFUIPresentation.ProjectSearchSource(
                documentID: other.documentID,
                title: "OtherB"
            ) { [weak otherPresenter = other.presenter] text, options in
                counter.record(text)
                return await otherPresenter?.hitsForProjectSearch(text, options: options) ?? []
            }
        ]
        presenter.query = "STORKOK"
        presenter.runSearch()
        #expect(await Self.settle(presenter))
        #expect(!presenter.hits.isEmpty)
        #expect(counter.callCount == 0, "This Drawing must not have read the other drawing's index")

        presenter.searchesAllDrawings = true
        #expect(await Self.wait { presenter.hits.contains(where: { $0.sourceDocumentID != nil }) },
                "widening the reach must widen the result set already on screen")
        #expect(counter.queries == ["STORKOK"])
        #expect(presenter.hits.first(where: { $0.sourceDocumentID != nil })?.sourceDocumentTitle == "OtherB")
    }
}
