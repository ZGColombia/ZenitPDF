import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger
@testable import ZPDFUIShell

/// NL-UX-09 in the docked pane: clickable summary chips that filter by quantity kind, and the
/// ledger row context menu over the window's own doors.
@MainActor
@Suite("Quantities round 2 — ledger pane", .shellTierSerialised)
struct NLQuantitiesR2PaneTests {

    private func make() throws -> (LedgerPaneModel, MockLedgerPresenter, ProjectShellEnvironment, () -> Void) {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.r2pane")
        let environment = ProjectShellEnvironment.mock()
        let presenter = try #require(environment.ledger as? MockLedgerPresenter)
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        return (model, presenter, environment, { ShellScratchDefaults.discard(defaults, suiteName: name) })
    }

    @Test("The Areas chip filters to rows with a Plan Area; again, or Markups, shows every row")
    func kindChips() throws {
        let (model, presenter, _, tearDown) = try make()
        defer { tearDown() }
        let all = presenter.unfilteredRowCount
        // Hand count over the fixture: the rows whose Plan Area cell holds a value.
        let areas = (0..<all).compactMap { presenter.row(at: $0) }.filter {
            if let value = $0.values[.planArea] { return value != .empty }
            return false
        }.count
        #expect(areas > 0 && areas < all, "the fixture mixes areas with other kinds")

        model.toggleKindChip(.areas)
        #expect(model.activeKindChip == .areas)
        #expect(model.matchCount == areas, "the Filter button reads (\(areas) of \(all))")
        #expect(!model.filter.isEmpty, "a chip is a real filter rule")

        model.toggleKindChip(.lengths)
        #expect(model.activeKindChip == .lengths, "one kind at a time")
        #expect(model.filter.rules.filter { LedgerPaneModel.kindChip(of: $0) != nil }.count == 1)

        model.toggleKindChip(.lengths)
        #expect(model.activeKindChip == nil)
        #expect(model.matchCount == all)

        model.toggleKindChip(.counts)
        model.toggleKindChip(.markups)
        #expect(model.activeKindChip == nil, "Markups — every row — clears the kind filter")
        #expect(model.matchCount == all)
    }

    @Test("The row menu lists Zoom To, Select on Canvas, Change Status, Lock, Delete")
    func rowMenuItems() throws {
        let (model, presenter, environment, tearDown) = try make()
        defer { tearDown() }
        let row = try #require(presenter.row(at: 0)?.markupID)
        let configuration = model.rowMenuConfiguration(environment: environment)
        let menu = NSMenu()
        model.host.controller.populateRowMenu(menu, rows: [row], configuration: configuration)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Zoom To", "Select on Canvas", "Change Status", "Lock", "Delete"])
        let statuses = try #require(menu.items.first { $0.title == "Change Status" }?.submenu)
        #expect(statuses.items.map(\.title) == model.rowMenuStatuses.map(\.title))
        #expect(!statuses.items.isEmpty)
        // With an explainer the menu offers Explain….
        let explaining = model.rowMenuConfiguration(environment: environment, explain: { _ in })
        let second = NSMenu()
        model.host.controller.populateRowMenu(second, rows: [row], configuration: explaining)
        #expect(second.items.contains { $0.title == "Explain…" })
        // No configuration, no menu: never dead items.
        model.host.controller.rowMenu = nil
        #expect(model.host.controller.tableViewForMenu.menu == nil)
        model.installRowMenu(environment: environment)
        #expect(model.host.controller.tableViewForMenu.menu != nil)
    }

    @Test("Each row-menu item goes through the window's own door")
    func rowMenuActions() async throws {
        let (model, presenter, environment, tearDown) = try make()
        defer { tearDown() }
        // Two rows unlocked both in the ledger and on the canvas, so Lock means "lock".
        let lockedOnCanvas = Set(environment.canvas.visibleMarkups.filter(\.locked).map(\.id))
        let unlocked = (0..<presenter.unfilteredRowCount).compactMap { presenter.row(at: $0) }
            .filter { !$0.locked && !lockedOnCanvas.contains($0.markupID) }.map(\.markupID)
        #expect(unlocked.count >= 2)
        let first = unlocked[0]
        let second = unlocked[1]
        let rows: Set<UUID> = [first, second]

        model.performRowMenuAction(.selectOnCanvas, rows: rows, environment: environment, explain: nil)
        #expect(environment.canvas.selectedMarkupIDs == rows)

        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        model.performRowMenuAction(.zoomTo, rows: rows, environment: environment, explain: nil)
        #expect(forwarded == [.zoomToSelection], "several rows fit the selection")
        model.performRowMenuAction(.delete, rows: [first], environment: environment, explain: nil)
        #expect(environment.canvas.selectedMarkupIDs == [first])
        #expect(forwarded.last == .deleteSelection)

        var locked: (Set<UUID>, Bool)?
        environment.inspectorEditing.onSetLocked = { ids, flag in locked = (ids, flag) }
        model.performRowMenuAction(.toggleLock, rows: rows, environment: environment, explain: nil)
        #expect(locked?.0 == rows)
        #expect(locked?.1 == true, "unlocked rows lock")

        var explained: Set<UUID>?
        model.performRowMenuAction(.explain, rows: rows, environment: environment, explain: { explained = $0 })
        #expect(explained == rows)

        let status = try #require(model.rowMenuStatuses.last?.value)
        model.performRowMenuAction(.setStatus(status), rows: rows, environment: environment, explain: nil)
        for _ in 0..<100 where presenter.appliedBulkEdits.isEmpty { await Task.yield() }
        let edit = try #require(presenter.appliedBulkEdits.last)
        #expect(edit.markupIDs == rows)
        #expect(edit.values[.status] == .choice(status), "one bulk edit: one undo step, one audit entry")
    }

    @Test("Explain: from the selection or a group heading, the rows behind the total and a way to each markup")
    func explainPanel() async throws {
        let (model, presenter, environment, tearDown) = try make()
        defer { tearDown() }
        #expect(model.canExplain)
        model.installRowMenu(environment: environment)
        #expect(model.host.controller.rowMenu?.canExplain == true)

        // A group heading stands for every row in the group.
        _ = model.host.controller.view   // loaded off-screen, never in a window
        model.setGrouping([.subject])
        model.host.controller.rebuildPlan()
        let group = try #require(model.host.controller.plan.groups.first)
        let inGroup = model.host.controller.rowIDs(inGroup: group.path)
        #expect(inGroup.count == group.rowRange.count)
        #expect(!inGroup.isEmpty)

        model.openExplain(inGroup)
        let panel = try #require(model.explainPanel)
        await panel.reload()
        let explanation = try #require(panel.explanation)
        #expect(Set(explanation.rows.map(\.markupID)) == inGroup)
        #expect(panel.canShow)
        let first = try #require(explanation.rows.first?.markupID)
        panel.show(first)
        #expect(environment.canvas.selectedMarkupIDs == [first], "Show selects the markup on the canvas")
        model.closeExplain()
        #expect(model.explainPanel == nil)

        // Nothing selected, nothing to explain.
        model.explainSelection()
        #expect(model.explainPanel == nil)
        _ = presenter
    }

    @Test("Summarise Closed Projects: the window's hook reaches the Whole Project panel, and its result shows")
    func batchSummaryFromThePanel() async throws {
        let (model, _, environment, tearDown) = try make()
        defer { tearDown() }
        let batch = LedgerBatchSummary(
            drawings: [], combined: [LedgerSubjectTotal(subject: "Slab", quantity: DecimalQuantity(value: 14, dimension: .area), rowCount: 2, text: "14.00 m²")],
            refused: [.init(name: "Bogus", reason: "not a project")]
        )
        var exported: LedgerBatchSummary?
        environment.onBatchProjectSummary = { batch }
        environment.onExportBatchSummary = { exported = $0 }
        model.installRowMenu(environment: environment)
        #expect(model.canSummariseProject, "a batch is possible with no other drawing open")
        model.openProjectSummary()
        let panel = try #require(model.projectSummaryPanel)
        #expect(panel.runBatch != nil && panel.exportBatch != nil)
        await panel.summariseClosedProjects()
        #expect(panel.batch == batch)
        panel.exportBatchWorkbook()
        #expect(exported == batch)
    }

    @Test("Import Recipes… in the Apply Assembly panel comes from the window and refreshes the list")
    func recipeImportFromThePanel() async throws {
        let (model, presenter, environment, tearDown) = try make()
        defer { tearDown() }
        let extra = LedgerAssemblySummary(id: UUID(), name: "Skirting", note: nil, inputs: [], lines: [])
        environment.onImportAssemblyRecipes = { presenter.availableAssemblies + [extra] }
        var exported = false
        environment.onExportAssemblyRecipes = { exported = true }
        model.installRowMenu(environment: environment)
        let first = try #require(presenter.row(at: 0)?.markupID)
        model.applyExternalSelection([first])
        model.openAssemblyPanel()
        let panel = try #require(model.assemblyPanel)
        #expect(panel.importRecipes != nil && panel.exportRecipes != nil)
        await panel.importRecipeFile()
        #expect(panel.assemblies.contains { $0.name == "Skirting" })
        #expect(panel.selectedID == extra.id, "the imported recipe is chosen")
        panel.exportRecipes?()
        #expect(exported)
    }
}

/// The mock ledger explains its rows the simple way — value text and a fixed provenance — so the
/// pane's Explain wiring can be driven without the app core.
extension MockLedgerPresenter: @retroactive LedgerExplaining {
    public func explain(_ markupIDs: Set<UUID>) async -> LedgerExplanation {
        let rows = (0..<unfilteredRowCount).compactMap { row(at: $0) }.filter { markupIDs.contains($0.markupID) }
        return LedgerExplanation(
            rows: rows.map { LedgerExplanation.Row(
                markupID: $0.markupID, subject: $0.displayValue(.subject), label: $0.displayValue(.label),
                valueText: $0.displayValue(.planArea), value: nil, provenance: "Measured on the mock sheet"
            ) },
            totals: []
        )
    }
}
