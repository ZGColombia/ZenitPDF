import AppKit
import SwiftUI
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// Fix round 2: the ledger UX package's side of the IM-056 / BH-102 changes in ZPDFAppCore.
@Suite("Fix2 U2 cross-package requests", .ledgerTierSerialised)
@MainActor
struct Fix2U2CrossPackageRequestTests {

    @Test("IM-056 / BH-102: the Value and Unit display columns carry no sort prototype")
    func displayColumnsAreNotSortable() {
        let columns = [LedgerDefaultColumns.valueColumn(), LedgerDefaultColumns.unitColumn()] + LedgerFixtures.columns
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let prototypes = Dictionary(
            controller.outlineViewForTesting.tableColumns.map { ($0.identifier.rawValue, $0.sortDescriptorPrototype != nil) },
            uniquingKeysWith: { first, _ in first }
        )
        // Old: every column, display.value and display.unit included, had a prototype, so the
        // header showed a sort arrow for a sort the presenter refused.
        #expect(prototypes[LedgerDefaultColumns.valueColumnID.rawValue] == false)
        #expect(prototypes[LedgerDefaultColumns.unitColumnID.rawValue] == false)
        let others = prototypes.filter { !LedgerDefaultColumns.isDisplayColumn(LedgerColumnID($0.key)) }
        #expect(!others.isEmpty && others.values.allSatisfy { $0 })
    }

    @Test("IM-056 / BH-102: the status banner states a failed rebuild and a refused sort")
    func statusBanner() {
        #expect(LedgerPresenterStatusBanner.rebuildErrorText("Disk full")
                == "The ledger could not be updated: Disk full. Showing the last result.")
        var dismissed = false
        let banner = LedgerPresenterStatusBanner(
            rebuildError: "Disk full", unappliedSortMessage: "Value cannot be sorted.",
            onDismissRebuildError: { dismissed = true }
        )
        #expect(!banner.isEmpty)
        #expect(LedgerPresenterStatusBanner(rebuildError: nil, unappliedSortMessage: nil, onDismissRebuildError: {}).isEmpty)
        // Rendered headless, never in a window.
        let host = NSHostingView(rootView: banner)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
        #expect(!dismissed)
    }
}
