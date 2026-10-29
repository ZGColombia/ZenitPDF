import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFFormulaEngine
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// NL-UX-20: Window ▸ New Window for Project — a full second window on the same project.
///
/// Old: `ZenitPDFProjectDocument.shell` and `.core` were single stored values built once per
/// document, `ProjectWindowController.install` built one canvas per document, and there was no
/// way to open the document in a second window at all (the Split Canvas pane in a window of its
/// own, NL-DOCS-14, was the nearest thing). These tests pin the new shape: one takeoff core per
/// document, a per-window core view, shell and canvas per window, edits and undo shared, and a
/// close path that keeps the document open until its last window closes.
///
/// No window is ever ordered on screen: `ProjectWindowController.secondWindowPresenter` shows a
/// window only in the assembled application, and the first window is never shown either.
@MainActor
@Suite(.appTierSerialised)
struct NLUX20SecondWindowTests {

    @MainActor
    private struct Harness {
        let document: ZenitPDFProjectDocument
        let first: ProjectWindowController
        let second: ProjectWindowController
        let directory: URL
        let previousTabHost: ProjectWindowController?

        var firstCore: AppCoreEnvironment { first.windowCore(for: document)! }
        var secondCore: AppCoreEnvironment { second.windowCore(for: document)! }
        var firstShell: ProjectShellEnvironment { first.windowShell(for: document)! }
        var secondShell: ProjectShellEnvironment { second.windowShell(for: document)! }
        var firstCanvas: PDFCanvasViewController { first.canvasController(for: document)! }
        var secondCanvas: PDFCanvasViewController { second.canvasController(for: document)! }

        func tearDown() {
            document.unsavedTakeoffReview = { _, answer in answer(.discard) }
            if !document.isClosed { document.close() }
            second.window?.close()
            first.window?.close()
            ProjectWindowController.tabHost = previousTabHost
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A two-sheet drawing in its first window, calibrated 100 pt = 1 m with snap off, and a
    /// second window opened on it through the command's own path.
    private func makeHarness(_ name: String) async throws -> Harness {
        let previousTabHost = ProjectWindowController.tabHost
        let url = try AppTestSupport.writeFixturePDF(named: name, pageCount: 2)
        let document = try AppTestSupport.makeDocument(opening: url)
        let first = ProjectWindowController(document: document)
        document.addWindowController(first)
        #expect(await AppTestSupport.wait { document.core != nil && first.canvasController(for: document) != nil })
        let core = try #require(document.core)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        var snap = await core.session.currentSnapSettings
        snap.enabledKinds = []
        try await core.session.setSnapSettings(snap)
        await core.refresh()
        document.updateChangeCount(.changeCleared)

        let second = try #require(await first.openNewWindow(for: document))
        #expect(await AppTestSupport.wait { second.canvasController(for: document) != nil })
        return Harness(
            document: document,
            first: first,
            second: second,
            directory: url.deletingLastPathComponent(),
            previousTabHost: previousTabHost
        )
    }

    private func record(on document: ZenitPDFProjectDocument, pageIndex: Int = 0, x: Double) throws -> MarkupRecord {
        let drawing = try #require(document.drawing)
        let page = drawing.pages[pageIndex]
        return MarkupRecord(
            id: MarkupID(UUID()),
            documentID: drawing.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .length,
            subject: "Wall",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: x, y: 200), PDFPoint(x: x + 100, y: 200)]),
            createdAt: Date(),
            modifiedAt: Date()
        )
    }

    private func menuItem(_ command: ZPDFCommandID) -> NSMenuItem {
        let item = NSMenuItem(title: command.rawValue, action: nil, keyEquivalent: "")
        item.representedObject = command.rawValue
        return item
    }

    private func markupIDs(_ core: AppCoreEnvironment) -> Set<UUID> {
        Set(core.snapshot.markups.map(\.id))
    }

    // MARK: - One core

    @Test("NL-UX-20: two window controllers on one document share one takeoff core — session, bus, undo, History")
    func twoWindowsShareTheCore() async throws {
        let harness = try await makeHarness("NLUX20-Share.pdf")
        defer { harness.tearDown() }
        let document = harness.document

        // One core, one view of it per window.
        #expect(harness.firstCore === document.primaryCore)
        #expect(harness.secondCore !== harness.firstCore)
        #expect(harness.secondCore.isWindowView)
        #expect(harness.secondCore.primaryEnvironment === harness.firstCore)
        #expect(harness.firstCore.windowViews.contains { $0 === harness.secondCore })
        #expect(harness.secondCore.session === harness.firstCore.session)
        #expect(harness.secondCore.commands === harness.firstCore.commands)
        #expect(harness.secondCore.history === harness.firstCore.history)
        #expect(harness.secondCore.review === harness.firstCore.review)
        #expect(harness.firstCore.commands.undoManager === document.undoManager)

        // Its own shell and canvas per window, on the same document, and the second window is a
        // window controller of the document, never on screen and never a tab host.
        #expect(harness.secondShell !== harness.firstShell)
        #expect(harness.secondCanvas !== harness.firstCanvas)
        #expect(harness.secondCanvas.core === harness.secondCore)
        #expect(harness.firstCanvas.core === harness.firstCore)
        #expect(document.windowControllers.contains { $0 === harness.first })
        #expect(document.windowControllers.contains { $0 === harness.second })
        #expect(harness.second.documents.count == 1 && harness.second.documents.first === document)
        #expect(!harness.second.canHostAdditionalDocuments)
        #expect(harness.second.window?.isVisible == false)
        #expect(harness.second.window?.title == "NLUX20-Share — 2")
        #expect(harness.second.layoutStoreKey(for: document) == ProjectWindowController.secondWindowLayoutKey)
        #expect(harness.first.layoutStoreKey(for: document) == ProjectWindowLayoutStore.defaultsKey)

        // The page on screen is the window's.
        let pages = harness.firstCore.document.pages.map(\.id)
        try #require(pages.count == 2)
        harness.secondShell.goToPage(id: pages[1])
        #expect(harness.secondCore.document.currentPageID == pages[1])
        #expect(harness.firstCore.document.currentPageID == pages[0], "turning the second window's sheet turned the first's")

        // One undo stack: an edit made in the second window is undone by ⌘Z in the first.
        let wall = try record(on: document, x: 100)
        _ = try await harness.secondCore.commands.perform(.addMarkup(wall))
        #expect(await AppTestSupport.wait {
            harness.firstCore.snapshot.markups.count == 1 && harness.secondCore.snapshot.markups.count == 1
        })
        let firstWindow = try #require(harness.first.window)
        let secondWindow = try #require(harness.second.window)
        #expect(harness.first.windowWillReturnUndoManager(firstWindow) === document.undoManager)
        #expect(harness.second.windowWillReturnUndoManager(secondWindow) === document.undoManager)
        #expect(document.isDocumentEdited)
        harness.first.undo(nil)
        #expect(await AppTestSupport.wait {
            harness.firstCore.snapshot.markups.isEmpty && harness.secondCore.snapshot.markups.isEmpty
        }, "one ⌘Z in the first window takes back the second window's edit in both")
        // …and the audit trail recorded the edit once, whichever window made it.
        #expect(harness.firstCore.history === harness.secondCore.history)
    }

    // MARK: - Per-window selection

    @Test("NL-UX-20: selection is per window, and a command routed through a window acts on that window's selection")
    func selectionIsPerWindow() async throws {
        let harness = try await makeHarness("NLUX20-Select.pdf")
        defer { harness.tearDown() }
        let document = harness.document
        let left = try record(on: document, x: 100)
        let right = try record(on: document, x: 300)
        _ = try await harness.firstCore.commands.perform(.addMarkup(left))
        _ = try await harness.firstCore.commands.perform(.addMarkup(right))
        #expect(await AppTestSupport.wait {
            markupIDs(harness.firstCore) == [left.id.rawValue, right.id.rawValue]
                && markupIDs(harness.secondCore) == [left.id.rawValue, right.id.rawValue]
        })

        harness.firstCore.canvas.select(markupIDs: [left.id.rawValue], additive: false)
        #expect(harness.firstCore.canvas.selectedMarkupIDs == [left.id.rawValue])
        #expect(harness.secondCore.canvas.selectedMarkupIDs.isEmpty, "selecting in the first window selected in the second")
        #expect(harness.secondCore.ledger.selectedRowIDs.isEmpty, "the second window's ledger followed the first's canvas")

        harness.secondCore.canvas.select(markupIDs: [right.id.rawValue], additive: false)
        #expect(harness.secondCore.canvas.selectedMarkupIDs == [right.id.rawValue])
        #expect(harness.firstCore.canvas.selectedMarkupIDs == [left.id.rawValue], "the first window lost its selection")

        // Delete, chosen in the second window, deletes the second window's selection — not the
        // first's — and both windows show the result. The first window had focus last, so this
        // is the routing's doing, not a leftover.
        harness.first.focusThisWindow()
        #expect(document.core === harness.firstCore)
        harness.second.performZenitCommand(menuItem(.deleteSelection))
        #expect(document.core === harness.secondCore, "a command routed through the second window acts on its view")
        #expect(await AppTestSupport.wait {
            markupIDs(harness.firstCore) == [left.id.rawValue]
                && markupIDs(harness.secondCore) == [left.id.rawValue]
        }, "Delete in the second window removed \(markupIDs(harness.secondCore)) instead of the right-hand wall only")
        #expect(harness.firstCore.canvas.selectedMarkupIDs == [left.id.rawValue])

        // Focus follows the window a command comes through.
        harness.first.focusThisWindow()
        #expect(document.core === harness.firstCore)
        #expect(document.shell === harness.firstShell)
    }

    // MARK: - Edits show in both

    @Test("NL-UX-20: a measurement drawn in window A appears in window B's scene and ledger, and B's tool stays its own")
    func editInOneWindowShowsInTheOther() async throws {
        let harness = try await makeHarness("NLUX20-Edit.pdf")
        defer { harness.tearDown() }

        // Window B draws from its own observation, as a window on screen does; nothing below
        // refreshes it by hand.
        let secondCanvas = harness.secondCanvas
        _ = secondCanvas.view
        secondCanvas.viewDidAppear()
        #expect(secondCanvas.sceneRecords.isEmpty)

        // Drawn in window A the way a person draws: arm Length, two clicks, finish.
        let firstCanvas = harness.firstCanvas
        _ = firstCanvas.view
        harness.first.focusThisWindow()
        harness.firstShell.perform(.measureLength)
        firstCanvas.refresh()
        firstCanvas.handleClick(at: PDFPointValue(x: 120, y: 200), additive: false)
        firstCanvas.handleClick(at: PDFPointValue(x: 320, y: 200), additive: false)
        await harness.firstCore.measurement.settlePlacements()
        harness.firstCore.measurement.commitActiveMeasurement()

        #expect(await AppTestSupport.wait { harness.firstCore.ledger.rowCount == 1 })
        #expect(await AppTestSupport.wait { secondCanvas.sceneRecords.count == 1 },
                "window B's scene never showed the measurement drawn in window A")
        #expect(harness.secondCore.ledger.rowCount == 1, "window B's ledger never showed the row")
        #expect(secondCanvas.sceneRecords.first?.id == harness.firstCore.snapshot.markups.first.map { MarkupID($0.id) })

        // The armed tool is the window's: Length is armed in A only.
        #expect(harness.firstCore.measurement.activeKind != nil)
        #expect(harness.secondCore.measurement.activeKind == nil, "arming a tool in window A armed it in window B")
        #expect(harness.secondShell.toolbar.activeSelection.mode == .select)
    }

    // MARK: - Closing

    @Test("NL-UX-20: closing window A leaves window B working, the document open and unreviewed")
    func closingTheFirstWindowKeepsTheDocument() async throws {
        let harness = try await makeHarness("NLUX20-CloseA.pdf")
        defer { harness.tearDown() }
        let document = harness.document
        _ = try await harness.firstCore.commands.perform(.addMarkup(try record(on: document, x: 100)))
        #expect(await AppTestSupport.wait { harness.secondCore.snapshot.markups.count == 1 })
        #expect(document.isDocumentEdited)
        var reviews = 0
        document.unsavedTakeoffReview = { _, answer in
            reviews += 1
            answer(.cancel)
        }
        let secondCore = harness.secondCore
        let secondCanvas = harness.secondCanvas
        secondCanvas.viewDidAppear()

        let firstWindow = try #require(harness.first.window)
        #expect(harness.first.windowShouldClose(firstWindow) == false, "the close runs as a review chain")
        #expect(await AppTestSupport.wait { harness.first.documents.isEmpty })

        // The document was handed over, not reviewed and not closed.
        #expect(reviews == 0, "closing one of two windows asked the unsaved-changes question")
        #expect(!document.isClosed)
        #expect(document.hostWindowController === harness.second)
        #expect(!document.windowControllers.contains { $0 === harness.first })
        #expect(document.windowControllers.contains { $0 === harness.second })
        #expect(document.core === secondCore, "the document still answers through the closed window's core")
        #expect(document.primaryCore?.windowViews.contains { $0 === secondCore } == true)

        // Window B still works: an edit there lands, shows, and undoes.
        let second = try record(on: document, x: 300)
        _ = try await secondCore.commands.perform(.addMarkup(second))
        #expect(await AppTestSupport.wait { secondCore.snapshot.markups.count == 2 && secondCanvas.sceneRecords.count == 2 })
        harness.second.undo(nil)
        #expect(await AppTestSupport.wait { secondCore.snapshot.markups.count == 1 && secondCanvas.sceneRecords.count == 1 })
        #expect(reviews == 0)
    }

    @Test("NL-UX-20: closing window B while A shows the document asks nothing and leaves A working")
    func closingTheSecondWindowKeepsTheDocument() async throws {
        let harness = try await makeHarness("NLUX20-CloseB.pdf")
        defer { harness.tearDown() }
        let document = harness.document
        _ = try await harness.firstCore.commands.perform(.addMarkup(try record(on: document, x: 100)))
        #expect(await AppTestSupport.wait { harness.secondCore.snapshot.markups.count == 1 })
        var reviews = 0
        document.unsavedTakeoffReview = { _, answer in
            reviews += 1
            answer(.cancel)
        }
        let secondCore = harness.secondCore
        let secondWindow = try #require(harness.second.window)
        #expect(harness.second.windowShouldClose(secondWindow), "a second window closes at once")
        secondWindow.close()

        #expect(reviews == 0)
        #expect(!document.isClosed)
        #expect(!document.windowControllers.contains { $0 === harness.second })
        #expect(document.windowViews.isEmpty)
        #expect(harness.firstCore.windowViews.isEmpty, "the closed window's view is still refreshed")
        #expect(document.primaryCore?.windowViews.contains { $0 === secondCore } == false)
        #expect(document.core === harness.firstCore)

        // The first window keeps working, with its own canvas callbacks back in place.
        _ = try await harness.firstCore.commands.perform(.addMarkup(try record(on: document, x: 300)))
        #expect(await AppTestSupport.wait { harness.firstCore.snapshot.markups.count == 2 })
        #expect(document.firstWindowSlots == nil, "the first window's slots were not restored")
    }

    @Test("NL-UX-20: closing window B, the document's last window, runs the normal close and review (injected)")
    func closingTheLastWindowRunsTheReview() async throws {
        let harness = try await makeHarness("NLUX20-CloseLast.pdf")
        defer { harness.tearDown() }
        let document = harness.document
        _ = try await harness.firstCore.commands.perform(.addMarkup(try record(on: document, x: 100)))
        #expect(await AppTestSupport.wait { harness.secondCore.snapshot.markups.count == 1 })
        var reviewed: [ZenitPDFProjectDocument] = []
        document.unsavedTakeoffReview = { reviewedDocument, answer in
            reviewed.append(reviewedDocument)
            answer(.discard)
        }

        // A goes first: no question, the document moves to B.
        let firstWindow = try #require(harness.first.window)
        _ = harness.first.windowShouldClose(firstWindow)
        #expect(await AppTestSupport.wait { harness.first.documents.isEmpty })
        #expect(reviewed.isEmpty)

        // B is now the last window: its close is the ordinary one — the review runs once, and its
        // answer closes the document and the window.
        let secondWindow = try #require(harness.second.window)
        var secondWindowClosed = false
        let observation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: secondWindow,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { secondWindowClosed = true }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        #expect(harness.second.windowShouldClose(secondWindow) == false, "the last window closes through the review chain")
        #expect(await AppTestSupport.wait { document.isClosed && secondWindowClosed })
        #expect(reviewed.count == 1 && reviewed.first === document, "the unsaved-changes review ran \(reviewed.count) times")
        #expect(harness.second.windowViews.isEmpty)
        #expect(document.windowViews.isEmpty)
    }

    // MARK: - The ledger's recipe library

    @Test("NL-UX-20: a second window's ledger offers the office library as a save target, and a project recipe saved there edits the document")
    func secondWindowLedgerHasTheRecipeLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-nlux20-recipes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = AssemblyRecipesFlow.library
        // A library in a temporary directory, never the user's Application Support.
        AssemblyRecipesFlow.library = AssemblyRecipeLibrary(directory: directory.appendingPathComponent("Library", isDirectory: true))
        defer {
            AssemblyRecipesFlow.library = previous
            try? FileManager.default.removeItem(at: directory)
        }
        let harness = try await makeHarness("NLUX20-Recipes.pdf")
        defer { harness.tearDown() }
        let document = harness.document
        let firstLedger = harness.firstCore.ledger
        let secondLedger = harness.secondCore.ledger

        // Old: the second window's ledger had no office library and no edit hook, so the recipe
        // editor there offered the project alone.
        #expect(firstLedger.assemblyRecipeStores == [.office, .project])
        #expect(secondLedger.officeRecipeLibrary != nil, "the second window's ledger has no office library")
        #expect(secondLedger.assemblyRecipeStores == [.office, .project], "Office Library is not a save target in the second window")
        #expect(secondLedger.onProjectAssembliesChanged != nil, "the second window's ledger cannot mark the document edited")
        #expect(harness.secondShell.onImportAssemblyRecipes != nil)
        #expect(harness.secondShell.onExportAssemblyRecipes != nil)
        #expect(harness.secondShell.onBatchProjectSummary != nil)

        let recipe = AssemblyDefinition(
            id: UUID(uuidString: "7C1B2F3E-2222-4A2B-9C3D-0000000020A1")!, name: "Skirting", note: nil,
            inputs: [AssemblyInput(name: "Perimeter", dimension: .length)],
            lines: [AssemblyLine(name: "Skirting board", source: "Perimeter", outputDimension: .length)]
        )
        // Saved to the office library from the second window: offered in both.
        let office = await harness.secondCore.saveAssemblyRecipe(recipe, to: .office)
        #expect(office.failureDescription == nil)
        #expect(firstLedger.officeAssemblies.map(\.id) == [recipe.id])
        #expect(secondLedger.officeAssemblies.map(\.id) == [recipe.id])
        #expect(try AssemblyRecipesFlow.library?.read().map(\.id) == [recipe.id])

        // Saved to the project from the second window: part of the document, so it is edited,
        // and the first window offers it too.
        document.updateChangeCount(.changeCleared)
        let project = await harness.secondCore.saveAssemblyRecipe(recipe, to: .project)
        #expect(project.failureDescription == nil)
        #expect(document.isDocumentEdited, "a project recipe saved in the second window did not edit the document")
        #expect(firstLedger.projectAssemblies.map(\.id) == [recipe.id])
        #expect(secondLedger.projectAssemblies.map(\.id) == [recipe.id])
    }

    // MARK: - The command

    @Test("NL-UX-20: Window ▸ New Window for Project is ⌃⌘N, needs a loaded document, and opens a window through the menu path")
    func theMenuCommandOpensASecondWindow() async throws {
        let spec = ZenitAppCommandTable.spec(for: .newWindowForProject)
        #expect(spec.title == "New Window for Project")
        #expect(spec.slot == .windowTabs)
        #expect(spec.keyEquivalent == ZenitKeyEquivalent("n", [.command, .control]))
        #expect(spec.rule == .loadedCore)

        let previousTabHost = ProjectWindowController.tabHost
        let url = try AppTestSupport.writeFixturePDF(named: "NLUX20-Menu.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        let first = ProjectWindowController(document: document)
        document.addWindowController(first)
        defer {
            for view in document.windowViews { view.controller?.window?.close() }
            document.close()
            first.window?.close()
            ProjectWindowController.tabHost = previousTabHost
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        #expect(await AppTestSupport.wait { document.core != nil && first.canvasController(for: document) != nil })

        let item = NSMenuItem(title: spec.title, action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZenitAppCommand.newWindowForProject.rawValue
        #expect(first.validateMenuItem(item))
        first.performZenitCommand(item)
        #expect(await AppTestSupport.wait { document.windowViews.first?.controller?.canvasController(for: document) != nil })
        let second = try #require(document.windowViews.first?.controller)
        #expect(second !== first)
        #expect(second.window?.isVisible == false, "a test put the second window on screen")
        #expect(ProjectWindowController.tabHost !== second, "a second window became the tab host")
    }
}
