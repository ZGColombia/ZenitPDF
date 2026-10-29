import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger
@testable import ZPDFUIShell

/// NL-QTY-07-UI in the docked pane: the recipe editor is reached from the ledger's Apply Assembly
/// panel, over the window's own presenter, and nothing is put on screen.
@MainActor
@Suite("NL-QTY-07-UI — recipe editor from the ledger pane", .shellTierSerialised)
struct NLQty07UIPaneRecipeTests {

    @Test("Apply Assembly… ▸ New Recipe… ▸ Save, then Done returns to Apply Assembly")
    func editorFromThePane() async throws {
        let (defaults, name) = try ShellScratchDefaults.make(prefix: "zenit.test.recipes")
        defer { ShellScratchDefaults.discard(defaults, suiteName: name) }
        let environment = ProjectShellEnvironment.mock()
        let presenter = try #require(environment.ledger as? MockLedgerPresenter)
        let model = LedgerPaneModel(presenter: presenter, preferences: LedgerPanePreferences(defaults: defaults))
        let first = try #require(presenter.row(at: 0)?.markupID)
        model.applyExternalSelection([first])
        model.openAssemblyPanel()
        let panel = try #require(model.assemblyPanel)
        #expect(panel.canEditRecipes)

        panel.openNewRecipe()
        let editor = try #require(panel.recipeEditor)
        editor.form?.name = "Skirting"
        editor.form?.lines[0].name = "Skirting board"
        editor.form?.lines[0].unitCostText = "42"
        #expect(await editor.save())
        #expect(presenter.mockAssemblyRecipes.map(\.draft.name) == ["Skirting"])
        #expect(presenter.mockAssemblyRecipes.first?.draft.lines.first?.unitCost?.value == 42)

        panel.closeRecipeEditor()
        #expect(panel.recipeEditor == nil)
        #expect(model.assemblyPanel === panel, "still in Apply Assembly")
    }
}
