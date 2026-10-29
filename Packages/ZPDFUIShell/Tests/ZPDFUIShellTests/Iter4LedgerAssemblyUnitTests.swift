import Foundation
import Testing
import ZPDFUILedger
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Loop iteration 4, area ui-workflows-ledger (U-064): Apply Assembly opens from the pane in
/// the pane's display length unit, so a length input reads as it does in the Tool Library.
@MainActor
@Suite("Loop iteration 4 — assembly inputs in the ledger's unit", .shellTierSerialised)
struct Iter4LedgerAssemblyUnitTests {

    @Test("U-064: in a millimetre session the panel takes lengths in mm")
    func panelTakesThePaneUnit() async throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.it4assembly")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let presenter = MockLedgerPresenter()
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        model.setSubtotalUnitPolicy(LedgerUnitPolicy(length: .millimetre))
        let first = try #require(presenter.row(at: 0)?.markupID)
        model.applyExternalSelection([first])
        model.openAssemblyPanel()
        let panel = try #require(model.assemblyPanel)
        // Old output: .metre whatever the session showed — "600" was 600 m.
        #expect(panel.lengthUnit == .millimetre)
        panel.parameterTexts["Spacing"] = "600"
        #expect(await panel.apply())
        let spacing = try #require(presenter.appliedAssemblies.last?.parameters["Spacing"])
        #expect(spacing == DecimalQuantity(value: Decimal(string: "0.6", locale: Locale(identifier: "en_US_POSIX"))!, dimension: .length))
        model.closeAssemblyPanel()
    }
}
