import AppKit
import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The docked Quantity Ledger's two power tools, driven through the pane's own model.
///
/// Both `LedgerFilterBuilder` and `LedgerBulkEditModel` were finished, tested inside
/// `ZPDFUILedger`, and had no caller: the docked pane — the ledger the application
/// actually shows — offered neither. These tests drive `LedgerPaneModel`, which is what
/// the pane's controls are bound to, so a regression that unbinds them fails here rather
/// than in front of a user.
@Suite("Quantity Ledger pane panels", .shellTierSerialised)
@MainActor
struct LedgerPanePanelsTests {

    /// This helper had two defects, and the second was the serious one: it read
    /// `UserDefaults(suiteName: name) ?? .standard`. That fallback has never fired, but the
    /// run on which it does points a test fixture at the user's **real** preferences — shared
    /// state outside the tree, the same class that reddened
    /// `build-app-package.sh` three times in agreement with itself. There is no fallback now:
    /// a suite that cannot be created is a `#require` failure. The name is also fixed rather
    /// than a UUID, so this fixture stops adding one plist per test per run (58 of the 2 634 on
    /// a development machine were its own), which is safe because ``ShellTierSerialisation`` admits one test at
    /// a time across this whole target.
    private func makePreferences() throws -> (LedgerPanePreferences, UserDefaults, String) {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.ledgerpane.tests")
        return (LedgerPanePreferences(defaults: defaults), defaults, name)
    }

    private func makeModel() throws -> (LedgerPaneModel, MockLedgerPresenter, UserDefaults, String) {
        let presenter = MockLedgerPresenter()
        let (preferences, defaults, suite) = try makePreferences()
        let model = LedgerPaneModel(presenter: presenter, preferences: preferences)
        // The table controller builds its plan only once its view exists — in the app the
        // split item loads it. Headless, the test loads it the same way AppKit would, with
        // no window and no focus taken from whoever is using this machine.
        model.host.controller.loadViewIfNeeded()
        return (model, presenter, defaults, suite)
    }

    // MARK: Filter

    @Test("Editing the filter reaches the presenter, and the live count is over the whole ledger")
    func filterReachesThePresenter() throws {
        let (model, presenter, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }

        let total = presenter.unfilteredRowCount
        #expect(total > 0)
        #expect(model.totalCount == total)
        #expect(model.matchCount == presenter.rowCount)

        let subject = try #require(presenter.row(at: 0)).displayValue(.subject)
        model.setFilter(LedgerFilterGroup(
            id: UUID(),
            rules: [LedgerFilterRule(
                id: UUID(),
                column: .subject,
                comparison: .equals,
                operand: .text(subject)
            )]
        ))

        #expect(presenter.isFiltered)
        #expect(model.matchCount == presenter.rowCount)
        #expect(model.matchCount < total, "the filter must narrow the sample")
        // The denominator stays the whole ledger, which is the honest thing for both the
        // panel's "n of m" and every export that repeats it (QUALITY_BAR A35).
        #expect(model.totalCount == total)

        model.setFilter(LedgerFilterTreeEditor.cleared(model.filter))
        #expect(!presenter.isFiltered)
        #expect(model.matchCount == total)
    }

    @Test("The canvas behaviour control reaches the presenter")
    func canvasBehaviourReachesThePresenter() throws {
        let (model, presenter, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }

        #expect(model.canvasFilterBehavior == presenter.canvasFilterBehavior)
        model.setCanvasFilterBehavior(.hideNonMatching)
        #expect(presenter.canvasFilterBehavior == .hideNonMatching)
        #expect(model.canvasFilterBehavior == .hideNonMatching)
    }

    @Test("A named filter survives the pane being rebuilt")
    func savedFiltersPersist() throws {
        let (preferences, defaults, suite) = try makePreferences()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let presenter = MockLedgerPresenter()

        let model = LedgerPaneModel(presenter: presenter, preferences: preferences)
        #expect(model.savedFilters.filters.isEmpty)

        var store = model.savedFilters
        store.save(
            name: "Unresolved",
            filter: LedgerFilterGroup(
                id: UUID(),
                rules: [LedgerFilterRule(
                    id: UUID(),
                    column: .status,
                    comparison: .isAnyOf,
                    operand: .choices(["open"])
                )]
            )
        )
        model.savedFilters = store

        // A new pane over the same preferences — a relaunch, or the detached window —
        // finds the filter still there, with its rules intact.
        let reopened = LedgerPaneModel(presenter: MockLedgerPresenter(), preferences: preferences)
        let restored = try? #require(reopened.savedFilters.filter(named: "Unresolved"))
        #expect(restored?.name == "Unresolved")
        #expect(restored?.filter.enabledRuleCount == 1)
    }

    // MARK: Bulk edit

    @Test("The bulk-edit panel follows the table's selection, mixed values and all")
    func bulkEditFollowsSelection() throws {
        let (model, presenter, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        model.refresh()

        #expect(model.bulkEdit.rows.isEmpty, "nothing selected, nothing to edit")

        let first = try #require(presenter.row(at: 0))
        let second = try #require(presenter.row(at: 1))
        model.applyExternalSelection([first.markupID, second.markupID])

        #expect(model.bulkEdit.rows.count == 2)
        #expect(model.bulkEdit.markupIDs == [first.markupID, second.markupID])
        #expect(!model.bulkEdit.columns.isEmpty)
        // Two rows with different subjects must read as mixed, not as one of the two.
        if first.displayValue(.subject) != second.displayValue(.subject) {
            #expect(model.bulkEdit.displayState(.subject).isMixed)
        }
    }

    @Test("Apply routes the staged edits into the presenter's bulk-edit seam and reports the outcome")
    func applyRoutesThroughThePresenter() async throws {
        let (model, presenter, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        model.refresh()
        #expect(model.canBulkEdit)

        // Two unlocked rows: since BH-772 the mock refuses locked markups, as the engine does.
        let unlocked = (0..<presenter.rowCount).compactMap { presenter.row(at: $0) }.filter { !$0.locked }
        let first = try #require(unlocked.first)
        let second = try #require(unlocked.dropFirst().first)
        model.applyExternalSelection([first.markupID, second.markupID])

        model.bulkEdit.setEdit(.text("Perimeter wall"), for: .subject)
        #expect(!model.bulkEdit.summary.isEmpty)
        model.bulkEdit.apply()

        // The apply is asynchronous — the app tier's implementation awaits the command
        // bus — so the model publishes the receipt when it lands.
        var receipt = model.lastBulkEditReceipt
        for _ in 0..<200 where receipt == nil {
            await Task.yield()
            receipt = model.lastBulkEditReceipt
        }
        let landed = try #require(receipt)
        #expect(!landed.didFail, "refusal: \(landed.failureDescription ?? "")")
        #expect(landed.changedMarkupIDs == [first.markupID, second.markupID])

        let request = try #require(presenter.appliedBulkEdits.last)
        #expect(request.markupIDs == [first.markupID, second.markupID])
        #expect(request.values[.subject] == .text("Perimeter wall"))
        #expect(request.color == nil, "an untouched colour well must not recolour the selection")

        // Staged edits are cleared once applied, so the next Apply cannot repeat them.
        #expect(model.bulkEdit.summary.isEmpty)

        model.clearBulkEditReceipt()
        #expect(model.lastBulkEditReceipt == nil)
    }

    @Test("A ledger that cannot be edited says so instead of offering an inert Apply")
    func readOnlyLedgerRefuses() async throws {
        let (preferences, defaults, suite) = try makePreferences()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let model = LedgerPaneModel(presenter: ReadOnlyLedgerPresenter(), preferences: preferences)
        #expect(!model.canBulkEdit)
    }
}

/// A ledger presenter with no bulk-edit conformance: the pane must notice and disable the
/// control rather than showing an Apply button that quietly does nothing.
@MainActor
private final class ReadOnlyLedgerPresenter: LedgerPresenting {
    var columns: [LedgerColumn] = []
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

    func setGrouping(_ columns: [LedgerColumnID]) {}
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
}
