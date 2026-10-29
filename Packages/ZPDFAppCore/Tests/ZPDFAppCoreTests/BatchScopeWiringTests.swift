import Foundation
import Testing
import ZPDFContracts
import ZPDFSearch
import ZPDFUIPresentation

@testable import ZPDFAppCore

/// The two batch scopes that were reachable and inert, and the preview sentence that has to
/// make either of them checkable.
///
/// Both defects were the same shape and both are worse than an absent feature: the sheet
/// offered the choice, accepted it, and then did something else. The search-term scope had
/// nothing filling ``BatchApplyRequest/searchMatchedPageIDs``, so it always selected no
/// pages; the navigator-selection scope was handed the page on screen, so it always selected
/// exactly one. Nothing here uses a double for the search index: the resolver is driven
/// against a real FTS5 database over a real three-page drawing, because "the term found the
/// right pages" is a claim about the query, not about a dictionary.
@Suite("Batch scopes: search term and navigator selection")
struct BatchScopeWiringTests {

    // MARK: - The search-term scope

    @Test("The search term resolves to exactly the pages whose text contains it")
    @MainActor
    func searchTermResolvesToTheRightPages() async throws {
        let fixture = try await Self.makeIndexedDrawing()
        defer { fixture.tearDown() }

        let resolved = await fixture.resolver.resolve(term: "FIRE")
        #expect(resolved.term == "FIRE")
        #expect(resolved.isAvailable)
        #expect(resolved.unavailableReason == nil)
        // Sheets one and three say FIRE; the second says SCREED and must not be stamped.
        #expect(resolved.pageIDs == Set([fixture.pageIDs[0], fixture.pageIDs[2]]))
        #expect(resolved.wasTruncated == false)
        #expect(resolved.includesRecognisedText == false)
        #expect(resolved.cautionSentence == nil)
    }

    @Test("Whitespace around the term is not a different question")
    @MainActor
    func theTermIsTrimmedBeforeItIsSearched() async throws {
        let fixture = try await Self.makeIndexedDrawing()
        defer { fixture.tearDown() }

        let padded = await fixture.resolver.resolve(term: "  FIRE\n")
        // The trimmed form is what is reported, so a caller comparing the resolution's term
        // against the trimmed field contents compares like with like and does not re-query.
        #expect(padded.term == "FIRE")
        #expect(padded.pageIDs.count == 2)
    }

    @Test("A term no page contains resolves to none, and says so rather than saying nothing")
    @MainActor
    func aTermThatMatchesNothingIsAnAnswer() async throws {
        let fixture = try await Self.makeIndexedDrawing()
        defer { fixture.tearDown() }

        let resolved = await fixture.resolver.resolve(term: "BALUSTRADE")
        // Available *and* empty. The distinction is the whole point: "no page matched" is an
        // answer the person can act on, "nobody looked" is not, and the sheet renders them
        // differently.
        #expect(resolved.isAvailable)
        #expect(resolved.pageIDs.isEmpty)
        #expect(resolved.cautionSentence == nil)
    }

    @Test("A zero-page search scope previews as zero and places nothing")
    @MainActor
    func aZeroPageSearchScopePlacesNothing() async throws {
        let fixture = try await Self.makeIndexedDrawing()
        defer { fixture.tearDown() }

        let (environment, _, domainPages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 6)
        let producer = try #require(environment.stampBatchProducer(
            for: StampAndBatchApplyTests.preset(stamp: StampAndBatchApplyTests.template(id: UUID())),
            promptedText: "Checked",
            now: StampAndBatchApplyTests.placementInstant
        ))
        _ = domainPages

        let resolved = await fixture.resolver.resolve(term: "BALUSTRADE")
        let plan = environment.planBatchApply(producer, request: BatchApplyRequest(
            scope: .matchingSearchTerm("BALUSTRADE"),
            anchor: .centered,
            searchMatchedPageIDs: resolved.pageIDs
        ))

        #expect(plan.placementCount == 0)
        #expect(plan.inScopeCount == 0)
        #expect(plan.totalPageCount == 6)
        #expect(plan.isEmpty)
        #expect(plan.previewSentence.contains("No page matches this scope"))
        // The scope is restated even when it selects nothing, because "0 of 6" against a
        // named scope is checkable and a bare "nothing will be placed" is not.
        #expect(plan.scopeSentence.contains("BALUSTRADE"))
        #expect(plan.scopeSentence.contains("0 of 6"))

        let receipt = await environment.runBatchApply(producer, plan: plan)
        #expect(receipt.placementCount == 0)
        #expect(environment.snapshot.markups.isEmpty, "an empty scope must place nothing at all")
    }

    @Test("A resolved search scope stamps those pages and no others")
    @MainActor
    func aResolvedSearchScopeStampsOnlyTheMatchedPages() async throws {
        let (environment, _, domainPages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 9)
        let producer = try #require(environment.stampBatchProducer(
            for: StampAndBatchApplyTests.preset(stamp: StampAndBatchApplyTests.template(id: UUID())),
            promptedText: "Checked",
            now: StampAndBatchApplyTests.placementInstant
        ))
        let matched = Set([domainPages[1].id.rawValue, domainPages[4].id.rawValue, domainPages[7].id.rawValue])

        let plan = environment.planBatchApply(producer, request: BatchApplyRequest(
            scope: .matchingSearchTerm("FIRE"),
            anchor: .corner(.bottomRight, insetX: 36, insetY: 36),
            searchMatchedPageIDs: matched
        ))
        #expect(plan.placementCount == 3)
        #expect(plan.inScopeCount == 3)
        #expect(plan.scopeSentence.contains("3 of 9"))
        #expect(plan.previewSentence.contains("3"))

        let receipt = await environment.runBatchApply(producer, plan: plan)
        #expect(receipt.placementCount == 3)
        #expect(Set(environment.snapshot.markups.map(\.pageID)) == matched)
    }

    // MARK: - The navigator-selection scope

    @Test("A plain click selects one page; Command-click builds a real multi-selection")
    @MainActor
    func commandClickSelectsMoreThanOnePage() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 8)
        let presenter = environment.document
        let ids = pages.map(\.id.rawValue)

        presenter.selectPage(id: ids[2], mode: .replace)
        #expect(presenter.selectedPageIDs == [ids[2]])
        #expect(presenter.currentPageID == ids[2])

        presenter.selectPage(id: ids[5], mode: .toggle)
        presenter.selectPage(id: ids[0], mode: .toggle)
        // Document order, not click order: 0, 2, 5 — never 2, 5, 0.
        #expect(presenter.selectedPageIDs == [ids[0], ids[2], ids[5]])
        // The canvas follows the page that was clicked, or the click had no visible result.
        #expect(presenter.currentPageID == ids[0])

        // Command-clicking a selected page takes it out again.
        presenter.selectPage(id: ids[2], mode: .toggle)
        #expect(presenter.selectedPageIDs == [ids[0], ids[5]])
    }

    @Test("Command-clicking the last selected page leaves an empty selection, not a hidden one")
    @MainActor
    func deselectingEverythingIsAState() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 4)
        let presenter = environment.document
        let ids = pages.map(\.id.rawValue)

        presenter.selectPage(id: ids[1], mode: .replace)
        presenter.selectPage(id: ids[1], mode: .toggle)
        // Empty, and empty must stay empty. A selection that quietly falls back to "the page
        // on screen" is exactly the defect this scope had.
        #expect(presenter.selectedPageIDs.isEmpty)

        let scope = AppCoreEnvironment.pageIDsInScope(
            request: BatchApplyRequest(
                scope: .navigatorSelection(presenter.selectedPageIDs),
                anchor: .centered
            ),
            pages: environment.snapshot.pages
        )
        #expect(scope.isEmpty, "an empty selection is an empty batch, never the whole document")
    }

    @Test("Shift-click extends from the anchor, and repeated Shift-clicks reshape one range")
    @MainActor
    func shiftClickExtendsFromTheAnchor() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 12)
        let presenter = environment.document
        let ids = pages.map(\.id.rawValue)

        presenter.selectPage(id: ids[4], mode: .replace)
        presenter.selectPage(id: ids[8], mode: .extend)
        #expect(presenter.selectedPageIDs == Array(ids[4...8]))

        // The second Shift-click must measure from 4 again, not from 8. Measuring from the
        // page last reached leaves 6...8 selected, which is a different five sheets.
        presenter.selectPage(id: ids[6], mode: .extend)
        #expect(presenter.selectedPageIDs == Array(ids[4...6]))

        // Backwards over the anchor, too.
        presenter.selectPage(id: ids[1], mode: .extend)
        #expect(presenter.selectedPageIDs == Array(ids[1...4]))
    }

    @Test("Navigating to a page is a plain selection of it")
    @MainActor
    func navigatingResetsTheSelection() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 6)
        let presenter = environment.document
        let ids = pages.map(\.id.rawValue)

        presenter.selectPage(id: ids[0], mode: .replace)
        presenter.selectPage(id: ids[3], mode: .toggle)
        #expect(presenter.selectedPageIDs.count == 2)

        presenter.goToPage(index: 5)
        #expect(presenter.selectedPageIDs == [ids[5]], "the sidebar and the scope cannot disagree")
    }

    @Test("The navigator scope stamps every selected page and only those")
    @MainActor
    func theNavigatorScopeStampsTheWholeSelection() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 10)
        let presenter = environment.document
        let ids = pages.map(\.id.rawValue)
        presenter.selectPage(id: ids[1], mode: .replace)
        presenter.selectPage(id: ids[4], mode: .toggle)
        presenter.selectPage(id: ids[9], mode: .toggle)

        let producer = try #require(environment.stampBatchProducer(
            for: StampAndBatchApplyTests.preset(stamp: StampAndBatchApplyTests.template(id: UUID())),
            promptedText: "Checked",
            now: StampAndBatchApplyTests.placementInstant
        ))
        let plan = environment.planBatchApply(producer, request: BatchApplyRequest(
            scope: .navigatorSelection(presenter.selectedPageIDs),
            anchor: .centered
        ))
        // Three, not one. One was the defect.
        #expect(plan.placementCount == 3)
        #expect(plan.scopeSentence.contains("3 of 10"))

        let receipt = await environment.runBatchApply(producer, plan: plan)
        #expect(receipt.placementCount == 3)
        #expect(Set(environment.snapshot.markups.map(\.pageID)) == Set([ids[1], ids[4], ids[9]]))
    }

    @Test("Modifier keys map to the three selection modes the platform means")
    func modifierMapping() {
        #expect(PageSelectionMode.forModifiers(command: false, shift: false) == .replace)
        #expect(PageSelectionMode.forModifiers(command: true, shift: false) == .toggle)
        #expect(PageSelectionMode.forModifiers(command: false, shift: true) == .extend)
        // Command wins: Command-Shift-click on a list toggles, it does not extend.
        #expect(PageSelectionMode.forModifiers(command: true, shift: true) == .toggle)
    }

    // MARK: - The preview sentence

    @Test("Every scope restates itself with a count the person can check")
    @MainActor
    func theScopeSentenceNamesTheScopeAndBothCounts() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 12)
        let producer = try #require(environment.stampBatchProducer(
            for: StampAndBatchApplyTests.preset(stamp: StampAndBatchApplyTests.template(id: UUID())),
            promptedText: "Checked",
            now: StampAndBatchApplyTests.placementInstant
        ))
        let ids = pages.map(\.id.rawValue)

        func sentence(_ scope: BatchPageScope, matched: Set<UUID>? = nil) -> String {
            environment.planBatchApply(producer, request: BatchApplyRequest(
                scope: scope, anchor: .centered, searchMatchedPageIDs: matched
            )).scopeSentence
        }

        #expect(sentence(.allPages).contains("12 of 12"))
        #expect(sentence(.pageRange(from: 3, through: 5)).contains("3 of 12"))
        #expect(sentence(.pageRange(from: 3, through: 5)).contains("3"))
        let sized = sentence(.matchingSize(widthPoints: 1191, heightPoints: 842, tolerancePoints: 1))
        #expect(sized.contains("4 of 12"), "every third sheet of the fixture is the A3 detail")
        let searched = sentence(.matchingSearchTerm("FIRE"), matched: Set([ids[0], ids[3]]))
        #expect(searched.contains("FIRE"))
        #expect(searched.contains("2 of 12"))
        #expect(sentence(.navigatorSelection([ids[6]])).contains("1 of 12"))
    }

    @Test("Pages in scope and placements are counted apart, so a full skip does not read as an empty scope")
    @MainActor
    func skippedPagesAreNotAnEmptyScope() async throws {
        let (environment, _, pages) = try await StampAndBatchApplyTests.makeEnvironment(pageCount: 5)
        let templateID = UUID()
        let preset = StampAndBatchApplyTests.preset(stamp: StampAndBatchApplyTests.template(id: templateID))
        let producer = try #require(environment.stampBatchProducer(
            for: preset, promptedText: "Checked", now: StampAndBatchApplyTests.placementInstant
        ))
        _ = pages

        let first = environment.planBatchApply(producer, request: BatchApplyRequest(
            scope: .allPages, anchor: .centered
        ))
        _ = await environment.runBatchApply(producer, plan: first)
        #expect(environment.snapshot.markups.count == 5)

        // Every page now carries it, so the skip rule takes all five out. The scope still
        // found five, and the preview has to say which of the two noughts this is — an
        // estimator who reads "no page matches this scope" here changes a correct scope.
        let second = environment.planBatchApply(producer, request: BatchApplyRequest(
            scope: .allPages, anchor: .centered
        ))
        #expect(second.inScopeCount == 5)
        #expect(second.placementCount == 0)
        #expect(second.scopeSentence.contains("5 of 5"))
        #expect(second.previewSentence.contains("already carry"))
        #expect(second.previewSentence.contains("No page matches this scope") == false)
    }

    // MARK: - Fixtures

    /// A three-page drawing with a real text layer, indexed, plus the resolver over it.
    struct IndexedDrawing {
        let index: DocumentSearchIndex
        let resolver: BatchSearchScopeResolver
        let pageIDs: [UUID]
        let directory: URL

        func tearDown() {
            let index = self.index
            let directory = self.directory
            Task { await index.shutDown() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Opens a three-page PDF whose sheets say FIRE, SCREED and FIRE, indexes its text layer
    /// and returns a resolver over the result.
    static func makeIndexedDrawing() async throws -> IndexedDrawing {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-batchscope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = directory.appendingPathComponent("Set.pdf")
        try writeTextPDF(to: pdf, pageTexts: ["FIRE DOOR SCHEDULE", "SCREED BAY 7", "FIRE MAIN RISER"])

        let documentUUID = UUID()
        let documentID = DocumentID(documentUUID)
        let pages = (0..<3).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: "A-10\(index)",
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
            displayName: "Set",
            pages: pages
        )
        // Awaited, not polled: the resolver's whole promise is that the count it reports is
        // taken from a finished index, and a timeout here would turn that into a coin flip.
        _ = try await index.indexDrawingText()

        let resolver = await BatchSearchScopeResolver(
            service: index.service,
            projectID: index.projectKey,
            documentID: index.documentKey,
            identity: index.identityMap(
                documentUUID: documentUUID,
                documentTitle: "Set",
                pages: pages,
                currentPageIndex: 0
            )
        )
        return IndexedDrawing(
            index: index,
            resolver: resolver,
            pageIDs: pages.map(\.id.rawValue),
            directory: directory
        )
    }

    /// A minimal multi-page PDF with one line of real text on each sheet.
    static func writeTextPDF(to url: URL, pageTexts: [String]) throws {
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("".utf8) // placeholder for the page tree, filled in once the kids are known
        ]
        var kids: [String] = []
        for text in pageTexts {
            let pageNumber = objects.count + 1
            let contentsNumber = pageNumber + 1
            kids.append("\(pageNumber) 0 R")
            objects.append(Data("""
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents \(contentsNumber) 0 R \
            /Resources << /Font << /F1 \(pageTexts.count * 2 + 3) 0 R >> >> >>
            """.utf8))
            let content = Data("BT /F1 18 Tf 72 700 Td (\(text)) Tj ET\n".utf8)
            var stream = Data("<< /Length \(content.count) >>\nstream\n".utf8)
            stream.append(content)
            stream.append(Data("\nendstream".utf8))
            objects.append(stream)
        }
        objects[1] = Data(
            "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pageTexts.count) >>".utf8
        )
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
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data(
            "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8
        ))
        try bytes.write(to: url)
    }
}
