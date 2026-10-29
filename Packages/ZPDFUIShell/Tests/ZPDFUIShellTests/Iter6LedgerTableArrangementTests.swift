import AppKit
import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// W-029 (appcore cycle 1): the ledger pane installs the route a job template takes to the table's
/// own column arrangement, and the arrangement it sets survives the table's next rebuild.
@Suite("Ledger table arrangement seam", .shellTierSerialised)
@MainActor
struct Iter6LedgerTableArrangementTests {

    @Test("W-029: the pane hands the presenter the table's arrangement, and what it applies outlives a rebuild")
    func paneInstallsTheTableArrangement() throws {
        let (defaults, suite) = try ShellScratchDefaults.make(prefix: "zenit.iter6.tablearrangement.tests")
        defer { ShellScratchDefaults.discard(defaults, suiteName: suite) }
        let presenter = MockLedgerPresenter()
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        model.host.controller.loadViewIfNeeded()

        // Old output: nil — a job template could only reach the presenter's columns, which the
        // table does not follow.
        let table = try #require(presenter.tableArrangement)
        #expect(table.read() == model.host.controller.columns)

        // Move the last column to the front and hide the first, as a template would.
        var arranged = table.read()
        try #require(arranged.count >= 3)
        let moved = arranged.removeLast()
        arranged.insert(moved, at: 0)
        arranged[1].visible = false
        table.apply(arranged)
        #expect(model.host.controller.columns.map(\.id) == arranged.map(\.id))
        #expect(model.host.controller.columns.map(\.visible) == arranged.map(\.visible))

        // The presenter's content changing rebuilds the table from its columns; the arrangement stays.
        model.refresh()
        #expect(model.host.controller.columns.map(\.id) == arranged.map(\.id))
        #expect(model.host.controller.columns.map(\.visible) == arranged.map(\.visible))
        #expect(table.read().map(\.id) == arranged.map(\.id))
    }
}
