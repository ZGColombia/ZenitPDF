import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Loop iteration 5, area ui-workflows-ledger: V-062 (Rate Library removal has an Undo and says
/// when it fails), V-063 (a late change report never lands under a newer selection, and the
/// report is built once per open) and V-067 (Apply Assembly reads parameters through the rule
/// the Tool Library uses). Never on screen.
@MainActor
@Suite("Ledger, loop iteration 5", .ledgerTierSerialised)
struct Iter5LedgerWorkflowsFixTests {

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: posix)!
    }

    private static func entry(_ name: String) -> LedgerRateEntrySummary {
        LedgerRateEntrySummary(
            id: UUID(), name: name, basis: .area, rate: 89.5, currencyCode: "SEK",
            waste: nil, packSize: nil, costCode: "", trade: ""
        )
    }

    // MARK: - V-062

    /// Old output: one click on "−" wrote the removal through at once — no Undo, no message —
    /// and the removed item was gone from the office's library.
    @Test("V-062: Remove hides the item with an Undo; Undo brings it back without a write")
    func removeThenUndo() async throws {
        let presenter = MockLedgerPresenter()
        let gypsum = Self.entry("Gypsum 13 mm")
        let stud = Self.entry("Steel stud 70")
        presenter.mockRateEntries = [gypsum, stud]
        let model = LedgerRateLibraryModel(presenter: presenter, markupIDs: [], locale: Self.posix)
        await model.reload()

        await model.remove(gypsum.id)
        #expect(model.entries.map(\.name) == ["Steel stud 70"])
        #expect(model.pendingRemoval == gypsum)
        #expect(model.message == "Removed \u{201C}Gypsum 13 mm\u{201D}.")
        #expect(presenter.removedRateEntryIDs.isEmpty, "nothing is written while Undo is offered")

        await model.undoRemove()
        #expect(model.entries.map(\.name) == ["Gypsum 13 mm", "Steel stud 70"])
        #expect(model.pendingRemoval == nil)
        #expect(model.message == nil)
        #expect(presenter.removedRateEntryIDs.isEmpty)
        #expect(presenter.mockRateEntries.count == 2)
    }

    @Test("V-062: the removal is written by the next action, or when the panel is done")
    func removalIsCommitted() async throws {
        let presenter = MockLedgerPresenter()
        let gypsum = Self.entry("Gypsum 13 mm")
        let stud = Self.entry("Steel stud 70")
        presenter.mockRateEntries = [gypsum, stud]
        let model = LedgerRateLibraryModel(presenter: presenter, markupIDs: [UUID()], locale: Self.posix)
        await model.reload()

        // A second removal makes the first final.
        await model.remove(gypsum.id)
        await model.remove(stud.id)
        #expect(presenter.removedRateEntryIDs == [gypsum.id])
        #expect(presenter.mockRateEntries.map(\.name) == ["Steel stud 70"])
        #expect(model.entries.isEmpty)
        // Done writes the one still pending.
        #expect(await model.commitPendingRemoval())
        #expect(presenter.removedRateEntryIDs == [gypsum.id, stud.id])
        #expect(presenter.mockRateEntries.isEmpty)
        #expect(model.pendingRemoval == nil)
    }

    /// Old output: `_ = await presenter.removeRateEntry(id)` — the `false` was discarded and the
    /// panel said nothing while the item stayed in the library.
    @Test("V-062: a removal the library cannot write is reported, and the item stays listed")
    func failedRemovalIsReported() async throws {
        let presenter = MockLedgerPresenter()
        let gypsum = Self.entry("Gypsum 13 mm")
        presenter.mockRateEntries = [gypsum]
        presenter.mockRateRemovalFails = true
        let model = LedgerRateLibraryModel(presenter: presenter, markupIDs: [], locale: Self.posix)
        await model.reload()

        await model.remove(gypsum.id)
        #expect(model.entries.isEmpty)
        let committed = await model.commitPendingRemoval()
        #expect(!committed, "the panel stays open")
        #expect(model.removalFailure == "\u{201C}Gypsum 13 mm\u{201D} could not be removed from the rate library. It is still there.")
        #expect(model.entries.map(\.name) == ["Gypsum 13 mm"])

        let hosting = NSHostingView(rootView: LedgerRateLibraryPanel(model: model, onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.window == nil)
    }

    /// V-062 re-fix. Removing B writes A, removed before it; the first fix then cleared
    /// `removalFailure` unconditionally. First-fix output: `removalFailure == nil`, A back in
    /// the list with no explanation, under "Removed “B”." with an Undo.
    @Test("V-062: a refused write of the item removed before survives the next removal")
    func failedEarlierRemovalSurvivesTheNextRemoval() async throws {
        let presenter = MockLedgerPresenter()
        let gypsum = Self.entry("Gypsum 13 mm")
        let stud = Self.entry("Steel stud 70")
        let track = Self.entry("Track 70")
        presenter.mockRateEntries = [gypsum, stud, track]
        presenter.mockRateRemovalFails = true
        let model = LedgerRateLibraryModel(presenter: presenter, markupIDs: [], locale: Self.posix)
        await model.reload()

        await model.remove(gypsum.id)
        await model.remove(stud.id)
        #expect(presenter.removedRateEntryIDs == [gypsum.id], "A's write ran inside remove(B)")
        #expect(model.removalFailure == "\u{201C}Gypsum 13 mm\u{201D} could not be removed from the rate library. It is still there.")
        #expect(model.entries.map(\.name) == ["Gypsum 13 mm", "Track 70"], "A is back, B is hidden")
        #expect(model.pendingRemoval == stud)
        #expect(model.message == "Removed \u{201C}Steel stud 70\u{201D}.")

        // Undo of B puts B back and leaves A's warning alone.
        await model.undoRemove()
        #expect(model.entries.map(\.name) == ["Gypsum 13 mm", "Steel stud 70", "Track 70"])
        #expect(model.removalFailure?.contains("Gypsum 13 mm") == true)

        // A removal whose own step writes nothing, or writes successfully, clears the old warning.
        presenter.mockRateRemovalFails = false
        await model.remove(track.id)
        #expect(model.removalFailure == nil)
        await model.remove(stud.id)
        #expect(model.removalFailure == nil)
        #expect(presenter.removedRateEntryIDs == [gypsum.id, track.id])
        #expect(model.entries.map(\.name) == ["Gypsum 13 mm"])
    }

    /// V-062 re-fix, the smaller gap: the sheet closed without Done wrote the removal in
    /// `onDisappear` and dropped a `false`. First-fix output: nothing reported anywhere.
    @Test("V-062: a removal refused as the panel closes is handed to the host")
    func failedRemovalOnCloseIsReportedToTheHost() async throws {
        let presenter = MockLedgerPresenter()
        let gypsum = Self.entry("Gypsum 13 mm")
        presenter.mockRateEntries = [gypsum]
        let model = LedgerRateLibraryModel(presenter: presenter, markupIDs: [], locale: Self.posix)
        var reported: [String] = []
        model.onRemovalFailedAfterClose = { reported.append($0) }
        await model.reload()

        // Nothing pending: closing writes nothing and reports nothing.
        await model.panelClosed()
        #expect(presenter.removedRateEntryIDs.isEmpty)
        #expect(reported.isEmpty)

        presenter.mockRateRemovalFails = true
        await model.remove(gypsum.id)
        await model.panelClosed()
        #expect(presenter.removedRateEntryIDs == [gypsum.id])
        #expect(reported == ["\u{201C}Gypsum 13 mm\u{201D} could not be removed from the rate library. It is still there."])

        // A write that succeeds on close reports nothing.
        presenter.mockRateRemovalFails = false
        await model.remove(gypsum.id)
        await model.panelClosed()
        #expect(reported.count == 1)
        #expect(presenter.mockRateEntries.isEmpty)
    }

    // MARK: - V-063

    @Test("V-063: a report that finishes after a newer selection is dropped")
    func lateReportIsDropped() async throws {
        let presenter = GatedReportsPresenter()
        let older = LedgerSnapshotSummary(id: "A", name: "Bid 1", createdAt: Date(timeIntervalSince1970: 1_000), author: "", rowCount: 3)
        let newer = LedgerSnapshotSummary(id: "B", name: "Bid 2", createdAt: Date(timeIntervalSince1970: 2_000), author: "", rowCount: 3)
        presenter.base.mockSnapshots = [newer, older]
        let model = LedgerSnapshotsModel(presenter: presenter)
        await model.reload()
        #expect(model.report?.snapshotName == "Bid 2")

        presenter.gated = true
        model.selectedID = "A"
        let slow = Task { await model.selectionChanged() }
        await presenter.waitForCall(count: 2)
        model.selectedID = "B"
        let fast = Task { await model.selectionChanged() }
        await presenter.waitForCall(count: 3)
        presenter.open("B")
        await fast.value
        #expect(model.report?.snapshotName == "Bid 2")
        presenter.open("A")
        await slow.value
        // Old output: "Bid 1" — A's report, assigned last, under a picker showing B.
        #expect(model.report?.snapshotName == "Bid 2")
        #expect(model.selectedID == "B")
    }

    @Test("V-063: opening the panel builds the report once, not once per trigger")
    func reportBuiltOncePerOpen() async throws {
        let presenter = GatedReportsPresenter()
        presenter.base.mockSnapshots = [
            LedgerSnapshotSummary(id: "A", name: "Bid 1", createdAt: Date(timeIntervalSince1970: 1_000), author: "", rowCount: 3)
        ]
        let model = LedgerSnapshotsModel(presenter: presenter)
        await model.reload()
        // The picker's change handler runs after reload has already built A's report.
        await model.selectionChanged()
        // Old output: 2 — reload built it, then the onChange rebuild built it again.
        #expect(presenter.reportCalls == ["A"])

        // Take Snapshot: one build for the new selection.
        model.newName = "Bid 2"
        #expect(await model.takeSnapshot())
        await model.selectionChanged()
        #expect(presenter.reportCalls.count == 2)
        #expect(model.report?.snapshotName == "Bid 2")
    }

    @Test("V-063: a cancelled matrix build leaves the matrix alone")
    func cancelledMatrixBuildIsDropped() async throws {
        let presenter = MockLedgerPresenter()
        let model = LedgerMatrixModel(
            presenter: presenter,
            options: [.init(column: .subject, title: "Subject"), .init(column: .pageLabel, title: "Page")],
            rows: .subject, columns: .pageLabel
        )
        await model.rebuild()
        let built = model.matrix
        #expect(built != nil)
        model.rowColumn = .pageLabel
        model.columnColumn = .subject
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.rebuild()
        }
        await cancelled.value
        // Old output: the cancelled build's matrix (Page × Subject) was assigned anyway.
        #expect(model.matrix == built)
    }

    // MARK: - V-067

    @Test("V-067: Apply Assembly reads each parameter through the shared input rules")
    func assemblyParametersFollowTheSharedRule() async throws {
        let presenter = MockLedgerPresenter()
        let model = LedgerAssemblyPanelModel(
            presenter: presenter, markupIDs: [UUID()], locale: Self.posix, lengthUnit: .millimetre
        )
        let inputs = try #require(model.selected?.inputs)
        let spacing = try #require(inputs.first { $0.name == "Spacing" })
        #expect(model.unitLabel(spacing.dimension) == spacing.unitLabel(lengthUnit: .millimetre))
        #expect(model.missingParameters == LedgerAssemblySummary.Input.missingParameters(inputs, texts: [:]))
        model.parameterTexts["Spacing"] = "6e2"
        model.parameterTexts["Height"] = "two"
        #expect(model.invalidInputs == ["Height"])
        model.parameterTexts["Height"] = "2400"
        let shared = LedgerAssemblySummary.Input.quantities(
            inputs, texts: model.parameterTexts, lengthUnit: .millimetre,
            parse: { ZPDFDecimalParser.decimal($0, allowingExponent: true) }
        )
        #expect(model.parameters() == shared)
        // 6e2 mm = 0.6 m, 2 400 mm = 2.4 m.
        #expect(shared["Spacing"] == DecimalQuantity(value: Self.decimal("0.6"), dimension: .length))
        #expect(shared["Height"] == DecimalQuantity(value: Self.decimal("2.4"), dimension: .length))
    }
}

/// A snapshots presenter whose change reports finish when the test says so (V-063). Everything
/// else is the mock presenter's.
@Observable
@MainActor
final class GatedReportsPresenter: LedgerSnapshotting {

    @ObservationIgnored let base = MockLedgerPresenter()
    /// When true, each report waits for ``open(_:)`` with its snapshot id.
    @ObservationIgnored var gated = false
    /// Every report asked for, oldest first.
    @ObservationIgnored private(set) var reportCalls: [String] = []
    @ObservationIgnored private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    var columns: [LedgerColumn] { base.columns }
    var rootGroups: [LedgerGroupNode] { base.rootGroups }
    var rowCount: Int { base.rowCount }
    var contentRevision: Int { base.contentRevision }
    var grandTotals: LedgerTotals { base.grandTotals }
    var groupingColumns: [LedgerColumnID] { base.groupingColumns }
    var filter: LedgerFilterGroup { base.filter }
    var canvasFilterBehavior: LedgerCanvasFilterBehavior { base.canvasFilterBehavior }
    var selectedRowIDs: Set<UUID> { base.selectedRowIDs }
    var sortDescriptors: [LedgerSortDescriptor] { base.sortDescriptors }
    var isLoading: Bool { base.isLoading }
    func setGrouping(_ columns: [LedgerColumnID]) { base.setGrouping(columns) }
    func setFilter(_ filter: LedgerFilterGroup) { base.setFilter(filter) }
    func setCanvasFilterBehavior(_ behavior: LedgerCanvasFilterBehavior) { base.setCanvasFilterBehavior(behavior) }
    func setColumnVisible(_ visible: Bool, columnID: LedgerColumnID) { base.setColumnVisible(visible, columnID: columnID) }
    func setColumnWidth(_ width: Double, columnID: LedgerColumnID) { base.setColumnWidth(width, columnID: columnID) }
    func setColumnPinned(_ pinned: Bool, columnID: LedgerColumnID) { base.setColumnPinned(pinned, columnID: columnID) }
    func moveColumn(_ columnID: LedgerColumnID, to index: Int) { base.moveColumn(columnID, to: index) }
    func toggleGroup(id: LedgerGroupNode.ID) { base.toggleGroup(id: id) }
    func select(rowIDs: Set<UUID>, additive: Bool) { base.select(rowIDs: rowIDs, additive: additive) }
    func sort(by columnID: LedgerColumnID, ascending: Bool) { base.sort(by: columnID, ascending: ascending) }
    func totals(forGroup groupID: LedgerGroupNode.ID?) -> LedgerTotals { base.totals(forGroup: groupID) }
    func row(at index: Int) -> LedgerRow? { base.row(at: index) }
    func index(of markupID: UUID) -> Int? { base.index(of: markupID) }
    func prefetchRows(in range: Range<Int>) { base.prefetchRows(in: range) }

    func snapshots() async -> [LedgerSnapshotSummary] { await base.snapshots() }
    func takeSnapshot(named name: String) async -> LedgerBulkEditReceipt { await base.takeSnapshot(named: name) }
    /// When true, every delete reports failure and stores nothing (W-062).
    @ObservationIgnored var deleteFails = false
    func deleteSnapshot(_ snapshotID: String) async -> Bool {
        deleteFails ? false : await base.deleteSnapshot(snapshotID)
    }

    func changeReport(since snapshotID: String) async throws -> LedgerChangeReport {
        reportCalls.append(snapshotID)
        if gated { await withCheckedContinuation { gates[snapshotID] = $0 } }
        return try await base.changeReport(since: snapshotID)
    }

    /// Lets the waiting report for `snapshotID` finish.
    func open(_ snapshotID: String) {
        gates.removeValue(forKey: snapshotID)?.resume()
    }

    /// Yields until `count` reports have been asked for and the last one is waiting.
    func waitForCall(count: Int) async {
        while reportCalls.count < count || (gated && gates[reportCalls[count - 1]] == nil) {
            await Task.yield()
        }
    }
}
