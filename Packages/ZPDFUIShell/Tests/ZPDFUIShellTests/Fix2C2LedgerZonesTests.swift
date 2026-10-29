import AppKit
import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZPDFUIShell

/// Bug hunt 2 / improvements: the Quantity Ledger pane, History and Project Zones.
@Suite("Fix2 ledger pane, history and zones", .shellTierSerialised)
@MainActor
struct Fix2C2LedgerZonesTests {

    private func makeModel(
        presenter: MockLedgerPresenter = MockLedgerPresenter(),
        rounding: LedgerRounding = .twoDigits,
        configure: (LedgerPanePreferences) -> Void = { _ in }
    ) throws -> (LedgerPaneModel, MockLedgerPresenter, UserDefaults, String) {
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2c2.tests")
        let preferences = LedgerPanePreferences(defaults: defaults)
        configure(preferences)
        let model = LedgerPaneModel(presenter: presenter, preferences: preferences, subtotalRounding: rounding)
        model.host.controller.loadViewIfNeeded()
        return (model, presenter, defaults, suite)
    }

    // MARK: - BH-294 / IM-028 / IM-121

    /// Old output: `ledger.isEmpty` (filtered rowCount 0) showed "Measure something on the page"
    /// for a filter matching none of 40 rows, and for a ledger still loading.
    @Test("No-match, loading and empty are three different states")
    func contentStates() {
        #expect(QuantityLedgerPane.contentState(rowCount: 0, unfilteredRowCount: 40, isFiltered: true, isLoading: false) == .noMatch(total: 40))
        #expect(QuantityLedgerPane.contentState(rowCount: 0, unfilteredRowCount: 0, isFiltered: false, isLoading: true) == .loading)
        #expect(QuantityLedgerPane.contentState(rowCount: 0, unfilteredRowCount: 0, isFiltered: false, isLoading: false) == .empty)
        #expect(QuantityLedgerPane.contentState(rowCount: 3, unfilteredRowCount: 40, isFiltered: true, isLoading: false) == .rows)
        #expect(QuantityLedgerPane.noMatchText(total: 40).contains("0 of 40"))
    }

    // MARK: - BH-295 / IM-214 / IM-029

    /// Old output: the model always started at `.twoDigits` whatever the session's precision.
    @Test("The pane starts at the session's subtotal rounding")
    func initialRounding() throws {
        let (model, _, defaults, suite) = try makeModel(rounding: .threeDigits)
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        #expect(model.host.controller.rounding == .threeDigits)
        let environment = ProjectShellEnvironment.mock()
        environment.inspectorEditing.activePrecision = .decimalPlaces(3)
        #expect(QuantityLedgerPane.subtotalRounding(for: environment) == .threeDigits)
    }

    /// IM-029. Old behaviour: one projection swap fired four `.onChange` refreshes, each a full
    /// plan rebuild. IM-214: a rounding change rebuilt the plan too.
    @Test("Several refresh triggers in one turn cost one rebuild; rounding costs none")
    func refreshesCoalesce() async throws {
        let (model, _, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let before = model.planRebuildCount
        for _ in 0..<4 { model.requestRefresh() }
        #expect(model.planRebuildCount == before)
        for _ in 0..<20 where model.planRebuildCount == before { await Task.yield() }
        #expect(model.planRebuildCount == before + 1)
        model.setSubtotalRounding(.fourDigits)
        #expect(model.planRebuildCount == before + 1)
        #expect(model.host.controller.rounding == .fourDigits)
    }

    // MARK: - IM-027 / BH-813 / BH-814

    /// IM-027. Old output: the presenter's grouping never moved, so "export as on screen"
    /// exported another grouping.
    @Test("The on-screen grouping reaches the presenter")
    func groupingReachesThePresenter() throws {
        let (model, presenter, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        model.setGrouping([.status])
        #expect(presenter.groupingColumns == [.status])
        #expect(!model.onScreenColumnOrder.isEmpty)
    }

    /// BH-813. Old output: Type → Per Sheet → Subject (menu) → Page (menu) → toggle off restored
    /// Type instead of Subject.
    @Test("The per-sheet toggle restores the grouping the person came from")
    func perSheetRestoresTheLatestGrouping() throws {
        let (model, _, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        model.setGrouping([.icon])
        model.toggleSheetGrouping()
        model.setGrouping([.subject])
        model.setGrouping([.pageLabel])
        model.toggleSheetGrouping()
        #expect(model.groupingColumns != [.icon], "the stale memory is gone")

        model.setGrouping([.subject])
        model.toggleSheetGrouping()
        #expect(model.isGroupedBySheet)
        model.toggleSheetGrouping()
        #expect(model.groupingColumns == [.subject])
    }

    /// BH-814. Old output: a stored unknown column grouped every row under one blank heading.
    @Test("An unknown stored grouping column is dropped")
    func unknownGroupingIsDropped() throws {
        let (model, _, defaults, suite) = try makeModel { $0.groupingColumns = [LedgerColumnID("custom.gone")] }
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        #expect(model.groupingColumns == LedgerDefaultColumns.defaultGroupingColumns)
        #expect(LedgerPaneModel.validatedGrouping([.status, LedgerColumnID("x")], known: [.status]) == [.status])
        #expect(LedgerPaneModel.validatedGrouping([], known: [.status]) == [])
    }

    // MARK: - BH-812 / BH-815

    /// BH-812. Old output: saving "site" silently replaced the existing "Site" layout.
    /// BH-815. Old output: an empty name vanished with no message; a save gave no feedback.
    @Test("Save Layout refuses a taken or empty name and confirms a save")
    func saveLayoutOutcomes() throws {
        let (model, _, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        #expect(model.saveLayout(named: "Site") != nil)
        #expect(model.layoutSaveMessage?.contains("Site") == true)
        let original = model.host.controller.layoutStore.layouts.first { $0.name == "Site" }?.id

        #expect(model.saveLayout(named: "site") == nil)
        #expect(model.layoutSaveMessage?.contains("already exists") == true)
        #expect(model.host.controller.layoutStore.layouts.first { $0.name == "Site" }?.id == original)

        #expect(model.saveLayout(named: "   ") == nil)
        #expect(model.layoutSaveMessage?.contains("needs a name") == true)
        #expect(model.pendingLayoutName == nil)

        #expect(model.saveLayout(named: "site", replacingExisting: true) != nil)
        model.clearLayoutSaveMessage()
        #expect(model.layoutSaveMessage == nil)
    }

    // MARK: - IM-122 / IM-123 / IM-215

    @Test("The totals label names a filtered subset; the close help has no empty shortcut")
    func totalsAndCloseHelp() {
        #expect(QuantityLedgerPane.totalsLabel(isFiltered: false, matchCount: 40, totalCount: 40) == "Totals")
        let filtered = QuantityLedgerPane.totalsLabel(isFiltered: true, matchCount: 12, totalCount: 40)
        #expect(filtered.contains("12") && filtered.contains("40"))
        // Old output: "Closes the pane.  brings it back, and so does the ear at the bottom edge."
        let unbound = QuantityLedgerPane.closeHelp(shortcut: nil)
        #expect(!unbound.contains("  "))
        #expect(QuantityLedgerPane.closeHelp(shortcut: "\u{2318}L").contains("\u{2318}L"))
    }

    // MARK: - History: BH-293 / BH-810 / BH-811 / IM-213

    /// Old output: markupID nil for a multi- or empty selection — the whole trail.
    @Test("Selected Markup with zero or several selected matches nothing")
    func selectedMarkupFilter() throws {
        let audit = MockLedgerPresenter()
        let filter = HistoryPaneContent.effectiveFilter(base: LedgerAuditFilter(), followsSelection: true, selection: [UUID(), UUID()])
        #expect(audit.auditEvents(matching: filter).isEmpty)
        let off = HistoryPaneContent.effectiveFilter(base: LedgerAuditFilter(), followsSelection: false, selection: [UUID()])
        #expect(off.markupID == nil)
    }

    @Test("History counts and reveal targets")
    func historyCountsAndReveal() {
        // BH-810. Old output: "1 entries".
        #expect(HistoryPaneContent.entryCountText(1) == "1 entry")
        #expect(HistoryPaneContent.entryCountText(3) == "3 entries")
        // BH-811. Old output: Reveal Markup offered on a deletion row.
        let id = UUID()
        let deleted = LedgerAuditEvent(sequence: 1, occurredAt: .distantPast, action: "markup_deleted", actor: "", markupID: id)
        let edited = LedgerAuditEvent(sequence: 2, occurredAt: .distantPast, action: "markup_modified", actor: "", markupID: id)
        #expect(HistoryPaneContent.revealableMarkupID(deleted, exists: { _ in true }) == nil)
        #expect(HistoryPaneContent.revealableMarkupID(edited, exists: { _ in false }) == nil)
        #expect(HistoryPaneContent.revealableMarkupID(edited, exists: { _ in true }) == id)
    }

    /// IM-213. Old behaviour: every body pass re-ran the audit query.
    @Test("The History query is memoised by filter and revision")
    func historyQueryIsMemoised() {
        let cache = HistoryEventCache()
        var calls = 0
        let query: (LedgerAuditFilter) -> [LedgerAuditEvent] = { _ in calls += 1; return [] }
        for _ in 0..<5 { _ = cache.events(for: LedgerAuditFilter(), revision: .init(ledger: 1, trail: 0), query: query) }
        #expect(calls == 1)
        _ = cache.events(for: LedgerAuditFilter(), revision: .init(ledger: 2, trail: 0), query: query)
        _ = cache.events(for: LedgerAuditFilter(pageLabel: "A-101"), revision: .init(ledger: 2, trail: 0), query: query)
        #expect(calls == 3)
    }

    // MARK: - Zones

    private func zone(_ name: String, parent: UUID? = nil, markups: Int = 0, id: UUID = UUID()) -> ProjectZoneSummary {
        ProjectZoneSummary(id: id, name: name, kind: .room, parentID: parent,
                           colorRGBA: ColorRGBA.Zenit.Dark.cyan, markupCount: markups)
    }

    /// BH-301 / IM-142. Old output: no UI path reached rename or re-parent; Delete was off
    /// with no reason.
    @Test("A zone is renamed and re-parented from its row")
    func renameAndReparent() {
        let building = zone("Building A")
        let typo = zone("Grund Floor", markups: 40)
        let model = ProjectZonesPanelModel(zones: [building, typo])
        var renamed: (UUID, String)?
        model.onRenameZone = { renamed = ($0, $1) }
        model.beginRename(zoneID: typo.id)
        #expect(model.renameDraft == "Grund Floor")
        model.renameDraft = "  Ground Floor "
        #expect(model.commitRename())
        #expect(renamed?.0 == typo.id && renamed?.1 == "Ground Floor")
        #expect(model.renamingZoneID == nil)

        #expect(model.parentChoices(for: typo.id).map(\.id) == [building.id])
        #expect(model.parentChoices(for: building.id).map(\.id) == [typo.id])
        #expect(ProjectZonesPanelModel.deleteTitle(markupCount: 40).contains("40"))
        #expect(ProjectZonesPanelModel.deleteTitle(markupCount: 1).contains("1 markup first"))
        #expect(ProjectZonesPanelModel.deleteTitle(markupCount: 0) == "Delete Zone")
    }

    /// BH-825 / BH-826. Old output: "Apartment 12" listed above its parent; "Zone 10" before
    /// "Zone 2".
    @Test("Zones list in tree order with a person's sort")
    func treeOrder() {
        let building = zone("Building A")
        let child = zone("Apartment 12", parent: building.id)
        let z2 = zone("Zone 2"), z10 = zone("Zone 10")
        let model = ProjectZonesPanelModel(zones: [z10, child, building, z2])
        #expect(model.ordered.map(\.name) == ["Apartment 12", "Building A", "Zone 2", "Zone 10"])
        #expect(model.treeOrdered.map(\.name) == ["Building A", "Apartment 12", "Zone 2", "Zone 10"])
    }

    /// BH-302 / BH-827. Old output: "+" during a capture replaced the draft and left the canvas
    /// polygon tool armed (no onCancelBoundaryDrawing).
    @Test("Add Zone keeps an open draft and never leaves a capture armed")
    func beginZoneKeepsTheDraft() {
        let model = ProjectZonesPanelModel()
        var cancelled = 0
        model.onBeginBoundary = {}
        model.onCancelBoundaryDrawing = { cancelled += 1 }
        model.onCreateZone = { _ in }
        model.beginZone()
        model.setDraftName("Apartment 12")
        model.beginBoundary()
        model.beginZone()
        #expect(model.draft?.name == "Apartment 12")
        #expect(model.isAwaitingBoundary, "an open draft is kept, capture included")
        // BH-304. Old output: stopping the drawing discarded the draft.
        model.stopBoundaryDrawing()
        #expect(!model.isAwaitingBoundary)
        #expect(cancelled == 1)
        #expect(model.draft?.name == "Apartment 12")
    }

    /// BH-303. Old output: Create while capturing left `isAwaitingBoundary` true and the tool
    /// armed; the next polygon hit "cannot store Project Zones yet".
    @Test("Creating the zone ends the capture")
    func commitEndsTheCapture() {
        let model = ProjectZonesPanelModel()
        var cancelled = 0
        model.onBeginBoundary = {}
        model.onCancelBoundaryDrawing = { cancelled += 1 }
        model.onCreateZone = { _ in }
        model.beginZone()
        model.beginBoundary()
        #expect(model.commitDraft())
        #expect(!model.isAwaitingBoundary)
        #expect(cancelled == 1)
    }

    /// BH-828. Old output: a parent undone while the draft was open was still forwarded.
    @Test("A vanished parent is not forwarded")
    func vanishedParent() {
        let parent = zone("Building A")
        let model = ProjectZonesPanelModel(zones: [parent])
        var created: [ProjectZoneCreation] = []
        model.onCreateZone = { created.append($0) }
        model.beginZone(parentID: parent.id)
        #expect(model.draft?.parentID == parent.id)
        model.setZones([])
        #expect(model.draft?.parentID == nil)
        #expect(model.commitDraft())
        #expect(created.first?.parentID == nil)
    }
}
