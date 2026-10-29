import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// NL-QTY-07: the Apply Assembly panel over the mock presenter. Never put on screen.
@MainActor
@Suite("Quantities — assembly panel", .ledgerTierSerialised)
struct NLQuantitiesAssemblyPanelTests {

    @Test("Apply needs every free parameter; the typed values reach the presenter in SI")
    func applyNeedsParameters() async {
        let presenter = MockLedgerPresenter()
        let rows: Set<UUID> = [UUID(), UUID()]
        let model = LedgerAssemblyPanelModel(presenter: presenter, markupIDs: rows, locale: Locale(identifier: "sv_SE"))
        #expect(model.selected?.name == "Timber stud wall")
        #expect(model.missingParameters == ["Spacing"])
        #expect(!model.canApply)
        model.parameterTexts["Spacing"] = "0,6"
        model.parameterTexts["Height"] = "2,4"
        #expect(model.canApply)
        #expect(await model.apply())
        let applied = presenter.appliedAssemblies.last
        #expect(applied?.markupIDs == rows)
        #expect(applied?.parameters["Spacing"] == DecimalQuantity(value: Decimal(string: "0.6")!, dimension: .length))
        #expect(applied?.parameters["Height"]?.value == Decimal(string: "2.4")!)
        #expect(model.message?.isEmpty == false)

        model.parameterTexts["Spacing"] = "sex decimeter"
        #expect(model.invalidInputs == ["Spacing"])
        #expect(!model.canApply)

        #expect(await model.remove())
        #expect(presenter.appliedAssemblies.last?.id == nil)
    }

    @Test("The panel builds off-screen")
    func panelHostsOffScreen() {
        let model = LedgerAssemblyPanelModel(presenter: MockLedgerPresenter(), markupIDs: [UUID()])
        let hosting = NSHostingView(rootView: LedgerAssemblyPanel(model: model, onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.window == nil)
        #expect(hosting.fittingSize.height > 0)
    }
}
