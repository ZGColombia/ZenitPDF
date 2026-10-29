import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The Inspector's Measurement section: Scale Region (popup), Subject
/// (editable combo), Value (read-only, geometry-driven), Precision (popup, display only).
/// The behaviour is asserted on `InspectorMeasurementModel` against the mock presenters —
/// the same seam the panel renders from.
@MainActor
@Suite("Inspector measurement section", .shellTierSerialised)
struct InspectorMeasurementTests {

    private func environmentAndSelection(
        count: Int = 1
    ) -> (ProjectShellEnvironment, InspectorSelectionSummary) {
        let environment = ProjectShellEnvironment.mock()
        // Unlocked: a locked markup's Scale Region and Subject are not editable (W-039), and
        // the sample locks every eleventh markup, the first among them.
        let measured = environment.canvas.visibleMarkups
            .filter { !$0.measurementFields.isEmpty && !$0.locked }
        let markups = Array(measured.prefix(count))
        environment.canvas.select(markupIDs: Set(markups.map(\.id)), additive: false)
        return (environment, InspectorSelectionSummary(markups: markups))
    }

    private func model(
        _ pair: (ProjectShellEnvironment, InspectorSelectionSummary)
    ) -> InspectorMeasurementModel {
        InspectorMeasurementModel(environment: pair.0, selection: pair.1)
    }

    // MARK: - Row grammar

    /// W-048: the rows used to carry a second label rule ("Value" for the primary field) that
    /// nothing drew. The label asserted here is the one the Markup tab draws.
    @Test("The section produces one value row per field, each named by the field it shows")
    func valueRowsFollowTheMockup() throws {
        let pair = environmentAndSelection()
        let rows = model(pair).valueRows
        #expect(!rows.isEmpty, "a measured markup must produce value rows")
        let primary = try #require(pair.1.markups.first?.primaryField?.field)
        let primaryRow = try #require(rows.first { $0.id == primary })
        #expect(InspectorPanel.quantityLabel(for: primaryRow) == primary.displayName)
        #expect(primaryRow.text == pair.1.measurementText(primary))
        // Every row keeps the field's own name so nothing is ambiguous.
        for row in rows {
            #expect(InspectorPanel.quantityLabel(for: row) == row.id.displayName)
        }
    }

    @Test("A selection with no quantities produces no control rows")
    func noQuantitiesNoRows() {
        let environment = ProjectShellEnvironment.mock()
        let plain = environment.canvas.visibleMarkups.filter { $0.measurementFields.isEmpty }
        let summary = InspectorSelectionSummary(markups: Array(plain.prefix(1)))
        let rows = InspectorMeasurementModel(environment: environment, selection: summary).valueRows
        #expect(rows.isEmpty)
    }

    // MARK: - Scale Region popup

    @Test("Scale Region choices start with the page default and name the document's regions")
    func scaleRegionChoices() throws {
        let pair = environmentAndSelection()
        let choices = model(pair).scaleRegionChoices
        let first = try #require(choices.first)
        #expect(first.id == InspectorMeasurementModel.pageDefaultChoiceID)
        #expect(first.name == "Page default")
        // Every non-default choice is a real region of the document.
        let regionNames = Set(pair.0.document.scaleRegions.map(\.name))
        for choice in choices.dropFirst() {
            #expect(regionNames.contains(choice.name), "unknown region choice \(choice.name)")
        }
    }

    @Test("The current choice reflects the markup's region, or the page default without one")
    func currentScaleRegionChoice() throws {
        let environment = ProjectShellEnvironment.mock()
        let withRegion = environment.canvas.visibleMarkups
            .first { $0.scaleRegionName != nil && !$0.measurementFields.isEmpty }
        if let withRegion {
            let summary = InspectorSelectionSummary(markups: [withRegion])
            let model = InspectorMeasurementModel(environment: environment, selection: summary)
            let region = try #require(environment.document.scaleRegions.first {
                $0.name == withRegion.scaleRegionName
            })
            #expect(model.currentScaleRegionChoiceID == region.id.uuidString)
        }
        let without = try #require(environment.canvas.visibleMarkups.first {
            $0.scaleRegionName == nil && !$0.measurementFields.isEmpty
        })
        let summary = InspectorSelectionSummary(markups: [without])
        let model = InspectorMeasurementModel(environment: environment, selection: summary)
        #expect(model.currentScaleRegionChoiceID == InspectorMeasurementModel.pageDefaultChoiceID)
    }

    @Test("Picking a region fires the hook with the selection and the region's identity")
    func scaleRegionEditFiresTheHook() throws {
        let pair = environmentAndSelection()
        var received: (ids: Set<UUID>, region: UUID?)?
        pair.0.inspectorEditing.onAssignScaleRegion = { ids, region in
            received = (ids, region)
        }
        let region = try #require(pair.0.document.scaleRegions.first)
        model(pair).selectScaleRegion(choiceID: region.id.uuidString)
        let landed = try #require(received)
        #expect(landed.ids == Set(pair.1.markups.map(\.id)))
        #expect(landed.region == region.id)

        // The page default travels as nil, and re-picking the current choice is inert.
        received = nil
        model(pair).selectScaleRegion(choiceID: InspectorMeasurementModel.pageDefaultChoiceID)
        if pair.1.common(\.scaleRegionName) ?? nil == nil {
            #expect(received == nil, "re-picking the current choice must be inert")
        } else {
            #expect(received?.region == nil)
        }
        // The mixed marker never fires an edit.
        received = nil
        model(pair).selectScaleRegion(choiceID: InspectorMeasurementModel.mixedChoiceID)
        #expect(received == nil)
    }

    // MARK: - Subject combo

    @Test("Committing a subject fires the hook trimmed; empty and unchanged edits are inert")
    func subjectCommitRules() throws {
        let pair = environmentAndSelection()
        var received: (ids: Set<UUID>, subject: String)?
        pair.0.inspectorEditing.onEditSubject = { ids, subject in
            received = (ids, subject)
        }
        let model = model(pair)

        model.commitSubject("  Betongpelare  ")
        let landed = try #require(received)
        #expect(landed.subject == "Betongpelare", "whitespace must be trimmed before it lands")
        #expect(landed.ids == Set(pair.1.markups.map(\.id)))

        received = nil
        model.commitSubject("   ")
        #expect(received == nil, "an empty subject must never blank the selection")

        received = nil
        model.commitSubject(model.subjectText)
        #expect(received == nil, "an unchanged subject is not an edit")
    }

    @Test("Subject suggestions are the page's existing subjects, distinct and sorted")
    func subjectSuggestions() {
        let pair = environmentAndSelection()
        let suggestions = model(pair).subjectSuggestions
        #expect(!suggestions.isEmpty)
        #expect(Set(suggestions).count == suggestions.count, "duplicates in the combo menu")
        #expect(suggestions == suggestions.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }

    // MARK: - Precision popup

    @Test("The popup offers metric decimals and the imperial fractions, 1/32 included")
    func precisionChoices() {
        let ids = InspectorPrecision.choices.map(\.id)
        #expect(ids.contains("decimals-0") && ids.contains("decimals-3"))
        #expect(ids.contains("fraction-32"), "the mockup's 1/32 must be a choice")
        let fraction = InspectorPrecision.imperialFraction(.thirtySecond)
        #expect(fraction.abbreviation == "1/32")
        #expect(Set(ids).count == ids.count, "picker identities must be unique")
    }

    @Test("Precision changes display formatting only: stored SI is bit-identical afterwards")
    func precisionNeverTouchesStoredSI() throws {
        let pair = environmentAndSelection(count: 2)
        let model = model(pair)
        var decimalHook: Int?
        pair.0.inspectorEditing.onSetDecimalPrecision = { decimalHook = $0 }

        let storedSIBefore = pair.0.canvas.selectedMarkups
            .flatMap { $0.measurementFields.map(\.quantity) }
        #expect(!storedSIBefore.isEmpty, "the selection must carry SI values or this proves nothing")

        // The imperial arm routes through the measurement presenter's display setting.
        model.selectPrecision(choiceID: "fraction-32")
        #expect(pair.0.measurement.imperialPrecision == .thirtySecond)
        // BH-286: the fraction is the imperial setting only; the metric precision the
        // ledger's subtotals follow is left alone.
        #expect(pair.0.inspectorEditing.activePrecision == .decimalPlaces(3))

        // The metric arm routes through the display hook.
        model.selectPrecision(choiceID: "decimals-2")
        #expect(decimalHook == 2)
        #expect(pair.0.inspectorEditing.activePrecision == .decimalPlaces(2))

        let storedSIAfter = pair.0.canvas.selectedMarkups
            .flatMap { $0.measurementFields.map(\.quantity) }
        #expect(storedSIAfter == storedSIBefore, "precision must never touch a stored SI value")
    }

    @Test("The environment carries the inspector edit surface, unwired by default")
    func editSurfaceExists() {
        let environment = ProjectShellEnvironment.mock()
        #expect(environment.inspectorEditing.onEditSubject == nil)
        #expect(environment.inspectorEditing.onAssignScaleRegion == nil)
        #expect(environment.inspectorEditing.activePrecision == .decimalPlaces(3))
    }
}
