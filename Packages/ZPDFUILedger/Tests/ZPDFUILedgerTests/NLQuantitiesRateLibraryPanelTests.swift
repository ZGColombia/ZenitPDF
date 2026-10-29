import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// NL-QTY-05: the rate library panel over the mock presenter. Never on screen.
@MainActor
@Suite("Quantities — rate library panel", .ledgerTierSerialised)
struct NLQuantitiesRateLibraryPanelTests {

    @Test("Paste, import, price the selection, remove")
    func lifecycle() async throws {
        let presenter = MockLedgerPresenter()
        let rows: Set<UUID> = [UUID(), UUID()]
        let model = LedgerRateLibraryModel(presenter: presenter, markupIDs: rows)
        model.pastedList = "Name;Unit;Rate\nGypsum 13 mm;m²;89,50\n"
        await model.importPasted()
        #expect(model.entries.map(\.name) == ["Gypsum 13 mm"])
        #expect(model.pastedList.isEmpty)
        #expect(model.message?.contains("1") == true)
        let entry = try #require(model.entries.first)
        await model.apply(entry.id)
        #expect(model.message?.contains("2") == true)
        await model.remove(entry.id)
        #expect(model.entries.isEmpty)
    }

    @Test("The panel builds off-screen")
    func hostsOffScreen() {
        let hosting = NSHostingView(rootView: LedgerRateLibraryPanel(
            model: LedgerRateLibraryModel(presenter: MockLedgerPresenter(), markupIDs: []), onDone: {}
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.window == nil)
    }
}
