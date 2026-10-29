import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Bug hunt 2 / improvements, the Inspector. Asserted on the value-level seams the panel
/// renders from, like the rest of the Inspector suites.
@MainActor
@Suite("Fix2 Inspector", .shellTierSerialised)
struct Fix2InspectorTests {

    private func measured() -> [MarkupSummary] {
        ZenitSampleProject.shared.markups.filter { !$0.measurementFields.isEmpty }
    }

    private func field(_ field: MeasurementField, metres value: Decimal, text: String, unit: String) -> MeasurementFieldSummary {
        let quantity: DecimalQuantity
        switch field.dimension {
        case .area: quantity = .squareMetres(value)
        case .count: quantity = .count(value)
        default: quantity = .metres(value)
        }
        return MeasurementFieldSummary(field: field, quantity: quantity, displayText: text, displayUnitSymbol: unit)
    }

    private func markup(kind: MeasurementKind, fields: [MeasurementFieldSummary], subject: String = "Wall") -> MarkupSummary {
        var markup = measured()[0]
        markup.measurementKind = kind
        markup.measurementFields = fields
        markup.subject = subject
        return markup
    }

    // MARK: - BH-053 / BH-288

    /// Old output: `ZPDFInspectorRow` always replaced its control with the mixed placeholder, so
    /// two arrows of different colours could never be given one colour from the panel, and
    /// `pickedColour(from: .red, current: nil)` returned nil.
    @Test("A mixed row keeps a control that handles mixed, and a deliberate pick is written")
    func mixedSelectionCanBeRestyled() {
        #expect(!ZPDFInspectorRow<EmptyView>.showsMixedPlaceholder(isMixed: true, showsContentWhenMixed: true))
        #expect(ZPDFInspectorRow<EmptyView>.showsMixedPlaceholder(isMixed: true, showsContentWhenMixed: false))
        // On the function the palette and colour panel call (T-035 removed the SwiftUI wrapper).
        let red = ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1)
        #expect(InspectorColourControl.pickedColour(red, current: nil) == red)
        #expect(InspectorColourControl.pickedColour(ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0), current: nil) == nil)
    }

    // MARK: - BH-279 / IM-024

    /// Old output: the Inspector built its summary from `selectedMarkups`, the visible subset —
    /// a selection on another page read as "Nothing selected" (count 0) while Delete still
    /// acted on `selectedMarkupIDs`.
    @Test("The Inspector's selection includes selected markups that are not visible")
    func selectionIsResolvedFromAllMarkups() throws {
        let environment = ProjectShellEnvironment.mock()
        let canvas = try #require(environment.canvas as? MockCanvasPresenter)
        let firstPage = canvas.viewport.pageID
        let elsewhere = try #require(ZenitSampleProject.shared.markups.first { $0.pageID != firstPage })
        canvas.select(markupIDs: [elsewhere.id], additive: false)
        canvas.showPage(id: firstPage)
        #expect(canvas.selectedMarkups.isEmpty, "the visible subset is empty")
        #expect(canvas.resolvedSelectedMarkups.map(\.id) == [elsewhere.id])
        #expect(InspectorSelectionSummary(markups: environment.canvas.resolvedSelectedMarkups).count == 1)
    }

    // MARK: - BH-284

    /// Old output: every colour-panel tick called `onChange`, one bulk edit per tick.
    @Test("A burst of colour picks is written once, with the last value")
    func colourBurstCoalesces() async throws {
        let coalescer = InspectorEditCoalescer<Int>(delay: .milliseconds(20))
        var applied: [Int] = []
        for value in 1...12 { coalescer.submit(value) { applied.append($0) } }
        #expect(applied.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(applied == [12])
        coalescer.submit(13) { applied.append($0) }
        coalescer.flush()
        #expect(applied == [12, 13])
        coalescer.flush()
        #expect(applied == [12, 13], "a flush with nothing pending writes nothing")
    }

    // MARK: - BH-285 / BH-800 / BH-801 / BH-802 / IM-022

    /// Old output: tabbing through a 1.333 pt width whose field shows "1.33" wrote 1.33
    /// (`commitTyped` re-parsed its own rounding); a 0.1 hairline became 0.25.
    @Test("A blur over untouched text is not an edit")
    func untouchedBlurWritesNothing() {
        let shown = InspectorNumberControl.format(1.333)
        #expect(InspectorNumberControl.commitDecision(text: shown, committedText: shown, value: 1.333, range: 0.25...48) == .none)
        let hairline = InspectorNumberControl.format(0.1)
        #expect(InspectorNumberControl.commitDecision(text: hairline, committedText: hairline, value: 0.1, range: 0.25...48) == .none)
        // A real edit still writes, clamped.
        #expect(InspectorNumberControl.commitDecision(text: "3", committedText: shown, value: 1.333, range: 0.25...48) == .write(3))
        #expect(InspectorNumberControl.commitDecision(text: "99", committedText: shown, value: 1.333, range: 0.25...48) == .write(48))
    }

    /// Old output: after ⌘Z moved the width back to 2 while the field kept focus showing "6",
    /// the field did not follow, and the blur re-applied 6.
    @Test("An undo that lands while focused is followed when nobody is typing")
    func undoWhileFocusedIsFollowed() {
        #expect(InspectorNumberControl.shouldResync(isEditing: true, text: "6", committedText: "6"))
        #expect(!InspectorNumberControl.shouldResync(isEditing: true, text: "6.", committedText: "6"))
        #expect(InspectorNumberControl.shouldResync(isEditing: false, text: "anything", committedText: "6"))
    }

    /// Old output: "nan" committed the range floor 0.25 to every selected markup; "inf" 48;
    /// "1,200.5" was read by `Double` after a comma swap as nil only by luck.
    @Test("Typed text is read by the shared grammar: non-numbers revert")
    func typedTextUsesTheSharedParser() {
        for text in ["nan", "inf", "-inf", "0x1p3", "1e400", "1,200.5", "wide"] {
            #expect(InspectorNumberControl.commitDecision(text: text, committedText: "2", value: 2, range: 0.25...48) == .revert, "\(text)")
        }
        #expect(InspectorNumberControl.commitDecision(text: "1,5", committedText: "2", value: 2, range: 0.25...48) == .write(1.5))
    }

    /// Old output: with the bulk edit still in flight, every stepper repeat computed 2 + 0.25
    /// from the stale prop and asked for 2.25 again.
    @Test("The stepper advances from the value it last asked for")
    func stepperUsesThePendingValue() {
        #expect(InspectorNumberControl.nudged(value: 2, pending: 2.25, delta: 0.25, range: 0.25...48) == 2.5)
        #expect(InspectorNumberControl.nudged(value: 2, pending: nil, delta: 0.25, range: 0.25...48) == 2.25)
        #expect(InspectorNumberControl.nudged(value: 48, pending: nil, delta: 1, range: 0.25...48) == nil)
        #expect(InspectorNumberControl.nudged(value: nil, pending: nil, delta: -1, range: 0.25...48) == 0.25,
                "a mixed selection is given the floor")
    }

    // MARK: - IM-023 / IM-211

    @Test("The locked help names no control that does not exist, and the stepper speaks a value")
    func lockedHelpAndStepperSpeech() {
        let help = InspectorAppearanceText.helpText(isEnabled: false)
        #expect(!help.contains("Status"), "old text: 'Unlock it under Status first.' — there is no unlock control there")
        #expect(help.localizedCaseInsensitiveContains("locked"))
        #expect(InspectorNumberControl.spokenValue(text: "2.5", suffix: "pt") == "2.5 pt")
        #expect(InspectorNumberControl.spokenValue(text: "", suffix: "pt") == "Mixed value")
    }

    // MARK: - BH-286 / BH-803

    /// Old output: picking "1/32" on a metric project set `activePrecision` to the fraction,
    /// which did nothing to metric numbers but flipped the ledger's subtotals to exact; an
    /// imperial project's popup showed the metric seed "0.000".
    @Test("The precision in force follows the session's unit system")
    func precisionFollowsTheSession() {
        #expect(InspectorPrecision.effective(active: .imperialFraction(.thirtySecond), lengthUnit: .metre, imperialPrecision: .sixteenth) == .decimalPlaces(3))
        #expect(InspectorPrecision.effective(active: .decimalPlaces(2), lengthUnit: .metre, imperialPrecision: .sixteenth) == .decimalPlaces(2))
        #expect(InspectorPrecision.effective(active: .decimalPlaces(3), lengthUnit: .foot, imperialPrecision: .eighth) == .imperialFraction(.eighth))
        let metricAllDecimal = InspectorPrecision.choices(forMetric: true).allSatisfy { $0.isDecimal }
        let imperialNoDecimal = InspectorPrecision.choices(forMetric: false).allSatisfy { !$0.isDecimal }
        #expect(metricAllDecimal)
        #expect(imperialNoDecimal)

        let environment = ProjectShellEnvironment.mock()
        let model = InspectorMeasurementModel(environment: environment, selection: InspectorSelectionSummary(markups: Array(measured().prefix(1))))
        model.selectPrecision(choiceID: "fraction-32")
        #expect(environment.inspectorEditing.activePrecision == .decimalPlaces(3))
    }

    /// Old output: "0.00" in every locale, beside Swedish values printed "5,04 m".
    @Test("The precision abbreviation uses the locale's decimal mark")
    func precisionAbbreviationIsLocalised() {
        #expect(InspectorPrecision.decimalPlaces(2).abbreviation(locale: Locale(identifier: "sv_SE")) == "0,00")
        #expect(InspectorPrecision.decimalPlaces(2).abbreviation(locale: Locale(identifier: "en_US")) == "0.00")
    }

    // MARK: - BH-804 / BH-287 / IM-026

    /// Old output: a perimeter tool selected first and an area second labelled the shared
    /// Perimeter row "Value"; the other order labelled it "Perimeter". W-048: asserted on the
    /// label the Markup tab draws, ``InspectorPanel/quantityLabel(for:)``.
    @Test("The Value label does not depend on click order")
    func valueLabelIsOrderIndependent() {
        let perimeter = markup(kind: .perimeter, fields: [field(.perimeter, metres: 12, text: "12.00", unit: "m")])
        let area = markup(kind: .area, fields: [
            field(.planArea, metres: 9, text: "9.00", unit: "m²"),
            field(.perimeter, metres: 12, text: "12.00", unit: "m")
        ])
        let environment = ProjectShellEnvironment.mock()
        let one = InspectorMeasurementModel(environment: environment, selection: InspectorSelectionSummary(markups: [perimeter, area])).valueRows
        let two = InspectorMeasurementModel(environment: environment, selection: InspectorSelectionSummary(markups: [area, perimeter])).valueRows
        let oneLabels = one.map(InspectorPanel.quantityLabel(for:))
        #expect(oneLabels == two.map(InspectorPanel.quantityLabel(for:)))
        #expect(oneLabels == ["Total \(MeasurementField.perimeter.displayName)"])
        #expect(!oneLabels.contains("Value"))
    }

    /// Old output: a length and an area together collapsed the section to "This selection
    /// produces no quantities." and hid the Scale Region popup.
    @Test("A mixed-kind selection with no shared field still has quantities")
    func mixedKindsStillHaveQuantities() {
        let length = markup(kind: .length, fields: [field(.planLength, metres: 3, text: "3.00", unit: "m")])
        let area = markup(kind: .area, fields: [field(.planArea, metres: 9, text: "9.00", unit: "m²")])
        let model = InspectorMeasurementModel(environment: .mock(), selection: InspectorSelectionSummary(markups: [length, area]))
        #expect(model.valueRows.isEmpty)
        #expect(model.hasAnyQuantities)
    }

    /// Old output: three lengths 1.10 / 2.20 / 3.30 m read "Multiple values".
    @Test("An additive field over a multi-selection is totalled, a slope is not")
    func additiveFieldsAreTotalled() throws {
        let lengths = [1.10, 2.20, 3.30].map { value in
            markup(kind: .length, fields: [field(.planLength, metres: Decimal(string: String(value))!, text: String(format: "%.2f", value), unit: "m")])
        }
        let summary = InspectorSelectionSummary(markups: lengths)
        #expect(summary.measurementTotalText(.planLength, locale: Locale(identifier: "en_US")) == "6.60 m")
        let rows = InspectorMeasurementModel(environment: .mock(), selection: summary).valueRows
        let row = try #require(rows.first)
        #expect(row.isTotal)
        #expect(InspectorPanel.quantityLabel(for: row) == "Total \(MeasurementField.planLength.displayName)")

        let slopes = [0.1, 0.2].map { value in
            markup(kind: .slope, fields: [MeasurementFieldSummary(field: .slopePercent, quantity: DecimalQuantity(value: Decimal(value), dimension: .ratio), displayText: "\(value)", displayUnitSymbol: "%")])
        }
        #expect(InspectorSelectionSummary(markups: slopes).measurementTotalText(.slopePercent) == nil)
        // Different display units are not silently added.
        let mixedUnits = [
            markup(kind: .length, fields: [field(.planLength, metres: 1, text: "1.00", unit: "m")]),
            markup(kind: .length, fields: [field(.planLength, metres: 1, text: "1000", unit: "mm")])
        ]
        #expect(InspectorSelectionSummary(markups: mixedUnits).measurementTotalText(.planLength) == nil)
    }

    // MARK: - IM-119

    /// Old output: the header showed `headerTitle` only — an empty line for a markup with no
    /// subject, and never the markup's type.
    @Test("The header names the markup type")
    func headerNamesTheType() {
        let unnamed = markup(kind: .length, fields: [], subject: "")
        let single = InspectorSelectionSummary(markups: [unnamed])
        #expect(single.headerLine == unnamed.kind.displayName)
        let named = InspectorSelectionSummary(markups: [markup(kind: .length, fields: [], subject: "Wall")])
        #expect(named.headerLine?.hasPrefix("Wall · ") == true)
        let one = InspectorSelectionSummary(markups: [])
        #expect(one.headerLine == nil)
    }

    // MARK: - BH-806

    /// Old output: two selected markups, one ledger row carrying "A": the row showed "A" as
    /// the shared value and `isMixed` was false.
    @Test("Custom Data with fewer ledger rows than markups is mixed")
    func customDataWithMissingRowsIsMixed() {
        #expect(InspectorPanel.customDataIsMixed(values: ["A"], rowCount: 1, selectedCount: 2))
        #expect(!InspectorPanel.customDataIsMixed(values: ["A"], rowCount: 2, selectedCount: 2))
        #expect(!InspectorPanel.customDataIsMixed(values: [], rowCount: 0, selectedCount: 2))
        #expect(InspectorPanel.customDataIsMixed(values: ["A", "B"], rowCount: 2, selectedCount: 2))
    }

    // MARK: - IM-117 / IM-118

    @Test("A refused edit produces a warning line, a landed one clears it")
    func refusalsAreSurfaced() async throws {
        #expect(InspectorStyleEditing.refusalMessage(for: .failure("The markup is locked.")) != nil)
        #expect(InspectorStyleEditing.refusalMessage(for: LedgerBulkEditReceipt(changedMarkupIDs: [UUID()])) == nil)

        let environment = ProjectShellEnvironment.mock()
        let editor = try #require(environment.ledger as? any LedgerBulkEditPresenting)
        environment.inspectorEditing.lastStyleRefusal = "stale"
        // The mock refuses locked markups since BH-772, as the engine does: a locked one
        // produces the warning, an unlocked one clears it.
        let locked = try #require(ZenitSampleProject.shared.markups.first { $0.locked }?.id)
        await InspectorStyleEditing.apply(
            LedgerBulkEditRequest(markupIDs: [locked], style: MarkupStyleEdit(lineWidth: 3)),
            with: editor, reportingTo: environment.inspectorEditing
        )
        #expect(environment.inspectorEditing.lastStyleRefusal != nil)
        let unlocked = try #require(measured().first { !$0.locked }?.id)
        await InspectorStyleEditing.apply(
            LedgerBulkEditRequest(markupIDs: [unlocked], style: MarkupStyleEdit(lineWidth: 3)),
            with: editor, reportingTo: environment.inspectorEditing
        )
        #expect(environment.inspectorEditing.lastStyleRefusal == nil)
    }

    @Test("Caption and comment commits issue one request, untouched text none")
    func captionCommits() {
        let ids: Set<UUID> = [UUID(), UUID()]
        let request = InspectorTextEditField.request(text: "North wall", current: "", column: .label, markupIDs: ids)
        #expect(request?.values[.label] == .text("North wall"))
        #expect(request?.markupIDs == ids)
        #expect(InspectorTextEditField.request(text: "North wall", current: "North wall", column: .label, markupIDs: ids) == nil)
        #expect(InspectorTextEditField.request(text: "  ", current: nil, column: .comment, markupIDs: ids) == nil,
                "an untouched mixed field never blanks every markup")
        #expect(InspectorTextEditField.request(text: "", current: "Old", column: .comment, markupIDs: ids)?.values[.comment] == .empty)
    }
}
