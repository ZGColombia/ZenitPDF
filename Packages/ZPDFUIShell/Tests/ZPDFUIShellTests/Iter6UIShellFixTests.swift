import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

// Regression tests for the quality loop's iteration-6 "uishell" list.
// Every test names its item and
// states what the old code produced. No window is built.

@MainActor
@Suite("Iteration 6 uishell fixes", .shellTierSerialised)
struct Iter6UIShellFixTests {

    private static let english = Locale(identifier: "en_US")

    /// The `index`th measured sample markup, given one Plan Area field, a page and a repeat
    /// count. Distinct indices give distinct identities.
    private func area(
        _ index: Int, squareMetres: Decimal, text: String, repeats: Int? = nil, pageID: UUID? = nil, locked: Bool = false
    ) throws -> MarkupSummary {
        let measured = ZenitSampleProject.shared.markups.filter { !$0.measurementFields.isEmpty }
        try #require(measured.count > index)
        var markup = measured[index]
        markup.measurementKind = .area
        markup.measurementFields = [MeasurementFieldSummary(
            field: .planArea, quantity: .squareMetres(squareMetres), displayText: text, displayUnitSymbol: "m²"
        )]
        markup.repeatCount = repeats
        markup.locked = locked
        markup.scaleRegionName = nil
        if let pageID { markup.pageID = pageID }
        return markup
    }

    // MARK: - W-039: one lock rule for Scale Region, Subject and Repeat

    /// Old output: `selectScaleRegion` and `commitSubject` fired their hooks for a locked
    /// markup (one refused command and one warning each), and the three controls were live.
    @Test("W-039: a locked selection's Scale Region, Subject and Repeat are off and fire nothing")
    func lockedSelectionEditsNothing() throws {
        let environment = ProjectShellEnvironment.mock()
        var assigned = 0
        var subjects = 0
        environment.inspectorEditing.onAssignScaleRegion = { _, _ in assigned += 1 }
        environment.inspectorEditing.onEditSubject = { _, _ in subjects += 1 }

        let locked = try area(0, squareMetres: 12, text: "12.00", locked: true)
        let free = try area(1, squareMetres: 10, text: "10.00")
        let model = InspectorMeasurementModel(
            environment: environment, selection: InspectorSelectionSummary(markups: [free, locked])
        )
        #expect(!model.canEdit, "old output: the controls had no lock gate")
        #expect(model.disabledReason == InspectorPanel.lockedMarkupReason)
        model.selectScaleRegion(choiceID: InspectorMeasurementModel.pageDefaultChoiceID)
        model.selectScaleRegion(choiceID: UUID().uuidString)
        model.commitSubject("Subject W-039")
        #expect(assigned == 0, "old output: 2 refused Scale Region commands")
        #expect(subjects == 0, "old output: 1 refused subject edit")

        // The same selection without the lock edits as before.
        let open = InspectorMeasurementModel(
            environment: environment, selection: InspectorSelectionSummary(markups: [free])
        )
        #expect(open.canEdit)
        #expect(open.disabledReason == nil)
        open.commitSubject("Subject W-039")
        #expect(subjects == 1)

        // The one rule, and the one wording the zone popup already used.
        #expect(InspectorSelectionSummary(markups: [free, locked]).includesLockedMarkup)
        #expect(!InspectorSelectionSummary(markups: [free]).includesLockedMarkup)
        #expect(InspectorPanel.zoneDisabledReason(InspectorSelectionSummary(markups: [locked]), wired: true)
            == InspectorPanel.lockedMarkupReason)
    }

    /// Old output: a refused ask stayed in flight — the stepper read ×2 for a markup stored at
    /// ×1, and the next click asked for 3, refused again.
    @Test("W-039: a refused repeat ask leaves the stepper; the next click steps from the stored count")
    func refusedRepeatAskIsDropped() {
        var inFlight = InspectorStepsInFlight<Int>()
        #expect(InspectorRepeatStepper.click(delta: 1, count: 1, inFlight: &inFlight) == 2)
        #expect(inFlight.last == 2)
        InspectorRepeatStepper.answered(false, inFlight: &inFlight)
        #expect(inFlight.last == nil, "old output: 2, shown as ×2")
        #expect(InspectorRepeatStepper.click(delta: 1, count: 1, inFlight: &inFlight) == 2, "old output: 3")

        // A landed ask is left to the refresh, as before (V-043).
        InspectorRepeatStepper.answered(true, inFlight: &inFlight)
        #expect(inFlight.last == 2)
    }

    // MARK: - W-040: the Inspector's total counts repeats as the ledger does

    /// A 12 m² room marked ×6 and a 10 m² room: ledger rows 72 and 10, subtotal 82 m².
    /// Hand-derived: 12 × 6 + 10 = 82 m²; 82 ÷ 0.09290304 m²/ft² = 882.6406… → 882.64 ft².
    /// Old output: "22.00 m²" and "236.81 ft²" (22 ÷ 0.09290304 = 236.806…).
    @Test("W-040: a multi-selection total multiplies each markup by its repeat count")
    func totalCountsRepeats() throws {
        let repeated = try area(0, squareMetres: 12, text: "12.00", repeats: 6)
        let plain = try area(1, squareMetres: 10, text: "10.00")
        let summary = InspectorSelectionSummary(markups: [repeated, plain])
        #expect(summary.measurementTotalText(.planArea, locale: Self.english) == "82.00 m²", "old output: 22.00 m²")
        #expect(summary.summedQuantity(.planArea) == .squareMetres(82))
        #expect(
            InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: true, in: summary, locale: Self.english) == "882.64 ft²",
            "old output: 236.81 ft²"
        )
        // A count below one or none reads as once, the ledger's rule.
        #expect(InspectorSelectionSummary.repetitions(plain) == 1)
        #expect(InspectorSelectionSummary.repetitions(repeated) == 6)
        var zero = plain
        zero.repeatCount = 0
        #expect(InspectorSelectionSummary.repetitions(zero) == 1)
    }

    /// One repeated markup shows its own one-instance value with the multiplier beside it — the
    /// ledger row multiplies it — and says the multiplier to VoiceOver.
    @Test("W-040: one repeated markup's value row carries ×6, restated per instance")
    func singleRepeatedMarkupShowsItsMultiplier() throws {
        let repeated = try area(0, squareMetres: 12, text: "12.00", repeats: 6)
        let summary = InspectorSelectionSummary(markups: [repeated])
        let rows = InspectorMeasurementModel(environment: .mock(), selection: summary).valueRows
        let row = try #require(rows.first)
        #expect(row.text == "12.00 m²")
        #expect(row.repetition == "×6")
        #expect(!row.isTotal)
        // Hand-derived: 12 ÷ 0.09290304 = 129.1669… → 129.17 ft², the one instance.
        #expect(InspectorMarkupFormatting.secondaryText(for: .planArea, isTotal: row.isTotal, in: summary, locale: Self.english) == "129.17 ft²")
        #expect(InspectorQuantityRow.spokenValue(primary: row.text, secondary: "129.17 ft²", repetition: row.repetition)
            == "12.00 m² ×6, 129.17 ft²")
        // An unrepeated markup carries no badge.
        let once = try area(1, squareMetres: 12, text: "12.00")
        #expect(InspectorMeasurementModel(environment: .mock(), selection: InspectorSelectionSummary(markups: [once]))
            .valueRows.first?.repetition == nil)
    }

    // MARK: - W-041: a selection over several sheets is offered no region

    /// Old output: every region of the document was offered (the mock has regions on two pages),
    /// and the engine refused each for a markup on another sheet with a raw-UUID warning.
    @Test("W-041: markups on two sheets are offered only Page default, with the reason")
    func multiSheetSelectionOffersOnlyThePageDefault() throws {
        let environment = ProjectShellEnvironment.mock()
        let pages = environment.document.pages
        try #require(pages.count >= 3)
        try #require(environment.document.scaleRegions.count >= 2, "the mock has regions to wrongly offer")
        let first = try area(0, squareMetres: 12, text: "12.00", pageID: pages[0].id)
        let third = try area(1, squareMetres: 10, text: "10.00", pageID: pages[2].id)

        let model = InspectorMeasurementModel(
            environment: environment, selection: InspectorSelectionSummary(markups: [first, third])
        )
        #expect(model.scaleRegionChoices.map(\.id) == [InspectorMeasurementModel.pageDefaultChoiceID],
                "old output: Page default plus every region in the document")
        #expect(model.currentScaleRegionChoiceID == InspectorMeasurementModel.pageDefaultChoiceID)
        #expect(model.scaleRegionNote != nil)

        // Each in a region of the same name on its own sheet: two regions, so the popup says
        // the selection disagrees rather than naming a region it does not offer.
        var named = [first, third]
        for index in named.indices { named[index].scaleRegionName = "Basement" }
        let mixed = InspectorMeasurementModel(environment: environment, selection: InspectorSelectionSummary(markups: named))
        #expect(mixed.isScaleRegionMixed)
        #expect(mixed.currentScaleRegionChoiceID == InspectorMeasurementModel.mixedChoiceID)
        #expect(mixed.scaleRegionChoices.map(\.id)
            == [InspectorMeasurementModel.pageDefaultChoiceID, InspectorMeasurementModel.mixedChoiceID])

        // One sheet still offers that sheet's regions, with no note.
        let onePage = InspectorMeasurementModel(
            environment: environment, selection: InspectorSelectionSummary(markups: [first])
        )
        #expect(onePage.scaleRegionNote == nil)
        let ownRegions = environment.document.scaleRegions(onPage: pages[0].id).map(\.id.uuidString)
        #expect(Array(onePage.scaleRegionChoices.dropFirst().map(\.id)) == ownRegions)
    }

    // MARK: - W-042: Custom Data reads the stored values whatever the filter

    /// Old output: the filtered-out markup's Waste Factor read "—" (no row, through the
    /// filtered `rows(withIDs:)`).
    @Test("W-042: a selected markup the ledger filter hides still shows its custom values")
    func customDataIgnoresTheLedgerFilter() throws {
        let environment = ProjectShellEnvironment.mock()
        let presenter = try #require(environment.ledger as? MockLedgerPresenter)
        let all = (0..<presenter.rowCount).compactMap { presenter.row(at: $0) }
        let kept = try #require(all.first)
        let hidden = try #require(all.first {
            $0.displayValue(.subject) != kept.displayValue(.subject)
                && !$0.displayValue(ZenitSampleProject.wasteFactorColumn).isEmpty
        })
        presenter.setFilter(LedgerFilterGroup(id: UUID(), rules: [LedgerFilterRule(
            id: UUID(), column: .subject, comparison: .equals, operand: .text(kept.displayValue(.subject))
        )]))
        #expect(presenter.rows(withIDs: [hidden.markupID]).isEmpty, "the filter hides the row")
        #expect(presenter.unfilteredRows(withIDs: [hidden.markupID]).first?.matchesFilter == false)

        let entries = InspectorPanel.customDataEntries(ledger: presenter, markupIDs: [hidden.markupID])
        let waste = try #require(entries.first { $0.column.id == ZenitSampleProject.wasteFactorColumn })
        #expect(!waste.isMixed)
        #expect(waste.text == hidden.displayValue(ZenitSampleProject.wasteFactorColumn), "old output: —")
        #expect(waste.text != InspectorAppearanceText.none)
    }

    // MARK: - W-044: Move Down never moves a sheet up

    /// [A B C D E] with A and E. Old output: target 1, [B A E C D] — E from fifth to third.
    @Test("W-044: Move Down on a scattered selection lands after its last member")
    func moveDownNeverMovesASheetUp() throws {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let order = [a, b, c, d, e]
        let target = try #require(NavigatorArrangeAction.moveDown.target(moving: [a, e], in: order))
        #expect(target == 3, "old output: 1")
        let moved = NavigatorArrangeAction.reordered(order, moving: [a, e], to: target)
        #expect(moved == [b, c, d, a, e], "old output: [B A E C D]")
        for id in [a, e] {
            let before = try #require(order.firstIndex(of: id))
            let after = try #require(moved.firstIndex(of: id))
            #expect(after >= before, "no selected sheet moves up")
        }
        // [A B C D E] with A and C: one place after C, past D.
        let gathered = try #require(NavigatorArrangeAction.moveDown.target(moving: [a, c], in: order))
        #expect(NavigatorArrangeAction.reordered(order, moving: [a, c], to: gathered) == [b, d, a, c, e])
        // A contiguous block keeps the one-place rule, and a block already last stays put.
        #expect(NavigatorArrangeAction.moveDown.target(moving: [b, c], in: order) == 2)
        #expect(NavigatorArrangeAction.moveDown.target(moving: [d, e], in: order) == nil)
    }

    // MARK: - W-047: one search field, one Escape rule, one clear rule

    /// Old output: the canvas bar's own field took Escape to drop focus only, leaving the query
    /// and the hits; the design system's field had no way to clear more than its text.
    @Test("W-047: Escape clears through the owner's clear, as the clear button does")
    func escapeUsesTheOwnersClear() {
        var query = "screed"
        var cleared = 0
        let binding = Binding(get: { query }, set: { query = $0 })
        let escape = ZPDFSearchField.exitCommand(text: binding, onClear: {
            cleared += 1
            query = ""
        })
        #expect(escape != nil)
        escape?()
        #expect(cleared == 1)
        #expect(query.isEmpty)
        #expect(ZPDFSearchField.exitCommand(text: binding, onClear: { cleared += 1 }) == nil,
                "nothing to clear: the Escape goes on to the panel")

        // Without an owner's clear, the text is emptied, as before (V-049).
        query = "RFI"
        ZPDFSearchField.exitCommand(text: binding)?()
        #expect(query.isEmpty)
        #expect(cleared == 1)
    }
}
