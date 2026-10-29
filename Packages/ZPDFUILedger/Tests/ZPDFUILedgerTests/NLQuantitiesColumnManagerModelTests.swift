import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// NL-QTY-02: the Column Manager's model and view, over the mock presenter's column seam.
/// Nothing here is put on screen — the view is hosted off-screen and never shown.
@MainActor
@Suite("Quantities — Column Manager model", .ledgerTierSerialised)
struct NLQuantitiesColumnManagerModelTests {

    func makeModel() -> (LedgerColumnManagerModel, MockLedgerPresenter) {
        let presenter = MockLedgerPresenter()
        return (LedgerColumnManagerModel(presenter: presenter), presenter)
    }

    @Test("Adding a Choice column with three coloured options is one applied change")
    func addChoiceColumn() async throws {
        let (model, presenter) = makeModel()
        model.beginAdd(kind: .choice)
        #expect(model.isDraftNew)
        #expect(model.draft?.choices.count == 1, "a choice column starts with one option to fill in")
        #expect(!model.canCommitDraft, "no name yet")
        model.draft?.title = "Grade"
        let first = try #require(model.draft?.choices.first?.id)
        model.setDraftOptionValue(first, "A")
        model.setDraftOptionColor(first, ZenitNamedPalette.entries[2].color)
        model.addDraftOption()
        model.addDraftOption()
        let ids = model.draft!.choices.map(\.id)
        model.setDraftOptionValue(ids[1], "B")
        model.setDraftOptionValue(ids[2], "C")
        model.setDraftDefaultOption(ids[0])
        #expect(model.canCommitDraft)

        #expect(await model.commitDraft())
        #expect(model.draft == nil)
        #expect(presenter.appliedColumnChanges.count == 1)
        #expect(presenter.appliedColumnChanges[0].actionName == LedgerColumnManagerModel.addActionName)
        let spec = presenter.mockColumnSpecs[0]
        #expect(spec.title == "Grade")
        #expect(spec.choices.map(\.value) == ["A", "B", "C"])
        #expect(spec.defaultChoiceID == ids[0])
        #expect(spec.choices[0].colorRGBA == ZenitNamedPalette.entries[2].color)
        #expect(model.columns.count == 1)
        #expect(model.message?.isEmpty == false)
    }

    @Test("Money columns start in the ledger's currency; a rate basis is money per m²")
    func moneyColumnDefaults() {
        let (model, _) = makeModel()
        model.beginAdd(kind: .currency)
        #expect(model.draft?.dimension == .currency("SEK"))
        model.draft?.dimension = LedgerMoneyBasis.perArea.dimension(currencyCode: "SEK")
        #expect(model.draft?.dimension?.lengthPower == -2)
        #expect(LedgerMoneyBasis(dimension: model.draft?.dimension) == .perArea)
        model.setDraftKind(.number)
        #expect(model.draft?.dimension == nil, "a number column does not keep a currency")
    }

    @Test("Rename, move, hide and delete are each one change; a refusal is reported and changes nothing")
    func editMoveHideDelete() async {
        let (model, presenter) = makeModel()
        _ = await presenter.applyColumnSpecs([
            LedgerColumnSpec(id: .custom("a"), title: "Alpha", kind: .text),
            LedgerColumnSpec(id: .custom("b"), title: "Beta", kind: .number, dimension: .area)
        ], actionName: "seed")
        model.reload()
        model.beginEdit(.custom("a"))
        model.draft?.title = "Alpha 2"
        #expect(await model.commitDraft())
        #expect(await model.move(.custom("b"), by: -1))
        #expect(model.columns.map(\.title) == ["Beta", "Alpha 2"])
        #expect(await model.setVisible(.custom("b"), false))
        #expect(model.columns[0].isVisible == false)
        #expect(await model.delete(.custom("b")))
        #expect(model.columns.map(\.title) == ["Alpha 2"])
        #expect(presenter.appliedColumnChanges.map(\.actionName).suffix(4) == [
            LedgerColumnManagerModel.editActionName, LedgerColumnManagerModel.moveActionName,
            LedgerColumnManagerModel.hideActionName, LedgerColumnManagerModel.deleteActionName
        ])

        // Two columns called the same: refused, said, nothing changed.
        model.beginAdd(kind: .text)
        model.draft?.title = "alpha 2"
        #expect(await model.commitDraft() == false)
        #expect(model.lastChangeFailed)
        #expect(model.columns.count == 1)
        #expect(model.draft != nil, "the draft stays open so the name can be fixed")
    }

    @Test("A formula draft is checked by the presenter and offers the variables and columns to insert")
    func formulaDraft() async {
        let (model, presenter) = makeModel()
        _ = await presenter.applyColumnSpecs(
            [LedgerColumnSpec(id: .custom("r"), title: "Rate", kind: .currency, dimension: .currency("SEK"))],
            actionName: "seed"
        )
        model.reload()
        model.beginAdd(kind: .formula)
        model.draft?.title = "Cost"
        #expect(!model.canCommitDraft, "an empty formula cannot be committed")
        model.draft?.formulaSource = "Area * [Rate]"
        #expect(model.draftFormulaProblem == nil)
        #expect(model.canCommitDraft)
        #expect(model.formulaNames.contains("Area"))
        #expect(model.formulaNames.contains("UnitCost"))
        #expect(model.formulaNames.contains("[Rate]"))
    }

    @Test("The view builds off-screen with every control labelled")
    func viewHostsOffScreen() {
        let (model, _) = makeModel()
        model.beginAdd(kind: .choice)
        let hosting = NSHostingView(rootView: LedgerColumnManagerView(model: model, onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
        #expect(hosting.window == nil, "never put on screen")
    }

    @Test("The header menu offers Add Column and Manage Columns only when a host listens")
    func headerMenuItems() {
        let source = LedgerArrayRowSource(rows: LedgerFixtures.rows, columns: LedgerFixtures.columns)
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let without = LedgerColumnMenuBuilder.menu(for: controller).items.map(\.title)
        #expect(!without.contains("Add Column…"))

        var requests: [Bool] = []
        controller.onManageColumnsRequested = { requests.append($0) }
        let menu = LedgerColumnMenuBuilder.menu(for: controller)
        let add = menu.items.first { $0.title == "Add Column…" }
        let manage = menu.items.first { $0.title == "Manage Columns…" }
        #expect(add != nil && manage != nil)
        if let add { controller.requestAddColumn(add) }
        if let manage { controller.requestManageColumns(manage) }
        #expect(requests == [true, false])
    }

    @Test("NL-QTY-06: Waste and Order adds four columns in one change, beside the net quantity")
    func wasteAndOrderPreset() async {
        let (model, presenter) = makeModel()
        _ = await presenter.applyColumnSpecs(
            [LedgerColumnSpec(id: .custom("w"), title: "Waste", kind: .text)], actionName: "seed"
        )
        model.reload()
        #expect(await model.addWasteAndOrderColumns(basis: .area))
        let specs = presenter.mockColumnSpecs
        #expect(specs.map(\.title) == ["Waste", "Waste 2", "Pack size", "Gross", "Order"], "an existing name is not reused")
        #expect(specs[1].dimension == .ratio)
        #expect(specs[2].dimension == .area)
        // ADR-0039 (U-056): Pack size is left out of totals, and Order is written as a count so
        // it totals — behaviour changes, not weakenings (was `neverSums` absent and
        // "ROUNDUP([Gross] / [Pack size], 0)", a ratio that never summed).
        #expect(specs[2].neverSums)
        #expect(!specs[1].neverSums && !specs[3].neverSums && !specs[4].neverSums)
        #expect(specs[3].formulaSource == "Area * (1 + COALESCE([Waste 2], 0))")
        #expect(specs[4].formulaSource == "CONVERT(ROUNDUP([Gross] / [Pack size], 0), 1, count)")
        #expect(presenter.appliedColumnChanges.last?.actionName == LedgerColumnManagerModel.addWasteActionName)
    }
}
