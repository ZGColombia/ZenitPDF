import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// The application-tier join for the two batch scopes that did nothing.
///
/// Neither of them was broken in the engine — ``AppCoreEnvironment/pageIDsInScope(request:pages:)``
/// resolved both correctly all along. They were broken in the join, which is exactly the class
/// of wiring defect found before: nothing filled `searchMatchedPageIDs`, and the
/// navigator scope was handed the viewport's page instead of a selection. A package-tier test
/// cannot see either, so everything below reaches the hooks only through the model
/// `ProjectWindowController.makeBatchApplyModel(for:)` returns — the same object
/// `presentBatchApply(for:)` puts in the sheet.
///
/// **No sheet is opened, and the fixture is one page.** No test may put a window on
/// screen, and `NSWindow.beginSheet` hangs in a headless process, so the wiring is
/// asserted as a value. One page because that is all this tier has to prove — that the wire
/// exists and carries a real answer. Whether the wire carries *the right* answer over 312 mixed
/// sheets, a three-page indexed drawing and an eight-page multi-selection is proved in
/// `ZPDFAppCoreTests/BatchScopeWiringTests`, which needs no window and can afford the pages.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct BatchScopeWiringTests {

    // MARK: - Fixtures

    private func stampPreset() -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Reviewed",
            category: "Review",
            panel: .myTools,
            markupKind: .stamp,
            colorRGBA: ColorRGBA(red: 0.8, green: 0.1, blue: 0.1),
            defaultSubject: "Review",
            stamp: StampTemplate(
                id: UUID(),
                widthPoints: 160,
                heightPoints: 60,
                fields: [StampFieldDefinition(kind: .pageLabel)]
            )
        )
    }

    /// Opens the text fixture in a real window, with the index attached and filled.
    private func openIndexedWindow(
        text: String
    ) async throws -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        let url = try SearchAndOCRWiringTests.writeTextFixturePDF(text: text)
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait(upTo: 60) {
            controller.contentViewController is ProjectWindowLayoutController
        })
        #expect(await AppTestSupport.wait(upTo: 60) { document.core != nil && document.shell != nil })
        #expect(await AppTestSupport.wait(upTo: 60) { document.searchIndex != nil })
        await document.settleTextIndexing()
        controller.window?.layoutIfNeeded()
        return (document, controller)
    }

    /// Previews the current choices and waits for a search resolution to land.
    private func preview(_ model: BatchApplyModel) async {
        model.preview()
        _ = await AppTestSupport.wait(upTo: 30) { !model.isResolvingScope }
    }

    // MARK: - The search-term scope

    @Test("The search-term scope reaches the real index and previews a real count")
    func theSearchScopeIsWiredToTheIndex() async throws {
        try await SearchAndOCRWiringTests.withScratchIndexRoot {
            let (document, controller) = try await openIndexedWindow(text: "SCREED BAY 7 THICKNESS 65MM")
            defer {
                document.updateChangeCount(.changeCleared)
                document.close()
            }
            let core = try #require(document.core)
            core.toolLibrary.setPresets(core.toolLibrary.presets + [stampPreset()])

            let wired = try #require(controller.makeBatchApplyModel(for: document))
            let model = wired.model
            // The hook that did not exist. Without it the scope was reachable and inert.
            #expect(model.onResolveSearchScope != nil, "nothing installed the search resolver")

            model.scopeChoice = .matchingSearchTerm
            model.searchTerm = "SCREED"
            await preview(model)

            let plan = try #require(model.plan)
            #expect(plan.placementCount == 1)
            #expect(model.searchResolution?.isAvailable == true)
            #expect(model.canApply)
            let scope = try #require(model.scopeSentence)
            #expect(scope.contains("SCREED"))
            #expect(scope.contains("1 of 1"))

            await model.run()
            #expect(await AppTestSupport.wait(upTo: 30) { core.snapshot.markups.count == 1 })
        }
    }

    @Test("A term the drawing does not contain places nothing, and the preview says so")
    func aTermThatMatchesNoPagePlacesNothing() async throws {
        try await SearchAndOCRWiringTests.withScratchIndexRoot {
            let (document, controller) = try await openIndexedWindow(text: "SCREED BAY 7 THICKNESS 65MM")
            defer {
                document.updateChangeCount(.changeCleared)
                document.close()
            }
            let core = try #require(document.core)
            core.toolLibrary.setPresets(core.toolLibrary.presets + [stampPreset()])

            let model = try #require(controller.makeBatchApplyModel(for: document)).model
            model.scopeChoice = .matchingSearchTerm
            model.searchTerm = "BALUSTRADE"
            await preview(model)

            // Resolved, available, and empty — three separate facts, and the sheet has all
            // three. "Nobody looked" would be a different state and would read the same.
            #expect(model.searchResolution?.isAvailable == true)
            #expect(model.searchResolution?.pageIDs.isEmpty == true)
            #expect(model.plan?.placementCount == 0)
            #expect(model.previewSentence.contains("No page matches this scope"))
            #expect(try #require(model.scopeSentence).contains("0 of 1"))
            #expect(model.canApply == false)

            await model.run()
            // Given a moment to be wrong in, and it must still be nothing.
            _ = await AppTestSupport.wait(upTo: 2) { !core.snapshot.markups.isEmpty }
            #expect(core.snapshot.markups.isEmpty, "a scope that resolved to zero pages places nothing")
        }
    }

    // MARK: - The navigator-selection scope

    @Test("The navigator scope reads the Navigator's selection, not the page on screen")
    func theNavigatorScopeReadsTheSelection() async throws {
        try await SearchAndOCRWiringTests.withScratchIndexRoot {
            let (document, controller) = try await openIndexedWindow(text: "SCREED BAY 7")
            defer {
                document.updateChangeCount(.changeCleared)
                document.close()
            }
            let core = try #require(document.core)
            core.toolLibrary.setPresets(core.toolLibrary.presets + [stampPreset()])
            let pageID = try #require(core.snapshot.pages.first?.id)

            // An opened drawing has its first page selected, so the sidebar's highlight and
            // the scope agree from the start.
            #expect(core.document.selectedPageIDs == [pageID])
            let selected = try #require(controller.makeBatchApplyModel(for: document)).model
            #expect(selected.navigatorSelection == [pageID])
            selected.scopeChoice = .navigatorSelection
            await preview(selected)
            #expect(selected.plan?.placementCount == 1)
            #expect(try #require(selected.scopeSentence).contains("1 of 1"))

            // Command-clicking the only selected page away leaves nothing selected, and the
            // scope must carry that through rather than falling back to the viewport's page —
            // which is precisely what it used to do.
            core.document.selectPage(id: pageID, mode: .toggle)
            #expect(core.document.selectedPageIDs.isEmpty)
            #expect(core.canvas.viewport.pageID == pageID, "the canvas is still showing it")

            let empty = try #require(controller.makeBatchApplyModel(for: document)).model
            #expect(empty.navigatorSelection.isEmpty, "the scope read the viewport, not the selection")
            empty.scopeChoice = .navigatorSelection
            await preview(empty)
            #expect(empty.plan?.placementCount == 0)
            #expect(empty.canApply == false)

            await empty.run()
            _ = await AppTestSupport.wait(upTo: 2) { !core.snapshot.markups.isEmpty }
            #expect(core.snapshot.markups.isEmpty)
        }
    }
}
