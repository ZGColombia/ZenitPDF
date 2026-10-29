import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// LT-40, 2026-08-29: File ▸ Export Snippet… and Copy Snippet stayed disabled with the
/// measurement row selected in the docked Quantity Ledger. The menu validation reads
/// `core.canvas.selectedMarkupIDs`; a ledger row selection is supposed to arrive there via
/// `AppLedgerPresenter.onSelectionChange → canvas.applyExternalSelection`
/// (`AppCoreEnvironment.wire()`). These tests drive the selection the way the pane does —
/// from the table host outward — and assert the menu validation actually flips.
@MainActor
@Suite(.appTierSerialised)
struct LedgerSelectionMenuValidationTests {

    struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let controller: ProjectWindowController
        let canvas: PDFCanvasViewController
        let directory: URL
        let markupID: UUID
        let previousTabHost: ProjectWindowController?
    }

    private func wait(
        upTo seconds: Double = 30,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    /// A loaded document in a real (never-visible) project window with one committed,
    /// calibrated length measurement — one ledger row to select.
    private func makeHarness() async throws -> Harness {
        let previousTabHost = ProjectWindowController.tabHost
        let url = try AppTestSupport.writeFixturePDF(named: "LedgerSelect.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil && document.shell != nil && document.drawing != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()

        let controller = ProjectWindowController(document: document)
        let canvas = try #require(controller.canvasController(for: document))
        _ = canvas.view

        shell.perform(.measureLength)
        canvas.refresh()
        canvas.handleClick(at: PDFPointValue(x: 120, y: 200), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 320, y: 200), additive: false)
        await core.measurement.settlePlacements()
        core.measurement.commitActiveMeasurement()
        #expect(await wait { core.measurement.placedPoints.isEmpty })
        await core.commands.settle()
        await core.refresh()
        #expect(await wait { core.ledger.rowCount == 1 },
                "the harness needs one committed measurement to select")

        let markupID = try #require(core.ledger.row(at: 0)?.markupID)
        return Harness(
            document: document,
            core: core,
            shell: shell,
            controller: controller,
            canvas: canvas,
            directory: url.deletingLastPathComponent(),
            markupID: markupID,
            previousTabHost: previousTabHost
        )
    }

    private func tearDown(_ harness: Harness) {
        harness.controller.window?.close()
        harness.document.close()
        ProjectWindowController.tabHost = harness.previousTabHost
        try? FileManager.default.removeItem(at: harness.directory)
    }

    private func menuItem(_ command: ZenitAppCommand) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = command.rawValue
        return item
    }

    @Test("Selecting the row through the ledger presenter enables Export Snippet and Copy Snippet")
    func presenterSelectionEnablesSnippetCommands() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        harness.core.canvas.clearSelection()
        #expect(harness.controller.validateMenuItem(menuItem(.exportSnippet)) == false)
        #expect(harness.controller.validateMenuItem(menuItem(.copySnippet)) == false)

        // The exact call the docked pane makes when a row is clicked
        // (LedgerPaneModel.wire → host.onSelectionChange → presenter.select).
        harness.core.ledger.select(rowIDs: [harness.markupID], additive: false)

        #expect(harness.core.canvas.selectedMarkupIDs == [harness.markupID],
                "the ledger selection never reached the canvas presenter")
        #expect(harness.controller.validateMenuItem(menuItem(.exportSnippet)) == true,
                "LT-40: Export Snippet… stays disabled after a ledger row selection")
        #expect(harness.controller.validateMenuItem(menuItem(.copySnippet)) == true,
                "LT-40: Copy Snippet stays disabled after a ledger row selection")
    }

    @Test("Selecting the row in the docked pane's real table reaches the menu validation")
    func dockedPaneTableSelectionEnablesSnippetCommands() async throws {
        let harness = try await makeHarness()
        defer { tearDown(harness) }

        try ScratchDefaults.with(prefix: "zenit-lt40-pane") { defaults, _ in
            let preferences = LedgerPanePreferences(defaults: defaults)
            let model = LedgerPaneModel(presenter: harness.core.ledger, preferences: preferences)
            let controller = model.host.controller
            controller.loadViewIfNeeded()
            controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
            controller.view.layoutSubtreeIfNeeded()
            model.refresh()

            harness.core.canvas.clearSelection()
            #expect(harness.controller.validateMenuItem(menuItem(.exportSnippet)) == false)

            // The pane's real selection surface: the AppKit table the person clicks. A click
            // sets the table's selection and AppKit posts the selection-did-change the
            // controller's delegate wiring listens to; `selectRowIndexes` posts the same
            // notification, so this is the user's path minus the mouse.
            let tables = Self.tables(in: controller.view)
            #expect(!tables.isEmpty, "the docked pane built no table to select in")
            var selected = false
            for table in tables where !selected {
                for row in 0..<table.numberOfRows {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    if harness.core.ledger.selectedRowIDs == [harness.markupID] {
                        selected = true
                        break
                    }
                }
            }
            #expect(selected, "no table row selection ever reached the ledger presenter")
            #expect(harness.core.canvas.selectedMarkupIDs == [harness.markupID],
                    "the pane's table selection never reached the canvas presenter")
            #expect(harness.controller.validateMenuItem(menuItem(.exportSnippet)) == true,
                    "LT-40: the docked pane's row selection leaves Export Snippet… disabled")
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView { found.append(table) }
        for subview in view.subviews {
            found.append(contentsOf: tables(in: subview))
        }
        return found
    }
}
