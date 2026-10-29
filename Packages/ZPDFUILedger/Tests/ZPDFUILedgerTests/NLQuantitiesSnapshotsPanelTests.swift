import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// NL-QTY-16: the snapshots panel over the mock presenter. Never on screen.
@MainActor
@Suite("Quantities — snapshots panel", .ledgerTierSerialised)
struct NLQuantitiesSnapshotsPanelTests {

    @Test("Take, list, report, delete")
    func lifecycle() async {
        let presenter = MockLedgerPresenter()
        let model = LedgerSnapshotsModel(presenter: presenter)
        await model.reload()
        #expect(model.snapshots.isEmpty)
        model.newName = "Bid 1"
        #expect(await model.takeSnapshot())
        #expect(model.snapshots.map(\.name) == ["Bid 1"])
        #expect(model.selectedID == model.snapshots.first?.id)
        #expect(model.report?.snapshotName == "Bid 1")
        #expect(model.newName.isEmpty)
        // Delete takes two presses since W-062: the first asks, the second deletes.
        model.requestDelete()
        #expect(model.snapshots.map(\.name) == ["Bid 1"])
        #expect(await model.confirmDelete())
        #expect(model.snapshots.isEmpty)
        #expect(model.report == nil)
        #expect(LedgerSnapshotsModel.kindTitle(.removed) == "Removed")
    }

    @Test("The panel builds off-screen")
    func hostsOffScreen() {
        let hosting = NSHostingView(rootView: LedgerSnapshotsPanel(model: LedgerSnapshotsModel(presenter: MockLedgerPresenter()), onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 460)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.window == nil)
    }
}
