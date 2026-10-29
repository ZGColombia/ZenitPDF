import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-QTY-02 and NL-QTY-08 in the docked pane: the Column Manager opens from the pane and the
/// header menu, and grouping nests by any groupable column.
@MainActor
@Suite("Quantities — ledger pane", .shellTierSerialised)
struct NLQuantitiesPaneTests {

    private func makeModel() throws -> (LedgerPaneModel, MockLedgerPresenter, () -> Void) {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.ledgerpane")
        let presenter = MockLedgerPresenter()
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        return (model, presenter, { ShellScratchDefaults.discard(defaults, suiteName: name) })
    }

    @Test("The Column Manager opens from the pane and from the header menu, and adds a column")
    func columnManagerFromThePane() async throws {
        let (model, presenter, tearDown) = try makeModel()
        defer { tearDown() }
        #expect(model.canManageColumns)
        #expect(model.columnManager == nil)

        model.openColumnManager()
        let manager = try #require(model.columnManager)
        #expect(manager.draft == nil)
        manager.beginAdd(kind: .number)
        manager.draft?.title = "Screed"
        manager.draft?.dimension = .area
        #expect(await manager.commitDraft())
        #expect(presenter.mockColumnSpecs.map(\.title) == ["Screed"])
        model.closeColumnManager()
        #expect(model.columnManager == nil)

        // The header menu's "Add Column…" opens it straight onto a new column.
        model.host.controller.onManageColumnsRequested?(true)
        #expect(model.columnManager?.isDraftNew == true)
        model.closeColumnManager()
    }

    @Test("Grouping nests: Page then Subject then Trade, and the innermost level comes off")
    func multiLevelGrouping() throws {
        let (model, _, tearDown) = try makeModel()
        defer { tearDown() }
        let groupable = model.groupableColumns.map(\.column)
        #expect(groupable.first == .icon)
        #expect(groupable.contains(.trade), "a built-in text column groups, not only six fixed choices")
        #expect(!groupable.contains(.planArea), "a measured quantity never groups")

        model.setGrouping([.pageLabel])
        model.addGroupingLevel(.subject)
        model.addGroupingLevel(.trade)
        model.addGroupingLevel(.subject)
        #expect(model.groupingColumns == [.pageLabel, .subject, .trade], "a level is never added twice")
        #expect(model.host.controller.mode == .grouped)
        model.removeLastGroupingLevel()
        #expect(model.groupingColumns == [.pageLabel, .subject])
    }

    @Test("NL-QTY-17: a status chip filters to its rows, its count equals those rows, a second click clears it")
    func statusChips() async throws {
        let (model, presenter, tearDown) = try makeModel()
        defer { tearDown() }
        let counts = model.statusCounts
        #expect(!counts.isEmpty)
        #expect(counts.reduce(0) { $0 + $1.count } == presenter.unfilteredRowCount, "every row is under exactly one status")
        let chip = try #require(counts.first)

        model.toggleStatusChip(chip.value)
        #expect(model.isStatusChipActive(chip.value))
        #expect(model.matchCount == chip.count, "the chip's count is the number of rows it shows")
        #expect(!model.filter.isEmpty, "a chip is a real filter: the Filter button counts it")
        #expect(model.statusCounts.first { $0.value == chip.value }?.count == chip.count, "counts are over every row, not the filtered ones")

        model.toggleStatusChip(chip.value)
        #expect(!model.isStatusChipActive(chip.value))
        #expect(model.matchCount == presenter.unfilteredRowCount)
        // Glyph and words, never tint alone.
        #expect(QuantityLedgerPane.statusGlyph("open") != QuantityLedgerPane.statusGlyph("rejected"))
    }

    @Test("NL-QTY-07: Apply Assembly opens over the selected rows and needs a selection")
    func assemblyPanelFromThePane() async throws {
        let (model, presenter, tearDown) = try makeModel()
        defer { tearDown() }
        #expect(!model.canApplyAssembly, "nothing selected")
        model.openAssemblyPanel()
        #expect(model.assemblyPanel == nil)

        let first = try #require(presenter.row(at: 0)?.markupID)
        model.applyExternalSelection([first])
        #expect(model.canApplyAssembly)
        model.openAssemblyPanel()
        let panel = try #require(model.assemblyPanel)
        #expect(panel.markupIDs == [first])
        panel.parameterTexts["Spacing"] = "0.6"
        #expect(await panel.apply())
        #expect(presenter.appliedAssemblies.count == 1)
        model.closeAssemblyPanel()
        #expect(model.assemblyPanel == nil)
    }

    @Test("NL-QTY-10: placing a live summary from the pane says what happened")
    func placeSummaryNotice() async throws {
        let (model, _, tearDown) = try makeModel()
        defer { tearDown() }
        #expect(model.canPlaceSummary)
        await model.placeSummary(.quantities)
        #expect(model.paneNotice?.contains("live quantity table") == true)
        model.clearLayoutSaveMessage()
        #expect(model.paneNotice == nil)
    }

    @Test("NL-QTY-09: the summary matrix opens with the outer grouping down and Page across")
    func matrixFromThePane() async throws {
        let (model, _, tearDown) = try makeModel()
        defer { tearDown() }
        #expect(model.canShowMatrix)
        model.setGrouping([.subject])
        model.openMatrix()
        let matrix = try #require(model.matrixPanel)
        #expect(matrix.rowColumn == .subject)
        #expect(matrix.columnColumn == .pageLabel)
        await matrix.rebuild()
        #expect(matrix.matrix != nil)
        model.closeMatrix()
        #expect(model.matrixPanel == nil)
    }

    @Test("NL-QTY-15 and NL-QTY-05: the whole-project summary and the rate library open from the pane")
    func projectSummaryAndRateLibrary() async throws {
        let (model, _, tearDown) = try makeModel()
        defer { tearDown() }
        #expect(model.canSummariseProject)
        model.openProjectSummary()
        let summary = try #require(model.projectSummaryPanel)
        await summary.reload()
        #expect(summary.summary?.combined.first?.text == "12.00 m²")
        model.closeProjectSummary()
        #expect(model.canUseRateLibrary)
        model.openRateLibrary()
        #expect(model.rateLibraryPanel != nil)
        model.closeRateLibrary()
        #expect(model.canSnapshot)
        model.openSnapshots()
        #expect(model.snapshotsPanel != nil)
        model.closeSnapshots()
    }

    /// V-062 re-fix: the rate library closed by Escape or the window writes its pending
    /// removal in `onDisappear`, after the sheet (and its warning) is gone. First-fix output:
    /// the refused write was dropped and the pane said nothing.
    @Test("V-062: a rate removal refused as the sheet closes is said in the pane")
    func rateRemovalRefusedOnCloseIsSaidInThePane() async throws {
        let (model, presenter, tearDown) = try makeModel()
        defer { tearDown() }
        let gypsum = LedgerRateEntrySummary(
            id: UUID(), name: "Gypsum 13 mm", basis: .area, rate: 89.5, currencyCode: "SEK",
            waste: nil, packSize: nil, costCode: "", trade: ""
        )
        presenter.mockRateEntries = [gypsum]
        presenter.mockRateRemovalFails = true
        model.openRateLibrary()
        let panel = try #require(model.rateLibraryPanel)
        await panel.reload()
        await panel.remove(gypsum.id)
        #expect(model.paneNotice == nil)

        // The sheet's binding closes it, then the view's onDisappear runs panelClosed().
        model.closeRateLibrary()
        #expect(model.rateLibraryPanel == nil)
        await panel.panelClosed()
        #expect(presenter.removedRateEntryIDs == [gypsum.id])
        #expect(model.paneNotice == "\u{201C}Gypsum 13 mm\u{201D} could not be removed from the rate library. It is still there.")
        #expect(presenter.mockRateEntries.map(\.name) == ["Gypsum 13 mm"])
    }
}
