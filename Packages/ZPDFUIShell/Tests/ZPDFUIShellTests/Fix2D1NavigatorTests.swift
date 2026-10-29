import CoreGraphics
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIMeasurement
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Fix round 2, part D1: the Navigator — page turns, the two layer lists, Search, and the
/// thumbnail loader.
@MainActor
@Suite("Fix2 D1 — Navigator", .shellTierSerialised)
struct Fix2D1NavigatorTests {

    // MARK: - Fixtures

    /// Arms a Scale Regions boundary on the page currently showing.
    private func drawDraft(in environment: ProjectShellEnvironment) throws -> PageDescriptor {
        let page = try #require(environment.document.currentPage)
        // The canvas's boundary tool, as the application wires it.
        if environment.scaleRegions.onBeginPolygon == nil {
            environment.scaleRegions.onBeginPolygon = {}
            environment.scaleRegions.onCancelPolygonDrawing = {}
        }
        #expect(environment.scaleRegions.beginRegion())
        #expect(environment.scaleRegions.completePolygon(
            [PDFPointValue(x: 100, y: 100), PDFPointValue(x: 400, y: 100), PDFPointValue(x: 400, y: 400)],
            pageID: page.id,
            pageLabel: page.label
        ))
        #expect(environment.scaleRegions.draft != nil)
        return page
    }

    private func markups(onLayers layers: [String?]) throws -> [MarkupSummary] {
        let seed = ZenitSampleProject.shared.markups
        try #require(seed.count >= layers.count)
        return zip(seed, layers).map { markup, layer in
            var copy = markup
            copy.layer = layer
            return copy
        }
    }

    // MARK: - BH-296: a page turn from the Navigator reaches the page-scoped panels

    /// Old output, against the Navigator calling `environment.document.selectPage` directly (the
    /// only thing a thumbnail click did before the fix):
    ///
    /// ```
    /// ✘ Expectation failed: (environment.scaleRegions.draft → ScaleRegionDraft(… pageID: …065 …)) == nil
    /// ✘ Expectation failed: (environment.scaleRegions.regions → [… "Stair Detail 1:20" …]) ≠ page two's
    /// ```
    ///
    /// The first block below keeps that old path as a control so the difference is visible in
    /// one test: the direct presenter call still leaves the panel stale, and the environment's
    /// page-turn path — the one every shell control now uses — does not.
    @Test("A thumbnail click, the page field and a search hit all refresh Scale Regions")
    func navigatorPageTurnRefreshesScaleRegions() throws {
        // Control: the old path.
        let control = ProjectShellEnvironment.mock()
        let drawnOn = try drawDraft(in: control)
        let other = try #require(control.document.pages.first { $0.id != drawnOn.id })
        control.document.selectPage(id: other.id, mode: .replace)
        #expect(control.document.currentPageID == other.id)
        #expect(control.scaleRegions.draft != nil, "control: the direct presenter call never told the panel")

        // The fix: the environment's page-turn path.
        let environment = ProjectShellEnvironment.mock()
        let first = try drawDraft(in: environment)
        let second = try #require(environment.document.pages.first { $0.id != first.id })
        environment.selectPage(id: second.id, mode: .replace)
        #expect(environment.document.currentPageID == second.id)
        #expect(environment.scaleRegions.draft == nil, "a boundary drawn on another sheet is still armed")
        #expect(
            environment.scaleRegions.regions.map(\.id)
                == environment.document.scaleRegions(onPage: second.id).map(\.id),
            "the panel still lists the previous sheet's regions"
        )

        // The status bar's page field path (BH-299's shape) and a search hit's reveal.
        _ = try drawDraft(in: environment)
        let firstIndex = try #require(environment.document.pages.firstIndex { $0.id == first.id })
        environment.goToPage(index: firstIndex)
        #expect(environment.document.currentPageID == first.id)
        #expect(environment.scaleRegions.draft == nil)
        _ = try drawDraft(in: environment)
        environment.turningPage { environment.document.goToPage(id: second.id) }
        #expect(environment.scaleRegions.draft == nil)
    }

    // MARK: - IM-030 / BH-297: the Layers page shows both kinds

    /// Old output: the page rendered `if !documentLayers.isEmpty { List(documentLayers) } else …`,
    /// so with two optional-content layers and markups on "Walls" the markup section did not
    /// exist — the rule below returned `[.drawingLayers(…)]` only.
    @Test("With PDF layers and markup layers, the Layers page shows both sections")
    func layersPageShowsBothSections() throws {
        let documentLayers = [
            NavigatorLayerRow(id: "oc-1", name: "A-WALL", isVisible: true, isLocked: true),
            NavigatorLayerRow(id: "oc-2", name: "A-DOOR", isVisible: false)
        ]
        let markupLayers = NavigatorLayersList.layers(in: try markups(onLayers: ["Walls", "Walls", nil]))
        let sections = NavigatorLayersList.sections(documentLayers: documentLayers, markupLayers: markupLayers)
        #expect(sections == [.drawingLayers(documentLayers), .markupLayers(markupLayers)])
        #expect(sections.map(\.title) == ["Drawing layers", "Markup layers"])

        #expect(NavigatorLayersList.sections(documentLayers: [], markupLayers: markupLayers) == [.markupLayers(markupLayers)])
        #expect(NavigatorLayersList.sections(documentLayers: documentLayers, markupLayers: []) == [.drawingLayers(documentLayers)])
        #expect(NavigatorLayersList.sections(documentLayers: [], markupLayers: []).isEmpty)

        // Both lists' drawing-layer rows offer the same measure-lock menu item.
        #expect(NavigatorLayerLabel.measureLockMenuTitle(isMeasuringHere: false) == "Measure Only on This Layer")
        #expect(NavigatorLayerLabel.measureLockMenuTitle(isMeasuringHere: true) == "Stop Measuring on One Layer")
        #expect(!NavigatorLayerLabel.locked.isEmpty, "the lock glyph is spoken")
    }

    // MARK: - BH-818 / IM-127: reading order, and a layer that survives a filter

    /// Old output: `.sorted { $0.name < $1.name }` → `["Väggar", "dörrar", "fönster"]`.
    @Test("Markup layers are listed in reading order, not code-point order")
    func layersSortForReaders() throws {
        let names = NavigatorLayersList.layers(in: try markups(onLayers: ["dörrar", "Väggar", "fönster"])).map(\.name)
        #expect(names == ["dörrar", "fönster", "Väggar"])
    }

    @Test("A layer whose markups a ledger filter hides stays listed on its page")
    func filteredLayerStaysListed() throws {
        let model = NavigatorLayerListModel()
        let page = NavigatorLayerScope(documentID: UUID(), pageID: UUID())
        let all = try markups(onLayers: ["Walls", "Doors", "Walls"])
        #expect(model.markupLayers(in: all, scope: page).map(\.name) == ["Doors", "Walls"])

        // The filter took every "Walls" markup off the canvas.
        let filtered = all.filter { $0.layer != "Walls" }
        let listed = model.markupLayers(in: filtered, scope: page)
        #expect(listed.map(\.name) == ["Doors", "Walls"], "Walls vanished, and with it its checkbox")
        #expect(listed.first { $0.name == "Walls" }?.markupCount == 0)

        // Another page starts clean.
        let otherPage = NavigatorLayerScope(documentID: page.documentID, pageID: UUID())
        #expect(model.markupLayers(in: filtered, scope: otherPage).map(\.name) == ["Doors"])
    }

    /// IM-127's performance half, measured rather than assumed: the derivation both lists run
    /// in `body` is one dictionary pass plus a sort of the (few) layer names.
    @Test("Deriving the layer list stays cheap at drawing-set scale")
    func layerDerivationIsCheap() throws {
        let seed = ZenitSampleProject.shared.markups
        let big: [MarkupSummary] = (0..<10_000).map { index in
            var copy = seed[index % seed.count]
            copy.layer = "Layer \(index % 24)"
            return copy
        }
        let model = NavigatorLayerListModel()
        let scope = NavigatorLayerScope(documentID: UUID(), pageID: UUID())
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 { _ = model.markupLayers(in: big, scope: scope) }
        }
        let perCall = elapsed / 10
        print("Fix2D1 IM-127: markupLayers over 10,000 markups / 24 layers = \(perCall) per call")
        #expect(perCall < .milliseconds(50))
    }

    // MARK: - IM-128 / IM-129 / IM-130: Search

    @Test("Search copy follows the scope, the reach and what can still widen")
    func searchCopyFollowsTheScope() {
        #expect(NavigatorSearchPage.fieldPrompt(searchesAllDrawings: false) == "Search this document")
        #expect(NavigatorSearchPage.fieldPrompt(searchesAllDrawings: true) == "Search all open drawings")

        let idle = NavigatorSearchPage.emptyState(query: "", scope: .default, searchesAllDrawings: false, offersReach: false)
        #expect(idle.message.contains("PDF Text"))
        // L-20: the default scope searches recognised text, and the idle copy says so.
        // Old: "Looks through PDF Text, Markups, Comments, and Labels. …" — no OCR Text.
        #expect(idle.message.contains("OCR Text"), "the default scope searches recognised text (L-20)")
        #expect(!idle.message.contains("Custom Fields"))

        let oneDrawing = NavigatorSearchPage.emptyState(query: "x", scope: .default, searchesAllDrawings: false, offersReach: false)
        #expect(oneDrawing.title == "No results")
        #expect(!oneDrawing.message.contains("all open drawings"), "one drawing open: nothing to reach")
        #expect(oneDrawing.message.contains("Search Options"))

        let everything = SearchScope(sources: Set(SearchSource.allCases))
        let nothingLeft = NavigatorSearchPage.emptyState(query: "x", scope: everything, searchesAllDrawings: true, offersReach: true)
        #expect(!nothingLeft.message.contains("Search Options"))
        #expect(!nothingLeft.message.contains("all open drawings"))

        let both = NavigatorSearchPage.emptyState(query: "x", scope: .default, searchesAllDrawings: false, offersReach: true)
        #expect(both.message.contains("all open drawings") && both.message.contains("Search Options"))
    }

    @Test("Toggling a source updates the presenter's scope and never empties it")
    func sourceToggles() {
        let search = MockSearchPresenter()
        // L-20: recognised text starts ticked, so the first toggle unticks it.
        #expect(search.scope.sources.contains(.ocrText))
        search.scope = SearchScopeEditing.scope(search.scope, togglingSource: .ocrText)
        #expect(!search.scope.sources.contains(.ocrText))
        search.scope = SearchScopeEditing.scope(search.scope, togglingSource: .ocrText)
        #expect(search.scope.sources.contains(.ocrText))
        // A source the default leaves out is added by its toggle.
        #expect(!search.scope.sources.contains(.customFields))
        search.scope = SearchScopeEditing.scope(search.scope, togglingSource: .customFields)
        #expect(search.scope.sources.contains(.customFields))

        let single = SearchScope(sources: [.markups])
        #expect(SearchScopeEditing.scope(single, togglingSource: .markups) == single)
    }

    @Test("Previous and Next step through hits and the counter follows")
    func stepperAdvances() throws {
        let environment = ProjectShellEnvironment.mock()
        let search = environment.search
        let word = try #require(
            ZenitSampleProject.shared.searchHits
                .compactMap { $0.snippet.split(separator: " ").first.map(String.init) }
                .first { candidate in
                    ZenitSampleProject.shared.searchHits
                        .filter { $0.snippet.localizedCaseInsensitiveContains(candidate) }
                        .count >= 2
                },
            "the sample project needs a word with two hits"
        )
        search.query = word
        try #require(search.hits.count >= 2)
        let firstActive = search.activeHitID
        environment.advanceSearch(by: 1)
        #expect(search.activeHitID != firstActive)
        #expect(search.activeHitPosition == 2)
        #expect(NavigatorSearchPage.positionText(position: 2, count: search.hits.count) == "2 of \(search.hits.count)")
        environment.advanceSearch(by: -1)
        #expect(search.activeHitID == firstActive)

        #expect(NavigatorSearchPage.positionText(position: nil, count: 1) == "1 result")
        #expect(NavigatorSearchPage.positionText(position: nil, count: 3) == "3 results")
    }

    /// Old output: the page showed `ZPDFEmptyState("No results")` whenever `hits.isEmpty` —
    /// `isSearching` was never read, so the rule was `hitCount == 0` alone.
    @Test("A running search is never shown as No results")
    func searchingIsNotNoResults() {
        #expect(!NavigatorSearchPage.showsEmptyState(isSearching: true, hitCount: 0))
        #expect(NavigatorSearchPage.showsEmptyState(isSearching: false, hitCount: 0))
        #expect(!NavigatorSearchPage.showsEmptyState(isSearching: false, hitCount: 4))
        #expect(!NavigatorSearchPage.searchingText.isEmpty)
    }

    // MARK: - IM-125 / BH-816: the page row's task re-keys on the provider

    /// Old output: the row keyed its task on `page.id` alone, so the key before and after a
    /// provider arrived was the same value and the task never re-ran.
    @Test("A provider installed after the first render changes the page row's task key")
    func pageTaskKeyFollowsTheProvider() {
        let loader = NavigatorThumbnailLoader()
        let pageID = UUID()
        let before = NavigatorThumbnailTaskKey(subject: pageID, providerRevision: loader.providerRevision)
        loader.setProvider({ _, _ in nil }, identity: "doc-1")
        let after = NavigatorThumbnailTaskKey(subject: pageID, providerRevision: loader.providerRevision)
        #expect(before != after)
    }

    // MARK: - IM-131: a byte budget, not just a count

    private static func image(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    @Test("64 full-size thumbnails stay inside the byte budget, least recent evicted first")
    func thumbnailCacheHasAByteBudget() async throws {
        let sample = try #require(Self.image(width: 480, height: 680))
        let loader = NavigatorThumbnailLoader()
        loader.setProvider({ _, _ in sample }, identity: "doc")
        var ids: [UUID] = []
        for index in 0..<64 {
            let id = UUID()
            ids.append(id)
            await loader.request(pageID: id, pageIndex: index)
        }
        let perImage = NavigatorThumbnailLoader.byteCost(of: sample)
        print("Fix2D1 IM-131: one 480x680 thumbnail = \(perImage) bytes; count cap alone would hold \(64 * perImage) bytes; budget holds \(loader.cachedBytes)")
        #expect(loader.cachedBytes <= loader.byteBudget)
        #expect(loader.cachedCount < 64)
        #expect(64 * perImage > loader.byteBudget, "the old count-only cap exceeded the budget")
        // LRU: the survivors are the most recent requests, in order.
        #expect(loader.recencyOrder == Array(ids.suffix(loader.cachedCount)))
    }

    // MARK: - IM-220: identified requests are deduplicated in flight

    /// Old output: `request(id:)` checked only `images[id] == nil`, so two overlapping requests
    /// both reached the provider — `calls == 2`.
    @Test("Two overlapping requests for one drawing render it once")
    func identifiedRequestsDedupe() async {
        let loader = NavigatorThumbnailLoader()
        var calls = 0
        let sample = Self.image(width: 8, height: 8)
        loader.setIdentifiedProvider({ _, _ in
            calls += 1
            try? await Task.sleep(for: .milliseconds(20))
            return sample
        }, identity: "drawings")
        let id = UUID()
        async let first: Void = loader.request(id: id)
        async let second: Void = loader.request(id: id)
        _ = await (first, second)
        #expect(calls == 1)
        #expect(loader.image(for: id) != nil)
    }

    // MARK: - IM-216 / IM-217: names and next steps

    @Test("The open-drawings section has one name and its own glyph")
    func drawingsSectionNaming() {
        #expect(NavigatorSection.drawings.switcherTitle == "Drawings")
        #expect(NavigatorSection.drawings.displayName == "Open Drawings")
        #expect(NavigatorSection.drawings.glyph != .symbol(.workspaces), "Workspaces is a different feature")
        #expect(NavigatorSection.drawings.glyph != NavigatorSection.pages.glyph)
    }

    @Test("The empty Pages list offers Open, which runs the open command")
    func pagesEmptyStateOffersOpen() {
        #expect(NavigatorPagesList.emptyStateActionTitle == "Open…")
        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        environment.perform(.openDocument)
        #expect(forwarded == [.openDocument])
    }
}
