import AppKit
import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Fix round 2: changes other packages asked of ZPDFUIShell's ledger pane and Inspector.
@Suite("Fix2 shell cross-package requests", .shellTierSerialised)
@MainActor
struct Fix2C2CrossPackageRequestTests {

    private func makeModel() throws -> (LedgerPaneModel, MockLedgerPresenter, LedgerPanePreferences, UserDefaults, String) {
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.fix2handoff.tests")
        let preferences = LedgerPanePreferences(defaults: defaults)
        let presenter = MockLedgerPresenter()
        let model = LedgerPaneModel(presenter: presenter, preferences: preferences)
        model.host.controller.loadViewIfNeeded()
        return (model, presenter, preferences, defaults, suite)
    }

    /// BH-705: a layout store change from the header menu persists.
    @Test("A header-menu layout change is persisted")
    func layoutStoreChangePersists() throws {
        let (model, _, preferences, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        var store = model.host.controller.layoutStore
        _ = store.save(model.host.columns, name: "From the menu")
        model.host.controller.onLayoutStoreChange?(store)
        #expect(preferences.columnLayouts.layout(named: "From the menu") != nil)
    }

    /// IM-013: an inline cell edit is a one-markup bulk edit through the presenter.
    ///
    /// L-85 changed the outcome: the inline edit no longer leaves its "Changed 1 markup" under
    /// the Bulk Edit panel (old output: `lastBulkEditReceipt.changedMarkupIDs == [row]`, read by
    /// the panel the next time it opened, before anything was applied there).
    @Test("An inline edit goes through the bulk-edit seam")
    func inlineEditUsesTheBulkEditSeam() async throws {
        let (model, presenter, _, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let row = try #require((0..<presenter.rowCount).compactMap { presenter.row(at: $0) }.first { !$0.locked })
        let request = LedgerBulkEditRequest(markupIDs: [row.markupID], values: [.comment: .text("inline")])
        let hook = try #require(model.host.onCommitInlineEdit)
        hook(request)
        for _ in 0..<200 where presenter.appliedBulkEdits.isEmpty { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(presenter.appliedBulkEdits.last?.values[.comment] == .text("inline"))
        #expect(model.lastBulkEditReceipt == nil, "the Bulk Edit panel's outcome line is the panel's own")
    }

    /// IM-099: the header's sort levels reach the presenter.
    @Test("Sort levels reach the presenter")
    func sortLevelsReachThePresenter() throws {
        let (model, presenter, _, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let hook = try #require(model.host.onSortDescriptors)
        hook([LedgerSortDescriptor(column: .pageLabel, ascending: false), LedgerSortDescriptor(column: .subject, ascending: true)])
        #expect(presenter.sortDescriptors.first == LedgerSortDescriptor(column: .pageLabel, ascending: false))
    }

    /// BH-732: subtotals print in the session's display units.
    @Test("The subtotal unit policy follows the session")
    func unitPolicyFollowsTheSession() throws {
        let (model, _, _, defaults, suite) = try makeModel()
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let environment = ProjectShellEnvironment.mock()
        environment.measurement.setLengthUnit(.foot)
        let policy = QuantityLedgerPane.unitPolicy(for: environment)
        #expect(policy.length == .foot)
        model.setSubtotalUnitPolicy(policy)
        #expect(model.host.unitPolicy == policy)
    }

    /// BH-616 / BH-192: derivation labels and wording.
    @Test("Rise/drop facts have labels and a vertical slope has words")
    func derivationLabels() {
        #expect(InspectorDerivationSection.factLabel("slope.totalRiseDrop") == "Total rise/drop")
        #expect(InspectorDerivationSection.factLabel("slope.perSegmentRiseDrop") == "Rise/drop per segment")
        let vertical = LedgerDerivationFact(key: "slope.magnitude", value: "vertical")
        #expect(InspectorDerivationSection.factText(vertical) != "vertical")
        let display = LedgerDerivationFact(key: "value.planLength.display", value: "70 ft")
        #expect(InspectorDerivationSection.factText(display) == "70 ft", "shown verbatim, no unit appended")
    }
}
