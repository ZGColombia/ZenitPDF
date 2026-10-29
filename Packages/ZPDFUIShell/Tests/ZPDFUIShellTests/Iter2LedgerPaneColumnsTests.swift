import AppKit
import Foundation
import Testing
@testable import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Loop iteration 2, area ui-workflows-ledger, through the docked pane's own model: a column made,
/// renamed, hidden or deleted in the Column Manager reaches the table when the manager closes
/// (S-075), the ledger reopens in the saved layout the header menu ticks (S-082), and the filter
/// panel the pane draws knows every column the chips filter on (S-078). Never on screen: the table
/// controller is loaded, not shown.
@Suite("Quantity Ledger pane, loop iteration 2", .shellTierSerialised)
@MainActor
struct Iter2LedgerPaneColumnsTests {

    /// Reuses the pane tests' scratch suite, so the Preferences census stays flat.
    private func makeModel(
        _ presenter: ColumnManagingLedgerPresenter,
        store: LedgerColumnLayoutStore? = nil
    ) throws -> (LedgerPaneModel, LedgerPanePreferences, () -> Void) {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.ledgerpane")
        let preferences = LedgerPanePreferences(defaults: defaults)
        if let store { preferences.columnLayouts = store }
        let model = LedgerPaneModel(presenter: presenter, preferences: preferences)
        return (model, preferences, { ShellScratchDefaults.discard(defaults, suiteName: name) })
    }

    /// Old output: the presenter held "Screed" and the table did not — `host.controller.columns`
    /// kept the set the pane was built with, so the rename, the hide and the delete never showed
    /// either, and a deleted column stayed on screen drawing blank cells.
    @Test("S-075: Column Manager changes reach the pane's table when the manager closes")
    func columnManagerChangesReachTheTable() async throws {
        let presenter = ColumnManagingLedgerPresenter()
        let (model, _, tearDown) = try makeModel(presenter)
        defer { tearDown() }
        let controller = model.host.controller
        controller.loadViewIfNeeded()

        model.openColumnManager(addingNew: true)
        let adding = try #require(model.columnManager)
        adding.draft?.title = "Screed"
        #expect(await adding.commitDraft())
        model.closeColumnManager()
        let id = try #require(presenter.specs.first?.id)
        #expect(controller.column(id)?.title == "Screed")
        #expect(controller.column(id)?.visible == true)
        #expect(model.host.columns.contains { $0.id == id })

        model.openColumnManager()
        let editing = try #require(model.columnManager)
        editing.beginEdit(id)
        editing.draft?.title = "Floor Screed"
        #expect(await editing.commitDraft())
        model.closeColumnManager()
        #expect(controller.column(id)?.title == "Floor Screed")

        model.openColumnManager()
        #expect(await model.columnManager?.setVisible(id, false) == true)
        model.closeColumnManager()
        #expect(controller.column(id)?.visible == false)

        model.openColumnManager()
        #expect(await model.columnManager?.delete(id) == true)
        model.closeColumnManager()
        #expect(controller.column(id) == nil)
    }

    /// Old output: the store was restored, "Status first" was ticked in the header menu, and the
    /// table opened in the default arrangement — Page first, Status hidden.
    @Test("S-082: the pane reopens in the active saved layout")
    func paneReopensInTheActiveLayout() throws {
        let presenter = ColumnManagingLedgerPresenter()
        var arranged = LedgerDefaultColumns.arranged(presenter.columns)
        let statusIndex = try #require(arranged.firstIndex { $0.id == .status })
        var status = arranged.remove(at: statusIndex)
        status.visible = true
        arranged.insert(status, at: 0)
        let layout = LedgerColumnLayout.capturing(arranged, name: "Status first")
        let store = LedgerColumnLayoutStore(layouts: [layout], activeLayoutID: layout.id)

        let (model, preferences, tearDown) = try makeModel(presenter, store: store)
        defer { tearDown() }
        let controller = model.host.controller
        controller.loadViewIfNeeded()
        #expect(controller.columns.filter(\.visible).first?.id == .status)
        #expect(model.host.columns.first?.id == .status, "the host's mirror follows")
        #expect(controller.layoutStore.activeLayoutID == layout.id)
        #expect(preferences.columnLayouts == store, "nothing was rewritten")
    }

    /// Old output (the pane passed `arranged(visibleColumns).filter(\.visible)`): with the Status
    /// chip and the Areas chip on, the filter panel showed two "column not in this project"
    /// warnings — for `status` and `planArea` — over a filter that was in fact applied, and a
    /// rule could not be written on Status at all.
    @Test("S-078: the filter panel knows the columns the chips filter on")
    func filterPanelKnowsTheChipColumns() throws {
        let presenter = ColumnManagingLedgerPresenter()
        let (model, _, tearDown) = try makeModel(presenter)
        defer { tearDown() }
        model.host.controller.loadViewIfNeeded()

        // The fixture discriminates: neither chip column is on screen in the pane's table.
        let onScreen = Set(model.host.columns.filter(\.visible).map(\.id))
        #expect(!onScreen.contains(.status))
        #expect(!onScreen.contains(.planArea))

        // The chips' own code writes the rules.
        model.toggleStatusChip("Approved")
        model.toggleKindChip(.areas)
        let rules = model.filter.rules
        #expect(rules.contains { $0.column == .status && $0.comparison == .isAnyOf && $0.operand == .choices(["Approved"]) })
        #expect(rules.contains { $0.column == .planArea && $0.comparison == .isNotEmpty })

        // The columns the pane hands its filter panel.
        let columns = model.filterColumns
        #expect(LedgerFilterDiagnostic.unappliedRules(in: model.filter, columns: columns).isEmpty)
        let offered = Set(LedgerFilterRuleRow.selectableColumns(columns, current: .pageLabel).map(\.id))
        #expect(offered.contains(.status))
        #expect(offered.contains(.planArea))
        #expect(!offered.contains(LedgerDefaultColumns.valueColumnID))
        #expect(!offered.contains(LedgerDefaultColumns.unitColumnID))
        #expect(LedgerFilterRuleRow.defaultColumn(in: columns)?.id == .pageLabel, "a new rule still starts on screen")

        // The builder the pane really draws carries those columns, not the on-screen set.
        let builder = QuantityLedgerPane.filterBuilder(for: model)
        let drawn = try #require(
            Mirror(reflecting: builder).descendant("columns") as? [LedgerColumn],
            "LedgerFilterBuilder's stored `columns` was renamed; point this test at the new name"
        )
        #expect(drawn.map(\.id) == columns.map(\.id))

        // A rule on a column the presenter truly lacks is still reported.
        var stray = model.filter
        stray.rules.append(LedgerFilterRule(id: UUID(), column: "custom.gone", comparison: .isNotEmpty, operand: .none))
        #expect(LedgerFilterDiagnostic.unappliedRules(in: stray, columns: columns)
            == [.unknownColumnNotApplied(columnName: "custom.gone")])
    }
}

/// A ledger presenter whose user columns are what the Column Manager last applied, as the
/// application presenter's are after a projection: `columns` is the built-ins plus the specs.
@MainActor
final class ColumnManagingLedgerPresenter: LedgerPresenting, LedgerColumnManaging {

    private static let builtIns: [LedgerColumn] = [
        LedgerColumn(id: .pageLabel, title: "Page", kind: .text, width: 60),
        LedgerColumn(id: .icon, title: "Type", kind: .text, width: 60),
        LedgerColumn(id: .label, title: "Label", kind: .text, width: 100, isEditable: true),
        LedgerColumn(id: .subject, title: "Subject", kind: .text, width: 160, isEditable: true),
        LedgerColumn(id: .comment, title: "Comment", kind: .text, width: 120, isEditable: true),
        LedgerColumn(id: .status, title: "Status", kind: .choice, width: 96),
        LedgerColumn(id: .perimeter, title: "Perimeter", kind: .number, dimension: .length, width: 90,
                     alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m"),
        // Off the default set, so the arrangement hides it, as the Areas chip's column is in the app.
        LedgerColumn(id: .planArea, title: "Plan Area", kind: .number, dimension: .area, width: 90,
                     alignment: .trailing, aggregate: .sum, displayUnitSymbol: "m²")
    ]

    private(set) var specs: [LedgerColumnSpec] = []

    var columns: [LedgerColumn] {
        Self.builtIns + specs.map { spec in
            LedgerColumn(
                id: spec.id, title: spec.title, kind: spec.kind, dimension: spec.dimension, width: 96,
                visible: spec.isVisible, isEditable: true, choices: spec.choices,
                formulaSource: spec.formulaSource, isUserDefined: true
            )
        }
    }
    var rootGroups: [LedgerGroupNode] = []
    var rowCount: Int { 0 }
    var contentRevision: Int { 0 }
    var grandTotals: LedgerTotals = .empty
    var groupingColumns: [LedgerColumnID] = []
    var filter = LedgerFilterGroup(id: UUID())
    var canvasFilterBehavior: LedgerCanvasFilterBehavior = .dimNonMatching
    var selectedRowIDs: Set<UUID> = []
    var sortDescriptors: [LedgerSortDescriptor] = []
    var isLoading: Bool { false }

    func setGrouping(_ columns: [LedgerColumnID]) { groupingColumns = columns }
    func setFilter(_ filter: LedgerFilterGroup) { self.filter = filter }
    func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) { canvasFilterBehavior = behavior }
    func setColumnVisible(_ visible: Bool, columnID: LedgerColumnID) {}
    func setColumnWidth(_ width: Double, columnID: LedgerColumnID) {}
    func setColumnPinned(_ pinned: Bool, columnID: LedgerColumnID) {}
    func moveColumn(_ columnID: LedgerColumnID, to index: Int) {}
    func toggleGroup(id: LedgerGroupNode.ID) {}
    func select(rowIDs: Set<UUID>, additive: Bool) { selectedRowIDs = rowIDs }
    func sort(by columnID: LedgerColumnID, ascending: Bool) {}
    func totals(forGroup groupID: LedgerGroupNode.ID?) -> LedgerTotals { .empty }
    func row(at index: Int) -> LedgerRow? { nil }
    func index(of markupID: UUID) -> Int? { nil }
    func prefetchRows(in range: Range<Int>) {}

    var userColumnSpecs: [LedgerColumnSpec] { specs }
    var defaultCurrencyCode: String { "SEK" }
    func applyColumnSpecs(_ specs: [LedgerColumnSpec], actionName: String) async -> LedgerBulkEditReceipt {
        self.specs = specs
        return LedgerBulkEditReceipt(undoActionName: actionName)
    }
    func checkFormula(_ source: String, forColumn id: LedgerColumnID?, specs: [LedgerColumnSpec]) -> String? { nil }
}
