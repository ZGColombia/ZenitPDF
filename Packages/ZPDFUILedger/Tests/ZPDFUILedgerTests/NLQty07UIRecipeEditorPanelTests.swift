import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// NL-QTY-07-UI: the recipe editor, reached from the Apply Assembly panel, over the mock
/// presenter. Nothing here is put on screen: the views are hosted in views that have no window.
@MainActor
@Suite("NL-QTY-07-UI — assembly recipe editor", .ledgerTierSerialised)
struct NLQty07UIRecipeEditorPanelTests {

    static func panel(_ presenter: MockLedgerPresenter = MockLedgerPresenter()) -> LedgerAssemblyPanelModel {
        LedgerAssemblyPanelModel(presenter: presenter, markupIDs: [UUID()], locale: Locale(identifier: "sv_SE"))
    }

    @Test("New Recipe… opens the editor on a new recipe; Save writes it with its unit cost in the ledger's currency, and Apply offers it")
    func newRecipeFromThePanel() async throws {
        let presenter = MockLedgerPresenter()
        let panel = Self.panel(presenter)
        #expect(panel.canEditRecipes)
        panel.openNewRecipe()
        let editor = try #require(panel.recipeEditor)
        #expect(editor.isNew)
        #expect(editor.destination == .project, "the first place the presenter can save to")

        editor.form?.name = "Painted wall"
        editor.form?.inputs.append(.init(name: "Height", unit: .length))
        editor.form?.lines[0].name = "Paint"
        editor.form?.lines[0].formula = "Length * Height * 2"
        editor.form?.lines[0].unit = .area
        editor.form?.lines[0].unitCostText = "89,95"        // Swedish decimal comma
        #expect(editor.unitCostLabel(try #require(editor.form?.lines[0])) == "SEK per m²")
        #expect(editor.check.measuredInputs == [0, 1])
        editor.destination = .office
        #expect(editor.canSave)
        #expect(await editor.save())

        let saved = try #require(presenter.mockAssemblyRecipes.last)
        #expect(saved.store == .office)
        #expect(saved.draft.name == "Painted wall")
        #expect(saved.draft.lines[0].unitCost == DecimalQuantity(value: Decimal(string: "89.95")!, dimension: .currency("SEK")))
        #expect(saved.draft.lines[0].dimension == .area)
        #expect(editor.store == .office)
        #expect(!editor.hasUnsavedChanges)
        #expect(editor.message?.contains("Painted wall") == true)

        // Back to Apply Assembly; the mock's Apply list is fixed, the editor list is not.
        panel.closeRecipeEditor()
        #expect(panel.recipeEditor == nil)
    }

    @Test("A unit cost that is not a number, or a line the presenter refuses, blocks Save and says why")
    func invalidInputBlocksSave() async throws {
        let panel = Self.panel()
        panel.openNewRecipe()
        let editor = try #require(panel.recipeEditor)
        editor.form?.lines[0].name = "Plates"
        editor.form?.lines[0].unitCostText = "tolv kronor"
        let lineID = try #require(editor.form?.lines[0].id)
        #expect(editor.invalidUnitCosts == [lineID])
        #expect(!editor.canSave)
        editor.form?.lines[0].unitCostText = ""
        #expect(editor.canSave, "an empty unit cost prices nothing, and is allowed")
        editor.form?.lines[0].formula = " "
        #expect(editor.check.lineProblems[0] != nil)
        #expect(!editor.canSave)
        #expect(!(await editor.save()))
        editor.form?.lines[0].formula = "Length * 2"
        editor.form?.name = ""
        #expect(editor.check.refusal != nil)
        #expect(!editor.canSave)
    }

    @Test("Edit Recipe… on a built-in opens it read-only; Duplicate makes an editable copy with a new identity")
    func builtInIsReadOnly() async throws {
        let presenter = MockLedgerPresenter()
        let panel = Self.panel(presenter)
        panel.openEditRecipe()
        let editor = try #require(panel.recipeEditor)
        #expect(editor.form?.id == MockLedgerPresenter.mockBuiltInRecipe.id)
        #expect(editor.isReadOnly)
        #expect(!editor.canSave)
        #expect(!editor.canDelete)

        editor.duplicate()
        #expect(editor.isNew)
        #expect(editor.form?.id != MockLedgerPresenter.mockBuiltInRecipe.id)
        #expect(editor.form?.name == "Timber stud wall copy")
        #expect(editor.form?.lines.map(\.formula) == ["FLOOR(Length / Spacing) + 1"])
        #expect(await editor.save())
        #expect(presenter.mockAssemblyRecipes.map(\.store) == [.project])
    }

    @Test("Switching recipes never throws typing away; Revert does, on purpose")
    func unsavedChangesAreGuarded() async throws {
        let presenter = MockLedgerPresenter()
        presenter.mockAssemblyRecipes = [LedgerAssemblyRecipeEntry(
            draft: LedgerAssemblyRecipeDraft(
                id: UUID(), name: "Slab edge",
                inputs: [.init(name: "Perimeter", dimension: .length)],
                lines: [.init(name: "Formwork", formula: "Perimeter", dimension: .length)]
            ),
            store: .project
        )]
        let editor = LedgerAssemblyRecipeEditorModel(presenter: presenter, locale: Locale(identifier: "en_US"))
        let slab = presenter.mockAssemblyRecipes[0].id
        #expect(editor.select(slab))
        #expect(!editor.hasUnsavedChanges)
        editor.form?.lines[0].unitCostText = "120"
        #expect(editor.hasUnsavedChanges)
        #expect(!editor.select(MockLedgerPresenter.mockBuiltInRecipe.id))
        #expect(editor.lastFailed)
        #expect(editor.form?.id == slab, "still on the edited recipe")
        editor.newRecipe()
        #expect(editor.form?.id == slab, "New refuses too while edits are unsaved")
        editor.revert()
        #expect(!editor.hasUnsavedChanges)
        #expect(editor.form?.lines[0].unitCostText == "")
        #expect(editor.select(MockLedgerPresenter.mockBuiltInRecipe.id))
    }

    @Test("Delete takes two presses and removes the recipe from where it lives")
    func deleteTakesTwoPresses() async throws {
        let presenter = MockLedgerPresenter()
        let id = UUID()
        presenter.mockAssemblyRecipes = [LedgerAssemblyRecipeEntry(
            draft: LedgerAssemblyRecipeDraft(
                id: id, name: "Kerb",
                inputs: [.init(name: "Length", dimension: .length)],
                lines: [.init(name: "Kerb", formula: "Length", dimension: .length,
                              unitCost: DecimalQuantity(value: Decimal(string: "350.5")!, dimension: .currency("EUR")))]
            ),
            store: .office
        )]
        let editor = LedgerAssemblyRecipeEditorModel(presenter: presenter, locale: Locale(identifier: "en_US"))
        #expect(editor.select(id))
        // A stored rate keeps its own currency; the text is the locale's editing form.
        #expect(editor.form?.lines[0].unitCostText == "350.5")
        #expect(editor.unitCostLabel(try #require(editor.form?.lines[0])) == "EUR per m")
        #expect(editor.canDelete)
        #expect(!(await editor.confirmDelete()), "a single press deletes nothing")
        editor.requestDelete()
        #expect(editor.isConfirmingDelete)
        editor.cancelDelete()
        #expect(presenter.mockAssemblyRecipes.count == 1)
        editor.requestDelete()
        #expect(await editor.confirmDelete())
        #expect(presenter.mockAssemblyRecipes.isEmpty)
        #expect(editor.form == nil)
        #expect(editor.message?.contains("keep their copy") == true)
    }

    @Test("The panel and the editor build off-screen")
    func viewsHostOffScreen() throws {
        let panel = Self.panel()
        let hosting = NSHostingView(rootView: LedgerAssemblyPanel(model: panel, onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.window == nil)

        panel.openEditRecipe()
        let editorHost = NSHostingView(rootView: LedgerAssemblyPanel(model: panel, onDone: {}))
        editorHost.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        editorHost.layoutSubtreeIfNeeded()
        #expect(editorHost.window == nil)
        #expect(editorHost.fittingSize.width >= 760, "the editor replaced the panel's content")

        try #require(panel.recipeEditor).duplicate()
        let copyHost = NSHostingView(rootView: LedgerAssemblyRecipeEditor(model: try #require(panel.recipeEditor), onDone: {}))
        copyHost.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
        copyHost.layoutSubtreeIfNeeded()
        #expect(copyHost.window == nil)
        #expect(copyHost.fittingSize.height > 0)
    }
}
